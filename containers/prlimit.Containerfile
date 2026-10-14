# Build the static prlimit the NAS needs.
#
# LXD wraps qemu-img in it to bound its CPU and memory use, and nothing on QTS
# provides prlimit. See prlimit/prlimit.c: it is a small tool of our own rather
# than util-linux, because util-linux's prlimit is not an --enable- option (it is
# built only when its dependencies happen to be enabled) and pulling the whole
# autotools build in would buy us nothing here.
#
# Alpine + musl + -static: one file, no libraries, nothing to match on the NAS.
ARG ALPINE=3.22
FROM alpine:${ALPINE}

RUN apk add --no-cache build-base file

COPY prlimit/prlimit.c /src/prlimit.c

RUN gcc -static -O2 -Wall -Wextra -Werror -o /prlimit /src/prlimit.c \
    && strip -s /prlimit \
    && file /prlimit \
    && /prlimit --version
