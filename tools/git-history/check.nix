{ pkgs, lib, toolName, package }:

pkgs.runCommand "${toolName}-check" {
  src = ./.;
  nativeBuildInputs = [ pkgs.bash pkgs.bats pkgs.coreutils pkgs.gitMinimal ];
  GIT_HISTORY_BIN = lib.getExe package;
} ''
  cd "$src"
  bats --tap tests/cli.bats tests/rewrite.bats
  touch "$out"
''
