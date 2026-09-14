#!/usr/bin/env python3
"""Render one goal timeline per ranked baseline/concurrent sample pair."""

import argparse
import html
import importlib.util
import json
import os
from pathlib import Path


VALIDATION_COMMANDS = (
    "audit_widget_coverage.py",
    "check-port-widget.js",
    "npm run check",
    "node --check",
    "tsc --noEmit",
)

GOAL_DETAILS = {
    "G000": "runtime planning",
    "G001": "audit scope and precedents",
    "G002": "shared foundation",
    "G003": "JavaScript widget",
    "G004": "React flavor",
    "G005": "Vue flavor",
    "G006": "cross-flavor tests",
    "G007": "applicable examples",
    "G008": "final validation",
}


def load_timeline_module(script):
    spec = importlib.util.spec_from_file_location("goal_timeline", script)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def command_text(tool):
    arguments = tool[4]
    return str(arguments.get("command", "")) if isinstance(arguments, dict) else ""


def baseline_mapping(trace, title):
    turns = trace["turns"]
    first_write = next(
        (turn["number"] for turn in turns if any(tool[2] == "write" for tool in turn["tools"].values())),
        None,
    )
    if first_write is None:
        raise ValueError(f"baseline has no write turn: {title}")
    first_validation = next(
        (
            turn["number"]
            for turn in turns
            if turn["number"] > first_write
            and any(
                marker in command_text(tool)
                for tool in turn["tools"].values()
                for marker in VALIDATION_COMMANDS
            )
        ),
        None,
    )
    if first_validation is None:
        raise ValueError(f"baseline has no validation turn: {title}")

    audit = [turn["number"] for turn in turns if turn["number"] < first_write]
    implementation = [
        turn["number"] for turn in turns if first_write <= turn["number"] < first_validation
    ]
    validation = [turn["number"] for turn in turns if turn["number"] >= first_validation]
    return {
        "title": title,
        "goal_details": GOAL_DETAILS,
        "groups": [
            {"id": "G000", "name": GOAL_DETAILS["G000"], "baseline_turns": [], "concurrent_goals": ["G000"]},
            {"id": "G001", "name": GOAL_DETAILS["G001"], "baseline_turns": audit, "concurrent_goals": ["G001"]},
            {"id": "G002", "name": "shared foundation (no baseline edit needed)", "baseline_turns": [], "concurrent_goals": ["G002"]},
            {
                "id": "G003-G006",
                "name": "wrapper implementation and test wiring",
                "baseline_turns": implementation,
                "shared_baseline": True,
                "concurrent_goals": ["G003", "G004", "G005", "G006"],
            },
            {"id": "G007", "name": "examples (no baseline edit needed)", "baseline_turns": [], "concurrent_goals": ["G007"]},
            {"id": "G008", "name": GOAL_DETAILS["G008"], "baseline_turns": validation, "concurrent_goals": ["G008"]},
        ],
    }


def render_index(output, pages):
    cards = "".join(
        f"""<section><div><strong>Rank {rank}</strong><span>Single Pi {baseline:.1f}s · SoG {concurrent:.1f}s</span><a href="{html.escape(page)}">open separately</a></div><iframe loading="lazy" src="{html.escape(page)}" title="Rank {rank} goal timeline"></iframe></section>"""
        for rank, page, baseline, concurrent in pages
    )
    document = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>port-widget: ten goal-timeline comparisons</title><style>
*{{box-sizing:border-box}}body{{margin:0;background:#f3f5f7;color:#202428;font:14px/1.4 system-ui,sans-serif;letter-spacing:0}}header{{padding:20px 24px;background:#fff;border-bottom:1px solid #d9dee5;position:sticky;top:0;z-index:2}}h1{{font-size:21px;margin:0}}p{{color:#66707b;margin:4px 0 0}}main{{padding:18px}}section{{background:#fff;border:1px solid #d9dee5;margin-bottom:18px}}section>div{{height:44px;display:flex;align-items:center;gap:18px;padding:0 14px;border-bottom:1px solid #d9dee5}}section>div span{{color:#66707b}}section>div a{{margin-left:auto;color:#1769aa}}iframe{{display:block;width:100%;height:790px;border:0}}
</style></head><body><header><h1>port-widget: ten goal-timeline comparisons</h1><p>Baseline and concurrent samples are independently sorted and aligned by rank; rows are not paired executions. Hover bars for timing and turn details.</p></header><main>{cards}</main></body></html>"""
    output.write_text(document, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("output_directory", type=Path)
    parser.add_argument("--short-index", type=Path)
    args = parser.parse_args()

    timeline = load_timeline_module(Path(__file__).with_name("plot-goal-run-comparison.py"))
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    trace_root = args.manifest.parent / "runs" / "control"
    baselines = sorted(
        ((entry, timeline.parse_trace(trace_root / entry["trace"])) for entry in manifest["baseline"]),
        key=lambda item: item[1]["wall"],
    )
    concurrent = sorted(
        ((entry, timeline.parse_trace(trace_root / entry["trace"])) for entry in manifest["concurrent"]),
        key=lambda item: item[1]["wall"],
    )
    if len(baselines) != len(concurrent):
        raise ValueError("baseline and concurrent sample counts differ")

    args.output_directory.mkdir(parents=True, exist_ok=True)
    pages = []
    for rank, ((base_entry, base_trace), (sog_entry, sog_trace)) in enumerate(
        zip(baselines, concurrent), 1
    ):
        page_name = f"rank-{rank:02d}.html"
        title = (
            f"Rank {rank}: Single Pi {base_trace['wall']:.1f}s vs "
            f"SoG concurrent {sog_trace['wall']:.1f}s"
        )
        timeline.render(
            sog_trace,
            base_trace,
            baseline_mapping(base_trace, title),
            args.output_directory / page_name,
        )
        pages.append((rank, page_name, base_trace["wall"], sog_trace["wall"]))

    render_index(args.output_directory / "index.html", pages)
    if args.short_index:
        args.short_index.parent.mkdir(parents=True, exist_ok=True)
        short_pages = [
            (
                rank,
                os.path.relpath(args.output_directory / page, args.short_index.parent),
                baseline,
                concurrent,
            )
            for rank, page, baseline, concurrent in pages
        ]
        render_index(args.short_index, short_pages)
    print(f"wrote {len(pages)} comparisons to {args.output_directory}")


if __name__ == "__main__":
    main()
