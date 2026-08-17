# Hello World with a portable Nix/Bazel toolchain

This repository is a proof of concept for a useful division of responsibility: Nix selects and assembles the compiler SDK, while Bazel owns toolchain resolution, action inputs, sandboxing, caching, and eventual remote execution.

The important difference from pointing Bazel at `/nix/store/.../bin/rustc` is that the registered toolchains contain only ordinary files in a Bazel external repository. Build actions do not read the producer's Nix store.

```text
flake.lock + portable_toolchain.nix
                |
                v
       Nix builds and audits
       portable-sdk.tar.gz
                |
                v
     Bazel repository rule extracts
      bin/ + lib/ + sysroot/
                |
                v
       Rust and C/C++ toolchains
                |
                v
    sandboxed or remote build actions
```

## Follow the implementation

`flake.lock` pins Nixpkgs and rust-overlay. The development shell uses rust-overlay's stable toolchain with the default profile and the additional WebAssembly target. `nix/portable_toolchain.nix` selects the stable minimal profile directly and adds only rustfmt. Changing the lock file or portable-toolchain expression invalidates Bazel's generated repository.

`nix/portable_toolchain.nix` creates the transport artifact. It copies and dereferences a deliberately small set of Rust, Clang, LLD, LLVM, glibc, and GCC artifacts; adds a target sysroot; rewrites glibc's absolute linker scripts; patches host-tool ELF interpreters and RPATHs; and replaces any remaining `/nix/store/` prefix with an invalid same-length prefix. The derivation fails if a store reference remains, then emits a deterministic `portable-sdk.tar.gz`.

`nix/portable_cc_wrapper.c` is compiled as a small static executable. Bazel can place an external repository at an arbitrary execroot path, so the launcher derives the SDK root from its own invocation path and supplies relative `--sysroot`, `-resource-dir`, `--gcc-toolchain`, and `-B` locations to the bundled Clang. This avoids embedding either a Nix path or a Bazel output-base path.

`nix/extensions.bzl` is the bootstrap boundary. Its repository rule runs `nix-build` on the Bazel client, extracts the archive, validates the metadata and relocated `rustc`, and generates a BUILD file. It intentionally uses `--no-out-link`: after extraction, no garbage-collector root or symlink back into the store is needed.

`nix/portable_toolchain.BUILD.bazel.tpl` describes the extracted files to `rules_rust` and `rules_cc`. `MODULE.bazel` registers its Rust, rustfmt, and C/C++ toolchains. `.bazelrc` prevents rules_cc from probing the host for a second compiler configuration.

The application target remains an ordinary `rust_binary`. `cc_toolchain_smoke` is a small C++ program that proves the same SDK supplies Clang, LLD, C and C++ headers, glibc start files, libgcc, and libstdc++.

## Build and run

Enter the development shell so the client has Bazel and Nix available:

```console
nix develop
bazel build //:hello_world //:cc_toolchain_smoke
bazel run //:hello_world
bazel run //:cc_toolchain_smoke
```

Cargo still uses the interactive Nix shell toolchain and its own build graph:

```console
RUST_LOG=info cargo run
```

The transport artifact can also be inspected directly:

```console
nix build .#portable-toolchain
tar -tzf result/portable-sdk.tar.gz | head
```

## Prove that actions cannot see the Nix store

The strongest local regression check starts with a fresh Bazel output base and mounts an empty tmpfs over `/nix/store` inside every action sandbox:

```console
verification_base="$(mktemp -d)"
bazel --output_base="$verification_base" build \
  //:hello_world \
  //:cc_toolchain_smoke \
  --sandbox_tmpfs_path=/nix/store
```

This still permits the repository rule to use Nix during the client-side fetch phase. All compile and link actions run later with the store hidden. A normal build can show the selected executables explicitly:

```console
bazel aquery 'mnemonic("Rustc", //:hello_world)' --output=commands
bazel aquery 'mnemonic("CppCompile", //:cc_toolchain_smoke)' --output=commands
```

Both command lines should name `nix_portable_toolchain` paths under Bazel's execroot, never `/nix/store` paths.

## Why this can execute remotely

Bazel uploads an action's declared input tree to a remote executor. Because the generated external repository contains materialized compiler binaries, shared libraries, headers, start files, standard libraries, and linker tools, those bytes travel like any other Bazel inputs. The worker neither evaluates Nix nor mounts the client's Nix store.

Nix is still required where Bazel fetches external repositories, normally the developer machine or CI coordinator. That is a bootstrap dependency, not a remote action dependency. A production setup could build the same archive in CI, publish it by content digest, and replace the local `nix-build` call with `http_archive`; the registered toolchain layout would stay the same.

## Deliberate boundaries

- The proof registers only native `x86_64-unknown-linux-gnu` toolchains.
- Host tools use the standard `/lib64/ld-linux-x86-64.so.2` interpreter. A remote execution platform must therefore provide a compatible x86-64 Linux/glibc runtime. This is an execution-platform constraint, not access to a host compiler or sysroot.
- Built programs use the normal Linux runtime ABI. A container image or platform definition should pin that runtime for remote tests as well as remote compilation.
- The archive favors clarity over transfer size. A production version would split Rust and C/C++ file groups more aggressively, strip unused compiler resources, and publish the compressed archive to a shared cache.
- The static Clang launcher assumes Linux `/proc/self/exe` only when invoked without a path. Bazel invokes it by an execroot-relative path, which also keeps compiler dependency files relocatable.
- This is not a general Nix-to-Bazel package bridge and does not implement cross-compilation.

The remaining non-hermetic input is thus explicit: the worker's declared Linux execution-platform ABI. The compilers, linker, binutils, headers, sysroot, and language standard libraries are all pinned and supplied as Bazel inputs.
