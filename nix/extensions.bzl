"""Materializes a Nix-built, relocatable Linux SDK as Bazel toolchains."""

visibility("//")

_REPOSITORY_NAME = "nix_portable_toolchain"
_SUPPORTED_HOST_TRIPLE = "x86_64-unknown-linux-gnu"

def _fail_nix_build(command, result):
    fail("""nix-build could not create the portable toolchain archive.
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

    for required in ["format", "host", "rust", "clang", "gcc"]:
        if required not in values:
            fail("Portable toolchain metadata has no '{}' entry.".format(required))
    if values["format"] != "1":
        fail("Unsupported portable toolchain format: {}".format(values["format"]))
    if values["host"] != _SUPPORTED_HOST_TRIPLE:
        fail("This proof of concept supports {}, but Nix built {}.".format(
            _SUPPORTED_HOST_TRIPLE,
            values["host"],
        ))
    return values

def _nix_portable_toolchain_repository_impl(repository_ctx):
    if repository_ctx.os.name != "linux":
        fail("The //nix portable toolchain proof of concept supports Linux only.")
    if repository_ctx.os.arch not in ["amd64", "x86_64"]:
        fail("The //nix portable toolchain proof of concept supports x86-64 only.")

    nix_build = repository_ctx.which("nix-build")
    if nix_build == None:
        fail("nix-build was not found in PATH. Run Bazel from `nix develop`.")

    nix_expression = repository_ctx.path(repository_ctx.attr.nix_expression)
    flake_lock = repository_ctx.path(repository_ctx.attr.flake_lock)
    cc_wrapper = repository_ctx.path(repository_ctx.attr.cc_wrapper)

    # --no-out-link is intentional. Once extract() returns, every action input
    # is a regular file in Bazel's external repository; no Nix store path is
    # part of the registered toolchains.
    command = [
        nix_build,
        nix_expression,
        "--argstr",
        "flakeLock",
        flake_lock,
        "--argstr",
        "ccWrapper",
        cc_wrapper,
        "--no-out-link",
    ]

    repository_ctx.report_progress("Building the pinned, relocatable Nix SDK")
    result = repository_ctx.execute(command, quiet = False, timeout = 3600)
    if result.return_code != 0:
        _fail_nix_build(command, result)

    output_lines = [line for line in result.stdout.splitlines() if line]
    if not output_lines:
        fail("nix-build succeeded but did not print a Nix output path.")
    archive = output_lines[-1] + "/portable-sdk.tar.gz"
    if not repository_ctx.path(archive).exists:
        fail("The Nix output does not contain portable-sdk.tar.gz: {}".format(archive))

    repository_ctx.report_progress("Materializing the portable SDK as Bazel files")
    repository_ctx.extract(archive = archive)

    metadata = _read_metadata(repository_ctx)
    rustc_result = repository_ctx.execute(
        [repository_ctx.path("bin/rustc"), "--version", "--verbose"],
        quiet = True,
        timeout = 60,
    )
    if rustc_result.return_code != 0:
        fail("The extracted rustc could not run:\n{}".format(rustc_result.stderr))
    if "host: {}".format(metadata["host"]) not in rustc_result.stdout:
        fail("The extracted rustc does not match TOOLCHAIN-METADATA.")

    repository_ctx.template(
        "BUILD.bazel",
        repository_ctx.attr.build_template,
        substitutions = {
            "%{GCC_VERSION}": metadata["gcc"],
            "%{RUST_TRIPLE}": metadata["host"],
            "%{RUST_VERSION}": metadata["rust"],
        },
    )

_nix_portable_toolchain_repository = repository_rule(
    implementation = _nix_portable_toolchain_repository_impl,
    attrs = {
        "build_template": attr.label(allow_single_file = True, mandatory = True),
        "cc_wrapper": attr.label(allow_single_file = True, mandatory = True),
        "flake_lock": attr.label(allow_single_file = True, mandatory = True),
        "nix_expression": attr.label(allow_single_file = True, mandatory = True),
    },
    configure = True,
    environ = ["PATH"],
)

def _nix_toolchains_impl(_module_ctx):
    _nix_portable_toolchain_repository(
        name = _REPOSITORY_NAME,
        build_template = "//nix:portable_toolchain.BUILD.bazel.tpl",
        cc_wrapper = "//nix:portable_cc_wrapper.c",
        flake_lock = "//:flake.lock",
        nix_expression = "//nix:portable_toolchain.nix",
    )

nix_toolchains = module_extension(
    implementation = _nix_toolchains_impl,
    arch_dependent = True,
    os_dependent = True,
)
