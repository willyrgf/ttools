{ pkgs, lib, toolName, flakeCommit ? "unknown" }:

pkgs.writeShellApplication {
  name = toolName;
  runtimeInputs = lib.unique [ pkgs.coreutils pkgs.gitMinimal ];
  text = builtins.readFile ./git-history.sh;
  derivationArgs = { passthru = { inherit flakeCommit; }; };
  meta = {
    description = "Review and deliberately rewrite selected Git history.";
    mainProgram = toolName;
  };
}
