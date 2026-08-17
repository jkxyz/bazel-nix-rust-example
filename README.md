# Hello World with a portable Nix/Bazel toolchain

Nix is the source of truth for the compiler release and SDK contents. Bazel receives an ordinary relocatable SDK, so compile and link actions do not require Nix or access `/nix/store`.

```text
                    flake.lock
                        |
              one pinned Rust release
                 /             \
        full developer       minimal Bazel
            profile             profile
                                  |
                      platform SDK assembly
                                  |
                 reference-free tree + archive
                                  |
                     Bazel external repository
                                  |
                   Rust and C/C++ toolchains
```

## Flake outputs

The flake deliberately separates selection from profiles:

- `rust-toolchain` is the full interactive profile used by the default development shell. It adds Clippy, rust-analyzer, rust-src, and rustfmt.
- `portable-toolchain-tree` is the audited, unpacked native SDK. It starts from the same Rust release's minimal profile and adds only rustfmt.
- `portable-toolchain` is the deterministic compressed form consumed by Bazel.
- `devShells.ci` contains Bazel but not the full developer Rust profile. This is what CI uses.

Changing `flake.lock` changes the shared Rust release selection for both the developer shell and Bazel. There is no second Rust version in `MODULE.bazel` and no developer machine compiler discovery.

The flake supports native SDKs for `x86_64-linux`, `aarch64-linux`, and `aarch64-darwin`. CI and production use x86_64 Linux; ARM Linux and Apple Silicon macOS are supported developer execution environments. Intel macOS is intentionally not exposed.

## What enters the artifact

[`nix/portable_toolchain.nix`](nix/portable_toolchain.nix) is an allowlist, not a copied Nix closure. It selects rustc, rustdoc, rustfmt, the host Rust standard library, Clang, LLD, the required LLVM utilities, compiler runtime libraries, and the platform C/C++ SDK. Cargo, Clippy, rust-analyzer, rust-src, Bazel, and the repository source are not copied.

Evaluating a local flake does copy the repository to the Nix store as a build input. That does not make it an output dependency or archive member. The unpacked SDK derivation has `allowedReferences = []`, its Nix reference closure is empty, its generated manifest lists every artifact file, and the smoke test rejects repository files in the archive.

The platform-specific assembly is small and explicit:

| Host | Native ABI and SDK work |
| --- | --- |
| x86_64 Linux | glibc/GCC sysroot, bundled `ld-linux-x86-64.so.2`, ELF RPATH relocation, static runtime launcher |
| ARM64 Linux | glibc/GCC sysroot, bundled `ld-linux-aarch64.so.1`, ELF RPATH relocation, static runtime launcher |
| Apple Silicon macOS | pinned Apple SDK with self-contained symlinks, libc++, Mach-O install names/RPATHs, ad-hoc signing where required |

[`nix/relocate_elf.sh`](nix/relocate_elf.sh) and [`nix/relocate_macho.sh`](nix/relocate_macho.sh) compute host-tool runtime dependencies and rewrite them to SDK-relative locations. The Apple SDK copy preserves its native relative symlinks while materializing nixpkgs-added store links as ordinary files. Nix's `nuke-refs` removes remaining producer references, then the build rejects any remaining textual `/nix/store/` path. The ELF and Mach-O target sysroots themselves remain data; only executable host tools are relocated.

## Compiler configuration and Linux runtime launcher

Clang supports portable configuration files with paths relative to the configuration file. The SDK's `bin/clang.cfg` supplies the target, sysroot, resource directory, GCC installation where applicable, and LLD selection using `<CFGDIR>`.

Linux ELF interpreters are absolute `PT_INTERP` paths, so RPATH relocation alone would still select the worker's glibc loader and could mix the worker's libc with Nix-built LLVM libraries. [`nix/linux_runtime_launcher.c`](nix/linux_runtime_launcher.c) is compiled statically for each Linux host. Every exported tool uses that launcher to find the SDK relative to `/proc/self/exe` and invoke its real binary from `libexec` with the SDK's own loader and libraries. macOS tools run directly because Mach-O supports relative `@loader_path` metadata.

When Clang runs inside Bazel, [`nix/extensions.bzl`](nix/extensions.bzl) generates equivalent execroot-relative location flags for compile actions. That keeps dependency files stable and lets Bazel validate SDK headers. Link actions continue to use the relocatable Clang configuration. No shell script sits between Bazel and Clang.

The generated [`nix/portable_toolchain.BUILD.bazel.tpl`](nix/portable_toolchain.BUILD.bazel.tpl) keeps Rust standard-library files out of C/C++ action inputs and separates C/C++ compiler files from linker files. `/bin/sh` is registered explicitly as the common Linux/macOS shell execution ABI so rules_rust does not capture the Nix development shell in a generated shebang.

## Build and inspect

Enter the full development shell for normal work:

```console
nix develop
bazel build //:hello_world //nix:cc_toolchain_smoke
bazel run //:hello_world
bazel run //nix:cc_toolchain_smoke
```

Cargo uses the same flake-pinned Rust release through the shell:

```console
RUST_LOG=info cargo run
```

Inspect the transport artifact or its exact manifest:

```console
nix build .#portable-toolchain
cat result/TOOLCHAIN-METADATA
less result/SDK-MANIFEST.tsv
tar -tzf result/portable-sdk.tar.gz
```

## Strong local smoke test

Run the same test as CI:

```console
nix develop .#ci --command bash nix/smoke_test.sh
```

The script checks the SDK's empty Nix reference closure, scans the extracted archive for store paths and leaked repository files, starts Bazel with a fresh output base, hides or blocks `/nix/store` in every action sandbox, builds both the Rust and C++ targets, and runs them. The repository rule may use Nix during Bazel's client-side fetch phase; actions cannot.

## Bootstrap boundary

[`nix/extensions.bzl`](nix/extensions.bzl) is the only Nix/Bazel boundary. It asks the local flake for `portable-toolchain`, extracts the archive as regular Bazel repository files, validates the host metadata and relocated rustc, and generates/registers native Rust, rustfmt, C/C++, and shell toolchains.

This is why Nix is needed on a developer machine or CI coordinator but not on a remote worker. A future production path can publish the exact same archive by content digest and replace the repository rule's local `nix build` with an archive download without changing any registered toolchain.
