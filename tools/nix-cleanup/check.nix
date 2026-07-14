{ pkgs, lib, toolName, package }:

pkgs.runCommand "${toolName}-check" {
  src = ./.;
  nativeBuildInputs = [
    pkgs.bash
    pkgs.bats
    pkgs.coreutils
    pkgs.gnugrep
  ];
  NIX_CLEANUP_BIN = lib.getExe package;
} ''
  cd "$src"
  bats --tap tests/cli.bats
  touch "$out"
''
