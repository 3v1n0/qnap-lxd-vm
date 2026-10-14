/*
 * A static nice for the NAS.
 *
 * LXD runs image unpacking at low priority so it does not starve the rest of the
 * system (lxd/storage/utils.go):
 *
 *   nice -n19 qemu-img convert -f qcow2 -O raw <img> <dst>
 *
 * QTS has no nice in the daemon's PATH, so this adds the requested adjustment to
 * the current niceness (as coreutils and util-linux do) and execs the rest of
 * the command line.
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

static int usage(void)
{
    fprintf(stderr, "usage: nice [-n adjustment] command [args]...\n");
    return 2;
}

static int parse(long *out, const char *text)
{
    char *end;

    *out = strtol(text, &end, 10);
    if (*end != '\0') {
        return -1;
    }

    return 0;
}

int main(int argc, char **argv)
{
    long adjustment = 10;
    long current;
    int i = 1;

    if (i < argc && strcmp(argv[i], "--version") == 0) {
        printf("nice (qnap-vsock) 1.0\n");
        return 0;
    }

    for (; i < argc; i++) {
        const char *arg = argv[i];

        if (strncmp(arg, "-n", 2) == 0) {
            /* -n19 and -n 19, the forms coreutils and util-linux accept */
            const char *value = arg + 2;

            if (*value == '\0') {
                if (i + 1 >= argc) {
                    return usage();
                }
                value = argv[++i];
            }
            if (parse(&adjustment, value) != 0) {
                return usage();
            }
        } else if (strncmp(arg, "--adjustment=", 13) == 0) {
            if (parse(&adjustment, arg + 13) != 0) {
                return usage();
            }
        } else if (arg[0] == '-' && arg[1] >= '0' && arg[1] <= '9') {
            /* the historical form: nice -19 command */
            if (parse(&adjustment, arg + 1) != 0) {
                return usage();
            }
        } else if (strcmp(arg, "--") == 0) {
            i++;
            break;
        } else {
            break;
        }
    }

    if (i >= argc) {
        return usage();
    }

    errno = 0;
    current = getpriority(PRIO_PROCESS, 0);
    if (current == -1 && errno != 0) {
        /* Same as coreutils: warn and carry on with the adjustment alone. */
        fprintf(stderr, "nice: cannot read niceness: %s\n", strerror(errno));
        current = 0;
    }

    if (setpriority(PRIO_PROCESS, 0, (int)(current + adjustment)) != 0) {
        fprintf(stderr, "nice: cannot set niceness: %s\n", strerror(errno));
    }

    execvp(argv[i], &argv[i]);
    fprintf(stderr, "nice: %s: %s\n", argv[i], strerror(errno));
    return 127;
}
