load(
    "@rules_rust//rust:toolchain.bzl",
    "rust_stdlib_filegroup",
    "rust_toolchain",
    "rustfmt_toolchain",
)
load("@bazel_tools//tools/sh:sh_toolchain.bzl", "sh_toolchain")

package(default_visibility = ["//visibility:private"])

sh_toolchain(
    name = "sh_toolchain_impl",
    path = "%{SHELL}",
)

toolchain(
    name = "sh_toolchain",
    exec_compatible_with = ["@platforms//os:%{OS}"],
    toolchain = ":sh_toolchain_impl",
    toolchain_type = "@bazel_tools//tools/sh:toolchain_type",
    visibility = ["//visibility:public"],
)

filegroup(
    name = "cargo",
    srcs = ["bin/cargo"],
)

filegroup(
    name = "cargo_clippy",
    srcs = ["bin/cargo-clippy"],
)

filegroup(
    name = "clippy_driver",
    srcs = ["bin/clippy-driver"],
)

filegroup(
    name = "rustc",
    srcs = ["bin/rustc"],
)

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
    binary_ext = "",
    cargo = ":cargo",
    cargo_clippy = ":cargo_clippy",
    channel = "stable",
    clippy_driver = ":clippy_driver",
    default_edition = "2024",
    dylib_ext = "%{DYLIB_EXT}",
    exec_triple = "%{RUST_TRIPLE}",
    rust_doc = ":rustdoc",
    rust_std = ":rust_std",
    rustc = ":rustc",
    rustc_lib = ":rustc_lib",
    rustfmt = ":rustfmt",
    staticlib_ext = ".a",
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
