# Build the static nice the NAS needs.
#
# LXD runs image unpacking through nice to keep it from starving the rest of the
# system, and QTS has no nice in the daemon's PATH. See nice/nice.c: a small tool
# of our own, for the same reason as prlimit.
#
# Alpine + musl + -static: one file, no libraries, nothing to match on the NAS.
ARG ALPINE=3.22
FROM alpine:${ALPINE}

RUN apk add --no-cache build-base file

COPY nice/nice.c /src/nice.c

RUN gcc -static -O2 -Wall -Wextra -Werror -o /nice /src/nice.c \
    && strip -s /nice \
    && file /nice \
    && /nice --version
