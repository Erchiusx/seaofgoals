#!/usr/bin/env python3
import argparse
import json
import shutil
import sys
import textwrap
from collections import OrderedDict
from pathlib import Path


EVENT_GLYPHS = {
    "harness_started": "◆",
    "assistant_message": "│",
    "tool_call": "▶",
    "tool_result": "◀",
    "subgoal_started": "┌",
    "subgoal_ended": "└",
    "effect_recorded": "✎",
    "workflow_status": "◇",
    "harness_finished": "■",
}


def main():
    parser = argparse.ArgumentParser(
        description="Render a SeaOfGoals harness JSONL trace as a compact terminal timeline."
    )
    parser.add_argument(
        "target",
        help="Experiment name under test-suite/skill-experiments, or a path to sog-trace.jsonl.",
    )
    parser.add_argument(
        "--width",
        type=int,
        default=shutil.get_terminal_size((120, 24)).columns,
        help="Output width. Defaults to terminal width.",
    )
    parser.add_argument(
        "--full",
        action="store_true",
        help="Do not truncate long tool results or assistant messages.",
    )
    parser.add_argument(
        "--no-color",
        action="store_true",
        help="Disable ANSI colors.",
    )
    args = parser.parse_args()

    trace_path = resolve_trace_path(args.target)
    entries = read_trace(trace_path)
    if not entries:
        print(f"empty trace: {trace_path}", file=sys.stderr)
        return 1

    renderer = Renderer(width=max(args.width, 60), color=not args.no_color, full=args.full)
    renderer.render(trace_path, entries)
    return 0


def resolve_trace_path(target):
    path = Path(target)
    if path.is_file():
        return path

    root = Path(__file__).resolve().parent
    experiment_trace = root / target / "runs" / "current" / "sog-trace.jsonl"
    if experiment_trace.is_file():
        return experiment_trace

    print(f"could not find trace for {target!r}", file=sys.stderr)
    print(f"looked for file path and {experiment_trace}", file=sys.stderr)
    sys.exit(2)


def read_trace(path):
    entries = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError as exc:
                print(f"{path}:{line_number}: invalid json: {exc}", file=sys.stderr)
                sys.exit(2)
    return entries


class Renderer:
    def __init__(self, width, color, full):
        self.width = width
        self.color = color
        self.full = full

    def render(self, trace_path, entries):
        events = [entry.get("event", {}) for entry in entries]
        self.print_header(trace_path, entries, events)
        self.print_subgoals(events)
        self.print_timeline(entries)

    def print_header(self, trace_path, entries, events):
        started = first_event(events, "harness_started")
        finished = last_event(events, "harness_finished")
        prompt = (started or {}).get("prompt", "")
        reason = (finished or {}).get("reason", "unknown")

        print(self.style("SeaOfGoals Trace", "title"))
        print(self.rule())
        print(f"trace:   {trace_path}")
        print(f"events:  {len(entries)}")
        print(f"start:   {entries[0].get('timestamp', '')}")
        print(f"end:     {entries[-1].get('timestamp', '')}")
        print(f"reason:  {self.status(reason)}")
        if prompt:
            print()
            print(self.style("Prompt", "section"))
            print(self.wrap(prompt, limit=900))
        print()

    def print_subgoals(self, events):
        subgoals = OrderedDict()
        for event in events:
            event_type = event.get("type")
            if event_type == "subgoal_started":
                subgoals[event.get("subgoal_id", "?")] = {
                    "name": event.get("subgoal_name", ""),
                    "status": "running",
                    "summary": "",
                    "effects": [],
                    "tools": 0,
                }
            elif event_type == "subgoal_ended":
                subgoal = subgoals.setdefault(event.get("subgoal_id", "?"), {})
                subgoal["status"] = event.get("status", "")
                subgoal["summary"] = event.get("summary", "")
            elif event_type == "effect_recorded":
                active = event.get("active_subgoal") or "unassigned"
                subgoal = subgoals.setdefault(active, {"name": "", "status": "", "summary": "", "effects": [], "tools": 0})
                subgoal.setdefault("effects", []).append(event.get("effect", {}))
            elif event_type == "tool_call":
                active = event.get("active_subgoal") or "no-subgoal"
                if active in subgoals:
                    subgoals[active]["tools"] = subgoals[active].get("tools", 0) + 1

        print(self.style("Subgoals", "section"))
        if not subgoals:
            print("  none")
            print()
            return

        for subgoal_id, subgoal in subgoals.items():
            status = self.status(subgoal.get("status", ""))
            name = subgoal.get("name") or "(unnamed)"
            effects = len(subgoal.get("effects", []))
            tools = subgoal.get("tools", 0)
            print(f"  {status:<18} {subgoal_id:<24} {name}  tools={tools} effects={effects}")
            summary = subgoal.get("summary")
            if summary:
                print(f"    {self.wrap(summary, indent=4, limit=220)}")
        print()

    def print_timeline(self, entries):
        print(self.style("Timeline", "section"))
        for index, entry in enumerate(entries, start=1):
            event = entry.get("event", {})
            timestamp = compact_time(entry.get("timestamp", ""))
            event_type = event.get("type", "?")
            glyph = EVENT_GLYPHS.get(event_type, "·")
            active = event.get("active_subgoal")
            prefix = f"{index:04d} {timestamp} {glyph} "
            line = self.event_line(event)
            if active:
                line = f"[{active}] {line}"
            print(prefix + line)

            detail = self.event_detail(event)
            if detail:
                print(self.wrap(detail, indent=len(prefix), limit=None if self.full else 1200))

    def event_line(self, event):
        event_type = event.get("type")
        if event_type == "harness_started":
            return self.style("harness started", "meta")
        if event_type == "harness_finished":
            return f"harness finished: {self.status(event.get('reason', ''))}"
        if event_type == "assistant_message":
            content = event.get("content", "")
            return "assistant" if content else "assistant (empty)"
        if event_type == "tool_call":
            return f"tool call {self.style(event.get('tool_name', '?'), 'tool')} {event.get('call_id', '')}"
        if event_type == "tool_result":
            return f"tool result {self.style(event.get('tool_name', '?'), 'tool')} {event.get('call_id', '')}"
        if event_type == "subgoal_started":
            return f"begin {self.style(event.get('subgoal_id', '?'), 'subgoal')} {event.get('subgoal_name', '')}"
        if event_type == "subgoal_ended":
            return f"end {self.style(event.get('subgoal_id', '?'), 'subgoal')} {self.status(event.get('status', ''))}"
        if event_type == "effect_recorded":
            effect = event.get("effect", {})
            return f"effect {effect.get('kind', '?')} {effect.get('resource', '')}"
        if event_type == "workflow_status":
            completed = len(event.get("completed_nodes", []))
            warnings = len(event.get("transition_warnings", []))
            return (
                f"workflow active={event.get('active_node') or '-'} "
                f"last={event.get('last_node') or '-'} completed={completed} warnings={warnings}"
            )
        return event_type or "unknown"

    def event_detail(self, event):
        event_type = event.get("type")
        if event_type == "assistant_message":
            return event.get("content", "")
        if event_type == "tool_call":
            return format_jsonish(event.get("arguments"))
        if event_type == "tool_result":
            return event.get("result", "")
        if event_type == "subgoal_ended":
            return event.get("summary", "")
        if event_type == "effect_recorded":
            return event.get("effect", {}).get("detail", "")
        if event_type == "workflow_status":
            warnings = event.get("transition_warnings", [])
            if warnings:
                return "\n".join(warnings)
            return ""
        return ""

    def wrap(self, text, indent=0, limit=1200):
        if limit is not None and len(text) > limit:
            text = text[:limit] + "\n... truncated ..."
        width = max(self.width - indent, 40)
        lines = []
        for paragraph in str(text).splitlines() or [""]:
            if not paragraph:
                lines.append("")
            else:
                lines.extend(textwrap.wrap(paragraph, width=width, replace_whitespace=False, drop_whitespace=False))
        padding = " " * indent
        return "\n".join(padding + line for line in lines)

    def status(self, status):
        if not status:
            return ""
        if status in {"success", "stop", "assistant_finished"}:
            return self.style(status, "ok")
        if status in {"failed", "error", "max_turns_reached"} or "error" in status:
            return self.style(status, "bad")
        return self.style(status, "warn")

    def style(self, text, kind):
        if not self.color:
            return str(text)
        colors = {
            "title": "\033[1;36m",
            "section": "\033[1;33m",
            "ok": "\033[32m",
            "bad": "\033[31m",
            "warn": "\033[33m",
            "tool": "\033[35m",
            "subgoal": "\033[36m",
            "meta": "\033[2m",
        }
        return f"{colors.get(kind, '')}{text}\033[0m"

    def rule(self):
        return self.style("─" * min(self.width, 100), "meta")


def compact_time(timestamp):
    if "T" in timestamp:
        return timestamp.split("T", 1)[1].replace("Z", "")[:12]
    return timestamp[:12]


def first_event(events, event_type):
    for event in events:
        if event.get("type") == event_type:
            return event
    return None


def last_event(events, event_type):
    for event in reversed(events):
        if event.get("type") == event_type:
            return event
    return None


def format_jsonish(value):
    if value is None:
        return ""
    return json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True)


if __name__ == "__main__":
    raise SystemExit(main())
