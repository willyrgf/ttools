{
  pkgs,
  lib,
  toolName,
  flakeCommit ? "unknown",
}:

pkgs.writeShellApplication {
  name = toolName;
  runtimeInputs = lib.unique [
    pkgs.coreutils
    pkgs.findutils
    pkgs.gitMinimal
    pkgs.gnugrep
  ];
  text = builtins.readFile ./dump2llm.sh;
  derivationArgs = {
    passthru = {
      inherit flakeCommit;
    };
  };
  meta = {
    description = "Dump Git repositories and paths as text for LLM chats.";
    mainProgram = toolName;
  };
}
