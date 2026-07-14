{
  pkgs,
  lib,
  toolName,
  flakeCommit ? "unknown",
}:

pkgs.writeShellApplication {
  name = toolName;
  runtimeInputs = lib.unique [
    pkgs.cargo
    pkgs.python3
    pkgs.rust-analyzer
    pkgs.rustc
  ];
  text = ''
    exec python3 ${./rust-analyzer-references.py} "$@"
  '';
  derivationArgs = {
    passthru = {
      inherit flakeCommit;
    };
  };
  meta = {
    description = "Report Rust definitions by rust-analyzer reference count.";
    mainProgram = toolName;
  };
}
