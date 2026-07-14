{ pkgs, lib, toolName, flakeCommit ? "unknown" }:

pkgs.writeShellApplication {
  name = toolName;
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gitMinimal
  ];
  text = builtins.readFile ./git-history.sh;
  meta = {
    description = "Review and deliberately rewrite selected Git history.";
    mainProgram = toolName;
  };
}
