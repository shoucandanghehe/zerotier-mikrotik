#!/usr/bin/env python3

import json
import os
import re
import subprocess
import sys
from datetime import datetime, UTC
from pathlib import Path


SEMVER_RE = re.compile(r"\d+\.\d+\.\d+")


def run(cmd: list[str], *, check: bool = True, capture_output: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, check=check, capture_output=capture_output, text=True)


def capture(cmd: list[str]) -> str:
    return run(cmd, capture_output=True).stdout.strip()


def extract_semver(text: str) -> str:
    match = SEMVER_RE.search(text)
    return match.group(0) if match else ""


def resolve_version(image: str) -> str:
    version = extract_semver(
        capture([
            "docker",
            "image",
            "inspect",
            "--format",
            '{{ index .Config.Labels "org.opencontainers.image.version" }}',
            image,
        ])
    )
    if version:
        return version

    probe = run(
        ["docker", "run", "--rm", "--entrypoint", "zerotier-one", image, "-v"],
        check=False,
        capture_output=True,
    )
    return extract_semver(f"{probe.stdout}\n{probe.stderr}")


def load_state(path: Path) -> dict[str, object]:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def write_state(path: Path, state: dict[str, object]) -> None:
    path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")


def write_outputs(outputs: dict[str, str]) -> None:
    output_path = os.getenv("GITHUB_OUTPUT")
    lines = [f"{key}={value}" for key, value in outputs.items()]
    if output_path:
        with open(output_path, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
        return
    print("\n".join(lines))


def parse_revision(value: object) -> int:
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value:
        return int(value)
    return 0


def main() -> int:
    image = os.environ["UPSTREAM_IMAGE"]
    state_path = Path(os.environ["STATE_FILE"])
    event_name = os.getenv("GITHUB_EVENT_NAME", "")

    run(["docker", "pull", image])

    upstream_repo_digest = capture(["docker", "image", "inspect", "--format", "{{index .RepoDigests 0}}", image])
    upstream_digest = upstream_repo_digest.split("@", 1)[1]
    version = resolve_version(image)

    if not version:
        labels = capture(["docker", "image", "inspect", "--format", "{{json .Config.Labels}}", image])
        print(f"Failed to detect upstream ZeroTier version from {image}.", file=sys.stderr)
        print(f"Upstream labels: {labels}", file=sys.stderr)
        return 1

    state = load_state(state_path)
    old_version = str(state.get("upstream_version", "") or "")
    old_digest = str(state.get("upstream_digest", "") or "")
    old_rev = parse_revision(state.get("revision", 0))

    should_release = not (
        event_name == "schedule"
        and upstream_digest == old_digest
        and version == old_version
    )

    print(f"Resolved upstream version: {version}")
    print(f"Resolved upstream digest: {upstream_digest}")
    print(f"Release required: {str(should_release).lower()}")

    if should_release:
        rev = str(old_rev + 1 if version == old_version and old_version else 1)
        tag = f"{version}-r{rev}"

        write_state(
            state_path,
            {
                "upstream_image": image,
                "upstream_digest": upstream_digest,
                "upstream_version": version,
                "revision": int(rev),
                "last_release_tag": tag,
                "updated_at": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
            },
        )

        github_ref_name = os.environ["GITHUB_REF_NAME"]
        run(["git", "config", "user.name", "github-actions[bot]"])
        run(["git", "config", "user.email", "github-actions[bot]@users.noreply.github.com"])
        run(["git", "add", str(state_path)])
        run(["git", "commit", "-m", f"chore(release): {tag}"])
        run(["git", "push", "origin", f"HEAD:{github_ref_name}"])
        commit_sha = capture(["git", "rev-parse", "HEAD"])
    else:
        rev = ""
        tag = ""
        commit_sha = capture(["git", "rev-parse", "HEAD"])

    write_outputs(
        {
            "should_release": str(should_release).lower(),
            "upstream_digest": upstream_digest,
            "upstream_version": version,
            "revision": rev,
            "tag": tag,
            "commit_sha": commit_sha,
        }
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
