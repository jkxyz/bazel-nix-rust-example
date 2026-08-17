#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

sdk=$1
interpreter=$2
shift 2
runtime_roots=("$@")

is_elf() {
  patchelf --print-needed "$1" >/dev/null 2>&1
}

has_library() {
  local name=$1
  test -e "$sdk/lib/$name" || test -e "$sdk/sysroot/usr/lib/$name"
}

copy_library() {
  local name=$1 root candidate
  for root in "${runtime_roots[@]}"; do
    test -d "$root" || continue
    candidate=$(find -L "$root" -type f -name "$name" -print -quit)
    if test -n "$candidate"; then
      cp -L "$candidate" "$sdk/lib/$name"
      chmod u+w "$sdk/lib/$name"
      return 0
    fi
  done
  return 1
}

# Follow DT_NEEDED names rather than copying complete package outputs. This is
# the executable closure of the selected tools, expressed as ordinary files.
changed=1
while test "$changed" = 1; do
  changed=0
  while IFS= read -r -d '' file; do
    is_elf "$file" || continue
    while IFS= read -r needed; do
      test -n "$needed" || continue
      has_library "$needed" && continue
      if copy_library "$needed"; then
        changed=1
      else
        echo "cannot find ELF dependency $needed required by $file" >&2
        exit 1
      fi
    done < <(patchelf --print-needed "$file")
  done < <(find "$sdk/bin" "$sdk/lib" -type f -print0)
done

while IFS= read -r -d '' file; do
  is_elf "$file" || continue
  case "$file" in
    "$sdk"/bin/*)
      rpath='$ORIGIN/../lib'
      ;;
    *)
      rpath='$ORIGIN:$ORIGIN/..:$ORIGIN/../..:$ORIGIN/../../..:$ORIGIN/../../../..'
      ;;
  esac
  patchelf --set-rpath "$rpath" "$file"
  if patchelf --print-interpreter "$file" >/dev/null 2>&1; then
    patchelf --set-interpreter "$interpreter" "$file"
  fi
done < <(find "$sdk/bin" "$sdk/lib" -type f -print0)
