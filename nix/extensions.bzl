"""Materializes the current host's portable Nix SDK as Bazel toolchains."""

visibility("//")

_REPOSITORY_NAME = "nix_portable_toolchain"

def _fail_nix_build(command, result):
    fail("""Nix could not create the portable toolchain archive.
Command: {command}
Exit code: {return_code}
Standard output:
{stdout}
Standard error:
{stderr}""".format(
        command = " ".join([str(argument) for argument in command]),
        return_code = result.return_code,
        stderr = result.stderr,
        stdout = result.stdout,
    ))

def _read_metadata(repository_ctx):
    values = {}
    for line in repository_ctx.read("TOOLCHAIN-METADATA").splitlines():
        key, separator, value = line.partition(" = ")
        if separator:
            values[key] = value

    required = [
        "format",
        "system",
        "os",
        "cpu",
        "rust_triple",
        "rust",
        "clang",
        "gcc",
        "binary_ext",
        "staticlib_ext",
        "dylib_ext",
        "libc",
        "cxx_stdlib",
        "cxx_includes",
        "rust_stdlib_linkflags",
        "linker",
    ]
    for key in required:
        if key not in values:
            fail("Portable toolchain metadata has no '{}' entry.".format(key))
    if values["format"] != "2":
        fail("Unsupported portable toolchain format: {}".format(values["format"]))
    return values

def _host_system(repository_ctx):
    os_name = repository_ctx.os.name.lower()
    architecture = repository_ctx.os.arch.lower()
    if os_name == "linux":
        if architecture in ["amd64", "x86_64", "x64"]:
            return "x86_64-linux"
        if architecture in ["aarch64", "arm64"]:
            return "aarch64-linux"
    if os_name in ["mac os x", "macos", "darwin"] and architecture in ["aarch64", "arm64"]:
        return "aarch64-darwin"
    fail("No portable Nix SDK is defined for Bazel host {} / {}.".format(
        repository_ctx.os.name,
        repository_ctx.os.arch,
    ))

def _starlark_list(value):
    if not value:
        return "[]"
    return repr(value.split(";"))

def _builtin_include_list(value, repository_path):
    return repr([
        repository_path + "/" + path
        for path in value.split(";")
        if path
    ])

def _bazel_compile_flags(metadata, repository_path):
    # The portable clang.cfg uses <CFGDIR>, correctly producing absolute paths
    # when the SDK is used on its own. For Bazel compile actions, override only
    # these location flags with execroot-relative spellings so dependency files
    # are stable and pass Bazel's absolute-include validation.
    flags = [
        "--sysroot=" + repository_path + "/sysroot",
        "-resource-dir=" + repository_path + "/lib/clang/current",
        "-B" + repository_path + "/bin",
    ]
    if metadata["os"] == "linux":
        flags.append("--gcc-toolchain=" + repository_path + "/sysroot/usr")
    return repr(flags)

def _nix_portable_toolchain_repository_impl(repository_ctx):
    expected_system = _host_system(repository_ctx)
    nix = repository_ctx.which("nix")
    if nix == None:
        fail("nix was not found in PATH. Run Bazel from `nix develop`.")

    # Resolve every label so Bazel invalidates this generated repository when
    # any part of the flake-side SDK definition changes.
    for source in repository_ctx.attr.sources:
        repository_ctx.path(source)
    flake_root = repository_ctx.path(repository_ctx.attr.flake).dirname
    flake_reference = "path:{}#portable-toolchain".format(flake_root)
    command = [
        nix,
        "build",
        "--no-link",
        "--print-out-paths",
        flake_reference,
    ]

    repository_ctx.report_progress("Building the pinned {} portable SDK".format(expected_system))
    result = repository_ctx.execute(command, quiet = False, timeout = 3600)
    if result.return_code != 0:
        _fail_nix_build(command, result)

    output_lines = [line for line in result.stdout.splitlines() if line]
    if not output_lines:
        fail("nix build succeeded but did not print an output path.")
    archive = output_lines[-1] + "/portable-sdk.tar.gz"
    if not repository_ctx.path(archive).exists:
        fail("The Nix output does not contain portable-sdk.tar.gz: {}".format(archive))

    repository_ctx.report_progress("Extracting the portable SDK into Bazel")
    repository_ctx.extract(archive = archive)
    metadata = _read_metadata(repository_ctx)
    if metadata["system"] != expected_system:
        fail("Bazel is running on {}, but Nix built {}.".format(
            expected_system,
            metadata["system"],
        ))

    rustc_result = repository_ctx.execute(
        [repository_ctx.path("bin/rustc"), "--version", "--verbose"],
        quiet = True,
        timeout = 60,
    )
    if rustc_result.return_code != 0:
        fail("The extracted rustc could not run:\n{}".format(rustc_result.stderr))
    if "host: {}".format(metadata["rust_triple"]) not in rustc_result.stdout:
        fail("The extracted rustc does not match TOOLCHAIN-METADATA.")

    os_constraint = "osx" if metadata["os"] == "macos" else metadata["os"]
    repository_path = "external/{}".format(repository_ctx.name)
    repository_ctx.template(
        "BUILD.bazel",
        repository_ctx.attr.build_template,
        substitutions = {
            "%{BINARY_EXT}": metadata["binary_ext"],
            "%{BAZEL_COMPILE_FLAGS}": _bazel_compile_flags(metadata, repository_path),
            "%{CPU}": metadata["cpu"],
            "%{CXX_INCLUDES}": _builtin_include_list(metadata["cxx_includes"], repository_path),
            "%{DYLIB_EXT}": metadata["dylib_ext"],
            "%{GCC_VERSION}": metadata["gcc"],
            "%{LIBC}": metadata["libc"],
            "%{LINKER}": metadata["linker"],
            "%{LINK_LIBS}": repr(["-l" + metadata["cxx_stdlib"], "-lm"]),
            "%{OS}": os_constraint,
            "%{RUST_STDLIB_LINKFLAGS}": _starlark_list(metadata["rust_stdlib_linkflags"]),
            "%{RUST_TRIPLE}": metadata["rust_triple"],
            "%{RUST_VERSION}": metadata["rust"],
            "%{STATICLIB_EXT}": metadata["staticlib_ext"],
            "%{SYSTEM}": metadata["system"],
        },
    )

_nix_portable_toolchain_repository = repository_rule(
    implementation = _nix_portable_toolchain_repository_impl,
    attrs = {
        "build_template": attr.label(allow_single_file = True, mandatory = True),
        "flake": attr.label(allow_single_file = True, mandatory = True),
        "sources": attr.label_list(allow_files = True, mandatory = True),
    },
    configure = True,
    environ = ["PATH"],
)

def _nix_toolchains_impl(_module_ctx):
    _nix_portable_toolchain_repository(
        name = _REPOSITORY_NAME,
        build_template = "//nix:portable_toolchain.BUILD.bazel.tpl",
        flake = "//:flake.nix",
        sources = [
            "//:flake.lock",
            "//nix:portable_toolchain.nix",
            "//nix:relocate_elf.sh",
            "//nix:relocate_macho.sh",
        ],
    )

nix_toolchains = module_extension(
    implementation = _nix_toolchains_impl,
    arch_dependent = True,
    os_dependent = True,
)
