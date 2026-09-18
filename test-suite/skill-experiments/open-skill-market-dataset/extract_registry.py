#!/usr/bin/env python3
"""Extract a reproducible, metadata-only slice of Open Skill Market.

This deliberately consumes the marketplace's published GitHub registry instead
of scraping rendered HTML.  It does not clone repositories or download skill
content; use fetch_skill_markdown.py for a reviewed, bounded second phase.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urljoin
from urllib.request import Request, urlopen


DEFAULT_REGISTRY_URL = (
    "https://raw.githubusercontent.com/coolzwc/open-skill-market/main/"
    "market/skills.json"
)
USER_AGENT = "SeaOfGoals-skill-dataset/0.1 (public-registry-extractor)"


def fetch_json(url: str) -> dict:
    request = Request(url, headers={"User-Agent": USER_AGENT})
    with urlopen(request, timeout=30) as response:
        payload = json.load(response)
    if not isinstance(payload, dict):
        raise ValueError(f"registry document at {url} is not a JSON object")
    return payload


def raw_skill_url(skill: dict) -> str | None:
    repo = skill.get("repo")
    path = skill.get("path")
    commit = skill.get("commitHash")
    files = skill.get("files")
    if not all(isinstance(value, str) and value for value in (repo, path, commit)):
        return None
    if not isinstance(files, list) or "SKILL.md" not in files:
        return None
    return f"https://raw.githubusercontent.com/{repo}/{commit}/{path}/SKILL.md"


def selected(skill: dict, categories: set[str], contains: str | None) -> bool:
    if categories and not categories.intersection(skill.get("categories", [])):
        return False
    if contains:
        haystack = "\n".join(
            str(skill.get(key, "")) for key in ("name", "description", "repo", "path")
        ).casefold()
        return contains.casefold() in haystack
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True, help="destination JSONL file")
    parser.add_argument("--registry-url", default=DEFAULT_REGISTRY_URL)
    parser.add_argument("--category", action="append", default=[], help="repeatable exact category filter")
    parser.add_argument("--contains", help="case-insensitive metadata substring filter")
    parser.add_argument("--limit", type=int, default=0, help="maximum records; 0 means no limit")
    args = parser.parse_args()
    if args.limit < 0:
        parser.error("--limit must be non-negative")

    root = fetch_json(args.registry_url)
    meta = root.get("meta")
    chunks = meta.get("chunks", []) if isinstance(meta, dict) else []
    if not isinstance(chunks, list) or not all(isinstance(chunk, str) for chunk in chunks):
        raise ValueError("registry meta.chunks must be a list of strings")

    documents = [root]
    for chunk in chunks:
        documents.append(fetch_json(urljoin(args.registry_url, chunk)))

    repositories: dict[str, dict] = {}
    by_id: dict[str, dict] = {}
    for document in documents:
        repositories.update(document.get("repositories", {}))
        for skill in document.get("skills", []):
            if isinstance(skill, dict) and isinstance(skill.get("id"), str):
                by_id.setdefault(skill["id"], skill)

    categories = set(args.category)
    result = []
    for skill_id in sorted(by_id):
        skill = by_id[skill_id]
        if not selected(skill, categories, args.contains):
            continue
        record = {
            "source": "open-skill-market",
            "registry_url": args.registry_url,
            "registry_generated_at": meta.get("generatedAt") if isinstance(meta, dict) else None,
            "registry_timed_out": meta.get("timedOut") if isinstance(meta, dict) else None,
            "registry_rate_limited": meta.get("rateLimited") if isinstance(meta, dict) else None,
            "skill": skill,
            "repository": repositories.get(skill.get("repo")),
            "raw_skill_url": raw_skill_url(skill),
        }
        result.append(record)
        if args.limit and len(result) >= args.limit:
            break

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8") as handle:
        for record in result:
            handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
    print(
        json.dumps(
            {
                "written": len(result),
                "registry_declared_total": meta.get("totalSkills") if isinstance(meta, dict) else None,
                "unique_registry_skills": len(by_id),
                "extracted_at": datetime.now(timezone.utc).isoformat(),
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"extract_registry: {error}", file=sys.stderr)
        raise SystemExit(1)
