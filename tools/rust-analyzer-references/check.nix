{
  pkgs,
  lib,
  toolName,
  package,
}:

let
  fakeAnalyzer = pkgs.writeShellScript "${toolName}-fake-analyzer" ''
    exec ${pkgs.python3}/bin/python3 ${./tests/fake-rust-analyzer.py} "$@"
  '';
in
pkgs.runCommand "${toolName}-check"
  {
    src = ./.;
    nativeBuildInputs = [
      pkgs.bash
      pkgs.bats
      pkgs.coreutils
      pkgs.python3
    ];
    RUST_ANALYZER_REFERENCES_BIN = lib.getExe package;
    RUST_ANALYZER_REFERENCES_FIXTURE = "${./tests/fixtures/sample.rs}";
    RUST_ANALYZER_REFERENCES_MANIFEST = "${./tests/fixtures/Cargo.toml}";
    RUST_ANALYZER_REFERENCES_FAKE_SOURCE = fakeAnalyzer;
  }
  ''
    cd "$src"
    bats --tap --print-output-on-failure tests/cli.bats
    touch "$out"
  ''
