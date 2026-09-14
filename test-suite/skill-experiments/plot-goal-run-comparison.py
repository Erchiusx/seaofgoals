#!/usr/bin/env python3
"""Render baseline and concurrent goal phases on aligned elapsed-time axes."""

import argparse
import datetime
import html
import json
import re
from collections import defaultdict
from pathlib import Path


PLANNER_CONTROL_TOOLS = {
    "set_goal_resolution",
    "set_predicted_actions_plan",
    "set_preload_plan",
}


def timestamp(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def tool_phase(tool_name, arguments):
    if tool_name in PLANNER_CONTROL_TOOLS:
        return "control"
    if tool_name in {"write", "edit"}:
        return "write"
    if tool_name != "bash":
        return "read"
    command = str(arguments.get("command", ""))
    command_words = re.sub(r"'(?:[^']*)'|\"(?:\\.|[^\"])*\"", "", command)
    writes = bool(
        re.search(
            r"\b(apply_patch|sed\s+-i|perl\s+-i|tee|mv|cp|rm|mkdir|touch|"
            r"heavy-compile\.mjs\s+(build|test)|package\.mjs|"
            r"npm(?:\s+--[A-Za-z0-9_-]+(?:[= ][^\s;&|]+)?)*\s+(run|test|install)|"
            r"git\s+(apply|checkout|reset))\b",
            command_words,
        )
    )
    return "write" if writes else "read"


def parse_trace(path):
    records = [json.loads(line) for line in path.open(encoding="utf-8")]
    trace_start = min(timestamp(record["timestamp"]) for record in records)
    trace_end = max(timestamp(record["timestamp"]) for record in records)
    active = {}
    turns = []
    turn_number = 0
    merge_starts = {}
    merges = defaultdict(list)
    resolutions = defaultdict(list)

    for record in records:
        now = timestamp(record["timestamp"])
        wrapper = record.get("event", {})
        if wrapper.get("type") == "planner_goal_resolved":
            resolutions[wrapper["goal_id"]].append(
                (now, wrapper.get("resolution_kind", "resolved"), wrapper.get("context", ""))
            )
        if wrapper.get("type") == "dag_snapshot":
            phase = wrapper.get("phase", "")
            reason = wrapper.get("reason", "")
            if reason.startswith("goal="):
                goal = reason.split(";", 1)[0][5:]
                if phase == "merge_before":
                    merge_starts[goal] = now
                elif phase in {"merge_accept", "merge_conflict"} and goal in merge_starts:
                    merges[goal].append((merge_starts.pop(goal), now, phase))
        if wrapper.get("type") != "codex_event":
            continue
        goal = wrapper.get("goal_id")
        raw = wrapper.get("raw_event", {})
        kind = raw.get("type")
        if kind == "message" and isinstance(raw.get("message"), dict):
            kind = raw["message"].get("type")
        key = goal or "__baseline__"

        if kind == "turn_start":
            turn_number += 1
            active[key] = {
                "number": turn_number,
                "goal": goal,
                "start": now,
                "tools": {},
            }
        elif kind == "tool_execution_start" and key in active:
            arguments = raw.get("args") or raw.get("arguments") or {}
            tool_name = raw.get("toolName", "")
            active[key]["tools"][raw.get("toolCallId", str(now))] = [
                now,
                now,
                tool_phase(tool_name, arguments),
                tool_name,
                arguments,
            ]
        elif kind == "tool_execution_end" and key in active:
            tool_id = raw.get("toolCallId")
            if tool_id in active[key]["tools"]:
                active[key]["tools"][tool_id][1] = now
        elif kind == "turn_end" and key in active:
            turn = active.pop(key)
            turn["end"] = now
            turn["segments"] = partition_turn(turn)
            turns.append(turn)

    return {
        "start": trace_start,
        "end": trace_end,
        "wall": (trace_end - trace_start).total_seconds(),
        "turns": turns,
        "merges": merges,
        "resolutions": resolutions,
    }


def partition_turn(turn):
    points = {turn["start"], turn["end"]}
    for begin, end, *_ in turn["tools"].values():
        points.update((begin, end))
    points = sorted(point for point in points if turn["start"] <= point <= turn["end"])
    segments = []
    for begin, end in zip(points, points[1:]):
        if end <= begin:
            continue
        covering = [tool for tool in turn["tools"].values() if tool[0] <= begin and end <= tool[1]]
        if covering:
            phases = {tool[2] for tool in covering}
            phase = next(
                candidate
                for candidate in ("write", "control", "read")
                if candidate in phases
            )
            names = ", ".join(sorted({tool[3] for tool in covering if tool[3]}))
        else:
            phase = "model"
            names = "model response"
        segments.append((phase, begin, end, names))
    return segments


def elapsed_rounds(trace, selected_turns):
    selected = set(selected_turns)
    segments = []
    for turn in trace["turns"]:
        if turn["number"] not in selected:
            continue
        tool_phases = [tool[2] for tool in turn["tools"].values()]
        if not tool_phases:
            phase = "model"
            tool_names = "model response without tool calls"
        else:
            phase = next(
                candidate
                for candidate in ("write", "control", "read")
                if candidate in tool_phases
            )
            tool_names = ", ".join(sorted({tool[3] for tool in turn["tools"].values()}))
        segments.append(
            {
                "phase": phase,
                "start": (turn["start"] - trace["start"]).total_seconds(),
                "end": (turn["end"] - trace["start"]).total_seconds(),
                "detail": tool_names,
                "turn": turn["number"],
            }
        )
    return segments


def concurrent_rounds(trace, goal):
    rounds = elapsed_rounds(
        trace,
        [turn["number"] for turn in trace["turns"] if turn["goal"] == goal],
    )
    rounds.extend(
        {
            "phase": "merge",
            "start": (begin - trace["start"]).total_seconds(),
            "end": (end - trace["start"]).total_seconds(),
            "detail": phase,
            "turn": 0,
        }
        for begin, end, phase in trace["merges"].get(goal, [])
    )
    rounds.extend(
        {
            "phase": "resolved",
            "start": (at - trace["start"]).total_seconds(),
            "end": (at - trace["start"]).total_seconds(),
            "detail": f"{kind}: {context}",
            "turn": 0,
        }
        for at, kind, context in trace["resolutions"].get(goal, [])
    )
    return sorted(rounds, key=lambda segment: segment["start"])


def render_row(goal, name, segments, total, shared=False):
    bars = []
    for segment in segments:
        left = 100 * segment["start"] / total
        width = max(100 * (segment["end"] - segment["start"]) / total, 0.12)
        duration = segment["end"] - segment["start"]
        turn_detail = f'; turn {segment["turn"]}' if segment["turn"] else ""
        tooltip = html.escape(
            f'{goal}; {segment["phase"]}{turn_detail}; '
            f'{segment["start"]:.1f}s-{segment["end"]:.1f}s; {duration:.1f}s; '
            f'{segment["detail"]}'
        )
        shared_class = " shared" if shared else ""
        bars.append(
            f'<span class="segment {segment["phase"]}{shared_class}" '
            f'style="left:{left:.4f}%;width:{width:.4f}%" title="{tooltip}"></span>'
        )
        if width >= 4.8:
            bars.append(
                f'<span class="duration" style="left:{left:.4f}%;width:{width:.4f}%">'
                f'{duration:.1f}s</span>'
            )
    return f'<div class="row"><strong>{html.escape(goal)}</strong><span>{html.escape(name)}</span><div class="track">{"".join(bars)}</div></div>'


def render(concurrent, baseline, config, output):
    total = max(concurrent["wall"], baseline["wall"])
    baseline_rows = []
    concurrent_rows = []
    for group in config["groups"]:
        baseline_turns = group.get("baseline_turns", [])
        if baseline_turns:
            baseline_rows.append(
                render_row(
                    group["id"],
                    group["name"],
                    elapsed_rounds(baseline, baseline_turns),
                    total,
                    group.get("shared_baseline", False),
                )
            )
        for goal in group.get("concurrent_goals", []):
            concurrent_rows.append(
                render_row(
                    goal,
                    config.get("goal_details", {}).get(goal, ""),
                    concurrent_rounds(concurrent, goal),
                    total,
                )
            )

    ticks = []
    tick = 0
    while tick < total:
        ticks.append(tick)
        tick += 20
    ticks.append(total)
    tick_html = "".join(
        f'<span style="left:{100 * value / total:.4f}%">{value:.0f}s</span>' for value in ticks
    )

    document = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(config["title"])}</title>
<style>
:root{{--bg:#fff;--line:#d9dee5;--text:#202428;--muted:#66707b;--read:#568bc8;--write:#dd8529;--control:#0f766e;--model:#8b5cf6;--merge:#475569;--resolved:#16a085}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--text);font:14px/1.4 system-ui,sans-serif;letter-spacing:0}}
main{{width:min(1500px,calc(100% - 32px));margin:20px auto 48px}}header{{display:flex;justify-content:space-between;align-items:end;gap:24px;margin-bottom:14px}}
h1{{font-size:21px;margin:0 0 3px}}p{{margin:0;color:var(--muted)}}.walls{{display:flex;gap:24px}}.walls strong{{display:block;font-size:19px}}
.legend{{display:flex;gap:20px;margin:12px 0 4px}}.key::before{{content:"";display:inline-block;width:12px;height:12px;margin-right:6px;background:var(--color)}}
.axis{{position:sticky;top:0;z-index:5;margin-left:260px;height:34px;background:#fffc;border-bottom:1px solid #9aa3ad;backdrop-filter:blur(5px)}}.axis span{{position:absolute;bottom:6px;transform:translateX(-50%);color:var(--muted);font-size:12px}}.axis span:first-child{{transform:none}}.axis span:last-child{{transform:translateX(-100%)}}
.panel{{margin-top:18px}}.panel-head{{display:flex;align-items:baseline;justify-content:space-between;margin:0 0 7px 260px}}.panel-head h2{{font-size:16px;margin:0}}.panel-head span{{color:var(--muted)}}
.row{{display:grid;grid-template-columns:80px 180px 1fr;min-height:43px;align-items:center}}.row>strong{{font-family:ui-monospace,monospace}}.row>span{{color:var(--muted);padding-right:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}}
.track{{height:29px;position:relative;border-bottom:1px solid var(--line);background:repeating-linear-gradient(to right,transparent 0,transparent calc(10% - 1px),#eef1f4 calc(10% - 1px),#eef1f4 10%)}}.segment{{position:absolute;top:2px;height:27px;min-width:2px}}.read{{background:var(--read)}}.write{{background:var(--write)}}.control{{background:var(--control)}}.model{{background:var(--model)}}.merge{{background:var(--merge)}}.resolved{{background:var(--resolved)}}.shared{{background-image:repeating-linear-gradient(135deg,#0000 0 7px,#ffffff66 7px 10px)}}.duration{{position:absolute;z-index:2;top:6px;text-align:center;color:#15191d;font-weight:600;pointer-events:none;white-space:nowrap}}
footer{{margin-top:17px;color:var(--muted);font-size:12px}}@media(max-width:780px){{.axis,.panel-head{{margin-left:135px}}.row{{grid-template-columns:60px 75px 1fr}}}}
</style></head><body><main>
<header><div><h1>{html.escape(config["title"])}</h1><p>Both traces aligned to their own start at t=0</p></div><div class="walls"><div>Baseline wall<strong>{baseline["wall"]:.1f}s</strong></div><div>Concurrent wall<strong>{concurrent["wall"]:.1f}s</strong></div></div></header>
<div class="legend"><span class="key" style="--color:var(--read)">read round</span><span class="key" style="--color:var(--write)">write round</span><span class="key" style="--color:var(--control)">planner control round</span><span class="key" style="--color:var(--model)">model-only round</span><span class="key" style="--color:var(--merge)">FUSE merge</span><span class="key" style="--color:var(--resolved)">planner-resolved goal</span></div>
<div class="axis">{tick_html}</div>
<section class="panel"><div class="panel-head"><h2>Serial baseline</h2><span>{baseline["wall"]:.1f}s wall time</span></div>{''.join(baseline_rows)}</section>
<section class="panel"><div class="panel-head"><h2>Concurrent SOG</h2><span>{concurrent["wall"]:.1f}s wall time</span></div>{''.join(concurrent_rows)}</section>
<footer>Tool rounds include their model generation time. Model-only bars are final responses without tool calls. Merge bars cover snapshot materialization. Remaining gaps are dependency or planner-readiness waits. Hover for timestamps and turn number.</footer>
</main></body></html>"""
    output.write_text(document, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--concurrent", required=True, type=Path)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--mapping", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    render(
        parse_trace(args.concurrent),
        parse_trace(args.baseline),
        json.loads(args.mapping.read_text(encoding="utf-8")),
        args.out,
    )
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
