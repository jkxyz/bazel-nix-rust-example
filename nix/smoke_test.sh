#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary_root=$(mktemp -d)
cleanup() {
  chmod -R u+w "$temporary_root" 2>/dev/null || true
  rm -rf -- "$temporary_root"
}
trap cleanup EXIT

archive=$(nix build --no-link --print-out-paths "path:$repository_root#portable-toolchain")
sdk=$(nix build --no-link --print-out-paths "path:$repository_root#portable-toolchain-tree")

path_info=$(nix path-info --json --json-format 1 "$sdk")
case "$path_info" in
  *'"references":[]'*) ;;
  *)
    echo "portable SDK has a non-empty Nix reference closure" >&2
    printf '%s\n' "$path_info" >&2
    exit 1
    ;;
esac

if LC_ALL=C grep -R -a -l -m1 '/nix/store/' "$sdk"; then
  echo "portable SDK contains a Nix store path" >&2
  exit 1
fi
if tar -tzf "$archive/portable-sdk.tar.gz" \
  | grep -E '^\./(flake\.nix|flake\.lock|Cargo\.toml|src(/|$)|nix(/|$))'; then
  echo "repository source leaked into the portable SDK archive" >&2
  exit 1
fi

sandbox_flags=(--sandbox_block_path=/nix/store)
if test "$(uname -s)" = Linux; then
  sandbox_flags=(--sandbox_tmpfs_path=/nix/store)
fi

bazel \
  --output_base="$temporary_root/bazel" \
  build \
  --repo_contents_cache= \
  "${sandbox_flags[@]}" \
  //:hello_world \
  //:cc_toolchain_smoke
bazel --output_base="$temporary_root/bazel" run --repo_contents_cache= "${sandbox_flags[@]}" //:hello_world
bazel --output_base="$temporary_root/bazel" run --repo_contents_cache= "${sandbox_flags[@]}" //:cc_toolchain_smoke

printf 'portable SDK smoke test passed (%s, %s compressed)\n' \
  "$(sed -n 's/^system = //p' "$archive/TOOLCHAIN-METADATA")" \
  "$(du -h "$archive/portable-sdk.tar.gz" | cut -f1)"
