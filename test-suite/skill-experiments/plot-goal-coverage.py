#!/usr/bin/env python3
"""Render goal wall-clock coverage from a SOG JSONL trace as an SVG."""

import argparse
import datetime
import html
import json
from pathlib import Path


def parse_timestamp(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def read_goal_ranges(trace_path):
    ranges = {}
    for line in trace_path.open(encoding="utf-8"):
        event = json.loads(line)
        timestamp = parse_timestamp(event["timestamp"])
        wrapper = event.get("event", {})
        goal = wrapper.get("goal_id")
        if not goal:
            continue
        if goal not in ranges:
            ranges[goal] = [timestamp, timestamp]
        else:
            ranges[goal][0] = min(ranges[goal][0], timestamp)
            ranges[goal][1] = max(ranges[goal][1], timestamp)
    return ranges


def render_svg(ranges, output):
    if not ranges:
        raise ValueError("trace contains no goal events")

    start = min(value[0] for value in ranges.values())
    finish = max(value[1] for value in ranges.values())
    total = max((finish - start).total_seconds(), 0.001)
    goals = sorted(ranges)
    left, top, row_height = 120, 48, 34
    width = 1100
    height = top + row_height * len(goals) + 42
    plot_width = width - left - 24

    def x(value):
        return left + plot_width * ((value - start).total_seconds() / total)

    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}">',
        '<style>text{font:13px sans-serif;fill:#202124}.axis{stroke:#9aa0a6}.grid{stroke:#e5e7eb}'
        '.bar{fill:#4f86c6}.label{font-weight:600}</style>',
        f'<text x="{left}" y="22" font-size="16" class="label">Goal coverage</text>',
        f'<text x="{width - 24}" y="22" text-anchor="end">wall time: {total:.1f}s</text>',
    ]
    for index, goal in enumerate(goals):
        y = top + index * row_height
        begin, end = ranges[goal]
        begin_x, end_x = x(begin), x(end)
        if end_x - begin_x < 2:
            end_x = begin_x + 2
        lines.append(f'<line x1="{left}" y1="{y + 12}" x2="{width - 24}" y2="{y + 12}" class="grid"/>')
        lines.append(f'<text x="{left - 12}" y="{y + 17}" text-anchor="end" class="label">{html.escape(goal)}</text>')
        lines.append(f'<rect x="{begin_x:.2f}" y="{y}" width="{end_x - begin_x:.2f}" height="24" rx="3" class="bar"/>')
        lines.append(f'<title>{html.escape(goal)}: {(end - begin).total_seconds():.1f}s</title>')
        lines.append(f'<text x="{min(end_x + 8, width - 24):.2f}" y="{y + 17}">{(end - begin).total_seconds():.1f}s</text>')
    lines.extend([
        f'<line x1="{left}" y1="{top - 8}" x2="{left}" y2="{height - 30}" class="axis"/>',
        f'<line x1="{left}" y1="{height - 30}" x2="{width - 24}" y2="{height - 30}" class="axis"/>',
        f'<text x="{left}" y="{height - 10}">0s</text>',
        f'<text x="{width - 24}" y="{height - 10}" text-anchor="end">{total:.1f}s</text>',
        '</svg>',
    ])
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description="Plot concurrent goal coverage from a SOG trace.")
    parser.add_argument("trace", type=Path, help="path to sog-trace.jsonl")
    parser.add_argument("-o", "--output", type=Path, help="output SVG path (default: next to trace)")
    args = parser.parse_args()
    output = args.output or args.trace.with_suffix(".goals.svg")
    render_svg(read_goal_ranges(args.trace), output)
    print(f"wrote {output}")


if __name__ == "__main__":
    main()
