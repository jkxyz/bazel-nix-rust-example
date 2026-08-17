#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

: "${NIX_RUST_TOOLCHAIN:?Run this test from nix develop}"
: "${CC:?Run this test from nix develop}"

test -x "$NIX_RUST_TOOLCHAIN/bin/rustc"
test -x "$CC"

case "$NIX_RUST_TOOLCHAIN:$CC" in
  /nix/store/*:/nix/store/*) ;;
  *)
    echo "the supported build tools must come from the Nix store" >&2
    exit 1
    ;;
esac

temporary_root=$(mktemp -d "$repository_root/.nix-bazel-smoke.XXXXXX")
cleanup() {
  chmod -R u+w "$temporary_root" 2>/dev/null || true
  rm -rf -- "$temporary_root"
}
trap cleanup EXIT

# Keep external repositories under this workspace-local output base. Shared
# repository-cache symlinks may point outside Bazel's sandbox.
bazel \
  --output_base="$temporary_root/bazel" \
  build \
  --repo_contents_cache= \
  //:hello_world \
  //bazel/toolchains:cc_toolchain_smoke
bazel \
  --output_base="$temporary_root/bazel" \
  build \
  --repo_contents_cache= \
  --aspects=@rules_rust//rust:defs.bzl%rust_clippy_aspect \
  --output_groups=clippy_checks \
  //:hello_world
bazel \
  --output_base="$temporary_root/bazel" \
  build \
  --repo_contents_cache= \
  --aspects=@rules_rust//rust:defs.bzl%rustfmt_aspect \
  --output_groups=rustfmt_checks \
  //:hello_world
bazel --output_base="$temporary_root/bazel" run --repo_contents_cache= //:hello_world
bazel --output_base="$temporary_root/bazel" run --repo_contents_cache= //bazel/toolchains:cc_toolchain_smoke

rust_command=$(
  bazel --output_base="$temporary_root/bazel" \
    aquery --repo_contents_cache= 'mnemonic("Rustc", //:hello_world)' --output=commands
)
cc_link_command=$(
  bazel --output_base="$temporary_root/bazel" \
    aquery --repo_contents_cache= 'mnemonic("CppLink", //bazel/toolchains:cc_toolchain_smoke)' --output=commands
)
rust_linker=$(
  printf '%s\n' "$rust_command" \
    | sed -n "s/.*--codegen=linker=\([^ ']*\).*/\1/p"
)

case "$rust_command" in
  *nix_rust_toolchain*) ;;
  *)
    echo "Rust did not use the Nix Rust toolchain" >&2
    printf '%s\n' "$rust_command" >&2
    exit 1
    ;;
esac
if test -z "$rust_linker"; then
  echo "Rust did not use the resolved C/C++ linker" >&2
  printf '%s\n' "$rust_command" >&2
  exit 1
fi
case "$cc_link_command" in
  *"$rust_linker"*) ;;
  *)
    echo "Rust and C++ did not use the same resolved linker" >&2
    printf '%s\n%s\n' "$rust_command" "$cc_link_command" >&2
    exit 1
    ;;
esac

if test "$(uname -s)" = Linux; then
  : "${BAZEL_LINKOPTS:?The Linux dev shell must configure the GCC runtime RPATH}"
  if test "$rust_linker" != "$CC"; then
    echo "Rust and C++ did not use the shell-selected compiler" >&2
    printf '%s\n%s\n' "$rust_command" "$cc_link_command" >&2
    exit 1
  fi
  case "$rust_command:$cc_link_command" in
    *"--codegen=link-arg=-fuse-ld=lld"*"-fuse-ld=lld"*) ;;
    *)
      echo "Rust and C++ did not both select LLD" >&2
      printf '%s\n%s\n' "$rust_command" "$cc_link_command" >&2
      exit 1
      ;;
  esac
  case "$rust_command:$cc_link_command" in
    *"$BAZEL_LINKOPTS"*"$BAZEL_LINKOPTS"*) ;;
    *)
      echo "Rust and C++ did not both inherit the Nix GCC runtime RPATH" >&2
      printf '%s\n%s\n' "$rust_command" "$cc_link_command" >&2
      exit 1
      ;;
  esac
fi

printf 'Nix/Bazel toolchain smoke test passed (%s, %s)\n' \
  "$("$NIX_RUST_TOOLCHAIN/bin/rustc" --version)" \
  "$("$CC" --version | sed -n '1p')"
