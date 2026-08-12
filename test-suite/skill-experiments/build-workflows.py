#!/usr/bin/env python3
import argparse
import json
import os
import sys
from pathlib import Path


DEFAULT_SKILLS = ("nextjs-performance", "database-migrations", "mysql2postgres", "test-with-postgres")
DEFAULT_SCFG_PACKAGE = Path("/home/erchius/development/scfg/scfg-package")
DEFAULT_SSL_ROOT = Path("/home/erchius/datasets/SSL")


def main():
    parser = argparse.ArgumentParser(
        description="Build SeaOfGoals workflow.json files from raw SKILL.md files via scfg-package."
    )
    parser.add_argument(
        "skills",
        nargs="*",
        default=list(DEFAULT_SKILLS),
        help="Skill slugs under docs/testsets and test-suite/skill-experiments.",
    )
    parser.add_argument(
        "--scfg-package",
        default=os.environ.get("SCFG_PACKAGE_DIR", str(DEFAULT_SCFG_PACKAGE)),
        help="Path to the scfg-package checkout.",
    )
    parser.add_argument(
        "--ssl-root",
        default=os.environ.get("SSL_ROOT", str(DEFAULT_SSL_ROOT)),
        help="Path to the SSL repository containing docs/testsets.",
    )
    parser.add_argument(
        "--model",
        default=os.environ.get("SCFG_PACKAGE_MODEL"),
        help="OpenAI model for scfg-package. Defaults to scfg-package behavior.",
    )
    parser.add_argument(
        "--max-repair-rounds",
        type=int,
        default=3,
        help="Maximum SCFG repair rounds.",
    )
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[2]
    scfg_package = Path(args.scfg_package).expanduser().resolve(strict=False)
    ssl_root = Path(args.ssl_root).expanduser().resolve(strict=False)

    sys.path.insert(0, str(scfg_package))
    try:
        from scfg_package import build_scfg
    except Exception as exc:
        print(f"could not import scfg_package from {scfg_package}: {exc}", file=sys.stderr)
        return 2

    for slug in args.skills:
        skill_path = ssl_root / "docs" / "testsets" / slug / "SKILL.md"
        experiment_dir = repo_root / "test-suite" / "skill-experiments" / slug
        if not skill_path.is_file():
            print(f"missing skill: {skill_path}", file=sys.stderr)
            return 2
        if not experiment_dir.is_dir():
            print(f"missing experiment directory: {experiment_dir}", file=sys.stderr)
            return 2

        out_dir = experiment_dir / "scfg-output"
        result = build_scfg(
            skill_path,
            out_dir=out_dir,
            model=args.model,
            max_repair_rounds=args.max_repair_rounds,
        )
        workflow = workflow_from_scfg(result.scfg)
        workflow_path = experiment_dir / "workflow.json"
        workflow_path.write_text(json.dumps(workflow, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(
            f"{slug}: wrote {workflow_path} "
            f"({len(workflow['nodes'])} nodes, {len(workflow['edges'])} edges; scfg={result.scfg_path})"
        )

    return 0


def workflow_from_scfg(scfg):
    return {
        "name": scfg.skill_name,
        "nodes": [
            {
                "id": node.id,
                "title": node.title,
                "body": compact_body(node.body),
            }
            for node in scfg.instructions
        ],
        "edges": [
            {
                "source": edge.src,
                "target": edge.dst,
                "rationale": edge.rationale,
            }
            for edge in scfg.edges
        ],
    }


def compact_body(body):
    lines = []
    for raw_line in body.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("First run `echo \"[AgentSanitizer]"):
            continue
        if line.startswith("On completion of this node, run `echo \"[AgentSanitizer]"):
            continue
        if line.startswith("This step can be the first step if necessary."):
            continue
        if line.startswith("After this step,"):
            continue
        lines.append(line)
        if len(" ".join(lines)) > 500:
            break
    compacted = " ".join(lines)
    if len(compacted) > 600:
        return compacted[:597] + "..."
    return compacted


if __name__ == "__main__":
    raise SystemExit(main())
