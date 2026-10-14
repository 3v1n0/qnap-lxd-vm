#!/bin/sh
#
# QPKG service program for QNAP_Vsock.
#
# `start` is run by QTS at boot and when the package is enabled, and is the
# only thing that has to happen: everything else lives in the shared helper.
#
# `stop` deliberately leaves the modules loaded. Unloading vsock while LXD has
# sockets open would break any running VM; disabling or removing the package is
# the way to get rid of them.
QPKG_NAME="QNAP_Vsock"
CONF=/etc/config/qpkg.conf
QPKG_ROOT=$(/sbin/getcfg "$QPKG_NAME" Install_Path -f "$CONF")

export QNAP_QPKG=$QPKG_NAME
export QNAP_VSOCK_PREFIX=$QPKG_ROOT

# qbuild flattens shared/ into the package root, but accept either layout.
HELPER="$QPKG_ROOT/qnap-vsock.sh"
[ -x "$HELPER" ] || HELPER="$QPKG_ROOT/shared/qnap-vsock.sh"

case "$1" in
start)
    # QTS only starts packages it considers enabled, but the flag may not be
    # written yet when "qpkg_cli --enable" runs this: warn instead of refusing,
    # so enabling the package cannot fail over a flag that is about to be set.
    ENABLED=$(/sbin/getcfg "$QPKG_NAME" Enable -u -d FALSE -f "$CONF")
    if [ "$ENABLED" != "TRUE" ]; then
        echo "$QPKG_NAME is not marked enabled in $CONF; starting anyway." >&2
    fi

    if [ ! -x "$HELPER" ]; then
        echo "helper not found: $HELPER" >&2
        exit 1
    fi

    "$HELPER" install
    ;;

stop)
    echo "$QPKG_NAME stopped (modules stay loaded; remove the QPKG to unload them)"
    ;;

restart)
    "$0" stop
    "$0" start
    ;;

remove)
    ;;

*)
    echo "Usage: $0 {start|stop|restart|remove}" >&2
    exit 1
    ;;
esac

exit 0
