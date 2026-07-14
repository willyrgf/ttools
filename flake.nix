{
  description = "ttools: a collection of tiny command-line tools.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        inherit (pkgs) lib;
        toolRoot = ./tools;
        flakeCommit = self.rev or (self.dirtyRev or "unknown");
        reservedToolNames = [ "default" "help" "list" "version" ];
        directoryEntries = builtins.readDir toolRoot;

        validateToolName = toolName:
          if builtins.match "[a-z][a-z0-9]*(-[a-z0-9]+)*" toolName == null then
            throw "invalid tool name '${toolName}': use lowercase kebab-case"
          else if lib.elem toolName reservedToolNames then
            throw "reserved tool name '${toolName}' cannot be used"
          else
            toolName;

        validateToolLayout = toolName:
          let
            toolDirectory = toolRoot + "/${toolName}";
          in
          if !(builtins.pathExists (toolDirectory + "/README.md")) then
            throw "tool '${toolName}' is missing README.md"
          else if !(builtins.pathExists (toolDirectory + "/package.nix")) then
            throw "tool '${toolName}' is missing package.nix"
          else if !(builtins.pathExists (toolDirectory + "/check.nix")) then
            throw "tool '${toolName}' is missing check.nix"
          else
            toolName;

        toolNames =
          lib.sort builtins.lessThan
            (map validateToolLayout
              (map validateToolName
                (lib.filter
                  (toolName: directoryEntries.${toolName} == "directory")
                  (builtins.attrNames directoryEntries))));

        toolPackages = lib.genAttrs toolNames (toolName:
          import (toolRoot + "/${toolName}/package.nix") {
            inherit pkgs lib toolName flakeCommit;
          });

        toolChecks = lib.genAttrs toolNames (toolName:
          import (toolRoot + "/${toolName}/check.nix") {
            inherit pkgs lib toolName;
            package = toolPackages.${toolName};
          });

        toolInfo = lib.mapAttrs (_toolName: package: {
          inherit (package.meta) description;
          program = lib.getExe package;
        }) toolPackages;

        catalogLines = lib.concatStringsSep "\n" (map (toolName:
          "  printf '  %s\\n' ${lib.escapeShellArg "${toolName} - ${toolInfo.${toolName}.description}"}"
        ) toolNames);

        dispatchCases = lib.concatStringsSep "\n" (map (toolName:
          ''
            ${toolName})
              exec "${toolInfo.${toolName}.program}" "$@"
              ;;
          ''
        ) toolNames);

        ttoolsEntrypoint = pkgs.writeShellScriptBin "ttools" ''
          set -euo pipefail

          _catalog() {
            printf '%s\n' 'Available tools:'
          ${catalogLines}
          }

          _usage() {
            printf '%s\n' 'ttools - a collection of tiny command-line tools.'
            printf '\n'
            _catalog
            printf '\n'
            printf '%s\n' 'Usage:'
            printf '%s\n' '  ttools'
            printf '%s\n' '  ttools list'
            printf '%s\n' '  ttools --help'
            printf '%s\n' '  ttools <tool-name> [args...]'
          }

          _error() {
            printf 'error: %s\n' "$*" >&2
          }

          if [ "$#" -eq 0 ]; then
            _usage
            exit 0
          fi

          case "$1" in
            -h|--help|help)
              _usage
              exit 0
              ;;
            list)
              _catalog
              exit 0
              ;;
          esac

          tool="$1"
          shift
          case "$tool" in
          ${dispatchCases}
            *)
              _error "unknown tool: $tool"
              exit 1
              ;;
          esac
        '';
        dispatcherProgram = "${ttoolsEntrypoint}/bin/ttools";
        quality = import ./nix/quality.nix {
          inherit pkgs lib;
          src = ./.;
        };
      in
      {
        packages = toolPackages // {
          default = ttoolsEntrypoint;
        };

        apps = quality.apps // {
          default = {
            type = "app";
            program = dispatcherProgram;
            meta.description = "Generated ttools dispatcher for the repository's tiny tools.";
          };
        };

        checks = toolChecks // quality.checks // {
          repo-ttools-smoke = pkgs.runCommand "repo-ttools-smoke" {
            src = ./.;
            nativeBuildInputs = [ pkgs.coreutils ];
          } ''
            set -euo pipefail
            cd "$src"

            help_output="$(${pkgs.coreutils}/bin/env -i HOME="$TMPDIR" PATH=/nonexistent "${dispatcherProgram}" --help)"
            case "$help_output" in
              *"ttools - a collection of tiny command-line tools."*"Available tools:"*"git-history"*"nix-cleanup"*) ;;
              *)
                printf '%s\n' "dispatcher help output is incomplete" >&2
                exit 1
                ;;
            esac

            list_output="$(${pkgs.coreutils}/bin/env -i HOME="$TMPDIR" PATH=/nonexistent "${dispatcherProgram}" list)"
            first_tool="$(printf '%s\n' "$list_output" | sed -n '2p')"
            second_tool="$(printf '%s\n' "$list_output" | sed -n '3p')"
            [ "$first_tool" = "  git-history - Review and deliberately rewrite selected Git history." ]
            [ "$second_tool" = "  nix-cleanup - Safely remove dead Nix store paths and optionally run garbage collection." ]

            ${pkgs.coreutils}/bin/env -i HOME="$TMPDIR" PATH=/nonexistent "${dispatcherProgram}" git-history --help > "$TMPDIR/git-history-help"
            ${pkgs.coreutils}/bin/env -i HOME="$TMPDIR" PATH=/nonexistent "${dispatcherProgram}" nix-cleanup --help > "$TMPDIR/nix-cleanup-help"
            grep -F 'Usage:' "$TMPDIR/git-history-help" > /dev/null
            grep -F 'Usage:' "$TMPDIR/nix-cleanup-help" > /dev/null

            if "${dispatcherProgram}" unknown-tool > "$TMPDIR/unknown-out" 2> "$TMPDIR/unknown-error"; then
              printf '%s\n' "unknown dispatcher tool unexpectedly succeeded" >&2
              exit 1
            fi
            grep -Fx 'error: unknown tool: unknown-tool' "$TMPDIR/unknown-error" > /dev/null
            touch "$out"
          '';
        };

        devShells = {
          quality = pkgs.mkShell {
            packages = quality.devPackages;
          };
          default = pkgs.mkShell {
            packages = quality.devPackages;
          };
        };
      });
}
