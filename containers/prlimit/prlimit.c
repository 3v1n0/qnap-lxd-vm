/*
 * A static prlimit for the NAS.
 *
 * LXD runs qemu-img through prlimit so that a malformed image cannot make it
 * consume unbounded CPU or memory (lxd/storage/utils.go):
 *
 *   prlimit --cpu=2 --as=1000000000 qemu-img info -f qcow2 --output=json <img>
 *
 * QTS has no prlimit, and neither busybox nor toybox provide one, so this sets
 * the limits asked for and execs the rest of the command line. The option names
 * and the value syntax follow util-linux ("unlimited", "-1", or "soft:hard"),
 * so anything LXD passes keeps working.
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

struct limit {
    const char *name;
    int resource;
};

static const struct limit limits[] = {
    {"as", RLIMIT_AS},
    {"core", RLIMIT_CORE},
    {"cpu", RLIMIT_CPU},
    {"data", RLIMIT_DATA},
    {"fsize", RLIMIT_FSIZE},
    {"locks", RLIMIT_LOCKS},
    {"memlock", RLIMIT_MEMLOCK},
    {"msgqueue", RLIMIT_MSGQUEUE},
    {"nice", RLIMIT_NICE},
    {"nofile", RLIMIT_NOFILE},
    {"nproc", RLIMIT_NPROC},
    {"rss", RLIMIT_RSS},
    {"rtprio", RLIMIT_RTPRIO},
    {"rttime", RLIMIT_RTTIME},
    {"sigpending", RLIMIT_SIGPENDING},
    {"stack", RLIMIT_STACK},
    {NULL, 0},
};

static int parse_value(const char *text, rlim_t *value)
{
    char *end;
    unsigned long long number;

    if (strcmp(text, "unlimited") == 0 || strcmp(text, "-1") == 0) {
        *value = RLIM_INFINITY;
        return 0;
    }

    errno = 0;
    number = strtoull(text, &end, 10);
    if (errno != 0 || *end != '\0') {
        return -1;
    }

    *value = (rlim_t)number;
    return 0;
}

static int apply(const char *name, const char *text)
{
    const struct limit *limit;
    struct rlimit rl;
    char soft[64];
    const char *hard = text;
    const char *colon;
    size_t length;

    for (limit = limits; limit->name != NULL; limit++) {
        if (strcmp(limit->name, name) == 0) {
            break;
        }
    }

    if (limit->name == NULL) {
        fprintf(stderr, "prlimit: unknown limit: %s\n", name);
        return -1;
    }

    colon = strchr(text, ':');
    if (colon != NULL) {
        length = (size_t)(colon - text);
        if (length >= sizeof(soft)) {
            fprintf(stderr, "prlimit: value too long for %s\n", name);
            return -1;
        }
        memcpy(soft, text, length);
        soft[length] = '\0';
        text = soft;
        hard = colon + 1;
    }

    if (parse_value(text, &rl.rlim_cur) != 0 || parse_value(hard, &rl.rlim_max) != 0) {
        fprintf(stderr, "prlimit: invalid value for %s: %s\n", name, hard);
        return -1;
    }

    if (setrlimit(limit->resource, &rl) != 0) {
        fprintf(stderr, "prlimit: cannot set %s: %s\n", name, strerror(errno));
        return -1;
    }

    return 0;
}

int main(int argc, char **argv)
{
    int i;

    for (i = 1; i < argc; i++) {
        const char *arg = argv[i];
        const char *name;
        const char *value;
        char option[64];
        size_t length;

        if (strcmp(arg, "--version") == 0) {
            printf("prlimit (qnap-lxd-vm) 1.0\n");
            return 0;
        }

        if (strcmp(arg, "--") == 0) {
            i++;
            break;
        }

        if (strncmp(arg, "--", 2) != 0) {
            break;
        }

        name = arg + 2;
        value = strchr(name, '=');
        if (value != NULL) {
            length = (size_t)(value - name);
            if (length >= sizeof(option)) {
                fprintf(stderr, "prlimit: option name too long\n");
                return 2;
            }
            memcpy(option, name, length);
            option[length] = '\0';
            name = option;
            value++;
        } else {
            if (i + 1 >= argc) {
                fprintf(stderr, "prlimit: %s needs a value\n", arg);
                return 2;
            }
            value = argv[++i];
        }

        if (apply(name, value) != 0) {
            return 1;
        }
    }

    if (i >= argc) {
        fprintf(stderr, "usage: prlimit [--<limit>=<value>]... command [args]...\n");
        return 2;
    }

    execvp(argv[i], &argv[i]);
    fprintf(stderr, "prlimit: %s: %s\n", argv[i], strerror(errno));
    return 127;
}
