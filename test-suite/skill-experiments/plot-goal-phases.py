#!/usr/bin/env python3
"""Render read, write, and end_goal turn coverage from a SOG JSONL trace."""

import argparse
import datetime
import html
import json
from collections import defaultdict


def timestamp(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def tool_names(value):
    if isinstance(value, dict):
        names = []
        if value.get("type") == "toolCall":
            names.append(value.get("name", ""))
        if "toolName" in value:
            names.append(value.get("toolName", ""))
        for child in value.values():
            names.extend(tool_names(child))
        return names
    if isinstance(value, list):
        return [name for child in value for name in tool_names(child)]
    return []


def phases(path):
    active = {}
    result = defaultdict(list)
    for line in open(path, encoding="utf-8"):
        record = json.loads(line)
        event = record.get("event", {})
        goal = event.get("goal_id")
        if not goal:
            continue
        raw = event.get("raw_event", {})
        kind = raw.get("type")
        if kind == "message" and isinstance(raw.get("message"), dict):
            kind = raw["message"].get("type")
        if kind == "turn_start":
            active[goal] = [timestamp(record["timestamp"]), []]
        elif kind == "turn_end" and goal in active:
            start, names = active.pop(goal)
            end = timestamp(record["timestamp"])
            if "end_goal" in names:
                phase = "end_goal"
            elif any(name in {"write", "edit"} for name in names):
                phase = "write"
            elif names:
                phase = "read"
            else:
                phase = "read"
            result[goal].append((phase, start, end))
        elif goal in active:
            active[goal][1].extend(tool_names(raw))
    return result


def render(data, output):
    start = min(item[1] for items in data.values() for item in items)
    finish = max(item[2] for items in data.values() for item in items)
    total = max((finish - start).total_seconds(), 0.001)
    left, width, row = 120, 1100, 34
    goals = sorted(data)
    height = 48 + row * len(goals) + 78

    def x(value):
        return left + (width - left - 24) * (value - start).total_seconds() / total

    colors = {"read": "#4f86c6", "write": "#d9822b", "end_goal": "#7a5af8"}
    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<style>text{font:13px sans-serif;fill:#202124}.label{font-weight:600}.grid{stroke:#e5e7eb}</style>',
        f'<text x="{left}" y="22" class="label">Goal phase coverage</text>',
        f'<text x="{width-24}" y="22" text-anchor="end">wall time: {total:.1f}s</text>',
    ]
    for index, goal in enumerate(goals):
        y = 48 + index * row
        lines.append(f'<text x="{left-12}" y="{y+17}" text-anchor="end" class="label">{html.escape(goal)}</text>')
        lines.append(f'<line x1="{left}" y1="{y+12}" x2="{width-24}" y2="{y+12}" class="grid"/>')
        grouped = {}
        first = min(begin for _, begin, _ in data[goal])
        for phase, begin, end in data[goal]:
            grouped[phase] = grouped.get(phase, 0) + (end - begin).total_seconds()
        cursor = first
        for phase in ("read", "write", "end_goal"):
            duration = grouped.get(phase, 0)
            if not duration:
                continue
            begin, end = cursor, cursor + datetime.timedelta(seconds=duration)
            begin_x, end_x = x(begin), x(end)
            bar_width = max(end_x - begin_x, 2)
            offset_begin = (begin - start).total_seconds()
            offset_end = (end - start).total_seconds()
            tooltip = f'{html.escape(goal)} {phase}: {duration:.1f}s ({offset_begin:.1f}s - {offset_end:.1f}s)'
            lines.append(f'<rect x="{begin_x:.2f}" y="{y}" width="{bar_width:.2f}" height="24" fill="{colors[phase]}"><title>{tooltip}</title></rect>')
            if bar_width >= 72:
                lines.append(f'<text x="{begin_x + bar_width / 2:.2f}" y="{y + 17}" text-anchor="middle" fill="white">{duration:.1f}s</text>')
            cursor = end
    axis_y = 48 + row * len(goals) + 8
    plot_width = width - left - 24
    for fraction in (0, 0.25, 0.5, 0.75, 1):
        axis_x = left + plot_width * fraction
        elapsed = total * fraction
        lines.append(f'<line x1="{axis_x:.2f}" y1="{axis_y-4}" x2="{axis_x:.2f}" y2="{axis_y+4}" stroke="#9aa0a6"/>')
        lines.append(f'<text x="{axis_x:.2f}" y="{axis_y+20}" text-anchor="middle">{elapsed:.1f}s</text>')
    legend_x = left
    legend_y = height - 28
    for phase, color in colors.items():
        lines.append(f'<rect x="{legend_x}" y="{legend_y}" width="12" height="12" fill="{color}"/>')
        lines.append(f'<text x="{legend_x+18}" y="{legend_y+11}">{phase}</text>')
        legend_x += 100
    lines.append("</svg>")
    svg = "\n".join(lines)
    if output.endswith(".html"):
        document = """<!doctype html>
<meta charset="utf-8">
<title>Goal phase coverage</title>
<style>body{margin:0;background:#fff}svg{display:block;margin:16px auto;max-width:100%;height:auto}</style>
""" + svg
        open(output, "w", encoding="utf-8").write(document)
    else:
        open(output, "w", encoding="utf-8").write(svg)


parser = argparse.ArgumentParser()
parser.add_argument("trace")
parser.add_argument("--out", required=True)
args = parser.parse_args()
render(phases(args.trace), args.out)
print(f"wrote {args.out}")
