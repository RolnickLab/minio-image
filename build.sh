#!/usr/bin/env sh
# Build the image locally with the pinned versions from versions.env.
#
#   ./build.sh                         # linux/amd64, loaded into the local Docker daemon as insectai/minio:dev
#   ./build.sh --platform linux/arm64  # any extra arguments are passed to docker buildx build
#
# Set IMAGE_TAG to change the local tag.
set -eu
cd "$(dirname "$0")"
set -a
. ./versions.env
set +a
exec docker buildx build \
    --build-arg GO_IMAGE --build-arg RUNTIME_IMAGE \
    --build-arg MINIO_REPO --build-arg MINIO_TAG --build-arg MINIO_COMMIT \
    --build-arg MC_REPO --build-arg MC_TAG --build-arg MC_COMMIT \
    --build-arg SOURCE_REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)" \
    --tag "${IMAGE_TAG:-insectai/minio:dev}" \
    --load \
    "$@" .
