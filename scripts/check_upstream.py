#!/usr/bin/env python3
"""Check upstream sources for new releases and decide whether versions.env needs a change.

Run from anywhere; it reads and (with --write) rewrites the versions.env next to this repository's root.
It needs only the Python 3 standard library. Set GITHUB_TOKEN to avoid GitHub's anonymous rate limit.

    python3 scripts/check_upstream.py --dry-run
    python3 scripts/check_upstream.py --force-rebuild --dry-run
    python3 scripts/check_upstream.py --write --rebuild-if-older-than 30 --github-output "$GITHUB_OUTPUT"

What it looks up:

- The latest GitHub release of the server repository (MINIO_REPO) and the client repository (MC_REPO),
  and the commit each release tag points to (annotated tags are dereferenced).
- The `go` directive in both repositories' go.mod at those commits.
- The newest golang:<minor>.<patch>-alpine<alpine minor> image on Docker Hub, keeping the Alpine minor of
  the current GO_IMAGE. The Go minor is raised only when a go.mod requires a newer one; otherwise the
  newest patch of the current Go minor is used.
- The newest alpine:<minor>.<patch> image for the Alpine minor of the current RUNTIME_IMAGE.

How it decides, in order:

1. New release: if MINIO_TAG or MC_TAG differs from the latest upstream release, all source pins and both
   base images move to the newest values and IMAGE_REVISION restarts at 1.
2. Rebuild: otherwise, the current release is rebuilt (IMAGE_REVISION + 1, plus any newer base-image
   patches) when any of these holds:
   - --force-rebuild is given;
   - GO_IMAGE or RUNTIME_IMAGE has a newer patch release;
   - --rebuild-if-older-than DAYS is given and the published tag <MINIO_TAG>-r<IMAGE_REVISION> (or, if that
     tag does not exist yet, <MINIO_TAG>) was pushed to Docker Hub more than DAYS ago. This is what turns a
     weekly run into a roughly monthly rebuild that picks up Alpine package fixes.
3. Otherwise nothing changes.

A release tag that now points to a different commit than the one pinned is treated as an error: tags are
expected to be immutable, and a moved tag needs a human to look at it.

Exit status: 0 on success (whether or not a change is needed), 1 on any lookup failure or inconsistency.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERSIONS_FILE = os.path.join(REPO_ROOT, "versions.env")
DEFAULT_IMAGE = "insectai/minio"
USER_AGENT = "minio-image-check-upstream"

# Keys shown in the old/new table, in this order.
TRACKED_KEYS = [
    "MINIO_TAG",
    "MINIO_COMMIT",
    "MC_TAG",
    "MC_COMMIT",
    "GO_IMAGE",
    "RUNTIME_IMAGE",
    "IMAGE_REVISION",
]


class LookupFailed(Exception):
    """An upstream API call failed or returned something this script cannot interpret."""


# ---------------------------------------------------------------------------------------------------------
# HTTP helpers


def http_get_text(url: str, headers: dict[str, str] | None = None, allow_404: bool = False) -> str | None:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, **(headers or {})})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read().decode()
    except urllib.error.HTTPError as error:
        if error.code == 404 and allow_404:
            return None
        detail = error.read().decode(errors="replace")[:300]
        hint = ""
        if error.code in (403, 429) and "api.github.com" in url:
            hint = " (GitHub rate limit? set GITHUB_TOKEN)"
        raise LookupFailed(f"GET {url} returned HTTP {error.code}{hint}: {detail}") from error
    except urllib.error.URLError as error:
        raise LookupFailed(f"GET {url} failed: {error.reason}") from error


def http_get_json(url: str, headers: dict[str, str] | None = None, allow_404: bool = False):
    body = http_get_text(url, headers, allow_404)
    if body is None:
        return None
    try:
        return json.loads(body)
    except json.JSONDecodeError as error:
        raise LookupFailed(f"GET {url} did not return JSON") from error


def github_get(path: str, raw: bool = False):
    """GETs an api.github.com path; raw=True returns file contents as text instead of parsed JSON."""
    headers = {
        "Accept": "application/vnd.github.raw" if raw else "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    url = f"https://api.github.com/{path}"
    return http_get_text(url, headers) if raw else http_get_json(url, headers)


# ---------------------------------------------------------------------------------------------------------
# GitHub lookups


def github_slug(repo_url: str) -> str:
    """Turns https://github.com/owner/name.git into owner/name."""
    match = re.match(r"https://github\.com/([^/]+/[^/]+?)(?:\.git)?/?$", repo_url)
    if not match:
        raise LookupFailed(f"not a GitHub repository URL: {repo_url}")
    return match.group(1)


@dataclasses.dataclass
class Release:
    slug: str
    tag: str
    commit: str
    url: str
    go_version: tuple[int, int, int]


def resolve_tag_commit(slug: str, tag: str) -> str:
    ref = github_get(f"repos/{slug}/git/ref/tags/{urllib.parse.quote(tag)}")
    obj = ref["object"]
    # Annotated tags point to a tag object, which points to the commit (possibly through further tags).
    for _ in range(5):
        if obj["type"] == "commit":
            return obj["sha"]
        if obj["type"] != "tag":
            raise LookupFailed(f"{slug} tag {tag} points to a {obj['type']}, not a commit")
        obj = github_get(f"repos/{slug}/git/tags/{obj['sha']}")["object"]
    raise LookupFailed(f"{slug} tag {tag} is nested too deeply")


def go_directive(slug: str, commit: str) -> tuple[int, int, int]:
    go_mod = github_get(f"repos/{slug}/contents/go.mod?ref={commit}", raw=True)
    match = re.search(r"^go\s+(\d+)\.(\d+)(?:\.(\d+))?\s*$", go_mod, re.MULTILINE)
    if not match:
        raise LookupFailed(f"no go directive in {slug} go.mod at {commit}")
    return int(match.group(1)), int(match.group(2)), int(match.group(3) or 0)


def latest_release(repo_url: str) -> Release:
    slug = github_slug(repo_url)
    release = github_get(f"repos/{slug}/releases/latest")
    tag = release["tag_name"]
    commit = resolve_tag_commit(slug, tag)
    return Release(slug, tag, commit, release["html_url"], go_directive(slug, commit))


# ---------------------------------------------------------------------------------------------------------
# Docker Hub lookups


def docker_hub_tag_names(repository: str, name_filter: str) -> list[str]:
    url = (
        f"https://hub.docker.com/v2/repositories/{repository}/tags"
        f"?page_size=100&name={urllib.parse.quote(name_filter)}"
    )
    names: list[str] = []
    while url:
        page = http_get_json(url)
        names.extend(result["name"] for result in page.get("results", []))
        url = page.get("next")
    return names


def newest_patch(names: list[str], pattern: str) -> tuple[int, str] | None:
    """Returns (patch, tag) for the highest patch among tags matching pattern (group 1 = patch number)."""
    best: tuple[int, str] | None = None
    for name in names:
        match = re.fullmatch(pattern, name)
        if match and (best is None or int(match.group(1)) > best[0]):
            best = (int(match.group(1)), name)
    return best


def newest_go_image(current: str, required: tuple[int, int, int]) -> str:
    match = re.fullmatch(r"golang:(\d+)\.(\d+)\.(\d+)-alpine(\d+\.\d+)", current)
    if not match:
        raise LookupFailed(f"GO_IMAGE {current!r} is not of the form golang:X.Y.Z-alpineA.B")
    major, minor, patch = int(match.group(1)), int(match.group(2)), int(match.group(3))
    alpine = match.group(4)
    if (major, minor) < required[:2]:
        major, minor = required[:2]
        min_patch = required[2]
    else:
        # Same minor: never go below the current patch, nor below what go.mod asks for.
        min_patch = max(patch, required[2]) if (major, minor) == required[:2] else patch
    prefix = f"{major}.{minor}."
    names = docker_hub_tag_names("library/golang", prefix)
    best = newest_patch(names, rf"{major}\.{minor}\.(\d+)-alpine{re.escape(alpine)}")
    if best is None or best[0] < min_patch:
        raise LookupFailed(
            f"no golang:{major}.{minor}.N-alpine{alpine} image with N >= {min_patch} on Docker Hub; "
            "update GO_IMAGE by hand (the Alpine minor may need to change)"
        )
    return f"golang:{best[1]}"


def newest_runtime_image(current: str) -> str:
    match = re.fullmatch(r"alpine:(\d+)\.(\d+)\.(\d+)", current)
    if not match:
        raise LookupFailed(f"RUNTIME_IMAGE {current!r} is not of the form alpine:X.Y.Z")
    major, minor, patch = (int(group) for group in match.groups())
    names = docker_hub_tag_names("library/alpine", f"{major}.{minor}.")
    best = newest_patch(names, rf"{major}\.{minor}\.(\d+)")
    if best is None or best[0] < patch:
        return current
    return f"alpine:{best[1]}"


def published_at(image: str, tag: str) -> datetime.datetime | None:
    info = http_get_json(
        f"https://hub.docker.com/v2/repositories/{image}/tags/{urllib.parse.quote(tag)}", allow_404=True
    )
    if info is None:
        return None
    stamp = info.get("tag_last_pushed") or info.get("last_updated")
    if not stamp:
        return None
    return datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))


# ---------------------------------------------------------------------------------------------------------
# versions.env


def read_versions(path: str) -> tuple[list[str], dict[str, str]]:
    with open(path) as handle:
        lines = handle.read().splitlines()
    values: dict[str, str] = {}
    for line in lines:
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return lines, values


def write_versions(path: str, lines: list[str], new_values: dict[str, str]) -> None:
    """Rewrites only the KEY=value lines whose value changed; comments and order are kept."""
    out = []
    for line in lines:
        if line and not line.startswith("#") and "=" in line:
            key = line.split("=", 1)[0].strip()
            if key in new_values:
                line = f"{key}={new_values[key]}"
        out.append(line)
    with open(path, "w") as handle:
        handle.write("\n".join(out) + "\n")


# ---------------------------------------------------------------------------------------------------------
# Decision


@dataclasses.dataclass
class Decision:
    changed: bool
    kind: str  # "release", "rebuild" or "none"
    title: str
    reasons: list[str]
    new_values: dict[str, str]
    links: list[str]


def decide(values: dict[str, str], args: argparse.Namespace) -> Decision:
    for key in ("MINIO_REPO", "MC_REPO", *TRACKED_KEYS):
        if key not in values:
            raise LookupFailed(f"versions.env has no {key}")
    revision = int(values["IMAGE_REVISION"])

    server = latest_release(values["MINIO_REPO"])
    client = latest_release(values["MC_REPO"])
    required_go = max(server.go_version, client.go_version)
    go_image = newest_go_image(values["GO_IMAGE"], required_go)
    runtime_image = newest_runtime_image(values["RUNTIME_IMAGE"])

    links = [
        f"Server release: {server.url}",
        f"Client release: {client.url}",
    ]
    new = dict(values)
    new["GO_IMAGE"], new["RUNTIME_IMAGE"] = go_image, runtime_image

    if server.tag != values["MINIO_TAG"] or client.tag != values["MC_TAG"]:
        new.update(
            MINIO_TAG=server.tag,
            MINIO_COMMIT=server.commit,
            MC_TAG=client.tag,
            MC_COMMIT=client.commit,
            IMAGE_REVISION="1",
        )
        reasons = []
        if server.tag != values["MINIO_TAG"]:
            reasons.append(f"New server release {server.tag} in {server.slug}.")
        if client.tag != values["MC_TAG"]:
            reasons.append(f"New client release {client.tag} in {client.slug}.")
        title = f"Update to server {server.tag} and client {client.tag}"
        if server.tag == client.tag:
            title = f"Update to {server.tag}"
        return Decision(True, "release", title, reasons, new, links)

    # Same tags: the pinned commits must still match, or a tag moved upstream.
    for label, release, key in (("server", server, "MINIO_COMMIT"), ("client", client, "MC_COMMIT")):
        if release.commit != values[key]:
            raise LookupFailed(
                f"{label} tag {release.tag} in {release.slug} now points to {release.commit}, "
                f"but versions.env pins {values[key]}; check upstream before rebuilding"
            )

    reasons = []
    if args.force_rebuild:
        reasons.append("A rebuild was requested (--force-rebuild).")
    if go_image != values["GO_IMAGE"]:
        reasons.append(f"Newer Go toolchain image {go_image}.")
    if runtime_image != values["RUNTIME_IMAGE"]:
        reasons.append(f"Newer Alpine runtime image {runtime_image}.")
    if args.rebuild_if_older_than is not None:
        tag = f"{values['MINIO_TAG']}-r{revision}"
        pushed = published_at(args.image, tag)
        if pushed is None:
            tag = values["MINIO_TAG"]
            pushed = published_at(args.image, tag)
        if pushed is None:
            print(f"note: {args.image}:{tag} is not on Docker Hub, so its age is unknown", file=sys.stderr)
        else:
            age = datetime.datetime.now(datetime.timezone.utc) - pushed
            if age > datetime.timedelta(days=args.rebuild_if_older_than):
                reasons.append(
                    f"{args.image}:{tag} was pushed {age.days} days ago "
                    f"(threshold {args.rebuild_if_older_than} days), so base-image package fixes may be missing."
                )

    if not reasons:
        return Decision(False, "none", "No update needed", ["Pins are current."], dict(values), links)

    new["IMAGE_REVISION"] = str(revision + 1)
    title = f"Rebuild {values['MINIO_TAG']} as r{revision + 1}"
    return Decision(True, "rebuild", title, reasons, new, links)


def change_table(old: dict[str, str], new: dict[str, str]) -> str:
    rows = ["| Setting | Old | New |", "|---|---|---|"]
    for key in TRACKED_KEYS:
        marker = "" if old[key] == new[key] else " (changed)"
        rows.append(f"| `{key}`{marker} | `{old[key]}` | `{new[key]}` |")
    return "\n".join(rows)


def markdown_body(decision: Decision, old: dict[str, str], image: str) -> str:
    new = decision.new_values
    parts = [
        "Why:",
        "",
        *(f"- {reason}" for reason in decision.reasons),
        "",
        change_table(old, new),
    ]
    if decision.changed:
        parts += [
            "",
            f"New image tags: `{image}:{new['MINIO_TAG']}-r{new['IMAGE_REVISION']}` (immutable), "
            f"`{image}:{new['MINIO_TAG']}` and `{image}:latest`.",
        ]
    parts += [
        "",
        "Upstream:",
        "",
        *(f"- {link}" for link in decision.links),
    ]
    if decision.kind == "release":
        parts += ["", "Read both release notes for behaviour changes before merging."]
    return "\n".join(parts)


def write_github_output(path: str, decision: Decision, body: str) -> None:
    delimiter = f"EOF_{uuid.uuid4().hex}"
    with open(path, "a") as handle:
        handle.write(f"changed={'true' if decision.changed else 'false'}\n")
        handle.write(f"kind={decision.kind}\n")
        handle.write(f"title={decision.title}\n")
        handle.write(f"body<<{delimiter}\n{body}\n{delimiter}\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true", help="rewrite versions.env in place")
    mode.add_argument("--dry-run", action="store_true", help="only report the decision (default)")
    parser.add_argument(
        "--rebuild-if-older-than", type=int, metavar="DAYS", help="rebuild if the published image is older"
    )
    parser.add_argument("--force-rebuild", action="store_true", help="bump IMAGE_REVISION even if nothing changed")
    parser.add_argument("--github-output", metavar="PATH", help="append changed/kind/title/body outputs to this file")
    parser.add_argument("--image", default=DEFAULT_IMAGE, help=f"Docker Hub repository (default {DEFAULT_IMAGE})")
    parser.add_argument("--versions-file", default=VERSIONS_FILE, help=argparse.SUPPRESS)
    args = parser.parse_args()

    try:
        lines, values = read_versions(args.versions_file)
        decision = decide(values, args)
    except (LookupFailed, ValueError, KeyError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    body = markdown_body(decision, values, args.image)
    print(f"Decision: {decision.title}")
    print()
    print(body)

    if decision.changed and args.write:
        write_versions(args.versions_file, lines, decision.new_values)
        print(f"\nWrote {args.versions_file}")
    elif decision.changed:
        print("\nDry run: versions.env not modified (use --write).")
    if args.github_output:
        write_github_output(args.github_output, decision, body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
