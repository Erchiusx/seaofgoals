#!/usr/bin/env python3
"""Validate an experiment description and launch it with an isolated environment."""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


MANAGED_ENV = {
    "SOG_AGENT_RUNNER",
    "SOG_CABAL_FLAGS",
    "SOG_CONCURRENT_WORKSPACE",
    "SOG_CONFIG",
    "SOG_CONFIG_FILE",
    "SOG_CONFLICT_MODE",
    "SOG_DISABLE_WORKFLOW",
    "SOG_EXPERIMENT_DRIVER",
    "SOG_EXPERIMENT_CONFIG",
    "SOG_GRAPH_PATH",
    "SOG_HARNESS_LIFECYCLE",
    "SOG_HARNESS_COMPACTED_HISTORY_HANDOFF",
    "SOG_INCREMENTAL_PLANNER",
    "SOG_MODEL",
    "SOG_PI_HISTORY_HANDOFF",
    "SOG_PI_MODEL",
    "SOG_PRELOAD_GOAL_CONTEXT",
    "SOG_PROMPT_CACHE_KEY",
    "SOG_PROMPT_CACHE_RETENTION",
    "SOG_BWRAP_MASK_GOALS",
    "SOG_BWRAP_MASK_WORKSPACE_PATHS",
    "SOG_SANDBOX",
    "SOG_SKILL_PATH",
}


def require_keys(value, allowed, context):
    unknown = sorted(set(value) - set(allowed))
    if unknown:
        raise ValueError(f"unknown {context} keys: {', '.join(unknown)}")


def enum(value, choices, context):
    if value not in choices:
        raise ValueError(f"{context} must be one of: {', '.join(choices)}")
    return value


def boolean(value, context):
    if not isinstance(value, bool):
        raise ValueError(f"{context} must be a boolean")
    return value


def string_list(value, context):
    if not isinstance(value, list) or any(not isinstance(item, str) or not item for item in value):
        raise ValueError(f"{context} must be a list of non-empty strings")
    return value


def repo_path(repo_root, value, context):
    if not isinstance(value, str) or not value:
        raise ValueError(f"{context} must be a non-empty path")
    path = Path(value).expanduser()
    return path if path.is_absolute() else repo_root / path


def load_config(path, repo_root):
    config = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(config, dict):
        raise ValueError("experiment config must be a JSON object")
    require_keys(
        config,
        {
            "version",
            "experiment",
            "runner",
            "driver",
            "model",
            "scheduler",
            "workflow",
            "workspace",
            "planning",
            "history",
            "harness",
            "cache",
            "build",
            "runtimeConfig",
            "skillPath",
        },
        "top-level",
    )
    if config.get("version") != 1:
        raise ValueError("experiment config version must be 1")
    for key in ("experiment", "model"):
        if not isinstance(config.get(key), str) or not config[key]:
            raise ValueError(f"{key} must be a non-empty string")

    runner = enum(config.get("runner"), ("harness", "codex", "pi"), "runner")
    driver = enum(config.get("driver"), ("host", "docker"), "driver")
    scheduler = enum(config.get("scheduler"), ("serial", "concurrent"), "scheduler")

    workflow = config.get("workflow", {})
    require_keys(workflow, {"enabled", "graph"}, "workflow")
    workflow_enabled = boolean(workflow.get("enabled", True), "workflow.enabled")

    workspace = config.get("workspace", {})
    require_keys(
        workspace,
        {"backend", "sandbox", "conflictMode", "maskedPaths", "maskedPathGoals"},
        "workspace",
    )
    workspace_backend = enum(
        workspace.get("backend", "copy-tree"),
        ("copy-tree", "fuse"),
        "workspace.backend",
    )
    sandbox = enum(workspace.get("sandbox", "bwrap"), ("bwrap",), "workspace.sandbox")
    conflict_mode = enum(
        workspace.get("conflictMode", "strict"),
        ("strict", "file-writes-only"),
        "workspace.conflictMode",
    )
    masked_paths = string_list(workspace.get("maskedPaths", []), "workspace.maskedPaths")
    masked_path_goals = string_list(
        workspace.get("maskedPathGoals", []), "workspace.maskedPathGoals"
    )
    for path in masked_paths:
        parsed = Path(path)
        if parsed.is_absolute() or ".." in parsed.parts:
            raise ValueError("workspace.maskedPaths entries must stay inside the workspace")

    planning = config.get("planning", {})
    require_keys(planning, {"incremental", "preload"}, "planning")
    incremental = boolean(planning.get("incremental", False), "planning.incremental")
    preload = boolean(planning.get("preload", False), "planning.preload")

    history = config.get("history", {})
    require_keys(history, {"piHandoff", "harnessCompactedHandoff"}, "history")
    pi_handoff = boolean(history.get("piHandoff", False), "history.piHandoff")
    harness_compacted_handoff = boolean(
        history.get("harnessCompactedHandoff", False),
        "history.harnessCompactedHandoff",
    )
    if harness_compacted_handoff and runner != "harness":
        raise ValueError("history.harnessCompactedHandoff requires runner=harness")

    harness = config.get("harness", {})
    require_keys(harness, {"lifecycle"}, "harness")
    lifecycle = boolean(harness.get("lifecycle", False), "harness.lifecycle")

    cache = config.get("cache", {})
    require_keys(cache, {"key", "retention"}, "cache")
    cache_key = cache.get("key")
    cache_retention = cache.get("retention", "24h")
    if cache_key is not None and (not isinstance(cache_key, str) or not cache_key):
        raise ValueError("cache.key must be a non-empty string when provided")
    if not isinstance(cache_retention, str) or not cache_retention:
        raise ValueError("cache.retention must be a non-empty string")

    build = config.get("build", {})
    require_keys(build, {"fuseSupport"}, "build")
    fuse_support = boolean(
        build.get("fuseSupport", workspace_backend == "fuse"),
        "build.fuseSupport",
    )

    experiment_dir = repo_root / "test-suite" / "skill-experiments" / config["experiment"]
    graph = repo_path(
        repo_root,
        workflow.get("graph", str(experiment_dir / "sog.json")),
        "workflow.graph",
    )
    runtime_config = repo_path(
        repo_root,
        config.get("runtimeConfig", "seaofgoals.config.json"),
        "runtimeConfig",
    )
    skill_path = config.get("skillPath")
    if skill_path is not None:
        skill_path = repo_path(repo_root, skill_path, "skillPath")

    if scheduler != "concurrent" and workspace_backend == "fuse":
        raise ValueError("workspace.backend=fuse requires scheduler=concurrent")
    if workspace_backend == "fuse" and not fuse_support:
        raise ValueError("workspace.backend=fuse requires build.fuseSupport=true")
    if incremental and not workflow_enabled:
        raise ValueError("planning.incremental requires workflow.enabled=true")
    if preload and not incremental:
        raise ValueError("planning.preload requires planning.incremental=true")
    for referenced_path, context in (
        (experiment_dir, "experiment directory"),
        (graph, "workflow graph"),
        (runtime_config, "runtime config"),
    ):
        if not referenced_path.exists():
            raise ValueError(f"{context} does not exist: {referenced_path}")
    if skill_path is not None and not skill_path.is_file():
        raise ValueError(f"skill source does not exist: {skill_path}")

    return {
        "experiment": config["experiment"],
        "runner": runner,
        "driver": driver,
        "model": config["model"],
        "scheduler": scheduler,
        "workflow_enabled": workflow_enabled,
        "graph": graph,
        "workspace_backend": workspace_backend,
        "sandbox": sandbox,
        "conflict_mode": conflict_mode,
        "masked_paths": masked_paths,
        "masked_path_goals": masked_path_goals,
        "incremental": incremental,
        "preload": preload,
        "pi_handoff": pi_handoff,
        "harness_compacted_handoff": harness_compacted_handoff,
        "lifecycle": lifecycle,
        "cache_key": cache_key,
        "cache_retention": cache_retention,
        "fuse_support": fuse_support,
        "runtime_config": runtime_config,
        "skill_path": skill_path,
    }


def build_environment(config):
    environment = {key: value for key, value in os.environ.items() if key not in MANAGED_ENV}
    values = {
        "SOG_AGENT_RUNNER": config["runner"],
        "SOG_EXPERIMENT_DRIVER": config["driver"],
        "SOG_MODEL": config["model"],
        "SOG_PI_MODEL": config["model"],
        "SOG_SCHEDULER": config["scheduler"],
        "SOG_DISABLE_WORKFLOW": "0" if config["workflow_enabled"] else "1",
        "SOG_GRAPH_PATH": str(config["graph"]),
        "SOG_CONCURRENT_WORKSPACE": config["workspace_backend"],
        "SOG_SANDBOX": config["sandbox"],
        "SOG_CONFLICT_MODE": config["conflict_mode"],
        "SOG_INCREMENTAL_PLANNER": "1" if config["incremental"] else "0",
        "SOG_PRELOAD_GOAL_CONTEXT": "1" if config["preload"] else "0",
        "SOG_PI_HISTORY_HANDOFF": "1" if config["pi_handoff"] else "0",
        "SOG_HARNESS_COMPACTED_HISTORY_HANDOFF": (
            "1" if config["harness_compacted_handoff"] else "0"
        ),
        "SOG_HARNESS_LIFECYCLE": "1" if config["lifecycle"] else "0",
        "SOG_PROMPT_CACHE_RETENTION": config["cache_retention"],
        "SOG_CONFIG_FILE": str(config["runtime_config"]),
    }
    if config.get("masked_paths"):
        values["SOG_BWRAP_MASK_WORKSPACE_PATHS"] = os.pathsep.join(config["masked_paths"])
    if config.get("masked_path_goals"):
        values["SOG_BWRAP_MASK_GOALS"] = ",".join(config["masked_path_goals"])
    if config["fuse_support"]:
        values["SOG_CABAL_FLAGS"] = "-f fuse"
    if config["cache_key"] is not None:
        values["SOG_PROMPT_CACHE_KEY"] = config["cache_key"]
    if config["skill_path"] is not None:
        values["SOG_SKILL_PATH"] = str(config["skill_path"])
    environment.update(values)
    return environment, values


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("config", type=Path)
    parser.add_argument("--show", action="store_true", help="validate and print settings without running")
    args = parser.parse_args()
    repo_root = Path(__file__).resolve().parents[2]
    try:
        config_path = args.config.resolve()
        config = load_config(config_path, repo_root)
        environment, values = build_environment(config)
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"invalid experiment config: {error}", file=sys.stderr)
        return 2

    values["SOG_EXPERIMENT_CONFIG"] = str(config_path)
    environment["SOG_EXPERIMENT_CONFIG"] = str(config_path)
    print(json.dumps({"experiment": config["experiment"], "environment": values}, indent=2))
    if args.show:
        return 0
    command = ["bash", str(repo_root / "test-suite/skill-experiments/run-experiment.sh"), config["experiment"]]
    return subprocess.run(command, cwd=repo_root, env=environment, check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
