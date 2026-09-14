#!/usr/bin/env python3
"""Render streamed model and tool phase coverage from a SOG JSONL trace."""

import argparse
import datetime
import html
import json
import re
from collections import defaultdict
from pathlib import Path


def timestamp(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def command_writes(tool_name, arguments):
    if tool_name in {"write", "edit"}:
        return True
    if tool_name != "bash":
        return False
    command = str(arguments.get("command", ""))
    command_words = re.sub(r"'(?:[^']*)'|\"(?:\\.|[^\"])*\"", "", command)
    return bool(
        re.search(
            r"\b(apply_patch|sed\s+-i|perl\s+-i|tee|mv|cp|rm|mkdir|touch|"
            r"heavy-compile\.mjs\s+(build|test)|package\.mjs|"
            r"npm(?:\s+--[A-Za-z0-9_-]+(?:[= ][^\s;&|]+)?)*\s+(run|test|install)|"
            r"git\s+(apply|checkout|reset))\b",
            command_words,
        )
    )


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


def stream_kind(value):
    """Classify Pi's incremental event, rather than its cumulative partial."""
    if isinstance(value, dict):
        event_type = value.get("type", "")
        if event_type in {"thinking_start", "thinking_delta", "thinking_end"}:
            return "reasoning"
        if event_type in {
            "text_start",
            "text_delta",
            "text_end",
            "toolcall_start",
            "toolcall_delta",
            "toolcall_end",
        }:
            return "generation"
        for key, child in value.items():
            if key == "partial":
                continue
            kind = stream_kind(child)
            if kind:
                return kind
    elif isinstance(value, list):
        for child in value:
            kind = stream_kind(child)
            if kind:
                return kind
    return None


def phases(path):
    active = {}
    result = defaultdict(list)
    for line in open(path, encoding="utf-8"):
        record = json.loads(line)
        event = record.get("event", {})
        goal = event.get("goal_id")
        if not goal:
            goal = event.get("goal_id")
        raw = event.get("raw_event", {})
        direct_kind = event.get("type")
        if not goal or direct_kind == "model_usage":
            continue
        if direct_kind == "model_phase":
            phase = event.get("phase", "generation")
            if goal in active:
                active[goal][3].append((timestamp(record["timestamp"]), phase))
            continue
        kind = raw.get("type")
        if kind == "message" and isinstance(raw.get("message"), dict):
            kind = raw["message"].get("type")
        if kind == "turn_start":
            active[goal] = [timestamp(record["timestamp"]), [], {}, []]
        elif kind == "turn_end" and goal in active:
            start, _, tool_intervals, streamed = active.pop(goal)
            end = timestamp(record["timestamp"])
            points = {start, end}
            for begin, finish, _ in tool_intervals.values():
                points.update((begin, finish))
            points.update(point for point, _ in streamed)
            points = sorted(point for point in points if start <= point <= end)
            model_phase = "generation"
            for begin, finish in zip(points, points[1:]):
                for marker, phase in reversed(streamed):
                    if marker <= begin:
                        model_phase = phase
                        break
                phase = model_phase
                for tool_begin, tool_end, tool_phase in tool_intervals.values():
                    if tool_begin <= begin and finish <= tool_end:
                        phase = tool_phase
                        break
                if finish > begin:
                    result[goal].append((phase, begin, finish))
        elif goal in active:
            event_time = timestamp(record["timestamp"])
            if kind == "tool_execution_start":
                tool_name = raw.get("toolName", "")
                arguments = raw.get("args") or raw.get("arguments") or {}
                tool_phase = "write" if command_writes(tool_name, arguments) else "read"
                active[goal][2][raw.get("toolCallId", str(event_time))] = [
                    event_time,
                    event_time,
                    tool_phase,
                ]
            elif kind == "tool_execution_end":
                tool_id = raw.get("toolCallId")
                if tool_id in active[goal][2]:
                    active[goal][2][tool_id][1] = event_time
            elif kind in {"message_update", "message_start", "message_end", "assistant_message"}:
                stream_phase = stream_kind(raw)
                if stream_phase:
                    active[goal][3].append((event_time, stream_phase))
    return result


def render(data, output):
    start = min(item[1] for items in data.values() for item in items)
    finish = max(item[2] for items in data.values() for item in items)
    total = max((finish - start).total_seconds(), 0.001)
    left, width, row = 150, 1800, 38
    goals = sorted(data)
    height = 48 + row * len(goals) + 78

    def x(value):
        return left + (width - left - 24) * (value - start).total_seconds() / total

    colors = {
        "model_wait": "#94a3b8",
        "reasoning": "#8b5cf6",
        "generation": "#0f766e",
        "read": "#4f86c6",
        "write": "#d9822b",
        "end_goal": "#7a5af8",
    }
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
        for phase, begin, end in sorted(data[goal], key=lambda item: item[1]):
            duration = (end - begin).total_seconds()
            if duration <= 0:
                continue
            begin_x, end_x = x(begin), x(end)
            bar_width = max(end_x - begin_x, 2)
            offset_begin = (begin - start).total_seconds()
            offset_end = (end - start).total_seconds()
            tooltip = f'{html.escape(goal)} {phase}: {duration:.1f}s ({offset_begin:.1f}s - {offset_end:.1f}s)'
            lines.append(f'<rect x="{begin_x:.2f}" y="{y}" width="{bar_width:.2f}" height="24" fill="{colors[phase]}"><title>{tooltip}</title></rect>')
            if bar_width >= 72:
                lines.append(f'<text x="{begin_x + bar_width / 2:.2f}" y="{y + 17}" text-anchor="middle" fill="white">{duration:.1f}s</text>')
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
        legend_x += 135
    lines.append("</svg>")
    svg = "\n".join(lines)
    if output.endswith(".html"):
        document = """<!doctype html>
<meta charset="utf-8">
<title>Goal phase coverage</title>
<style>body{margin:0;background:#fff}svg{display:block;margin:16px auto;max-width:100%;height:auto}</style>
""" + svg
        Path(output).write_text(document, encoding="utf-8")
    else:
        Path(output).write_text(svg, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("trace")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    render(phases(args.trace), args.out)
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
