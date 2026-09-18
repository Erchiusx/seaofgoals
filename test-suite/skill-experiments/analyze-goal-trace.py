#!/usr/bin/env python3
"""Print Goal Read/Write round and duration statistics for a SOG trace."""

import argparse
import datetime
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


def is_write(name, arguments):
    if name in {"write", "edit", "write_file"}:
        return True
    if name not in {"bash", "shell"}:
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


def round_kind(calls):
    if any(is_write(name, arguments) for name, arguments in calls):
        return "write"
    if any(name in PLANNER_CONTROL_TOOLS for name, _ in calls):
        return "control"
    return "read"


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
    goal_walls = {}
    current = {}
    turn_number = 0
    for line in open(args.trace, encoding="utf-8"):
        event = json.loads(line)
        now = timestamp(event["timestamp"])
        timestamps.append(now)
        wrapper = event.get("event", {})
        harness_kind = wrapper.get("type")
        if harness_kind == "harness_started":
            match = re.search(r"^Goal id: ([^\s]+)$", wrapper.get("prompt", ""), re.MULTILINE)
            if match:
                goal_walls.setdefault(match.group(1), [now, None])
            continue
        if harness_kind == "tool_call":
            goal = wrapper.get("active_subgoal")
            name = wrapper.get("tool_name")
            if not goal or name == "end_goal":
                continue
            wall = goal_walls.setdefault(goal, [now, None])
            active = current.get(goal)
            start = wall[0]
            if active and active.get("last_result"):
                active["end"] = active["last_result"]
                turns[goal].append(active)
                start = active["last_result"]
                active = None
            if not active:
                active = {
                    "number": turn_number + 1,
                    "start": start,
                    "calls": [],
                    "last_result": None,
                }
                turn_number += 1
            active["calls"].append((name, wrapper.get("arguments") or {}))
            current[goal] = active
            continue
        if harness_kind == "tool_result":
            goal = wrapper.get("active_subgoal")
            if goal in current:
                current[goal]["last_result"] = now
            continue
        if harness_kind == "subgoal_ended":
            goal = wrapper.get("subgoal_id")
            if goal:
                wall = goal_walls.setdefault(goal, [now, None])
                wall[1] = now
                active = current.pop(goal, None)
                if active and active.get("last_result"):
                    active["end"] = active["last_result"]
                    turns[goal].append(active)
            continue
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

    print(
        "Goal | Read rounds | Read time | Write rounds | Write time | "
        "Planner rounds | Planner time | Round time | Goal wall time"
    )
    print(
        "-----|--------------|-----------|---------------|------------|"
        "----------------|--------------|------------|---------------"
    )
    for goal in sorted(turns):
        reads = []
        writes = []
        controls = []
        for turn in turns[goal]:
            calls = [(name, args) for name, args in turn["calls"] if name != "end_goal"]
            if not calls:
                continue
            duration = (turn["end"] - turn["start"]).total_seconds()
            target = {
                "read": reads,
                "write": writes,
                "control": controls,
            }[round_kind(calls)]
            target.append(duration)
        round_time = sum(reads) + sum(writes) + sum(controls)
        wall = goal_walls.get(goal)
        goal_wall_time = (
            (wall[1] - wall[0]).total_seconds()
            if wall and wall[1]
            else round_time
        )
        print(
            f"{goal} | {len(reads)} | {sum(reads):.1f}s | "
            f"{len(writes)} | {sum(writes):.1f}s | "
            f"{len(controls)} | {sum(controls):.1f}s | {round_time:.1f}s | "
            f"{goal_wall_time:.1f}s"
        )


if __name__ == "__main__":
    main()
