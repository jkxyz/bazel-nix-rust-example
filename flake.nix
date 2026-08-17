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
    flake-utils.lib.eachSystem
      [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ]
      (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ (import rust-overlay) ];
          };

          rustRelease = pkgs.rust-bin.stable.latest;

          portable = import ./nix/portable_toolchain.nix {
            inherit pkgs;
            rust = rustRelease.minimal.override {
              extensions = [ "rustfmt" ];
            };
            linuxRuntimeLauncher = ./nix/linux_runtime_launcher.c;
            relocateElf = ./nix/relocate_elf.sh;
            relocateMacho = ./nix/relocate_macho.sh;
          };
        in
        {
          packages = {
            rust-toolchain = rustRelease.default.override {
              extensions = [
                "clippy"
                "rust-analyzer"
                "rust-src"
                "rustfmt"
              ];
            };

            portable-toolchain = portable.archive;
            portable-toolchain-tree = portable.sdk;
          };

          checks = {
            portable-toolchain = portable.sdk;
          };

          devShells = {
            default = pkgs.mkShell {
              packages = [
                pkgs.bazel_9
                self.packages.${system}.rust-toolchain
              ];
            };

            ci = pkgs.mkShell {
              packages = [ pkgs.bazel_9 ];
            };
          };
        }
      );
}
