#!/usr/bin/env python3
"""Print Goal Read/Write round and duration statistics for a SOG trace."""

import argparse
import datetime
import json
import re
from collections import defaultdict
from pathlib import Path


def timestamp(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def is_write(name, arguments):
    if name in {"write", "edit"}:
        return True
    if name != "bash":
        return False
    command = str(arguments.get("command", ""))
    return bool(
        re.search(
            r"\b(apply_patch|sed\s+-i|perl\s+-i|tee|mv|cp|rm|mkdir|touch|"
            r"heavy-compile\.mjs\s+(build|test)|package\.mjs|"
            r"npm(?:\s+--[A-Za-z0-9_-]+(?:[= ][^\s;&|]+)?)*\s+(run|test|install)|"
            r"git\s+(apply|checkout|reset))\b",
            command,
        )
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", help="path to sog-trace.jsonl")
    parser.add_argument(
        "--mapping",
        type=Path,
        help="optional comparison mapping for assigning baseline turns to goals",
    )
    args = parser.parse_args()

    timestamps = []
    turns = defaultdict(list)
    current = {}
    turn_number = 0
    for line in open(args.trace, encoding="utf-8"):
        event = json.loads(line)
        now = timestamp(event["timestamp"])
        timestamps.append(now)
        wrapper = event.get("event", {})
        if wrapper.get("type") != "codex_event":
            continue
        goal = wrapper.get("goal_id")
        raw = wrapper.get("raw_event", {})
        kind = raw.get("type")
        if kind == "turn_start":
            turn_number += 1
            current[goal] = {"number": turn_number, "start": now, "calls": []}
        elif kind == "tool_execution_start" and goal in current:
            current[goal]["calls"].append(
                (raw.get("toolName"), raw.get("arguments") or raw.get("args") or {})
            )
        elif kind == "turn_end" and goal in current:
            turn = current.pop(goal)
            turn["end"] = now
            turns[goal].append(turn)

    if timestamps:
        print(f"Wall time: {(max(timestamps) - min(timestamps)).total_seconds():.1f}s")
    if args.mapping:
        mapping = json.loads(args.mapping.read_text(encoding="utf-8"))
        baseline_turns = {turn["number"]: turn for turn in turns.get(None, [])}
        turns = {
            group["id"]: [
                baseline_turns[number]
                for number in group.get("baseline_turns", [])
                if number in baseline_turns
            ]
            for group in mapping["groups"]
            if group.get("baseline_turns")
        }

    print("Goal | Read rounds | Read time | Write rounds | Write time | Goal time")
    print("-----|--------------|-----------|---------------|------------|----------")
    for goal in sorted(turns):
        reads = []
        writes = []
        for turn in turns[goal]:
            calls = [(name, args) for name, args in turn["calls"] if name != "end_goal"]
            if not calls:
                continue
            duration = (turn["end"] - turn["start"]).total_seconds()
            target = writes if any(is_write(name, args) for name, args in calls) else reads
            target.append(duration)
        goal_time = sum(reads) + sum(writes)
        print(
            f"{goal} | {len(reads)} | {sum(reads):.1f}s | "
            f"{len(writes)} | {sum(writes):.1f}s | {goal_time:.1f}s"
        )


if __name__ == "__main__":
    main()
