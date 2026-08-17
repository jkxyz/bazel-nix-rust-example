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
          rustToolchain = rustRelease.default.override {
            extensions = [
              "clippy"
              "rust-analyzer"
              "rust-src"
              "rustfmt"
            ];
          };
          ciRustToolchain = rustRelease.minimal.override {
            extensions = [
              "clippy"
              "rustfmt"
            ];
          };

          # Bazel's local C/C++ configuration discovers the compiler through
          # CC. Keep LLD beside the Nix compiler wrapper so that its linker
          # capability probe can select LLD instead of falling back to gold.
          bazelCcToolchain = pkgs.symlinkJoin {
            name = "bazel-cc-toolchain";
            paths = [
              pkgs.stdenv.cc
              pkgs.lld
            ];
            pathsToLink = [ "/bin" ];
          };

          mkDevShell = rust: pkgs.mkShellNoCC {
            packages = [
              bazelCcToolchain
              pkgs.bazel_9
              rust
            ];

            # The Rust repository rule consumes this path directly. Changing
            # the flake lock or profile changes the store path and invalidates
            # the repository.
            NIX_RUST_TOOLCHAIN = rust;
            NIX_BASH = "${pkgs.bash}/bin/bash";

            # rules_cc's local configuration records these in the generated
            # toolchain. Nix's GCC runtime is not in the host loader's default
            # search path, so Linux executables need its store path as RPATH.
            BAZEL_LINKOPTS = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux "-Wl,-rpath,${pkgs.lib.getLib pkgs.stdenv.cc.cc}/lib";

            # rules_cc's standard local configuration treats CC as its
            # compiler-selection interface. Set these after the standard shell
            # hooks, which otherwise normalize them back to gcc and g++.
            shellHook = ''
              export CC="${bazelCcToolchain}/bin/cc"
              export CXX="${bazelCcToolchain}/bin/c++"
            '';
          };
        in
        {
          packages = {
            rust-toolchain = rustToolchain;
            bazel-cc-toolchain = bazelCcToolchain;
          };

          devShells = {
            default = mkDevShell rustToolchain;
            ci = mkDevShell ciRustToolchain;
          };
        }
      );
}
