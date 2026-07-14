#!/usr/bin/env python3
"""Report Rust definitions with an exact rust-analyzer reference count.

The result is a workspace-hygiene signal, not a compiler-verified usage or
public-API guarantee. Downstream users outside the analyzed workspace are not
visible to the default reference count.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from typing import Any
import urllib.parse


FUNCTION_SYMBOL_KINDS = {6: "method", 12: "function"}
MODULE_SYMBOL_KIND = 2
SUPPORTED_KINDS = {
    "enum",
    "function",
    "method",
    "struct",
    "trait",
    "type-alias",
    "union",
}
TYPE_KEYWORDS = {
    "enum": "enum",
    "struct": "struct",
    "trait": "trait",
    "type": "type-alias",
    "union": "union",
}
SKIP_DIRS = {
    ".cache",
    ".direnv",
    ".git",
    ".mypy_cache",
    ".pytest_cache",
    "target",
}
VISIBILITY_PATTERN = re.compile(
    r"\b(?P<visibility>pub(?:\s*\([^)]*\))?)\s+"
    r"(?:(?:async|const|unsafe)\s+)*"
    r"(?:extern\s+(?:\"[^\"]+\"\s+)?)?"
    r"(?:fn|enum|struct|trait|type|union)\s*$",
    re.DOTALL,
)


@dataclass(frozen=True)
class Location:
    path: str
    line: int
    column: int
    snippet: str


@dataclass(frozen=True)
class Candidate:
    name: str
    kind: str
    visibility: str
    definition: Location
    uri: str
    position: dict[str, int]


class LspError(RuntimeError):
    def __init__(self, method: str, error: dict[str, Any]) -> None:
        self.method = method
        self.code = error.get("code")
        self.message = error.get("message", repr(error))
        super().__init__(f"{method} failed: {self.message}")


class LspClient:
    def __init__(
        self,
        command: str,
        root: Path,
        request_timeout: float,
        verbose: bool,
    ) -> None:
        self.root = root
        self.request_timeout = request_timeout
        self.verbose = verbose
        self._next_id = 1
        self._messages: queue.Queue[dict[str, Any] | BaseException] = queue.Queue()
        self._pending: dict[int, dict[str, Any]] = {}
        self._stderr: list[str] = []
        self._stderr_lock = threading.Lock()
        self._process = subprocess.Popen(
            [command],
            cwd=root,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if self._process.stdin is None or self._process.stdout is None:
            raise RuntimeError("failed to open rust-analyzer pipes")

        self._stdout_thread = threading.Thread(
            target=self._read_stdout,
            name="rust-analyzer-stdout",
            daemon=True,
        )
        self._stderr_thread = threading.Thread(
            target=self._read_stderr,
            name="rust-analyzer-stderr",
            daemon=True,
        )
        self._stdout_thread.start()
        self._stderr_thread.start()

        try:
            self._initialize()
        except Exception:
            self.close()
            raise

    def _initialize(self) -> None:
        root_uri = path_to_uri(self.root)
        self.request(
            "initialize",
            {
                "processId": os.getpid(),
                "rootUri": root_uri,
                "workspaceFolders": [{"uri": root_uri, "name": self.root.name}],
                "capabilities": {
                    "general": {"positionEncodings": ["utf-16"]},
                    "textDocument": {
                        "documentSymbol": {
                            "hierarchicalDocumentSymbolSupport": True,
                        },
                        "references": {},
                    },
                    "workspace": {
                        "configuration": True,
                        "workspaceFolders": True,
                    },
                },
                "clientInfo": {
                    "name": "rust-analyzer-references",
                    "version": "0.1.0",
                },
            },
        )
        self.notify("initialized", {})

    def close(self) -> None:
        if self._process.poll() is not None:
            return
        try:
            self.request("shutdown", None)
            self.notify("exit", None)
        except Exception:
            self._process.terminate()
        try:
            self._process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self._process.kill()

    def notify(self, method: str, params: Any) -> None:
        message: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self._send(message)

    def request(self, method: str, params: Any) -> Any:
        request_id = self._next_id
        self._next_id += 1
        message: dict[str, Any] = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
        }
        if params is not None:
            message["params"] = params
        self._send(message)

        deadline = time.monotonic() + self.request_timeout
        while True:
            pending = self._pending.pop(request_id, None)
            if pending is not None:
                return self._response_result(method, pending)

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(
                    f"timed out waiting for rust-analyzer response to {method}; "
                    f"stderr tail:\n{self.stderr_tail()}"
                )
            try:
                received = self._messages.get(timeout=min(remaining, 1.0))
            except queue.Empty:
                if self._process.poll() is not None:
                    raise RuntimeError(
                        f"rust-analyzer exited while handling {method}; "
                        f"stderr tail:\n{self.stderr_tail()}"
                    )
                continue

            if isinstance(received, BaseException):
                raise received
            if "method" in received and "id" in received:
                self._answer_server_request(received)
                continue

            response_id = received.get("id")
            if response_id == request_id:
                return self._response_result(method, received)
            if isinstance(response_id, int):
                self._pending[response_id] = received

    def request_with_retries(
        self,
        method: str,
        params: Any,
        attempts: int = 20,
    ) -> Any:
        for attempt in range(attempts):
            try:
                return self.request(method, params)
            except LspError as error:
                if error.code != -32801 or attempt == attempts - 1:
                    raise
                time.sleep(0.25)
        raise AssertionError("unreachable retry loop exit")

    def stderr_tail(self) -> str:
        with self._stderr_lock:
            return "".join(self._stderr[-80:]).strip()

    def _response_result(self, method: str, response: dict[str, Any]) -> Any:
        if "error" in response:
            raise LspError(method, response["error"])
        return response.get("result")

    def _answer_server_request(self, message: dict[str, Any]) -> None:
        method = message.get("method")
        result: Any = None
        if method == "workspace/configuration":
            items = message.get("params", {}).get("items", [])
            result = [None for _ in items]
        self._send({"jsonrpc": "2.0", "id": message["id"], "result": result})

    def _send(self, message: dict[str, Any]) -> None:
        if self._process.stdin is None:
            raise RuntimeError("rust-analyzer stdin is closed")
        body = json.dumps(message, separators=(",", ":")).encode("utf-8")
        header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
        self._process.stdin.write(header + body)
        self._process.stdin.flush()

    def _read_stderr(self) -> None:
        assert self._process.stderr is not None
        for raw_line in self._process.stderr:
            line = raw_line.decode("utf-8", errors="replace")
            with self._stderr_lock:
                self._stderr.append(line)
                if len(self._stderr) > 80:
                    del self._stderr[:-80]
            if self.verbose:
                print(line, end="", file=sys.stderr)

    def _read_stdout(self) -> None:
        assert self._process.stdout is not None
        try:
            while True:
                headers: dict[str, str] = {}
                while True:
                    raw_line = self._process.stdout.readline()
                    if raw_line == b"":
                        return
                    line = raw_line.decode("ascii", errors="replace").strip()
                    if not line:
                        break
                    name, separator, value = line.partition(":")
                    if not separator:
                        raise RuntimeError(f"invalid LSP header: {line}")
                    headers[name.lower()] = value.strip()
                content_length = int(headers["content-length"])
                body = self._process.stdout.read(content_length)
                if len(body) != content_length:
                    raise RuntimeError("rust-analyzer returned a truncated LSP message")
                self._messages.put(json.loads(body.decode("utf-8")))
        except BaseException as error:
            self._messages.put(error)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="rust-analyzer-references",
        description=(
            "Report Rust definitions with an exact rust-analyzer workspace "
            "reference count."
        )
    )
    parser.add_argument(
        "paths",
        nargs="*",
        help="Rust files or directories to scan; defaults to the workspace.",
    )
    parser.add_argument(
        "--workspace",
        default=".",
        help="rust-analyzer workspace root, default: current directory",
    )
    parser.add_argument(
        "--rust-analyzer",
        default=os.environ.get("RUST_ANALYZER", "rust-analyzer"),
        help="rust-analyzer executable, default: $RUST_ANALYZER or rust-analyzer",
    )
    parser.add_argument(
        "--kinds",
        required=True,
        help=(
            "comma-separated kinds: enum,function,method,struct,trait,"
            "type-alias,union, or all"
        ),
    )
    parser.add_argument(
        "--visibility",
        choices=("any", "exported"),
        default="any",
        help="candidate visibility filter, default: any",
    )
    parser.add_argument(
        "--count",
        type=int,
        required=True,
        help="exact workspace reference count, excluding declarations",
    )
    parser.add_argument(
        "--output",
        choices=("text", "json"),
        default="text",
        help="report format, default: text",
    )
    parser.add_argument(
        "--fail-on-findings",
        action="store_true",
        help="exit with status 1 when a matching definition is found",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="print analyzer stderr and scan progress to stderr",
    )
    parser.add_argument(
        "--startup-timeout",
        type=float,
        default=120.0,
        help="seconds to wait for workspace loading, default: 120",
    )
    parser.add_argument(
        "--request-timeout",
        type=float,
        default=120.0,
        help="seconds to wait for each LSP request, default: 120",
    )
    return parser.parse_args()


def parse_kinds(raw: str) -> set[str]:
    kinds = {item.strip() for item in raw.split(",") if item.strip()}
    if "all" in kinds:
        kinds.remove("all")
        kinds.update(SUPPORTED_KINDS)
    unknown = kinds - SUPPORTED_KINDS
    if not kinds:
        raise ValueError("--kinds must contain at least one kind")
    if unknown:
        raise ValueError(f"unknown kind(s): {', '.join(sorted(unknown))}")
    return kinds


def validate_args(args: argparse.Namespace) -> set[str]:
    if args.count < 0:
        raise ValueError("--count must be non-negative")
    if args.startup_timeout <= 0:
        raise ValueError("--startup-timeout must be positive")
    if args.request_timeout <= 0:
        raise ValueError("--request-timeout must be positive")
    return parse_kinds(args.kinds)


def discover_rust_files(root: Path, paths: list[str]) -> list[Path]:
    scan_roots = [Path(path) for path in paths] if paths else [root]
    files: list[Path] = []
    for scan_root in scan_roots:
        resolved = (root / scan_root).resolve() if not scan_root.is_absolute() else scan_root.resolve()
        if resolved.is_file():
            if resolved.suffix == ".rs":
                files.append(resolved)
            continue
        if not resolved.exists():
            raise FileNotFoundError(f"scan path does not exist: {scan_root}")
        if not resolved.is_dir():
            raise ValueError(f"scan path is not a file or directory: {scan_root}")
        for directory, dirnames, filenames in os.walk(resolved):
            dirnames[:] = [
                name
                for name in dirnames
                if name not in SKIP_DIRS and not name.startswith(".")
            ]
            for filename in filenames:
                if filename.endswith(".rs"):
                    files.append((Path(directory) / filename).resolve())
    return sorted(set(files))


def wait_for_workspace(client: LspClient, path: Path, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    params = {"textDocument": {"uri": path_to_uri(path)}}
    while True:
        try:
            status = client.request("rust-analyzer/analyzerStatus", params)
        except LspError as error:
            if error.code == -32601:
                return
            raise
        if isinstance(status, str) and (
            "Workspaces:\nLoaded" in status
            or ("Workspaces:" in status and "No workspaces" not in status)
        ):
            return
        if time.monotonic() >= deadline:
            raise TimeoutError("timed out waiting for rust-analyzer workspace load")
        time.sleep(0.25)


def validate_project_root(root: Path) -> None:
    markers = (root / "Cargo.toml", root / "rust-project.json")
    if not any(marker.is_file() for marker in markers):
        raise ValueError(
            "workspace does not contain Cargo.toml or rust-project.json: "
            f"{root}; pass --workspace to a Rust project root"
        )


def collect_candidates(
    client: LspClient,
    root: Path,
    files: list[Path],
    requested_kinds: set[str],
    visibility_mode: str,
    sources: dict[Path, str],
) -> list[Candidate]:
    candidates: list[Candidate] = []
    seen: set[tuple[str, int, int, str]] = set()
    for index, path in enumerate(files, start=1):
        if client.verbose:
            print(f"document symbols {index}/{len(files)} {relative(path, root)}", file=sys.stderr)
        source = sources[path]
        symbols = client.request_with_retries(
            "textDocument/documentSymbol",
            {"textDocument": {"uri": path_to_uri(path)}},
        ) or []
        lines = source.splitlines()
        for symbol, parent_kind in flatten_symbols(symbols):
            candidate = candidate_from_symbol(
                root=root,
                path=path,
                source=source,
                lines=lines,
                symbol=symbol,
                parent_kind=parent_kind,
                requested_kinds=requested_kinds,
                visibility_mode=visibility_mode,
            )
            if candidate is None:
                continue
            key = (
                candidate.uri,
                candidate.position["line"],
                candidate.position["character"],
                candidate.kind,
            )
            if key not in seen:
                seen.add(key)
                candidates.append(candidate)
    candidates.sort(key=lambda item: (item.definition.path, item.definition.line, item.definition.column))
    return candidates


def flatten_symbols(
    symbols: list[dict[str, Any]],
    parent_kind: int | None = None,
) -> list[tuple[dict[str, Any], int | None]]:
    flattened: list[tuple[dict[str, Any], int | None]] = []
    for symbol in symbols:
        flattened.append((symbol, parent_kind))
        children = symbol.get("children")
        if isinstance(children, list):
            flattened.extend(flatten_symbols(children, symbol.get("kind")))
    return flattened


def candidate_from_symbol(
    root: Path,
    path: Path,
    source: str,
    lines: list[str],
    symbol: dict[str, Any],
    parent_kind: int | None,
    requested_kinds: set[str],
    visibility_mode: str,
) -> Candidate | None:
    name = symbol.get("name")
    symbol_range = get_symbol_range(symbol)
    if not isinstance(name, str) or symbol_range is None:
        return None
    kind = declaration_kind(name, symbol, symbol_range, lines, parent_kind)
    if kind is None or kind not in requested_kinds:
        return None
    position = symbol_position(name, symbol, symbol_range, lines)
    visibility = symbol_visibility(source, symbol_range, position)
    if visibility_mode == "exported" and visibility != "pub":
        return None
    uri = path_to_uri(path)
    return Candidate(
        name=name,
        kind=kind,
        visibility=visibility,
        definition=make_location(path, position, root, lines),
        uri=uri,
        position=position,
    )


def get_symbol_range(symbol: dict[str, Any]) -> dict[str, Any] | None:
    symbol_range = symbol.get("range")
    if isinstance(symbol_range, dict):
        return symbol_range
    location = symbol.get("location")
    if isinstance(location, dict) and isinstance(location.get("range"), dict):
        return location["range"]
    return None


def declaration_kind(
    name: str,
    symbol: dict[str, Any],
    symbol_range: dict[str, Any],
    lines: list[str],
    parent_kind: int | None,
) -> str | None:
    raw_kind = symbol.get("kind")
    if raw_kind in FUNCTION_SYMBOL_KINDS:
        if raw_kind == 6:
            return "method"
        return "function" if parent_kind in {None, MODULE_SYMBOL_KIND} else "method"

    start_line = symbol_range.get("start", {}).get("line")
    end_line = symbol_range.get("end", {}).get("line")
    if not isinstance(start_line, int) or not isinstance(end_line, int):
        return None
    if not lines or start_line >= len(lines):
        return None
    end_line = min(end_line, start_line + 20, len(lines) - 1)
    haystack = "\n".join(lines[start_line : end_line + 1])
    pattern = re.compile(r"\b(enum|struct|trait|type|union)\s+" + re.escape(name) + r"\b")
    match = pattern.search(haystack)
    return TYPE_KEYWORDS[match.group(1)] if match else None


def symbol_position(
    name: str,
    symbol: dict[str, Any],
    symbol_range: dict[str, Any],
    lines: list[str],
) -> dict[str, int]:
    selection = symbol.get("selectionRange")
    if isinstance(selection, dict) and isinstance(selection.get("start"), dict):
        start = selection["start"]
        return {"line": start["line"], "character": start["character"]}

    start_line = symbol_range["start"]["line"]
    end_line = min(symbol_range["end"]["line"], start_line + 20, len(lines) - 1)
    name_pattern = re.compile(r"\b" + re.escape(name) + r"\b")
    for line_number in range(start_line, end_line + 1):
        match = name_pattern.search(lines[line_number])
        if match:
            return {
                "line": line_number,
                "character": py_index_to_utf16_units(lines[line_number], match.start()),
            }
    return {"line": start_line, "character": symbol_range["start"]["character"]}


def symbol_visibility(
    source: str,
    symbol_range: dict[str, Any],
    position: dict[str, int],
) -> str:
    start_offset = offset_for_position(source, symbol_range["start"])
    selection_offset = offset_for_position(source, position)
    prefix = source[start_offset:selection_offset]
    match = VISIBILITY_PATTERN.search(prefix)
    if match is None:
        return "private"
    return " ".join(match.group("visibility").split())


def find_matches(
    client: LspClient,
    root: Path,
    candidates: list[Candidate],
    sources: dict[Path, str],
    expected_count: int,
) -> list[tuple[Candidate, list[Location]]]:
    matches: list[tuple[Candidate, list[Location]]] = []
    for index, candidate in enumerate(candidates, start=1):
        if client.verbose:
            print(
                f"references {index}/{len(candidates)} {candidate.kind} {candidate.name}",
                file=sys.stderr,
            )
        references = client.request_with_retries(
            "textDocument/references",
            {
                "textDocument": {"uri": candidate.uri},
                "position": candidate.position,
                "context": {"includeDeclaration": False},
            },
        )
        locations = reference_locations(references or [], root, sources)
        if len(locations) == expected_count:
            matches.append((candidate, locations))
    return matches


def reference_locations(
    references: list[dict[str, Any]],
    root: Path,
    sources: dict[Path, str],
) -> list[Location]:
    locations: list[Location] = []
    seen: set[tuple[str, int, int, int, int]] = set()
    for reference in references:
        uri = reference_uri(reference)
        reference_range = reference.get("range")
        if not isinstance(uri, str) or not isinstance(reference_range, dict):
            continue
        path = path_from_file_uri(uri)
        if path is None or not is_relative_to(path, root):
            continue
        start = reference_range.get("start", {})
        end = reference_range.get("end", {})
        key = (
            str(path),
            start.get("line", -1),
            start.get("character", -1),
            end.get("line", -1),
            end.get("character", -1),
        )
        if key in seen:
            continue
        seen.add(key)
        source = sources.get(path)
        if source is None and path.exists():
            source = path.read_text(encoding="utf-8")
            sources[path] = source
        lines = (source or "").splitlines()
        if not isinstance(start.get("line"), int) or not isinstance(start.get("character"), int):
            continue
        locations.append(make_location(path, start, root, lines))
    locations.sort(key=lambda item: (item.path, item.line, item.column))
    return locations


def reference_uri(reference: dict[str, Any]) -> str | None:
    uri = reference.get("uri")
    if isinstance(uri, str):
        return uri
    target_uri = reference.get("targetUri")
    return target_uri if isinstance(target_uri, str) else None


def make_location(
    path: Path,
    position: dict[str, int],
    root: Path,
    lines: list[str],
) -> Location:
    line_number = position["line"]
    line = lines[line_number] if 0 <= line_number < len(lines) else ""
    column = utf16_units_to_py_index(line, position["character"]) + 1
    return Location(
        path=relative(path, root),
        line=line_number + 1,
        column=column,
        snippet=line.strip(),
    )


def path_to_uri(path: Path) -> str:
    return path.resolve().as_uri()


def path_from_file_uri(uri: str) -> Path | None:
    parsed = urllib.parse.urlparse(uri)
    if parsed.scheme != "file":
        return None
    return Path(urllib.parse.unquote(parsed.path)).resolve()


def relative(path: Path, root: Path) -> str:
    try:
        return str(path.resolve().relative_to(root))
    except ValueError:
        return str(path)


def is_relative_to(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root)
        return True
    except ValueError:
        return False


def offset_for_position(source: str, position: dict[str, int]) -> int:
    line = position["line"]
    character = position["character"]
    lines = source.splitlines(keepends=True)
    if line >= len(lines):
        return len(source)
    return sum(len(item) for item in lines[:line]) + py_index_for_utf16(
        lines[line], character
    )


def py_index_for_utf16(line: str, character: int) -> int:
    units = 0
    for index, char in enumerate(line):
        if units == character:
            return index
        units += 2 if ord(char) > 0xFFFF else 1
        if units > character:
            return index + 1
    return len(line)


def utf16_units_to_py_index(line: str, units: int) -> int:
    total = 0
    for index, char in enumerate(line):
        width = len(char.encode("utf-16-le")) // 2
        if total + width > units:
            return index
        total += width
    return len(line)


def py_index_to_utf16_units(line: str, index: int) -> int:
    return sum(len(char.encode("utf-16-le")) // 2 for char in line[:index])


def location_json(location: Location) -> dict[str, Any]:
    return {
        "path": location.path,
        "line": location.line,
        "column": location.column,
        "snippet": location.snippet,
    }


def candidate_json(candidate: Candidate, references: list[Location]) -> dict[str, Any]:
    return {
        "name": candidate.name,
        "kind": candidate.kind,
        "visibility": candidate.visibility,
        "definition": location_json(candidate.definition),
        "reference_count": len(references),
        "references": [location_json(reference) for reference in references],
    }


def emit_report(
    root: Path,
    kinds: set[str],
    visibility: str,
    count: int,
    candidate_count: int,
    matches: list[tuple[Candidate, list[Location]]],
    output: str,
) -> None:
    if output == "json":
        print(
            json.dumps(
                {
                    "workspace": str(root),
                    "kinds": sorted(kinds),
                    "visibility": visibility,
                    "reference_count": count,
                    "definitions_scanned": candidate_count,
                    "matches": [
                        candidate_json(candidate, references)
                        for candidate, references in matches
                    ],
                },
                indent=2,
                sort_keys=True,
            )
        )
        return

    for candidate, references in matches:
        definition = candidate.definition
        print(
            f"{definition.path}:{definition.line}:{definition.column} "
            f"{candidate.visibility} {candidate.kind} {candidate.name} "
            f"({len(references)} reference(s))"
        )
        for reference in references:
            print(
                f"  ref: {reference.path}:{reference.line}:{reference.column}"
            )
            if reference.snippet:
                print(f"       {reference.snippet}")
    print(
        f"scanned {candidate_count} definition(s); found {len(matches)} "
        f"with exactly {count} workspace reference(s)",
        file=sys.stderr,
    )


def main() -> int:
    args = parse_args()
    try:
        requested_kinds = validate_args(args)
        root = Path(args.workspace).resolve()
        if not root.is_dir():
            raise FileNotFoundError(f"workspace is not a directory: {args.workspace}")
        validate_project_root(root)
        analyzer = shutil.which(args.rust_analyzer)
        if analyzer is None:
            raise FileNotFoundError(
                f"could not find rust-analyzer executable: {args.rust_analyzer}"
            )
        files = discover_rust_files(root, args.paths)
        if not files:
            raise FileNotFoundError("no Rust source files found")

        sources = {path: path.read_text(encoding="utf-8") for path in files}
        client = LspClient(
            analyzer,
            root,
            request_timeout=args.request_timeout,
            verbose=args.verbose,
        )
        try:
            if args.verbose:
                print("waiting for rust-analyzer workspace load", file=sys.stderr)
            wait_for_workspace(client, files[0], args.startup_timeout)
            candidates = collect_candidates(
                client,
                root,
                files,
                requested_kinds,
                args.visibility,
                sources,
            )
            matches = find_matches(client, root, candidates, sources, args.count)
        finally:
            client.close()

        emit_report(
            root,
            requested_kinds,
            args.visibility,
            args.count,
            len(candidates),
            matches,
            args.output,
        )
        return 1 if matches and args.fail_on_findings else 0
    except (OSError, RuntimeError, TimeoutError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
