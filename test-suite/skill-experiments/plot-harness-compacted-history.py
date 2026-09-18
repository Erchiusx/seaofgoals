#!/usr/bin/env python3
"""Render Harness goal rounds and compacted-history handoffs on one timeline."""

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


def round_kind(calls):
    if any(name == "end_goal" for name, _ in calls):
        return "end_goal"
    if any(name in PLANNER_CONTROL_TOOLS for name, _ in calls):
        return "control"
    if any(name in {"write", "edit", "write_file"} for name, _ in calls):
        return "write"
    for name, arguments in calls:
        if name not in {"bash", "shell"}:
            continue
        command = re.sub(r"'(?:[^']*)'|\"(?:\\.|[^\"])*\"", "", str(arguments.get("command", "")))
        if re.search(r"\b(apply_patch|sed\s+-i|perl\s+-i|tee|mv|cp|rm|mkdir|touch|npm\s+(run|test|install))\b", command):
            return "write"
    return "read"


def goal_id(prompt):
    match = re.search(r"^Goal id: ([^\s]+)$", prompt, re.MULTILINE)
    return match.group(1) if match else None


def parse_trace(path):
    records = [json.loads(line) for line in path.open(encoding="utf-8")]
    start = timestamp(records[0]["timestamp"])
    end = timestamp(records[-1]["timestamp"])
    rounds = defaultdict(list)
    goal_walls = {}
    active = {}
    handoffs = []
    last_finished = None
    sequence = 0

    def close(goal):
        turn = active.pop(goal, None)
        if turn and turn["result"]:
            turn["end"] = turn["result"]
            rounds[goal].append(turn)

    for record in records:
        now = timestamp(record["timestamp"])
        event = record.get("event", {})
        kind = event.get("type")
        if kind == "harness_started":
            current_goal = goal_id(event.get("prompt", ""))
            if current_goal:
                goal_walls.setdefault(current_goal, [now, None])
        elif kind == "tool_call":
            goal = event.get("active_subgoal")
            name = event.get("tool_name")
            if not goal:
                continue
            previous = active.get(goal)
            if previous and previous["result"]:
                close(goal)
                begin = previous["result"]
            else:
                begin = goal_walls.setdefault(goal, [now, None])[0]
            if name == "end_goal":
                sequence += 1
                rounds[goal].append(
                    {
                        "number": sequence,
                        "start": begin,
                        "end": now,
                        "result": now,
                        "calls": [(name, event.get("arguments") or {})],
                    }
                )
                continue
            if goal not in active:
                sequence += 1
                active[goal] = {"number": sequence, "start": begin, "result": None, "calls": []}
            active[goal]["calls"].append((name, event.get("arguments") or {}))
        elif kind == "tool_result":
            goal = event.get("active_subgoal")
            if goal in active:
                active[goal]["result"] = now
        elif kind == "subgoal_ended":
            goal = event.get("subgoal_id")
            if goal:
                close(goal)
                goal_walls.setdefault(goal, [now, None])[1] = now
        elif kind == "harness_finished":
            last_finished = now
        elif kind == "compacted_history_handoff":
            handoffs.append(
                {
                    "goal": event["successor_goal_id"],
                    "start": last_finished or now,
                    "end": now,
                    "items": event["compaction_input_items"],
                    "output": event["compaction_output_items"],
                    "chars": event["compaction_encrypted_content_chars"],
                    "reused": event.get("reused", False),
                }
            )
    return start, end, rounds, goal_walls, handoffs


def render(trace, graph, output):
    start, end, rounds, walls, handoffs = parse_trace(trace)
    names = {goal["id"]: goal["name"] for goal in json.loads(graph.read_text(encoding="utf-8"))["goals"]}
    total = max((end - start).total_seconds(), 0.001)

    def offset(at):
        return (at - start).total_seconds()

    def segment(kind, begin, finish, detail, label=""):
        left = 100 * offset(begin) / total
        duration = max((finish - begin).total_seconds(), 0)
        width = max(100 * duration / total, 0.14)
        title = html.escape(f"{kind}; {offset(begin):.1f}s–{offset(finish):.1f}s; {duration:.1f}s; {detail}")
        text = f'<span class="duration" style="left:{left:.4f}%;width:{width:.4f}%">{label or f"{duration:.1f}s"}</span>' if width >= 5 else ""
        return f'<span class="segment {kind}" style="left:{left:.4f}%;width:{width:.4f}%" title="{title}"></span>{text}'

    rows = []
    for goal in names:
        bars = []
        for turn in rounds.get(goal, []):
            phase = round_kind(turn["calls"])
            tools = ", ".join(name for name, _ in turn["calls"])
            bars.append(segment(phase, turn["start"], turn["end"], f"round {turn['number']}; {tools}"))
        wall = walls.get(goal)
        wall_text = ""
        if wall and wall[1]:
            wall_text = f"{(wall[1] - wall[0]).total_seconds():.1f}s wall"
        rows.append(f'<div class="row"><strong>{html.escape(goal)}</strong><span>{html.escape(names[goal])}<small>{wall_text}</small></span><div class="track">{"".join(bars)}</div></div>')

    handoff_rows = []
    for handoff in handoffs:
        origin = "cache reuse" if handoff["reused"] else "remote compaction"
        detail = f"{origin}; {handoff['items']} input items → {handoff['output']} returned items; {handoff['chars']} encrypted chars"
        bar = segment("reused" if handoff["reused"] else "compact", handoff["start"], handoff["end"], detail)
        handoff_rows.append(f'<div class="row handoff"><strong>→ {html.escape(handoff["goal"])}</strong><span>compacted handoff<small>{html.escape(detail)}</small></span><div class="track">{bar}</div></div>')

    ticks = []
    step = 60
    value = 0
    while value < total:
        ticks.append(value)
        value += step
    ticks.append(total)
    tick_html = "".join(f'<span style="left:{100 * value / total:.4f}%">{value:.0f}s</span>' for value in ticks)
    document = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>port-widget compacted-history timeline</title><style>
:root{{--bg:#fff;--line:#d9dee5;--text:#202428;--muted:#66707b;--read:#568bc8;--write:#dd8529;--control:#0f766e;--end-goal:#475569;--compact:#8b5cf6;--reused:#64748b}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--text);font:14px/1.4 system-ui,sans-serif}}main{{width:min(1500px,calc(100% - 32px));margin:20px auto 48px}}header{{display:flex;justify-content:space-between;align-items:end;gap:24px;margin-bottom:14px}}h1{{font-size:21px;margin:0 0 3px}}p,small{{display:block;color:var(--muted)}}p{{margin:0}}.wall strong{{display:block;font-size:19px}}.legend{{display:flex;gap:20px;flex-wrap:wrap;margin:12px 0 4px}}.key::before{{content:"";display:inline-block;width:12px;height:12px;margin-right:6px;background:var(--color)}}.axis{{position:sticky;top:0;z-index:5;margin-left:260px;height:34px;background:#fffc;border-bottom:1px solid #9aa3ad;backdrop-filter:blur(5px)}}.axis span{{position:absolute;bottom:6px;transform:translateX(-50%);color:var(--muted);font-size:12px}}.axis span:first-child{{transform:none}}.axis span:last-child{{transform:translateX(-100%)}}.panel{{margin-top:18px}}.panel-head{{margin:0 0 7px 260px}}.panel-head h2{{font-size:16px;margin:0}}.row{{display:grid;grid-template-columns:80px 180px 1fr;min-height:43px;align-items:center}}.row>strong{{font-family:ui-monospace,monospace}}.row>span{{color:var(--muted);padding-right:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}}.track{{height:29px;position:relative;border-bottom:1px solid var(--line);background:repeating-linear-gradient(to right,transparent 0,transparent calc(10% - 1px),#eef1f4 calc(10% - 1px),#eef1f4 10%)}}.segment{{position:absolute;top:2px;height:27px;min-width:2px}}.read{{background:var(--read)}}.write{{background:var(--write)}}.control{{background:var(--control)}}.end_goal{{background:var(--end-goal)}}.compact{{background:var(--compact);background-image:repeating-linear-gradient(135deg,#0000 0 7px,#ffffff66 7px 10px)}}.reused{{background:var(--reused)}}.duration{{position:absolute;z-index:2;top:6px;text-align:center;color:#15191d;font-weight:600;pointer-events:none;white-space:nowrap}}footer{{margin-top:17px;color:var(--muted);font-size:12px}}@media(max-width:780px){{.axis,.panel-head{{margin-left:135px}}.row{{grid-template-columns:60px 75px 1fr}}}}
</style></head><body><main><header><div><h1>port-widget: compacted-history Harness run</h1><p>All phases share the run clock. Hover a bar for its exact interval, round, and tools.</p></div><div class="wall">Run wall time<strong>{total:.1f}s</strong></div></header><div class="legend"><span class="key" style="--color:var(--read)">read round</span><span class="key" style="--color:var(--write)">write round</span><span class="key" style="--color:var(--control)">planner control round</span><span class="key" style="--color:var(--end-goal)">goal completion</span><span class="key" style="--color:var(--compact)">remote compaction</span><span class="key" style="--color:var(--reused)">cache reuse</span></div><div class="axis">{tick_html}</div><section class="panel"><div class="panel-head"><h2>Goal read/write rounds</h2></div>{''.join(rows)}</section><section class="panel"><div class="panel-head"><h2>Compacted predecessor handoffs</h2></div>{''.join(handoff_rows)}</section><footer>Goal completion bars measure model time from a Harness start or prior tool result until its end_goal call. Compaction intervals run from the previous goal lifecycle finish to the recorded compaction response; they are client-observed and can include small scheduler overhead.</footer></main></body></html>"""
    output.write_text(document, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--trace", required=True, type=Path)
    parser.add_argument("--graph", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    render(args.trace, args.graph, args.out)
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
