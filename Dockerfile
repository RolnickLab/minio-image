# syntax=docker/dockerfile:1.7
#
# MinIO server + mc client built from source at pinned git tags, for CI and local development.
#
# Both binaries are compiled from the PGSTY forks (pgsty/silo and pgsty/mc) that continue the archived
# minio/minio and minio/mc projects. The clone is verified against a pinned commit SHA, so a moved tag
# fails the build instead of silently changing the image. Compilation happens on the build platform and
# cross-compiles for the target, so a multi-arch build needs no QEMU.
#
# All ARG values are supplied from versions.env by build.sh and the GitHub Actions workflow.

ARG GO_IMAGE
ARG RUNTIME_IMAGE

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS build
RUN apk add --no-cache git
ARG TARGETOS TARGETARCH
ARG MINIO_REPO MINIO_TAG MINIO_COMMIT
ARG MC_REPO MC_TAG MC_COMMIT
WORKDIR /src

# The forks' own buildscripts/gen-ldflags.go stamps the version, release tag and commit into the binary,
# so `minio --version` and `mc --version` report the pinned release rather than DEVELOPMENT.
# The release tag RELEASE.YYYY-MM-DDTHH-MM-SSZ becomes the version string YYYY-MM-DDTHH:MM:SSZ.

RUN git clone --quiet --depth 1 --branch "${MINIO_TAG}" "${MINIO_REPO}" minio \
    && cd minio \
    && test "$(git rev-parse HEAD)" = "${MINIO_COMMIT}" \
        || { echo "minio: tag ${MINIO_TAG} resolves to $(git rev-parse HEAD), expected ${MINIO_COMMIT}" >&2; exit 1; }
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    cd minio \
    && VERSION="$(echo "${MINIO_TAG#RELEASE.}" | sed 's/T\([0-9][0-9]\)-\([0-9][0-9]\)-\([0-9][0-9]\)Z$/T\1:\2:\3Z/')" \
    && LDFLAGS="$(MINIO_RELEASE=RELEASE go run buildscripts/gen-ldflags.go "${VERSION}")" \
    && CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
       go build -tags kqueue -trimpath -ldflags "${LDFLAGS}" -o /out/usr/bin/minio . \
    && mkdir -p /out/licenses/minio \
    && cp LICENSE NOTICE CREDITS /out/licenses/minio/

RUN git clone --quiet --depth 1 --branch "${MC_TAG}" "${MC_REPO}" mc \
    && cd mc \
    && test "$(git rev-parse HEAD)" = "${MC_COMMIT}" \
        || { echo "mc: tag ${MC_TAG} resolves to $(git rev-parse HEAD), expected ${MC_COMMIT}" >&2; exit 1; }
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    cd mc \
    && VERSION="$(echo "${MC_TAG#RELEASE.}" | sed 's/T\([0-9][0-9]\)-\([0-9][0-9]\)-\([0-9][0-9]\)Z$/T\1:\2:\3Z/')" \
    && LDFLAGS="$(MC_RELEASE=RELEASE go run buildscripts/gen-ldflags.go "${VERSION}")" \
    && CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
       go build -tags kqueue -trimpath -ldflags "${LDFLAGS}" -o /out/usr/bin/mc . \
    && mkdir -p /out/licenses/mc \
    && cp LICENSE /out/licenses/mc/ \
    && { test -f NOTICE && cp NOTICE /out/licenses/mc/ || true; } \
    && { test -f CREDITS && cp CREDITS /out/licenses/mc/ || true; }

# World-writable so the data volume works whichever uid the container is started with.
RUN mkdir -p /out/data && chmod 0777 /out/data

# The runtime stage only copies files, so the arm64 variant builds on an amd64 runner without emulation.
FROM ${RUNTIME_IMAGE}
ARG MINIO_REPO MINIO_TAG MINIO_COMMIT MC_REPO MC_TAG MC_COMMIT
ARG SOURCE_URL="https://github.com/RolnickLab/minio-image"
ARG SOURCE_REVISION=""
LABEL org.opencontainers.image.title="MinIO server and mc client (community build)" \
      org.opencontainers.image.description="MinIO-compatible S3 server and mc client compiled from the pgsty/silo and pgsty/mc forks at pinned tags, for CI and local development." \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.revision="${SOURCE_REVISION}" \
      org.opencontainers.image.version="${MINIO_TAG}" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.insectai.minio.source="${MINIO_REPO}" \
      org.insectai.minio.tag="${MINIO_TAG}" \
      org.insectai.minio.commit="${MINIO_COMMIT}" \
      org.insectai.mc.source="${MC_REPO}" \
      org.insectai.mc.tag="${MC_TAG}" \
      org.insectai.mc.commit="${MC_COMMIT}"
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /out/ /
# The entrypoint creates MINIO_DEFAULT_BUCKETS at startup; the health check reports healthy only once the
# server is ready and those buckets exist. See README "Creating buckets at startup".
COPY --chmod=0755 docker-entrypoint.sh /usr/bin/docker-entrypoint.sh
COPY --chmod=0755 minio-healthcheck /usr/bin/minio-healthcheck
EXPOSE 9000 9001
VOLUME ["/data"]
HEALTHCHECK --interval=5s --timeout=5s --start-period=10s --retries=12 CMD ["/usr/bin/minio-healthcheck"]
ENTRYPOINT ["/usr/bin/docker-entrypoint.sh"]
CMD ["server", "/data", "--console-address", ":9001"]
