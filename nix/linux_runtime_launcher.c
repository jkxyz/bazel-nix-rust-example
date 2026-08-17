/*
 * Run a tool with the dynamic loader and libraries shipped beside it.
 *
 * PT_INTERP contains an absolute path, so patching an ELF interpreter cannot
 * make a dynamically linked executable relocatable. This launcher is static:
 * it finds the SDK through /proc/self/exe, then invokes the bundled glibc
 * loader explicitly. A separate copy is installed for every exported tool;
 * its basename selects the matching real executable in libexec/.
 */
#define _GNU_SOURCE

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef LOADER_NAME
#error "LOADER_NAME must name the bundled glibc dynamic loader"
#endif

static void fail(const char *operation) {
    fprintf(stderr, "portable SDK launcher: %s: %s\n", operation, strerror(errno));
    exit(127);
}

static char *join(const char *left, const char *right) {
    size_t size = strlen(left) + strlen(right) + 1;
    char *result = malloc(size);

    if (result == NULL) {
        errno = ENOMEM;
        fail("malloc");
    }
    snprintf(result, size, "%s%s", left, right);
    return result;
}

int main(int argc, char **argv) {
    char executable[PATH_MAX + 1];
    ssize_t length = readlink("/proc/self/exe", executable, PATH_MAX);
    if (length < 0) {
        fail("readlink /proc/self/exe");
    }
    if (length == PATH_MAX) {
        fputs("portable SDK launcher: executable path is too long\n", stderr);
        return 127;
    }
    executable[length] = '\0';

    char *tool = strrchr(executable, '/');
    if (tool == NULL || tool == executable) {
        fputs("portable SDK launcher: executable has no tool name\n", stderr);
        return 127;
    }
    *tool++ = '\0';

    char *bin = strrchr(executable, '/');
    if (bin == NULL || strcmp(bin + 1, "bin") != 0) {
        fputs("portable SDK launcher: executable is not inside an SDK bin directory\n", stderr);
        return 127;
    }
    *bin = '\0';
    const char *root = executable;

    char *loader_suffix = join("/lib/", LOADER_NAME);
    char *loader = join(root, loader_suffix);
    char *real_prefix = join(root, "/libexec/");
    char *real_tool = join(real_prefix, tool);
    char *library_prefix = join(root, "/lib:");
    char *sysroot_libraries = join(root, "/sysroot/usr/lib");
    char *library_path = join(library_prefix, sysroot_libraries);
    char *clang_config = join(root, "/bin/clang.cfg");
    char *clang_config_argument = join("--config=", clang_config);
    int add_clang_driver_options = strcmp(tool, "clang") == 0 &&
                                   !(argc > 1 && strncmp(argv[1], "-cc1", 4) == 0);

    /* Loader options, an optional Clang config, arguments, and a null entry. */
    char **loader_argv = calloc((size_t)argc + 8, sizeof(char *));
    if (loader_argv == NULL) {
        errno = ENOMEM;
        fail("calloc");
    }
    loader_argv[0] = loader;
    loader_argv[1] = "--library-path";
    loader_argv[2] = library_path;
    loader_argv[3] = "--argv0";
    loader_argv[4] = argv[0];
    loader_argv[5] = real_tool;
    int prefix = 5;
    if (add_clang_driver_options) {
        loader_argv[++prefix] = clang_config_argument;
        /* Clang otherwise rediscovers ld-linux through /proc/self/exe and
         * attempts to execute the loader itself as its -cc1 frontend. */
        loader_argv[++prefix] = "-fintegrated-cc1";
    }
    for (int index = 1; index < argc; ++index) {
        loader_argv[index + prefix] = argv[index];
    }

    execv(loader, loader_argv);
    fail(loader);
}
