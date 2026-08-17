load("@rules_cc//cc/private/toolchain:unix_cc_toolchain_config.bzl", "cc_toolchain_config")
load("@rules_cc//cc/toolchains:cc_toolchain.bzl", "cc_toolchain")
load(
    "@rules_rust//rust:toolchain.bzl",
    "rust_stdlib_filegroup",
    "rust_toolchain",
    "rustfmt_toolchain",
)

package(default_visibility = ["//visibility:private"])

# Rust's compiler executables and their shared libraries are ordinary files in
# this repository. There are no symlinks back to the Nix store.
filegroup(
    name = "rustc",
    srcs = ["bin/rustc"],
)

filegroup(
    name = "rustc_lib",
    srcs = glob(
        [
            "lib/*.so*",
            "lib/rustlib/%{RUST_TRIPLE}/bin/**",
            "lib/rustlib/%{RUST_TRIPLE}/codegen-backends/*.so*",
            "lib/rustlib/%{RUST_TRIPLE}/lib/*.so*",
        ],
        allow_empty = True,
    ),
)

filegroup(
    name = "rustdoc",
    srcs = ["bin/rustdoc"],
)

filegroup(
    name = "rustfmt",
    srcs = ["bin/rustfmt"],
)

rust_stdlib_filegroup(
    name = "rust_std",
    srcs = glob(
        [
            "lib/rustlib/%{RUST_TRIPLE}/lib/*.a",
            "lib/rustlib/%{RUST_TRIPLE}/lib/*.rlib",
            "lib/rustlib/%{RUST_TRIPLE}/lib/*.rmeta",
            "lib/rustlib/%{RUST_TRIPLE}/lib/*.so*",
            "lib/rustlib/%{RUST_TRIPLE}/lib/self-contained/**",
        ],
        allow_empty = True,
    ),
)

rust_toolchain(
    name = "rust_toolchain_impl",
    binary_ext = "",
    channel = "stable",
    default_edition = "2024",
    dylib_ext = ".so",
    exec_triple = "%{RUST_TRIPLE}",
    rust_doc = ":rustdoc",
    rust_std = ":rust_std",
    rustc = ":rustc",
    rustc_lib = ":rustc_lib",
    staticlib_ext = ".a",
    stdlib_linkflags = [
        "-ldl",
        "-lpthread",
    ],
    target_triple = "%{RUST_TRIPLE}",
    version = "%{RUST_VERSION}",
)

rustfmt_toolchain(
    name = "rustfmt_toolchain_impl",
    rustc = ":rustc",
    rustc_lib = ":rustc_lib",
    rustfmt = ":rustfmt",
)

toolchain(
    name = "rust_toolchain",
    exec_compatible_with = [
        "@platforms//cpu:x86_64",
        "@platforms//os:linux",
    ],
    target_compatible_with = [
        "@platforms//cpu:x86_64",
        "@platforms//os:linux",
    ],
    toolchain = ":rust_toolchain_impl",
    toolchain_type = "@rules_rust//rust:toolchain_type",
    visibility = ["//visibility:public"],
)

toolchain(
    name = "rustfmt_toolchain",
    exec_compatible_with = [
        "@platforms//cpu:x86_64",
        "@platforms//os:linux",
    ],
    target_compatible_with = [
        "@platforms//cpu:x86_64",
        "@platforms//os:linux",
    ],
    toolchain = ":rustfmt_toolchain_impl",
    toolchain_type = "@rules_rust//rust/rustfmt:toolchain_type",
    visibility = ["//visibility:public"],
)

# The C/C++ toolchain uses the same materialized SDK. bin/clang is a static
# launcher that derives --sysroot, -resource-dir, and --gcc-toolchain from its
# own location, so none of these flags contains an execroot or store path.
filegroup(
    name = "cc_toolchain_files",
    srcs = glob([
        "bin/**",
        "lib/**",
        "sysroot/**",
    ]),
)

cc_toolchain_config(
    name = "cc_toolchain_config",
    abi_libc_version = "glibc",
    abi_version = "local",
    archive_flags = ["rcsD"],
    compiler = "clang",
    compile_flags = [
        "-no-canonical-prefixes",
        "-Wno-builtin-macro-redefined",
        "-D__DATE__=\"redacted\"",
        "-D__TIME__=\"redacted\"",
        "-D__TIMESTAMP__=\"redacted\"",
    ],
    cpu = "k8",
    cxx_builtin_include_directories = [
        "lib/clang/current/include",
        "sysroot/usr/include",
        "sysroot/usr/include/c++/%{GCC_VERSION}",
        "sysroot/usr/include/c++/%{GCC_VERSION}/%{RUST_TRIPLE}",
    ],
    cxx_flags = ["-std=c++17"],
    host_system_name = "local",
    link_libs = [
        "-lstdc++",
        "-lm",
    ],
    supports_start_end_lib = True,
    target_libc = "glibc",
    target_system_name = "%{RUST_TRIPLE}",
    tool_paths = {
        "ar": "bin/llvm-ar",
        "cpp": "bin/clang",
        "dwp": "bin/llvm-dwp",
        "gcc": "bin/clang",
        "gcov": "bin/llvm-cov",
        "ld": "bin/ld.lld",
        "nm": "bin/llvm-nm",
        "objcopy": "bin/llvm-objcopy",
        "objdump": "bin/llvm-objdump",
        "strip": "bin/llvm-strip",
    },
    toolchain_identifier = "nix-portable-clang",
)

cc_toolchain(
    name = "cc_toolchain_impl",
    all_files = ":cc_toolchain_files",
    ar_files = ":cc_toolchain_files",
    as_files = ":cc_toolchain_files",
    compiler_files = ":cc_toolchain_files",
    dwp_files = ":cc_toolchain_files",
    linker_files = ":cc_toolchain_files",
    objcopy_files = ":cc_toolchain_files",
    strip_files = ":cc_toolchain_files",
    supports_param_files = 1,
    toolchain_config = ":cc_toolchain_config",
    toolchain_identifier = "nix-portable-clang",
)

toolchain(
    name = "cc_toolchain",
    exec_compatible_with = [
        "@platforms//cpu:x86_64",
        "@platforms//os:linux",
    ],
    target_compatible_with = [
        "@platforms//cpu:x86_64",
        "@platforms//os:linux",
    ],
    toolchain = ":cc_toolchain_impl",
    toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
    visibility = ["//visibility:public"],
)
