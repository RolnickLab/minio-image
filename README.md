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
| `/usr/bin/docker-entrypoint.sh` | This repository | Starts the server and creates the buckets listed in `MINIO_DEFAULT_BUCKETS`. |
| `/usr/bin/minio-healthcheck` | This repository | The image's health check: healthy once the server is ready and those buckets exist. |
| `/bin/sh` and BusyBox | Alpine base | Runs the two scripts above, and lets you run your own shell scripts with `mc`. |
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
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: change-me-please
      MINIO_DEFAULT_BUCKETS: media:public,backups
    healthcheck:
      test: ["CMD", "minio-healthcheck"]
      interval: 5s
      retries: 12

  app:
    depends_on:
      minio:
        condition: service_healthy
```

The default command is `server /data --console-address ":9001"`, so the `command:` line can be left out. The `healthcheck:` block above only repeats the image's built-in health check with a shorter interval; it can also be left out.

The image tag is the server release tag. The client version is recorded in the `org.insectai.mc.tag` label.

## Creating buckets at startup

Set `MINIO_DEFAULT_BUCKETS` to a comma-separated list of buckets, each optionally followed by a colon and an anonymous-access policy:

```sh
MINIO_DEFAULT_BUCKETS=media:public,uploads:upload,backups
```

The policy is one of the values `mc anonymous set` accepts: `none`, `download` (anonymous read), `upload` (anonymous write) or `public` (anonymous read and write). A bucket without a policy is created private. The variable name and format are the same as in the Bitnami MinIO image, so this setting carries over from compose files written for that image. Bitnami's other variables (such as its port settings) are not supported.

When the variable is set, the entrypoint starts the server, waits until it is ready, creates each missing bucket, applies its policy, and logs one line per bucket. Existing buckets and their contents are left alone, and the policy is applied again on every start. If any step fails (an invalid bucket name, an unknown policy, wrong credentials), the entrypoint stops the server and the container exits with a non-zero status, so a misconfiguration is visible immediately instead of surfacing later as missing buckets. The server stays the container's main process: `docker stop` is forwarded to it and the container's exit code is the server's.

When the variable is not set, the entrypoint hands straight over to the server, so the image behaves exactly as it did before this feature existed. Any command other than `server ...` (for example `--version`) is passed to the `minio` binary unchanged, and `--entrypoint mc` still runs the client.

### Health check

The image declares a Docker `HEALTHCHECK` that runs `/usr/bin/minio-healthcheck`. It reports healthy only when the server answers its readiness probe and, if `MINIO_DEFAULT_BUCKETS` is set, the entrypoint has finished setting up the buckets (it writes a marker file, `/tmp/minio-default-buckets.ready`, as its last step). In compose, `depends_on: {minio: {condition: service_healthy}}` therefore means "the server is up and the buckets are in place", which replaces a separate init container.

### Limits

- The scripts talk to the server over plain HTTP on `127.0.0.1`. The API port is taken from the server's `--address` argument (for example `--address :9100`) and defaults to 9000. TLS on the API port is not supported by the bucket setup.
- The root credentials come from `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD`. Credentials supplied only through files or other mechanisms are not read.
- The entrypoint waits up to 120 seconds for the server to become ready before giving up. Set `MINIO_DEFAULT_BUCKETS_TIMEOUT` (in seconds) to change this.

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
   test/smoke.sh insectai/minio:dev
   ```

   The smoke test starts the image with and without `MINIO_DEFAULT_BUCKETS`, checks bucket creation, anonymous access, the health check, `--version` output and clean shutdown, and removes everything it created. The workflow runs the same script on every pull request.

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
