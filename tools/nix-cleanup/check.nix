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
      pkgs.cron
      pkgs.findutils
      pkgs.gawk
      pkgs.gitMinimal
      pkgs.gnugrep
      pkgs.nix
    ];
    NIX_CLEANUP_BIN = "${package.unwrapped}/bin/${toolName}";
  }
  ''
    export PATH="${
      lib.makeBinPath [
        pkgs.bash
        pkgs.nix
      ]
    }:$PATH"
    cd "$src"
    bats --tap --print-output-on-failure tests/cli.bats
    touch "$out"
  ''
