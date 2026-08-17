"""Exposes the Nix development shell's Rust derivation to rules_rust."""

visibility("//")

_RUST_ROOT_ENV = "NIX_RUST_TOOLCHAIN"

_HOSTS = {
    "aarch64-apple-darwin": {
        "cpu": "aarch64",
        "dylib_ext": ".dylib",
        "os": "osx",
        "stdlib_linkflags": ["-lSystem", "-lresolv"],
    },
    "aarch64-unknown-linux-gnu": {
        "cpu": "aarch64",
        "dylib_ext": ".so",
        "os": "linux",
        "stdlib_linkflags": ["-ldl", "-lpthread"],
    },
    "x86_64-unknown-linux-gnu": {
        "cpu": "x86_64",
        "dylib_ext": ".so",
        "os": "linux",
        "stdlib_linkflags": ["-ldl", "-lpthread"],
    },
}

def _nix_rust_toolchain_impl(repository_ctx):
    rust_root = repository_ctx.os.environ.get(_RUST_ROOT_ENV)
    if not rust_root:
        fail("{} is not set. Run Bazel from `nix develop`.".format(_RUST_ROOT_ENV))
    rustc = repository_ctx.path(rust_root + "/bin/rustc")
    if not rustc.exists:
        fail("{} does not contain bin/rustc: {}".format(_RUST_ROOT_ENV, rust_root))

    version_result = repository_ctx.execute(
        [rustc, "--version", "--verbose"],
        quiet = True,
        timeout = 60,
    )
    if version_result.return_code != 0:
        fail("The Nix development shell's rustc could not run:\n{}".format(version_result.stderr))

    host_triple = None
    rust_version = None
    for line in version_result.stdout.splitlines():
        if line.startswith("host: "):
            host_triple = line[len("host: "):]
        elif line.startswith("release: "):
            rust_version = line[len("release: "):]

    host = _HOSTS.get(host_triple)
    if host == None:
        fail("The Nix Rust toolchain has unsupported host triple '{}'; supported triples are {}.".format(
            host_triple or "unknown",
            ", ".join(sorted(_HOSTS.keys())),
        ))
    if rust_version == None:
        fail("rustc --version --verbose did not report a release version.")

    # These are shallow links into the Nix store by design. Build actions run
    # inside the same Nix environment and may use the derivation's references.
    repository_ctx.symlink(rust_root + "/bin", "bin")
    repository_ctx.symlink(rust_root + "/lib", "lib")
    repository_ctx.template(
        "BUILD.bazel",
        repository_ctx.path(Label("//nix:rust_toolchain.BUILD.bazel.tpl")),
        substitutions = {
            "%{CPU}": host["cpu"],
            "%{DYLIB_EXT}": host["dylib_ext"],
            "%{OS}": host["os"],
            "%{RUST_STDLIB_LINKFLAGS}": "\n".join(["        {},".format(repr(flag)) for flag in host["stdlib_linkflags"]]),
            "%{RUST_TRIPLE}": host_triple,
            "%{RUST_VERSION}": rust_version,
        },
    )

nix_rust_toolchain = repository_rule(
    implementation = _nix_rust_toolchain_impl,
    configure = True,
    environ = [_RUST_ROOT_ENV],
)
