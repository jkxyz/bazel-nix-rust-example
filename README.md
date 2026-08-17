# Hello World with Bazel inside Nix

This repository gives Nix ownership of the native build environment and Bazel ownership of the build graph. The supported workflow is deliberately local: run Bazel from `nix develop`, with `/nix/store` available to build actions. Remote execution and running Bazel outside the Nix environment are not supported.

```text
                         flake.lock
                              |
                flake-selected native tools
                  /                       \
       aggregate Rust profile      GCC/Clang wrapper + LLD
                  |                       |
       NIX_RUST_TOOLCHAIN                 CC
                  |                       |
        rules_rust toolchain      rules_cc local configuration
                  \                       /
                   Rust and native actions
```

## Boundary

[`flake.nix`](flake.nix) is the source of truth for all executable build tools:

- `rust-toolchain` is rust-overlay's flake-locked stable release with Cargo, Clippy, rust-analyzer, rust-src, rustfmt, rustc, rustdoc, and the native standard library.
- `bazel-cc-toolchain` places the native Nix compiler wrapper and LLD in one `bin` directory.
- The development shell exports `NIX_RUST_TOOLCHAIN`, `CC`, and `CXX` as Nix store paths. On Linux it also exports `BAZEL_LINKOPTS` with an RPATH to the selected libstdc++ runtime.
- The `ci` shell uses the same Rust release's minimal profile plus Clippy and rustfmt. It deliberately omits rust-analyzer and rust-src.

[`nix/rust_toolchain.bzl`](nix/rust_toolchain.bzl) is the small Rust-specific bridge. It validates the compiler reported by `NIX_RUST_TOOLCHAIN`, links that derivation's existing `bin/` and `lib/` trees into a Bazel repository, and generates the `rules_rust` declarations from [`nix/rust_toolchain.BUILD.bazel.tpl`](nix/rust_toolchain.BUILD.bazel.tpl). It does not copy, relocate, patch, or archive compiler files.

C/C++ needs no custom repository rule. `rules_cc` performs its standard local configuration using `CC`. Because LLD is beside the compiler wrapper, the probe selects it and produces link options equivalent to:

```text
/nix/store/...-bazel-cc-toolchain/bin/cc
-fuse-ld=lld
-B/nix/store/...-bazel-cc-toolchain/bin
```

`rules_rust` consumes that resolved C/C++ toolchain for native linking, so Rust receives the same compiler and `-fuse-ld=lld`. This fixes the gold-linker warning at the C/C++ toolchain boundary rather than adding unrelated Rust-only linker configuration.

On Linux, the shell's `BAZEL_LINKOPTS` is consumed directly by `rules_cc` during local toolchain configuration. The generated toolchain therefore records the flake-selected libstdc++ RPATH, allowing both C++ and Rust binaries to load that runtime without relying on the host environment.

## Build and run

Enter the environment before invoking Bazel:

```console
nix develop
bazel build //:hello_world //nix:cc_toolchain_smoke
bazel run //:hello_world
bazel run //nix:cc_toolchain_smoke
```

Or run a single command without entering an interactive shell:

```console
nix develop --command bazel build //:hello_world
```

Cargo sees the same Rust and C/C++ tools through the shell:

```console
RUST_LOG=info cargo run
```

Inspect the selected link commands with:

```console
bazel aquery 'mnemonic("Rustc", //:hello_world)' --output=commands
bazel aquery 'mnemonic("CppLink", //nix:cc_toolchain_smoke)' --output=commands
```

On Linux, both should contain `-fuse-ld=lld`, and the Rust command should contain `--codegen=linker=/nix/store/...-bazel-cc-toolchain/bin/cc`.

## Verification

CI runs the same strong local check on x86-64 Linux, ARM64 Linux, and Apple Silicon macOS:

```console
nix develop .#ci --command bash nix/smoke_test.sh
```

The script starts with a fresh Bazel output base, builds and runs both languages, runs the Clippy and rustfmt aspects, and inspects the resolved link commands. On Linux it fails unless both Rust and C++ select LLD.

## Deliberate limitations

- Bazel must run inside this flake's development shell.
- Build actions intentionally read flake-locked paths in `/nix/store`.
- Only native builds are registered for `x86_64-linux`, `aarch64-linux`, and `aarch64-darwin`.
- Remote execution, non-Nix workers, and cross-compilation are outside the contract.
- Cargo and Bazel share toolchain bytes and versions, but retain separate build graphs and dependency resolution.

With that boundary, Nix store references are a feature rather than something the repository must discover and remove.
