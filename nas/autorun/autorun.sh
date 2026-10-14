#!/bin/sh
#
# Boot hook for the plain (non-App-Center) install.
#
# QNAP runs a user script named autorun.sh at boot; where it lives depends on
# the firmware. This script is the body to use: it is idempotent, so wiring it
# into QNAP's autorun mechanism, a scheduled task on boot, or your own init
# script all work. See README.md for the options.
#
# It loads the modules and, as with every other entry point here, only restarts
# LXD when nothing is running.
set -u

STATE_DIR=${QNAP_VSOCK_STATE:-/var/lib/qnap-vsock}
PREFIX=${QNAP_VSOCK_PREFIX:-}

if [ -z "$PREFIX" ] && [ -f "$STATE_DIR/prefix" ]; then
    PREFIX=$(cat "$STATE_DIR/prefix")
fi
if [ -z "$PREFIX" ] || [ ! -x "$PREFIX/shared/qnap-vsock.sh" ]; then
    for PREFIX in /share/*/.qpkg/QNAP_Vsock /share/*/qnap-vsock; do
        [ -x "$PREFIX/shared/qnap-vsock.sh" ] && break
    done
fi

if [ ! -x "$PREFIX/shared/qnap-vsock.sh" ]; then
    echo "autorun: cannot find the qnap-vsock payload (set QNAP_VSOCK_PREFIX)" >&2
    exit 1
fi

exec "$PREFIX/shared/qnap-vsock.sh" install
