# Open Skill Market dataset extractor

This is a bounded extractor for the public registry published by
[`coolzwc/open-skill-market`](https://github.com/coolzwc/open-skill-market).
It uses the registry's GitHub JSON, not marketplace HTML. The first phase only
collects metadata and exact source URLs; content download is a separate,
bounded operation.

```bash
python3 extract_registry.py --out data/registry.jsonl
python3 fetch_skill_markdown.py \
  --input data/registry.jsonl \
  --out-dir data/skills \
  --limit 100
```

Records retain the registry generation time and its `timedOut` / `rateLimited`
flags. A registry snapshot marked incomplete must not be described as a full
marketplace census. `fetch_skill_markdown.py` fetches only `SKILL.md` files
from a URL constructed using the registry's recorded commit hash; it does not
download supporting files or clone repositories.

`data/` is deliberately ignored by Git: it is a persisted crawl snapshot, not
a source-controlled fixture. The `data/skills/manifest.json` file maps each
downloaded content hash and filename back to its registry id and pinned raw
GitHub URL.
