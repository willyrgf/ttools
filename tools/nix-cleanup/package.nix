{
  pkgs,
  lib,
  toolName,
  flakeCommit ? "unknown",
}:

let
  runtimePackages = [
    pkgs.coreutils
    pkgs.cron
    pkgs.findutils
    pkgs.gawk
    pkgs.gitMinimal
    pkgs.gnugrep
    pkgs.nix
  ];
  runtimePath = lib.makeBinPath runtimePackages;
  unwrapped = pkgs.stdenvNoCC.mkDerivation {
    pname = toolName;
    version = "0.0.1";
    src = ./.;

    nativeBuildInputs = [ pkgs.bash ];

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      substitute "$src/nix-cleanup.sh" "$out/bin/${toolName}" \
        --replace-fail "/usr/bin/env bash" "${pkgs.bash}/bin/bash" \
        --replace-fail "__NIX_CLEANUP_FLAKE_COMMIT__" "${flakeCommit}"
      chmod +x "$out/bin/${toolName}"
      runHook postInstall
    '';
  };
in
pkgs.symlinkJoin {
  name = toolName;
  paths = [ unwrapped ];
  nativeBuildInputs = [ pkgs.makeWrapper ];

  postBuild = ''
    wrapProgram "$out/bin/${toolName}" \
      --prefix PATH : "${runtimePath}" \
      --set NIX_CLEANUP_ARG0 "${toolName}"
  '';

  passthru.unwrapped = unwrapped;

  meta = {
    description = "Safely remove dead Nix store paths and optionally run garbage collection.";
    mainProgram = toolName;
  };
}
