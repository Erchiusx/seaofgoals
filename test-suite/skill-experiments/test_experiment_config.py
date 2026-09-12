#!/usr/bin/env python3

import importlib.util
import os
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("experiment-config.py")
SPEC = importlib.util.spec_from_file_location("experiment_config", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ExperimentConfigTest(unittest.TestCase):
    def test_checked_in_configs_load(self):
        repo_root = SCRIPT.resolve().parents[2]
        fixture = repo_root / "test-suite/skill-experiments/mcp-release-prep-qsv-real"
        concurrent = MODULE.load_config(fixture / "experiment.concurrent.json", repo_root)
        baseline = MODULE.load_config(fixture / "experiment.baseline.json", repo_root)

        self.assertEqual("file-writes-only", concurrent["conflict_mode"])
        self.assertEqual("fuse", concurrent["workspace_backend"])
        self.assertTrue(concurrent["fuse_support"])
        self.assertFalse(baseline["workflow_enabled"])
        self.assertEqual("serial", baseline["scheduler"])
        self.assertTrue(baseline["fuse_support"])

    def test_managed_environment_does_not_leak_between_runs(self):
        config = {
            "runner": "pi",
            "driver": "host",
            "model": "configured-model",
            "scheduler": "concurrent",
            "workflow_enabled": True,
            "graph": Path("/graph.json"),
            "workspace_backend": "fuse",
            "sandbox": "bwrap",
            "conflict_mode": "strict",
            "incremental": True,
            "preload": True,
            "pi_handoff": False,
            "lifecycle": False,
            "cache_key": None,
            "cache_retention": "24h",
            "fuse_support": True,
            "runtime_config": Path("/runtime.json"),
            "skill_path": None,
        }
        with patch.dict(
            os.environ,
            {"SOG_MODEL": "stale-model", "SOG_PROMPT_CACHE_KEY": "stale-key", "KEEP_ME": "yes"},
            clear=True,
        ):
            environment, values = MODULE.build_environment(config)

        self.assertEqual("configured-model", environment["SOG_MODEL"])
        self.assertNotIn("SOG_PROMPT_CACHE_KEY", environment)
        self.assertEqual("yes", environment["KEEP_ME"])
        self.assertEqual("-f fuse", values["SOG_CABAL_FLAGS"])


if __name__ == "__main__":
    unittest.main()
