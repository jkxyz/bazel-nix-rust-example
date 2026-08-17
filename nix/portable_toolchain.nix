{
  ccWrapper,
  flakeLock,
  system ? builtins.currentSystem,
}:
let
  lock = builtins.fromJSON (builtins.readFile (builtins.toPath flakeLock));
  rootNode = lock.nodes.${lock.root};

  lockedInput =
    name:
    let
      nodeName = rootNode.inputs.${name};
    in
    lock.nodes.${nodeName}.locked;

  fetchLockedGitHub =
    source:
    assert source.type == "github";
    builtins.fetchTarball {
      url = "https://github.com/${source.owner}/${source.repo}/archive/${source.rev}.tar.gz";
      sha256 = source.narHash;
    };

  nixpkgs = fetchLockedGitHub (lockedInput "nixpkgs");
  rust-overlay = fetchLockedGitHub (lockedInput "rust-overlay");

  pkgs = import nixpkgs {
    inherit system;
    overlays = [ (import rust-overlay) ];
  };

  rust = pkgs.rust-bin.stable.latest.minimal.override {
    extensions = [ "rustfmt" ];
  };
  clang = pkgs.llvmPackages.clang-unwrapped;
  llvm = pkgs.llvmPackages.llvm;
  gcc = pkgs.stdenv.cc.cc;
  gccLib = pkgs.stdenv.cc.cc.lib;
  staticCc = pkgs.pkgsStatic.stdenv.cc;
  ccWrapperSource = builtins.path {
    path = builtins.toPath ccWrapper;
    name = "portable_cc_wrapper.c";
  };
  hostTriple = "x86_64-unknown-linux-gnu";
in
assert pkgs.stdenv.hostPlatform.system == "x86_64-linux";
pkgs.runCommand "bazel-portable-sdk"
  {
    nativeBuildInputs = [
      pkgs.binutils
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnused
      pkgs.gnutar
      pkgs.gzip
      pkgs.patchelf
      pkgs.ripgrep
    ];
  }
  ''
    set -o errexit -o nounset -o pipefail

    sdk="$TMPDIR/sdk"
    mkdir -p "$sdk/bin" "$sdk/lib" "$sdk/sysroot/usr/include" "$sdk/sysroot/usr/lib"

    # Copy dereferenced files. The resulting archive must not depend on Nix's
    # symlink targets after Bazel extracts it on another machine.
    cp -L ${rust}/bin/rustc "$sdk/bin/rustc"
    cp -L ${rust}/bin/rustdoc "$sdk/bin/rustdoc"
    cp -L ${rust}/bin/rustfmt "$sdk/bin/rustfmt"
    cp -aL ${rust}/lib/. "$sdk/lib/"
    chmod -R u+w "$sdk/lib"
    rm -rf "$sdk/lib/rustlib"
    mkdir -p "$sdk/lib/rustlib/${hostTriple}"
    cp -aL ${rust}/lib/rustlib/${hostTriple}/. "$sdk/lib/rustlib/${hostTriple}/"

    clang_resource_dir="$(${clang}/bin/clang -print-resource-dir)"
    mkdir -p "$sdk/lib/clang/current"
    cp -aL "$clang_resource_dir/include" "$sdk/lib/clang/current/"
    cp -L ${clang}/bin/clang "$sdk/bin/clang.real"
    cp -L ${pkgs.lld}/bin/ld.lld "$sdk/bin/ld.lld"
    cp -L ${llvm}/bin/llvm-ar "$sdk/bin/llvm-ar"
    cp -L ${llvm}/bin/llvm-cov "$sdk/bin/llvm-cov"
    cp -L ${llvm}/bin/llvm-dwp "$sdk/bin/llvm-dwp"
    cp -L ${llvm}/bin/llvm-nm "$sdk/bin/llvm-nm"
    cp -L ${llvm}/bin/llvm-objcopy "$sdk/bin/llvm-objcopy"
    cp -L ${llvm}/bin/llvm-objdump "$sdk/bin/llvm-objdump"
    cp -L ${llvm}/bin/llvm-strip "$sdk/bin/llvm-strip"

    # These shared objects are the execution-time dependencies of rustc,
    # Clang, LLD, and the LLVM utilities. They live beside one another so a
    # short $ORIGIN RPATH is sufficient after relocation.
    cp -aL ${clang.lib}/lib/libclang-cpp.so* "$sdk/lib/"
    cp -aL ${llvm.lib}/lib/libLLVM.so* "$sdk/lib/"
    cp -aL ${gccLib}/lib/libgcc_s.so* "$sdk/lib/"
    cp -aL ${gccLib}/lib/libstdc++.so* "$sdk/lib/"
    cp -aL ${pkgs.libffi}/lib/libffi.so* "$sdk/lib/"
    cp -aL ${pkgs.libxml2.out}/lib/libxml2.so* "$sdk/lib/"
    cp -aL ${pkgs.zlib}/lib/libz.so* "$sdk/lib/"

    # Clang's target sysroot is a declared toolchain input, not the worker's
    # /usr. It includes glibc headers/start files and the GCC support files and
    # C++ headers that Clang discovers through --gcc-toolchain.
    cp -aL ${pkgs.glibc.dev}/include/. "$sdk/sysroot/usr/include/"
    cp -aL ${pkgs.glibc}/lib/*.a "$sdk/sysroot/usr/lib/"
    cp -aL ${pkgs.glibc}/lib/*.o "$sdk/sysroot/usr/lib/"
    cp -aL ${pkgs.glibc}/lib/*.so* "$sdk/sysroot/usr/lib/"
    chmod -R u+w "$sdk/sysroot"
    cp -aL ${gcc}/include/c++ "$sdk/sysroot/usr/include/"
    gcc_target_dir="$sdk/sysroot/usr/lib/gcc/${hostTriple}/${gcc.version}"
    mkdir -p "$gcc_target_dir"
    cp -aL ${gcc}/lib/gcc/${hostTriple}/${gcc.version}/crtbegin*.o "$gcc_target_dir/"
    cp -aL ${gcc}/lib/gcc/${hostTriple}/${gcc.version}/crtend*.o "$gcc_target_dir/"
    cp -aL ${gcc}/lib/gcc/${hostTriple}/${gcc.version}/libgcc.a "$gcc_target_dir/"
    cp -aL ${gcc}/lib/gcc/${hostTriple}/${gcc.version}/libgcc_eh.a "$gcc_target_dir/"
    cp -aL ${gccLib}/lib/libgcc_s.so* "$sdk/sysroot/usr/lib/"
    cp -aL ${gccLib}/lib/libstdc++.so* "$sdk/sysroot/usr/lib/"

    # Nixpkgs' glibc linker scripts name their store paths explicitly. The
    # equivalent local names let LLD resolve them through the sysroot search
    # path instead.
    cat >"$sdk/sysroot/usr/lib/libc.so" <<'EOF'
    OUTPUT_FORMAT(elf64-x86-64)
    GROUP ( libc.so.6 libc_nonshared.a AS_NEEDED ( ld-linux-x86-64.so.2 ) )
    EOF
    cat >"$sdk/sysroot/usr/lib/libm.so" <<'EOF'
    OUTPUT_FORMAT(elf64-x86-64)
    GROUP ( libm.so.6 AS_NEEDED ( libmvec.so.1 ) )
    EOF

    # A tiny static launcher computes paths from its invocation path, with
    # /proc/self/exe as a fallback. Unlike the Nix GCC wrapper it has no
    # store-bound shebang or embedded compiler path.
    ${staticCc}/bin/${staticCc.targetPrefix}cc \
      -O2 -static -Wall -Wextra -Werror \
      ${ccWrapperSource} \
      -o "$sdk/bin/clang"

    # Before changing ELF interpreters, prove the path-computing launcher and
    # bundled sysroot can drive a complete C compile and link in Nix's sandbox.
    printf '%s\n' 'int main(void) { return 0; }' > "$TMPDIR/smoke.c"
    "$sdk/bin/clang" "$TMPDIR/smoke.c" -o "$TMPDIR/smoke"
    test -s "$TMPDIR/smoke"

    chmod -R u+w "$sdk"

    # Patch only host tools. Files in sysroot/ are target inputs and retain
    # their normal ABI metadata.
    while IFS= read -r -d $'\0' file; do
      if patchelf --print-rpath "$file" >/dev/null 2>&1; then
        case "$file" in
          "$sdk"/bin/*)
            patchelf --set-rpath '$ORIGIN/../lib' "$file"
            ;;
          *)
            patchelf --set-rpath '$ORIGIN:$ORIGIN/..:$ORIGIN/../..:$ORIGIN/../../..:$ORIGIN/../../../..' "$file"
            ;;
        esac
        if patchelf --print-interpreter "$file" >/dev/null 2>&1; then
          patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 "$file"
        fi
      fi
    done < <(find "$sdk/bin" "$sdk/lib" -type f -print0)

    # Rust and LLVM artifacts can contain store paths outside ELF RPATHs. A
    # same-length invalid prefix prevents accidental fallback to the producer's
    # Nix store without changing binary offsets. rustc then derives its sysroot
    # from its relocated executable.
    find "$sdk" -type f -exec sed -i 's#/nix/store/#/nope/path/#g' {} +

    if rg --text --files-with-matches '/nix/store/' "$sdk"; then
      echo "portable SDK still contains a Nix store reference" >&2
      exit 1
    fi

    # The Nix build sandbox intentionally has no /lib64. Invoke its bundled
    # loader for this build-time check; after extraction Bazel exercises the
    # conventional interpreter path embedded above.
    loader="$sdk/sysroot/usr/lib/ld-linux-x86-64.so.2"
    run_host_tool() {
      "$loader" --library-path "$sdk/lib:$sdk/sysroot/usr/lib" "$@"
    }
    run_host_tool "$sdk/bin/rustc" --version --verbose
    test "$(run_host_tool "$sdk/bin/rustc" --print sysroot)" = "$sdk"
    run_host_tool "$sdk/bin/clang.real" --version
    run_host_tool "$sdk/bin/ld.lld" --version

    mkdir -p "$out"
    printf '%s\n' \
      'format = 1' \
      'host = ${hostTriple}' \
      'clang = ${clang.version}' \
      'gcc = ${gcc.version}' \
      "rust = $(run_host_tool "$sdk/bin/rustc" --version | cut -d' ' -f2)" \
      > "$sdk/TOOLCHAIN-METADATA"
    LC_ALL=C tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner \
      -C "$sdk" -cf - . | gzip -n > "$out/portable-sdk.tar.gz"
    cp "$sdk/TOOLCHAIN-METADATA" "$out/TOOLCHAIN-METADATA"
  ''
