#!/bin/sh
# Container entrypoint: runs the MinIO server and, when MINIO_DEFAULT_BUCKETS is set, creates those
# buckets (and their anonymous-access policies) once the server is ready. This removes the need for a
# separate init container in compose stacks.
#
#   MINIO_DEFAULT_BUCKETS="media:public,backups"   # name[:policy], comma-separated
#
# The policy is one of mc's anonymous-access policies: none, download, upload, public. A bucket without a
# policy is created private. The variable name and format match the old Bitnami MinIO image.
#
# Anything other than `server ...` (for example `--version`) is passed straight to the minio binary.
# Without MINIO_DEFAULT_BUCKETS the server is exec'd directly, exactly as before this script existed.
# The API port is read from `--address` (default 9000) and shared with minio-healthcheck via a file.
set -eu

MARKER=/tmp/minio-default-buckets.ready
PORT_FILE=/tmp/minio-api-port
READY_TIMEOUT="${MINIO_DEFAULT_BUCKETS_TIMEOUT:-120}"

log() { echo "minio-default-buckets: $*"; }

if [ "${1:-}" != "server" ]; then
    exec /usr/bin/minio "$@"
fi

# Find the API port from `--address HOST:PORT` or `--address=HOST:PORT`; the last occurrence wins.
address=""
prev=""
for arg in "$@"; do
    case "$prev" in --address) address="$arg" ;; esac
    case "$arg" in --address=*) address="${arg#--address=}" ;; esac
    prev="$arg"
done
port=9000
if [ -n "$address" ]; then
    port="${address##*:}"
fi
case "$port" in
    '' | *[!0-9]*) echo "docker-entrypoint.sh: cannot read a port from --address '$address'" >&2; exit 64 ;;
esac

# A restarted container keeps /tmp, so clear the marker before the buckets are (re)checked.
rm -f "$MARKER"
echo "$port" > "$PORT_FILE"

if [ -z "${MINIO_DEFAULT_BUCKETS:-}" ]; then
    exec /usr/bin/minio "$@"
fi

/usr/bin/minio "$@" &
server_pid=$!
trap 'kill -TERM "$server_pid" 2>/dev/null || true' TERM INT

# Returns the server's exit status once it has exited, surviving waits interrupted by a trapped signal.
wait_for_server() {
    status=0
    while :; do
        wait "$server_pid" && status=0 || status=$?
        kill -0 "$server_pid" 2>/dev/null || break
    done
    return "$status"
}

fail() {
    echo "minio-default-buckets: $*; stopping the server" >&2
    kill -TERM "$server_pid" 2>/dev/null || true
    wait_for_server || true
    exit 1
}

# A private mc config directory keeps credentials out of any ~/.mc the user may have mounted.
MC_CONFIG_DIR="$(mktemp -d /tmp/minio-entrypoint-mc.XXXXXX)"
export MC_CONFIG_DIR
endpoint="http://127.0.0.1:${port}"

# `mc ready` retries forever, so bound each attempt and check the server is still running between them.
elapsed=0
until MC_HOST_local="$endpoint" timeout 2 mc ready local >/dev/null 2>&1; do
    if ! kill -0 "$server_pid" 2>/dev/null; then
        wait_for_server && exit 0 || exit $?
    fi
    elapsed=$((elapsed + 3))
    [ "$elapsed" -lt "$READY_TIMEOUT" ] || fail "server not ready after ${READY_TIMEOUT}s"
    sleep 1
done

mc alias set local "$endpoint" "${MINIO_ROOT_USER:-minioadmin}" "${MINIO_ROOT_PASSWORD:-minioadmin}" >/dev/null \
    || fail "could not authenticate to the server"

old_ifs="$IFS"
IFS=,
for entry in $MINIO_DEFAULT_BUCKETS; do
    IFS="$old_ifs"
    entry="$(echo "$entry" | tr -d '[:space:]')"
    [ -n "$entry" ] || continue
    name="${entry%%:*}"
    policy=""
    case "$entry" in *:*) policy="${entry#*:}" ;; esac
    case "$policy" in
        '' | none | download | upload | public) ;;
        *) fail "bucket '$name' has unknown policy '$policy' (use none, download, upload or public)" ;;
    esac
    mc mb --ignore-existing "local/$name" >/dev/null || fail "could not create bucket '$name'"
    if [ -n "$policy" ]; then
        mc anonymous set "$policy" "local/$name" >/dev/null || fail "could not set policy '$policy' on '$name'"
        log "bucket '$name' ready (anonymous access: $policy)"
    else
        log "bucket '$name' ready"
    fi
done
IFS="$old_ifs"

rm -rf "$MC_CONFIG_DIR"
touch "$MARKER"
log "all buckets ready"

wait_for_server && exit 0 || exit $?
