#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

sdk=$1
rust_root=$2
clang_root=$3
llvm_root=$4
lld_root=$5
shift 5
common_roots=("$@")

mkdir -p "$sdk/lib/clang-runtime"

is_macho() {
  file -b "$1" | grep -q 'Mach-O'
}

find_runtime_library() {
  local group=$1 name=$2 root candidate
  local roots
  if test "$group" = clang; then
    roots=("$clang_root" "$llvm_root" "$lld_root" "${common_roots[@]}")
  else
    roots=("$rust_root" "${common_roots[@]}")
  fi
  for root in "${roots[@]}"; do
    test -d "$root" || continue
    candidate=$(find -L "$root" -type f -name "$name" -print -quit)
    if test -n "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

runtime_group() {
  case "$1" in
    "$sdk"/bin/clang|"$sdk"/bin/ld64.lld|"$sdk"/bin/llvm-*) printf '%s\n' clang ;;
    "$sdk"/lib/clang-runtime/*) printf '%s\n' clang ;;
    *) printf '%s\n' rust ;;
  esac
}

runtime_directory() {
  if test "$(runtime_group "$1")" = clang; then
    printf '%s\n' "$sdk/lib/clang-runtime"
  else
    printf '%s\n' "$sdk/lib"
  fi
}

# Copy every non-system Mach-O dependency, then repeat because each copied
# dylib can introduce more dependencies. Separate Rust and Clang runtime
# directories avoid LLVM basename collisions between the two tool families.
changed=1
while test "$changed" = 1; do
  changed=0
  while IFS= read -r -d '' file; do
    is_macho "$file" || continue
    group=$(runtime_group "$file")
    destination=$(runtime_directory "$file")
    while IFS= read -r dependency; do
      case "$dependency" in
        /nix/store/*|@rpath/*)
          name=${dependency##*/}
          test -e "$destination/$name" && continue
          if test -e "$dependency"; then
            source=$dependency
          else
            source=$(find_runtime_library "$group" "$name") || {
              echo "cannot find Mach-O dependency $dependency required by $file" >&2
              exit 1
            }
          fi
          cp -L "$source" "$destination/$name"
          chmod u+w "$destination/$name"
          changed=1
          ;;
      esac
    done < <(otool -L "$file" | tail -n +2 | sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/')
  done < <(find "$sdk/bin" "$sdk/lib" -type f -print0)
done

while IFS= read -r -d '' file; do
  is_macho "$file" || continue

  while IFS= read -r dependency; do
    case "$dependency" in
      /nix/store/*)
        install_name_tool -change "$dependency" "@rpath/${dependency##*/}" "$file"
        ;;
    esac
  done < <(otool -L "$file" | tail -n +2 | sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/')

  while IFS= read -r old_rpath; do
    case "$old_rpath" in
      /nix/store/*) install_name_tool -delete_rpath "$old_rpath" "$file" ;;
    esac
  done < <(otool -l "$file" | awk '$1 == "cmd" && $2 == "LC_RPATH" { in_rpath=1; next } in_rpath && $1 == "path" { print $2; in_rpath=0 }')

  relative_lib=$(realpath --relative-to="$(dirname "$file")" "$(runtime_directory "$file")")
  wanted_rpath="@loader_path/$relative_lib"
  if ! otool -l "$file" | awk '$1 == "cmd" && $2 == "LC_RPATH" { in_rpath=1; next } in_rpath && $1 == "path" { print $2; in_rpath=0 }' | grep -Fqx "$wanted_rpath"; then
    install_name_tool -add_rpath "$wanted_rpath" "$file"
  fi

  case "$file" in
    "$sdk"/lib/*.dylib|"$sdk"/lib/*.dylib.*|"$sdk"/lib/clang-runtime/*.dylib|"$sdk"/lib/clang-runtime/*.dylib.*)
      install_name_tool -id "@rpath/${file##*/}" "$file"
      ;;
  esac
done < <(find "$sdk/bin" "$sdk/lib" -type f -print0)
