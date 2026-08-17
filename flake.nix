{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      rust-overlay,
    }:

    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };
      in
      {
        packages = {
          rust-toolchain = pkgs.rust-bin.stable.latest.default.override {
            extensions = [
              "clippy"
              "rust-analyzer"
              "rust-src"
              "rustfmt"
            ];
          };
        }
        // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
          portable-toolchain = import ./nix/portable_toolchain.nix {
            ccWrapper = ./nix/portable_cc_wrapper.c;
            flakeLock = ./flake.lock;
            inherit system;
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [
            self.packages.${system}.rust-toolchain
            pkgs.bazel_9
            pkgs.bazel-gazelle
          ];
        };
      }
    );
}
