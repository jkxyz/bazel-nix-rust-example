load("@rules_cc//cc/private/toolchain:unix_cc_toolchain_config.bzl", "cc_toolchain_config")
load("@rules_cc//cc/toolchains:cc_toolchain.bzl", "cc_toolchain")
load("@bazel_tools//tools/sh:sh_toolchain.bzl", "sh_toolchain")
load(
    "@rules_rust//rust:toolchain.bzl",
    "rust_stdlib_filegroup",
    "rust_toolchain",
    "rustfmt_toolchain",
)

package(default_visibility = ["//visibility:private"])

# rules_rust uses this only to bootstrap its compiled process wrapper. /bin/sh
# is part of the declared Linux/macOS execution ABI, not a developer toolchain.
sh_toolchain(
    name = "sh_toolchain_impl",
    path = "/bin/sh",
)

toolchain(
    name = "sh_toolchain",
    exec_compatible_with = ["@platforms//os:%{OS}"],
    toolchain = ":sh_toolchain_impl",
    toolchain_type = "@bazel_tools//tools/sh:toolchain_type",
    visibility = ["//visibility:public"],
)

filegroup(
    name = "host_libraries",
    srcs = glob(
        [
            "libexec/**",
            "lib/*.so*",
            "lib/*.dylib*",
            "lib/clang-runtime/**",
        ],
        allow_empty = True,
    ),
)

filegroup(
    name = "rustc",
    srcs = ["bin/rustc"],
)

filegroup(
    name = "rustc_lib",
    srcs = [":host_libraries"] + glob(
        [
            "lib/rustlib/%{RUST_TRIPLE}/bin/**",
            "lib/rustlib/%{RUST_TRIPLE}/codegen-backends/**",
            "lib/rustlib/%{RUST_TRIPLE}/lib/*.so*",
            "lib/rustlib/%{RUST_TRIPLE}/lib/*.dylib*",
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
            "lib/rustlib/%{RUST_TRIPLE}/lib/*.dylib*",
            "lib/rustlib/%{RUST_TRIPLE}/lib/self-contained/**",
        ],
        allow_empty = True,
    ),
)

rust_toolchain(
    name = "rust_toolchain_impl",
    binary_ext = "%{BINARY_EXT}",
    channel = "stable",
    default_edition = "2024",
    dylib_ext = "%{DYLIB_EXT}",
    exec_triple = "%{RUST_TRIPLE}",
    rust_doc = ":rustdoc",
    rust_std = ":rust_std",
    rustc = ":rustc",
    rustc_lib = ":rustc_lib",
    staticlib_ext = "%{STATICLIB_EXT}",
    stdlib_linkflags = %{RUST_STDLIB_LINKFLAGS},
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
        "@platforms//cpu:%{CPU}",
        "@platforms//os:%{OS}",
    ],
    target_compatible_with = [
        "@platforms//cpu:%{CPU}",
        "@platforms//os:%{OS}",
    ],
    toolchain = ":rust_toolchain_impl",
    toolchain_type = "@rules_rust//rust:toolchain_type",
    visibility = ["//visibility:public"],
)

toolchain(
    name = "rustfmt_toolchain",
    exec_compatible_with = [
        "@platforms//cpu:%{CPU}",
        "@platforms//os:%{OS}",
    ],
    target_compatible_with = [
        "@platforms//cpu:%{CPU}",
        "@platforms//os:%{OS}",
    ],
    toolchain = ":rustfmt_toolchain_impl",
    toolchain_type = "@rules_rust//rust/rustfmt:toolchain_type",
    visibility = ["//visibility:public"],
)

# Keep compiler and linker inputs distinct. Most importantly, no C/C++ action
# receives the Rust standard-library tree merely because both use this SDK.
filegroup(
    name = "cc_headers",
    srcs = glob([
        "lib/clang/current/include/**",
        # Clang validates a GCC installation before deriving its C++ include
        # paths, so the small GCC marker/start-file directory is a compile
        # input as well as a link input.
        "sysroot/usr/include/**",
        "sysroot/usr/lib/gcc/**",
        "sysroot/System/Library/Frameworks/**",
        "sysroot/System/Library/PrivateFrameworks/**",
    ], allow_empty = True),
)

filegroup(
    name = "cc_compiler_files",
    srcs = [
        ":cc_headers",
        ":host_libraries",
        "bin/clang",
        "bin/clang.cfg",
    ],
)

filegroup(
    name = "cc_linker_files",
    srcs = [
        ":host_libraries",
        "bin/clang",
        "bin/clang.cfg",
        "%{LINKER}",
    ] + glob([
        "sysroot/usr/lib/**",
        "sysroot/System/Library/Frameworks/**",
    ], allow_empty = True),
)

filegroup(
    name = "cc_toolchain_files",
    srcs = [
        ":cc_compiler_files",
        ":cc_linker_files",
        "bin/llvm-ar",
        "bin/llvm-cov",
        "bin/llvm-dwp",
        "bin/llvm-nm",
        "bin/llvm-objcopy",
        "bin/llvm-objdump",
        "bin/llvm-strip",
    ],
)

cc_toolchain_config(
    name = "cc_toolchain_config",
    abi_libc_version = "%{LIBC}",
    abi_version = "local",
    archive_flags = ["rcsD"],
    compiler = "clang",
    compile_flags = [
        "-no-canonical-prefixes",
        "-Wno-builtin-macro-redefined",
        "-D__DATE__=\"redacted\"",
        "-D__TIME__=\"redacted\"",
        "-D__TIMESTAMP__=\"redacted\"",
    ] + %{BAZEL_COMPILE_FLAGS},
    cpu = "%{CPU}",
    cxx_builtin_include_directories = %{CXX_INCLUDES},
    cxx_flags = ["-std=c++17"],
    host_system_name = "%{SYSTEM}",
    link_libs = %{LINK_LIBS},
    supports_start_end_lib = True,
    target_libc = "%{LIBC}",
    target_system_name = "%{RUST_TRIPLE}",
    tool_paths = {
        "ar": "bin/llvm-ar",
        "cpp": "bin/clang",
        "dwp": "bin/llvm-dwp",
        "gcc": "bin/clang",
        "gcov": "bin/llvm-cov",
        "ld": "%{LINKER}",
        "nm": "bin/llvm-nm",
        "objcopy": "bin/llvm-objcopy",
        "objdump": "bin/llvm-objdump",
        "strip": "bin/llvm-strip",
    },
    toolchain_identifier = "nix-portable-clang-%{SYSTEM}",
)

cc_toolchain(
    name = "cc_toolchain_impl",
    all_files = ":cc_toolchain_files",
    ar_files = ":cc_toolchain_files",
    as_files = ":cc_compiler_files",
    compiler_files = ":cc_compiler_files",
    dwp_files = ":cc_toolchain_files",
    linker_files = ":cc_linker_files",
    objcopy_files = ":cc_toolchain_files",
    strip_files = ":cc_toolchain_files",
    supports_param_files = 1,
    toolchain_config = ":cc_toolchain_config",
    toolchain_identifier = "nix-portable-clang-%{SYSTEM}",
)

toolchain(
    name = "cc_toolchain",
    exec_compatible_with = [
        "@platforms//cpu:%{CPU}",
        "@platforms//os:%{OS}",
    ],
    target_compatible_with = [
        "@platforms//cpu:%{CPU}",
        "@platforms//os:%{OS}",
    ],
    toolchain = ":cc_toolchain_impl",
    toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
    visibility = ["//visibility:public"],
)
