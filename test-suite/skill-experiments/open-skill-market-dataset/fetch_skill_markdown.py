#!/usr/bin/env python3
"""Fetch a reviewed, bounded set of public SKILL.md files from JSONL metadata."""

from __future__ import annotations

import argparse
import hashlib
import json
import time
from pathlib import Path
from urllib.parse import quote, urlsplit, urlunsplit
from urllib.request import Request, urlopen


USER_AGENT = "SeaOfGoals-skill-dataset/0.1 (bounded-skill-fetcher)"


def request_url(raw_url: str) -> str:
    """Encode registry paths such as `Academic Writing/SKILL.md` for HTTP."""
    parts = urlsplit(raw_url)
    return urlunsplit((parts.scheme, parts.netloc, quote(parts.path, safe="/%"), parts.query, ""))


def write_manifest(path: Path, records: dict[str, dict]) -> None:
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(
        json.dumps(list(records.values()), ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True, help="JSONL from extract_registry.py")
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--limit", type=int, default=25, help="maximum new files to download")
    parser.add_argument("--delay-seconds", type=float, default=0.5)
    args = parser.parse_args()
    if args.limit <= 0 or args.delay_seconds < 0:
        parser.error("--limit must be positive and --delay-seconds must be non-negative")

    args.out_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = args.out_dir / "manifest.json"
    existing = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.exists() else []
    if not isinstance(existing, list):
        raise ValueError(f"{manifest_path} is not a JSON array")
    manifest = {
        entry["id"]: entry
        for entry in existing
        if isinstance(entry, dict) and isinstance(entry.get("id"), str)
    }
    attempted = 0
    for line in args.input.read_text(encoding="utf-8").splitlines():
        if attempted >= args.limit:
            break
        record = json.loads(line)
        url = record.get("raw_skill_url")
        skill_id = record.get("skill", {}).get("id")
        if not isinstance(url, str) or not isinstance(skill_id, str):
            continue
        previous = manifest.get(skill_id)
        if previous and previous.get("status") == "ok":
            continue
        filename = hashlib.sha256(skill_id.encode("utf-8")).hexdigest() + ".md"
        output_path = args.out_dir / filename
        # A process can be interrupted after writing a file but before its
        # manifest entry.  Recover that deterministic output rather than
        # downloading it again.
        if output_path.is_file():
            content = output_path.read_bytes()
            manifest[skill_id] = {
                "id": skill_id,
                "url": url,
                "status": "ok",
                "file": filename,
                "sha256": hashlib.sha256(content).hexdigest(),
                "recovered": True,
            }
            write_manifest(manifest_path, manifest)
            continue
        attempted += 1
        try:
            request = Request(request_url(url), headers={"User-Agent": USER_AGENT})
            with urlopen(request, timeout=30) as response:
                content = response.read()
        except (OSError, ValueError) as error:
            manifest[skill_id] = {"id": skill_id, "url": url, "status": "error", "error": str(error)}
            write_manifest(manifest_path, manifest)
            continue
        digest = hashlib.sha256(content).hexdigest()
        output_path.write_bytes(content)
        manifest[skill_id] = (
            {"id": skill_id, "url": url, "status": "ok", "file": filename, "sha256": digest}
        )
        write_manifest(manifest_path, manifest)
        if args.delay_seconds:
            time.sleep(args.delay_seconds)

    write_manifest(manifest_path, manifest)
    print(
        json.dumps(
            {
                "attempted_this_batch": attempted,
                "recorded": len(manifest),
                "ok": sum(entry["status"] == "ok" for entry in manifest.values()),
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
