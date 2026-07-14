# Repository-wide quality checks and developer commands.
{
  pkgs,
  lib,
  src,
}:
let
  qualityPackages = [
    pkgs.actionlint
    pkgs.bash
    pkgs.coreutils
    pkgs.deadnix
    pkgs.findutils
    pkgs.nixfmt-rfc-style
    pkgs.ruff
    pkgs.shellcheck
    pkgs.shfmt
    pkgs.statix
  ];

  devPackages = qualityPackages ++ [
    pkgs.bats
    pkgs.gitMinimal
    pkgs.nix
  ];

  mkRepoCheck =
    name: command:
    pkgs.runCommand name
      {
        inherit src;
        nativeBuildInputs = qualityPackages;
      }
      ''
        cd "$src"
        ${command}
        touch "$out"
      '';

  check = pkgs.writeShellApplication {
    name = "ttools-check";
    runtimeInputs = [
      pkgs.gitMinimal
      pkgs.nix
    ];
    text = ''
      exec nix flake check --print-build-logs --show-trace
    '';
  };

  format = pkgs.writeShellApplication {
    name = "ttools-format";
    runtimeInputs = [
      pkgs.findutils
      pkgs.nixfmt-rfc-style
      pkgs.ruff
      pkgs.shfmt
    ];
    text = ''
      ruff format --no-cache tools
      find tools -type f -name '*.sh' -print0 \
        | xargs -0 -r shfmt -w -i 2 -ci -sr
      find . -type f -name '*.nix' -not -path './.git/*' -print0 \
        | xargs -0 -r nixfmt
    '';
  };
in
{
  inherit devPackages;

  apps = {
    check = {
      type = "app";
      program = lib.getExe check;
      meta.description = "Run the repository's complete Nix and source-quality checks.";
    };

    format = {
      type = "app";
      program = lib.getExe format;
      meta.description = "Format the repository's Bash, Python, and Nix source files.";
    };
  };

  checks = {
    repo-bash-syntax = mkRepoCheck "repo-bash-syntax" ''
      while IFS= read -r -d $'\0' source; do
        bash -n "$source"
      done < <(find tools -type f -name '*.sh' -print0)
    '';

    repo-shellcheck = mkRepoCheck "repo-shellcheck" ''
      find tools -type f -name '*.sh' -print0 | xargs -0 -r shellcheck -x
    '';

    repo-shfmt = mkRepoCheck "repo-shfmt" ''
      find tools -type f -name '*.sh' -print0 | xargs -0 -r shfmt -d -i 2 -ci -sr
    '';

    repo-python = mkRepoCheck "repo-python" ''
      ruff check --no-cache tools
      ruff format --check --no-cache tools
    '';

    repo-nixfmt = mkRepoCheck "repo-nixfmt" ''
      find . -type f -name '*.nix' -print0 | xargs -0 -r nixfmt --check
    '';

    repo-actionlint = mkRepoCheck "repo-actionlint" ''
      actionlint .github/workflows/nix-checks.yml
    '';

    repo-statix = mkRepoCheck "repo-statix" ''
      statix check .
    '';

    repo-deadnix = mkRepoCheck "repo-deadnix" ''
      deadnix .
    '';
  };
}
