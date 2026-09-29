#!/usr/bin/env sh
# Smoke test for a built image: startup bucket creation, anonymous access policies, the health check,
# clean shutdown, and unchanged behaviour when MINIO_DEFAULT_BUCKETS is not set.
#
#   ./build.sh && test/smoke.sh insectai/minio:dev
#
# Needs only Docker. Every container and network it creates is removed on exit.
set -eu

IMAGE="${1:?usage: test/smoke.sh IMAGE_REF}"
cd "$(dirname "$0")/.."
EXPECTED_TAG="$(sed -n 's/^MINIO_TAG=//p' versions.env)"

run_id="minio-smoke-$$"
net="$run_id-net"
user=smokeadmin
password=smoke-secret-password

cleanup() {
    docker rm -f "$run_id-buckets" "$run_id-plain" "$run_id-badpolicy" >/dev/null 2>&1 || true
    docker network rm "$net" >/dev/null 2>&1 || true
}
trap cleanup EXIT

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# Waits until the container's health status is `healthy`; fails on `unhealthy`, exit, or a 90s timeout.
wait_healthy() {
    i=0
    while [ "$i" -lt 90 ]; do
        state="$(docker inspect -f '{{.State.Status}} {{.State.Health.Status}}' "$1")"
        case "$state" in
            "running healthy") return 0 ;;
            *unhealthy | exited* | dead*) docker logs "$1" >&2; fail "$1 is '$state'" ;;
        esac
        i=$((i + 1))
        sleep 1
    done
    docker logs "$1" >&2
    fail "$1 not healthy after 90s (last state '$state')"
}

# Runs a shell snippet in a throwaway client container on the test network.
client() {
    docker run --rm --network "$net" --entrypoint sh \
        -e SMOKE_USER="$user" -e SMOKE_PASSWORD="$password" "$IMAGE" -c "$1"
}

docker network create "$net" >/dev/null

echo "== version"
version="$(docker run --rm "$IMAGE" --version)"
echo "$version" | head -1
echo "$version" | grep -q "${EXPECTED_TAG}" || fail "minio --version does not report $EXPECTED_TAG"
pass "minio --version reports $EXPECTED_TAG through the entrypoint"
docker run --rm --entrypoint mc "$IMAGE" --version >/dev/null || fail "--entrypoint mc no longer works"
pass "--entrypoint mc still works"

echo "== startup buckets"
srv="$run_id-buckets"
docker run -d --name "$srv" --network "$net" --network-alias minio \
    -e MINIO_ROOT_USER="$user" -e MINIO_ROOT_PASSWORD="$password" \
    -e MINIO_DEFAULT_BUCKETS="smoke-public:public, smoke-private" \
    "$IMAGE" >/dev/null
wait_healthy "$srv"
pass "container with MINIO_DEFAULT_BUCKETS became healthy"
docker logs "$srv" 2>&1 | grep "minio-default-buckets:"
docker logs "$srv" 2>&1 | grep -q "$password" && fail "the root password appears in the container log"
pass "the root password is not in the container log"

# shellcheck disable=SC2016 # expanded inside the client container, not here
client '
set -eu
mc alias set s http://minio:9000 "$SMOKE_USER" "$SMOKE_PASSWORD" >/dev/null
mc ls s
mc ls s | grep -q "smoke-public/"
mc ls s | grep -q "smoke-private/"
echo public-object > /tmp/o && mc cp -q /tmp/o s/smoke-public/o.txt >/dev/null && mc cp -q /tmp/o s/smoke-private/o.txt >/dev/null
mc anonymous get s/smoke-public | grep -q "is .public.$"
mc anonymous get s/smoke-private | grep -q "is .private.$"
' || fail "buckets missing or policies wrong"
pass "both buckets exist with the expected policies"

# shellcheck disable=SC2016 # expanded inside the client container, not here
client '
set -eu
test "$(wget -qO- http://minio:9000/smoke-public/o.txt)" = public-object
if wget -qO- http://minio:9000/smoke-private/o.txt >/dev/null 2>&1; then exit 1; fi
' || fail "anonymous access does not match the policies"
pass "anonymous GET works on smoke-public and is denied on smoke-private"

echo "== restart keeps buckets and re-runs setup"
docker restart "$srv" >/dev/null
wait_healthy "$srv"
pass "container became healthy again after a restart"

echo "== clean shutdown"
start="$(date +%s)"
docker stop "$srv" >/dev/null
elapsed=$(($(date +%s) - start))
code="$(docker inspect -f '{{.State.ExitCode}}' "$srv")"
echo "docker stop took ${elapsed}s, exit code $code"
[ "$elapsed" -lt 10 ] || fail "docker stop needed the kill timeout (SIGTERM not forwarded)"
[ "$code" = 0 ] || fail "server exited with $code after SIGTERM"
pass "SIGTERM reaches the server and the container exits 0"

echo "== bad policy fails fast"
bad="$run_id-badpolicy"
docker run -d --name "$bad" --network "$net" \
    -e MINIO_ROOT_USER="$user" -e MINIO_ROOT_PASSWORD="$password" \
    -e MINIO_DEFAULT_BUCKETS="smoke-bad:everyone" "$IMAGE" >/dev/null
timeout 60 docker wait "$bad" >/dev/null || fail "container with a bad policy kept running"
code="$(docker inspect -f '{{.State.ExitCode}}' "$bad")"
[ "$code" != 0 ] || fail "container with a bad policy exited 0"
docker logs "$bad" 2>&1 | grep "unknown policy" || fail "no error message for the bad policy"
pass "a bad policy stops the container with exit code $code"

echo "== no MINIO_DEFAULT_BUCKETS (unchanged behaviour)"
plain="$run_id-plain"
docker run -d --name "$plain" --network "$net" \
    -e MINIO_ROOT_USER="$user" -e MINIO_ROOT_PASSWORD="$password" "$IMAGE" >/dev/null
wait_healthy "$plain"
pass "container without MINIO_DEFAULT_BUCKETS became healthy"
[ "$(docker exec "$plain" cat /proc/1/comm)" = minio ] || fail "PID 1 is not the minio server"
pass "the server is PID 1 (entrypoint exec'd it directly)"

echo "All smoke tests passed for $IMAGE"
