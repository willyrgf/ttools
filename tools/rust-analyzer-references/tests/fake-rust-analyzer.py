#!/usr/bin/env python3

from __future__ import annotations

import json
import os
from pathlib import Path
import sys


SYMBOLS = {
    "unused_public": (12, None),
    "used_public": (12, None),
    "OneUse": (23, None),
    "TwoUse": (23, None),
    "PrivateType": (23, None),
    "Widget": (23, ["method"]),
    "method": (6, None),
}


def read_message() -> dict:
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            raise EOFError
        line = line.decode("ascii").strip()
        if not line:
            break
        name, _, value = line.partition(":")
        headers[name.lower()] = value.strip()
    length = int(headers["content-length"])
    return json.loads(sys.stdin.buffer.read(length).decode("utf-8"))


def send(message: dict) -> None:
    body = json.dumps(message, separators=(",", ":")).encode("utf-8")
    sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode("ascii"))
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()


def source_for_uri(uri: str) -> tuple[Path, list[str]]:
    path = Path(uri.removeprefix("file://"))
    return path, path.read_text(encoding="utf-8").splitlines()


def utf16_units(line: str, index: int) -> int:
    return sum(len(character.encode("utf-16-le")) // 2 for character in line[:index])


def occurrence(lines: list[str], name: str, occurrence_number: int = 0) -> tuple[int, int]:
    seen = 0
    for line_number, line in enumerate(lines):
        start = 0
        while True:
            index = line.find(name, start)
            if index < 0:
                break
            if (index == 0 or not (line[index - 1].isalnum() or line[index - 1] == "_")) and (
                index + len(name) == len(line)
                or not (line[index + len(name)].isalnum() or line[index + len(name)] == "_")
            ):
                if seen == occurrence_number:
                    return line_number, utf16_units(line, index)
                seen += 1
            start = index + len(name)
    raise AssertionError(f"missing {name!r} occurrence {occurrence_number}")


def range_for(lines: list[str], name: str, occurrence_number: int = 0) -> dict:
    line_number, character = occurrence(lines, name, occurrence_number)
    return {
        "start": {"line": line_number, "character": 0},
        "end": {"line": line_number, "character": utf16_units(lines[line_number], len(lines[line_number]))},
    }


def symbol(name: str, kind: int, lines: list[str], occurrence_number: int = 0) -> dict:
    line_number, character = occurrence(lines, name, occurrence_number)
    return {
        "name": name,
        "kind": kind,
        "range": range_for(lines, name, occurrence_number),
        "selectionRange": {
            "start": {"line": line_number, "character": character},
            "end": {"line": line_number, "character": character + utf16_units(name, len(name))},
        },
    }


def document_symbols(lines: list[str]) -> list[dict]:
    result = []
    for name, (kind, children) in SYMBOLS.items():
        if name == "method":
            continue
        item = symbol(name, kind, lines)
        if children:
            item["children"] = [symbol(child, SYMBOLS[child][0], lines) for child in children]
        result.append(item)
    return result


def references(name: str, path: Path, lines: list[str]) -> list[dict]:
    reference_counts = {
        "used_public": 1,
        "OneUse": 1,
        "TwoUse": 2,
    }
    result = []
    for occurrence_number in range(1, reference_counts.get(name, 0) + 1):
        line_number, character = occurrence(lines, name, occurrence_number)
        end_character = character + utf16_units(name, len(name))
        result.append(
            {
                "uri": path.as_uri(),
                "range": {
                    "start": {"line": line_number, "character": character},
                    "end": {"line": line_number, "character": end_character},
                },
            }
        )
    return result


def main() -> int:
    retry_method = os.environ.get("RUST_ANALYZER_REFERENCES_RETRY_METHOD")
    retried = False
    while True:
        try:
            message = read_message()
        except EOFError:
            return 0
        method = message.get("method")
        request_id = message.get("id")
        if request_id is None:
            if method == "exit":
                return 0
            continue
        if (
            retry_method
            and method == f"textDocument/{retry_method}"
            and not retried
        ):
            retried = True
            send(
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {"code": -32801, "message": "analyzer is busy"},
                }
            )
            continue
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": request_id, "result": {}})
        elif method == "rust-analyzer/analyzerStatus":
            send({"jsonrpc": "2.0", "id": request_id, "result": "Workspaces:\nLoaded"})
        elif method == "textDocument/documentSymbol":
            uri = message["params"]["textDocument"]["uri"]
            _, lines = source_for_uri(uri)
            send({"jsonrpc": "2.0", "id": request_id, "result": document_symbols(lines)})
        elif method == "textDocument/references":
            uri = message["params"]["textDocument"]["uri"]
            path, lines = source_for_uri(uri)
            position = message["params"]["position"]
            name = next(
                name
                for name in SYMBOLS
                if occurrence(lines, name)[0] == position["line"]
                and occurrence(lines, name)[1] == position["character"]
            )
            send({"jsonrpc": "2.0", "id": request_id, "result": references(name, path, lines)})
        elif method == "shutdown":
            send({"jsonrpc": "2.0", "id": request_id, "result": None})
        else:
            send({"jsonrpc": "2.0", "id": request_id, "result": None})


if __name__ == "__main__":
    raise SystemExit(main())
