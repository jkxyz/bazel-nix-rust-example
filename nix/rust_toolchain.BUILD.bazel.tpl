load(
    "@rules_rust//rust:toolchain.bzl",
    "rust_stdlib_filegroup",
    "rust_toolchain",
    "rustfmt_toolchain",
)

package(default_visibility = ["//visibility:private"])

filegroup(
    name = "rustc_lib",
    srcs = glob(
        [
            "lib/*.so*",
            "lib/*.dylib*",
            "lib/rustlib/%{RUST_TRIPLE}/bin/**",
            "lib/rustlib/%{RUST_TRIPLE}/codegen-backends/**",
            "lib/rustlib/%{RUST_TRIPLE}/lib/*.so*",
            "lib/rustlib/%{RUST_TRIPLE}/lib/*.dylib*",
        ],
        allow_empty = True,
    ),
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
    binary_ext = "",
    cargo = "bin/cargo",
    cargo_clippy = "bin/cargo-clippy",
    channel = "stable",
    clippy_driver = "bin/clippy-driver",
    default_edition = "2024",
    dylib_ext = "%{DYLIB_EXT}",
    exec_triple = "%{RUST_TRIPLE}",
    rust_doc = "bin/rustdoc",
    rust_std = ":rust_std",
    rustc = "bin/rustc",
    rustc_lib = ":rustc_lib",
    staticlib_ext = ".a",
    stdlib_linkflags = [
%{RUST_STDLIB_LINKFLAGS}
    ],
    target_triple = "%{RUST_TRIPLE}",
    version = "%{RUST_VERSION}",
)

rustfmt_toolchain(
    name = "rustfmt_toolchain_impl",
    rustc = "bin/rustc",
    rustc_lib = ":rustc_lib",
    rustfmt = "bin/rustfmt",
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
