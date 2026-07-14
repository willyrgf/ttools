{
  pkgs,
  lib,
  toolName,
  package,
}:

pkgs.runCommand "${toolName}-check"
  {
    src = ./.;
    nativeBuildInputs = [
      pkgs.bash
      pkgs.bats
      pkgs.coreutils
      pkgs.findutils
      pkgs.gitMinimal
      pkgs.gnugrep
    ];
    DUMP2LLM_BIN = lib.getExe package;
  }
  ''
    cd "$src"
    bats --tap --print-output-on-failure tests/cli.bats
    touch "$out"
  ''
