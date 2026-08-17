{
  pkgs,
  rust,
  relocateElf,
  relocateMacho,
}:
let
  inherit (pkgs) lib;

  platforms = {
    x86_64-linux = {
      os = "linux";
      bazelCpu = "x86_64";
      rustTriple = "x86_64-unknown-linux-gnu";
      dynamicLinker = "/lib64/ld-linux-x86-64.so.2";
      loaderName = "ld-linux-x86-64.so.2";
      elfFormat = "elf64-x86-64";
    };
    aarch64-linux = {
      os = "linux";
      bazelCpu = "aarch64";
      rustTriple = "aarch64-unknown-linux-gnu";
      dynamicLinker = "/lib/ld-linux-aarch64.so.1";
      loaderName = "ld-linux-aarch64.so.1";
      elfFormat = "elf64-littleaarch64";
    };
    aarch64-darwin = {
      os = "macos";
      bazelCpu = "aarch64";
      rustTriple = "aarch64-apple-darwin";
    };
  };

  platform =
    platforms.${pkgs.stdenv.hostPlatform.system}
      or (throw "portable-toolchain: unsupported host ${pkgs.stdenv.hostPlatform.system}; supported hosts are ${lib.concatStringsSep ", " (builtins.attrNames platforms)}");
  isLinux = platform.os == "linux";
  isDarwin = platform.os == "macos";

  clang = pkgs.llvmPackages.clang-unwrapped;
  llvm = pkgs.llvmPackages.llvm;
  lld = pkgs.llvmPackages.lld;
  gcc = pkgs.stdenv.cc.cc;
  gccLib = lib.getLib gcc;
  libcxx = pkgs.llvmPackages.libcxx;

  elfRelocator = builtins.path {
    path = builtins.toPath relocateElf;
    name = "relocate-elf.sh";
  };
  machoRelocator = builtins.path {
    path = builtins.toPath relocateMacho;
    name = "relocate-macho.sh";
  };

  runtimeRoots = [
    rust
    clang
    clang.lib
    llvm
    llvm.lib
    lld
    gccLib
    (lib.getLib pkgs.libffi)
    (lib.getLib pkgs.libxml2)
    (lib.getLib pkgs.zlib)
    (lib.getLib pkgs.zstd)
    (lib.getLib pkgs.ncurses)
  ];

  nativeBuildInputs = [
    pkgs.coreutils
    pkgs.findutils
    pkgs.gawk
    pkgs.gnugrep
    pkgs.gnused
    pkgs.gnutar
    pkgs.gzip
    pkgs.nukeReferences
    pkgs.ripgrep
  ]
  ++ lib.optionals isLinux [
    pkgs.binutils
    pkgs.patchelf
  ]
  ++ lib.optionals isDarwin [
    pkgs.darwin.autoSignDarwinBinariesHook
    pkgs.darwin.cctools
    pkgs.file
  ];

  sdk =
    pkgs.runCommand "portable-sdk-${pkgs.stdenv.hostPlatform.system}"
      {
        inherit nativeBuildInputs;
        allowedReferences = [ ];
        dontPatchShebangs = true;
        dontStrip = true;
      }
      ''
        set -o errexit -o nounset -o pipefail

        sdk=$out
        mkdir -p "$sdk/bin" "$sdk/lib" "$sdk/lib/clang/current" "$sdk/sysroot"

        # Only the components named here enter the SDK. In particular, Cargo,
        # Clippy, rust-analyzer, and rust-src belong to the development profile,
        # not to Bazel's transport artifact.
        for tool in rustc rustdoc rustfmt; do
          install -Dm755 "${rust}/bin/$tool" "$sdk/bin/$tool"
        done
        cp -aL ${rust}/lib/. "$sdk/lib/"
        chmod -R u+w "$sdk/lib"
        rm -rf "$sdk/lib/rustlib"
        mkdir -p "$sdk/lib/rustlib/${platform.rustTriple}"
        cp -aL ${rust}/lib/rustlib/${platform.rustTriple}/. "$sdk/lib/rustlib/${platform.rustTriple}/"

        clang_resource_dir=$(${clang}/bin/clang -print-resource-dir)
        cp -aL "$clang_resource_dir/include" "$sdk/lib/clang/current/"
        install -Dm755 ${clang}/bin/clang "$sdk/bin/clang"

        for tool in llvm-ar llvm-cov llvm-dwp llvm-nm llvm-objcopy llvm-objdump llvm-strip; do
          install -Dm755 "${llvm}/bin/$tool" "$sdk/bin/$tool"
        done
        ${lib.optionalString isLinux ''
          install -Dm755 ${lld}/bin/ld.lld "$sdk/bin/ld.lld"
        ''}
        ${lib.optionalString isDarwin ''
          install -Dm755 ${lld}/bin/ld64.lld "$sdk/bin/ld64.lld"
        ''}

        ${lib.optionalString isLinux ''
          mkdir -p "$sdk/sysroot/usr/include" "$sdk/sysroot/usr/lib"
          cp -aL ${pkgs.glibc.dev}/include/. "$sdk/sysroot/usr/include/"
          cp -aL ${pkgs.glibc}/lib/*.a "$sdk/sysroot/usr/lib/"
          cp -aL ${pkgs.glibc}/lib/*.o "$sdk/sysroot/usr/lib/"
          cp -aL ${pkgs.glibc}/lib/*.so* "$sdk/sysroot/usr/lib/"
          chmod -R u+w "$sdk/sysroot"
          cp -aL ${gcc}/include/c++ "$sdk/sysroot/usr/include/"

          gcc_triple=$(${gcc}/bin/gcc -dumpmachine)
          gcc_version=$(${gcc}/bin/gcc -dumpfullversion)
          gcc_source_dir=$(dirname "$(${gcc}/bin/gcc -print-file-name=crtbegin.o)")
          gcc_target_dir="$sdk/sysroot/usr/lib/gcc/$gcc_triple/$gcc_version"
          mkdir -p "$gcc_target_dir"
          for pattern in crtbegin\*.o crtend\*.o libgcc.a libgcc_eh.a libstdc++.a libsupc++.a; do
            for file in "$gcc_source_dir"/$pattern; do
              test -e "$file" && cp -aL "$file" "$gcc_target_dir/"
            done
          done
          cp -aL ${gccLib}/lib/libgcc_s.so* "$sdk/sysroot/usr/lib/"
          cp -aL ${gccLib}/lib/libstdc++.so* "$sdk/sysroot/usr/lib/"

          # Nixpkgs' glibc linker scripts contain producer-store paths. These
          # equivalent scripts resolve entirely inside --sysroot.
          printf '%s\n' \
            'OUTPUT_FORMAT(${platform.elfFormat})' \
            'GROUP ( libc.so.6 libc_nonshared.a AS_NEEDED ( ${platform.loaderName} ) )' \
            > "$sdk/sysroot/usr/lib/libc.so"
          printf '%s\n' \
            'OUTPUT_FORMAT(${platform.elfFormat})' \
            'GROUP ( libm.so.6 AS_NEEDED ( libmvec.so.1 ) )' \
            > "$sdk/sysroot/usr/lib/libm.so"

          printf '%s\n' \
            '--target=${platform.rustTriple}' \
            '--sysroot=<CFGDIR>/../sysroot' \
            '-resource-dir=<CFGDIR>/../lib/clang/current' \
            '--gcc-toolchain=<CFGDIR>/../sysroot/usr' \
            '-B<CFGDIR>' \
            '-fuse-ld=lld' \
            '$-Wl,--dynamic-linker=${platform.dynamicLinker}' \
            > "$sdk/bin/clang.cfg"

          gcc_version_metadata=$gcc_version
          cxx_includes="lib/clang/current/include;sysroot/usr/include;sysroot/usr/include/c++/$gcc_version;sysroot/usr/include/c++/$gcc_version/$gcc_triple"
        ''}

        ${lib.optionalString isDarwin ''
          cp -aL ${pkgs.apple-sdk.sdkroot}/. "$sdk/sysroot/"
          chmod -R u+w "$sdk/sysroot"
          if test -d ${lib.getDev libcxx}/include/c++/v1; then
            mkdir -p "$sdk/sysroot/usr/include/c++"
            cp -aL ${lib.getDev libcxx}/include/c++/v1 "$sdk/sysroot/usr/include/c++/"
          fi

          printf '%s\n' \
            '--target=${platform.rustTriple}' \
            '-isysroot' \
            '<CFGDIR>/../sysroot' \
            '-resource-dir=<CFGDIR>/../lib/clang/current' \
            '-stdlib=libc++' \
            '-B<CFGDIR>' \
            '-fuse-ld=lld' \
            > "$sdk/bin/clang.cfg"

          gcc_version_metadata=none
          cxx_includes='lib/clang/current/include;sysroot/usr/include;sysroot/usr/include/c++/v1'
        ''}

        chmod -R u+w "$sdk"

        # Before relocation, the copied tools still have their producer-store
        # runtime metadata. Use that one opportunity to exercise both complete
        # compile-and-link paths against the newly assembled relative SDK.
        printf '%s\n' 'int main(void) { return 0; }' > "$TMPDIR/smoke.c"
        printf '%s\n' '#include <vector>' 'int main() { std::vector<int> v{1}; return v[0] - 1; }' > "$TMPDIR/smoke.cc"
        printf '%s\n' 'fn main() {}' > "$TMPDIR/smoke.rs"
        "$sdk/bin/clang" "$TMPDIR/smoke.c" -o "$TMPDIR/smoke-c"
        "$sdk/bin/clang" "$TMPDIR/smoke.cc" -l${if isLinux then "stdc++" else "c++"} -o "$TMPDIR/smoke-cc"
        "$sdk/bin/rustc" "$TMPDIR/smoke.rs" -C "linker=$sdk/bin/clang" -o "$TMPDIR/smoke-rust"
        test -s "$TMPDIR/smoke-c" -a -s "$TMPDIR/smoke-cc" -a -s "$TMPDIR/smoke-rust"
        rust_version=$("$sdk/bin/rustc" --version | cut -d' ' -f2)

        ${lib.optionalString isLinux ''
          ${pkgs.bash}/bin/bash ${elfRelocator} \
            "$sdk" ${lib.escapeShellArg platform.dynamicLinker} \
            ${lib.escapeShellArgs (map toString runtimeRoots)}
        ''}
        ${lib.optionalString isDarwin ''
          ${pkgs.bash}/bin/bash ${machoRelocator} \
            "$sdk" ${
              lib.escapeShellArgs (
                map toString (
                  [
                    rust
                    clang.lib
                    llvm.lib
                    lld
                  ]
                  ++ [
                    (lib.getLib pkgs.libffi)
                    (lib.getLib pkgs.libxml2)
                    (lib.getLib pkgs.zlib)
                    (lib.getLib pkgs.zstd)
                    (lib.getLib pkgs.ncurses)
                  ]
                )
              )
            }
        ''}

        # nuke-refs is the standard Nix-aware pass (including arm64 Darwin
        # signing support). Replace its non-existent sentinel prefix as well so
        # the unpacked artifact contains no textual /nix/store path at all.
        find "$sdk" -type f -exec nuke-refs {} +
        find "$sdk" -type f -exec sed -i 's#/nix/store/#/nope/path/#g' {} +
        if rg --text --files-with-matches '/nix/store/' "$sdk"; then
          echo 'portable SDK still contains a Nix store path' >&2
          exit 1
        fi

        printf '%s\n' \
          'format = 2' \
          'system = ${pkgs.stdenv.hostPlatform.system}' \
          'os = ${platform.os}' \
          'cpu = ${platform.bazelCpu}' \
          'rust_triple = ${platform.rustTriple}' \
          "rust = $rust_version" \
          'clang = ${clang.version}' \
          "gcc = $gcc_version_metadata" \
          'binary_ext = ' \
          'staticlib_ext = .a' \
          'dylib_ext = ${if isLinux then ".so" else ".dylib"}' \
          'libc = ${if isLinux then "glibc" else "macos"}' \
          'cxx_stdlib = ${if isLinux then "stdc++" else "c++"}' \
          "cxx_includes = $cxx_includes" \
          'rust_stdlib_linkflags = ${if isLinux then "-ldl;-lpthread" else "-lSystem;-lresolv"}' \
          'linker = ${if isLinux then "bin/ld.lld" else "bin/ld64.lld"}' \
          > "$sdk/TOOLCHAIN-METADATA"

        (
          cd "$sdk"
          find . -type f ! -name SDK-MANIFEST.tsv -print0 \
            | LC_ALL=C sort -z \
            | while IFS= read -r -d $'\0' file; do
                size=$(stat -c %s "$file" 2>/dev/null || stat -f %z "$file")
                printf '%s\t%s\t%s\n' "''${file#./}" "$size" "$(sha256sum "$file" | cut -d' ' -f1)"
              done > SDK-MANIFEST.tsv
        )
      '';

  archive =
    pkgs.runCommand "portable-toolchain-${pkgs.stdenv.hostPlatform.system}"
      {
        nativeBuildInputs = [
          pkgs.gnutar
          pkgs.gzip
        ];
        allowedReferences = [ ];
      }
      ''
        set -o errexit -o nounset -o pipefail
        mkdir -p "$out"
        LC_ALL=C tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner \
          -C ${sdk} -cf - . | gzip -n > "$out/portable-sdk.tar.gz"
        cp ${sdk}/TOOLCHAIN-METADATA ${sdk}/SDK-MANIFEST.tsv "$out/"
      '';
in
{
  inherit archive platform sdk;
}
