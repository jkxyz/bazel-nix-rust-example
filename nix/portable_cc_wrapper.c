/*
 * Give Clang paths relative to this executable instead of paths into the Nix
 * store. Bazel may place an external repository anywhere in its execroot, so
 * computing the SDK root at runtime is what makes the archive relocatable.
 */
#define _GNU_SOURCE

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char *sdk_path(const char *root, const char *prefix, const char *suffix) {
    size_t size = strlen(prefix) + strlen(root) + strlen(suffix) + 1;
    char *result = malloc(size);

    if (result == NULL) {
        fputs("portable Clang wrapper: out of memory\n", stderr);
        exit(127);
    }
    snprintf(result, size, "%s%s%s", prefix, root, suffix);
    return result;
}

int main(int argc, char **argv) {
    char executable[PATH_MAX];
    if (strchr(argv[0], '/') != NULL) {
        if (strlen(argv[0]) >= sizeof(executable)) {
            fputs("portable Clang wrapper: executable path is too long\n", stderr);
            return 127;
        }
        strcpy(executable, argv[0]);
    } else {
        ssize_t length = readlink("/proc/self/exe", executable, sizeof(executable) - 1);
        if (length < 0) {
            fprintf(stderr, "portable Clang wrapper: readlink: %s\n", strerror(errno));
            return 127;
        }
        executable[length] = '\0';
    }

    char *bin = strrchr(executable, '/');
    if (bin == NULL) {
        fputs("portable Clang wrapper: executable has no parent directory\n", stderr);
        return 127;
    }
    *bin = '\0';

    char *root_end = strrchr(executable, '/');
    if (root_end == NULL) {
        strcpy(executable, ".");
    } else {
        *root_end = '\0';
    }

    int links = 1;
    for (int index = 1; index < argc; ++index) {
        if (strcmp(argv[index], "-c") == 0 ||
            strcmp(argv[index], "-S") == 0 ||
            strcmp(argv[index], "-E") == 0 ||
            strcmp(argv[index], "-M") == 0 ||
            strcmp(argv[index], "-MM") == 0 ||
            strcmp(argv[index], "-fsyntax-only") == 0) {
            links = 0;
        }
    }

    char **clang_argv = calloc((size_t)argc + 7, sizeof(char *));
    if (clang_argv == NULL) {
        fputs("portable Clang wrapper: out of memory\n", stderr);
        return 127;
    }

    clang_argv[0] = sdk_path(executable, "", "/bin/clang.real");
    clang_argv[1] = sdk_path(executable, "--sysroot=", "/sysroot");
    clang_argv[2] = sdk_path(executable, "-resource-dir=", "/lib/clang/current");
    clang_argv[3] = sdk_path(executable, "--gcc-toolchain=", "/sysroot/usr");
    clang_argv[4] = sdk_path(executable, "-B", "/bin");
    int prefix_count = 5;
    if (links) {
        clang_argv[prefix_count++] = "-fuse-ld=lld";
        clang_argv[prefix_count++] = "-Wl,--dynamic-linker=/lib64/ld-linux-x86-64.so.2";
    }
    for (int index = 1; index < argc; ++index) {
        clang_argv[index + prefix_count - 1] = argv[index];
    }

    execv(clang_argv[0], clang_argv);
    fprintf(stderr, "portable Clang wrapper: execv: %s\n", strerror(errno));
    return 127;
}
