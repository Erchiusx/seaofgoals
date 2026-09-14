#!/usr/bin/env python3

import datetime
import importlib.util
import tempfile
import unittest
from collections import defaultdict
from pathlib import Path


SCRIPT = Path(__file__).with_name("plot-goal-phases.py")
SPEC = importlib.util.spec_from_file_location("plot_goal_phases", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PlotGoalPhasesTest(unittest.TestCase):
    def test_render_preserves_actual_phase_order(self):
        start = datetime.datetime(2026, 1, 1, tzinfo=datetime.UTC)
        data = defaultdict(list)
        data["G000"] = [
            ("read", start, start + datetime.timedelta(seconds=5)),
            (
                "generation",
                start + datetime.timedelta(seconds=5),
                start + datetime.timedelta(seconds=10),
            ),
            (
                "reasoning",
                start + datetime.timedelta(seconds=10),
                start + datetime.timedelta(seconds=20),
            ),
        ]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "phases.html"
            MODULE.render(data, str(output))
            rendered = output.read_text(encoding="utf-8")

        read = rendered.index("G000 read: 5.0s (0.0s - 5.0s)")
        generation = rendered.index("G000 generation: 5.0s (5.0s - 10.0s)")
        reasoning = rendered.index("G000 reasoning: 10.0s (10.0s - 20.0s)")
        self.assertLess(read, generation)
        self.assertLess(generation, reasoning)


if __name__ == "__main__":
    unittest.main()
