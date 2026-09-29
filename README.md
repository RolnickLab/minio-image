# minio-image

A MinIO-compatible S3 server and `mc` client in one small container image, built from source at pinned git tags and published as [`insectai/minio`](https://hub.docker.com/r/insectai/minio) on Docker Hub. It exists so the Antenna test suite and local development stacks stop depending on registries and images that other organisations can withdraw.

## Why this exists

MinIO archived its open-source server and client repositories in 2026, stopped serving binaries from `dl.min.io`, and removed or restricted the `minio/minio` and `minio/mc` images on Docker Hub and quay.io. Each of those changes broke the Antenna CI job for every open pull request at once. This repository builds the image we depend on, from sources we can point to, into a Docker Hub organisation we own.

The `insectai` organisation is a Docker-Sponsored Open Source namespace, so anonymous pulls of this image are not subject to Docker Hub's pull rate limits. That matters on shared CI runners.

## What is in the image

| Component | Source | Notes |
|---|---|---|
| `/usr/bin/minio` | [pgsty/silo](https://github.com/pgsty/silo), the community-maintained fork of `minio/minio` | Built with the fork's own `gen-ldflags.go`, so `minio --version` reports the pinned release. |
| `/usr/bin/mc` | [pgsty/mc](https://github.com/pgsty/mc), the matching fork of `minio/mc` | Same command set as upstream `mc` (`alias set`, `mb`, `anonymous set`, `ready`). |
| `/bin/sh` and BusyBox | Alpine base | Lets an init container run a shell script with `mc`. |
| `/licenses/` | Copied from the source checkouts | AGPL-3.0 licence, NOTICE and CREDITS files. |

The binaries keep their original names (`minio`, `mc`) so existing compose files and scripts work unchanged. The image runs as root by default, like the historical official image, and `/data` is world-writable so a non-root `user:` also works on a fresh volume.

Platforms: `linux/amd64` and `linux/arm64`.

Exact source revisions are recorded in `versions.env` and in the image labels (`org.insectai.minio.*`, `org.insectai.mc.*`), and a pinned commit SHA is verified after cloning, so a moved tag fails the build.

## Using the image

Pin by tag and digest in compose files. The digest for each published tag is printed in the workflow run's summary. To look it up later, read the first `Digest:` line (the manifest list, which covers both platforms) from:

```sh
docker buildx imagetools inspect insectai/minio:RELEASE.2026-09-16T00-00-00Z
```

```yaml
services:
  minio:
    image: insectai/minio:RELEASE.2026-09-16T00-00-00Z@sha256:<digest>
    command: server /data --console-address ":9001"
    healthcheck:
      test: ["CMD", "mc", "ready", "local"]
  minio-init:
    image: insectai/minio:RELEASE.2026-09-16T00-00-00Z@sha256:<digest>
    entrypoint: ["/bin/sh", "/etc/minio/init.sh"]
```

The image tag is the server release tag. The client version is recorded in the `org.insectai.mc.tag` label.

## Bumping versions

1. Find the new release tags on [pgsty/silo/releases](https://github.com/pgsty/silo/releases) and [pgsty/mc/releases](https://github.com/pgsty/mc/releases), and read their release notes for behaviour changes.
2. Resolve each tag to its commit (annotated tags need the second command):

   ```sh
   gh api repos/pgsty/silo/git/ref/tags/<tag> -q '.object | "\(.type) \(.sha)"'
   gh api repos/pgsty/silo/git/tags/<tag-object-sha> -q .object.sha
   ```

3. Edit `versions.env`: `MINIO_TAG`, `MINIO_COMMIT`, `MC_TAG`, `MC_COMMIT`. Check the `go` directive in both `go.mod` files and raise `GO_IMAGE` if needed. Bump `RUNTIME_IMAGE` to the current Alpine patch release.
4. Build locally and smoke-test:

   ```sh
   ./build.sh
   docker run --rm insectai/minio:dev --version
   docker run --rm --entrypoint mc insectai/minio:dev --version
   ```

5. Open a pull request. The workflow builds both platforms without pushing.
6. Merge to `main`. The workflow pushes `insectai/minio:<MINIO_TAG>` and `insectai/minio:latest`, and prints the digest pin line in the run summary.
7. Update the digest pins in the consuming repositories (for Antenna: `docker-compose.yml` and `docker-compose.ci.yml`).

To republish an existing version without moving `latest` (for example after a base-image security update), run the workflow manually with "Also move the latest tag" unchecked.

## Publishing setup

The workflow needs two repository secrets:

- `DOCKERHUB_USERNAME`: the Docker Hub account or organisation the token belongs to.
- `DOCKERHUB_TOKEN`: an access token with read and write access to `insectai/minio`. Create it under the Docker Hub organisation settings (organisation access token) or as a personal access token of an organisation member.

## Licence

The build files in this repository are licensed under the GNU Affero General Public License v3.0 or later, the same licence as the software they package. The published image contains unmodified builds of AGPL-3.0 software from the repositories named in `versions.env`; the corresponding source for any published image is the tagged commit recorded in that file and in the image labels. MinIO is a trademark of MinIO, Inc.; the name is used here only to identify the upstream project and compatibility lineage.
