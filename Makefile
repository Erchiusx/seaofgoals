SKILL_EXPERIMENT ?=
SKILL_NAME ?= skill
SKILL_PATH ?=
COMPILED_GOALS_OUT ?= compiled-goals.json
SCFG_PYTHON ?= /home/erchius/development/scfg/scfg-package/.venv/bin/python

.PHONY: lint test analyze-trace plot-goal-coverage plot-goal-phases compile-skill compile-skill-with-preload-planner compile-skill-bootstrap compile-skill-bootstrap-with-preload-planner build-workflows smoke-containerd smoke-bwrap experiment experiment-concurrent experiment-codex experiment-codex-fuse experiment-codex-fuse-preload experiment-pi experiment-pi-concurrent experiment-pi-concurrent-planner experiment-pi-fuse-concurrent-planner experiment-no-scfg experiment-nextjs-performance experiment-database-migrations experiment-mysql2postgres experiment-test-with-postgres experiment-docker-development experiments experiments-no-scfg view-trace serve-traces

lint:
	fourmolu --config ./fourmolu.yaml -i lib/ test/ test-suite/agent-runner/ compiler/ compiler-bootstrap/ smoke/ test-fuse/

test:
	cabal test

analyze-trace:
	test -n "$(TRACE)"
	python3 test-suite/skill-experiments/analyze-goal-trace.py "$(TRACE)"

plot-goal-coverage:
	test -n "$(TRACE)"
	test -n "$(OUT)"
	python3 test-suite/skill-experiments/plot-goal-coverage.py "$(TRACE)" --out "$(OUT)"

plot-goal-phases:
	test -n "$(TRACE)"
	test -n "$(OUT)"
	python3 test-suite/skill-experiments/plot-goal-phases.py "$(TRACE)" --out "$(OUT)"

.PHONY: test-port-widget-fixture
test-port-widget-fixture:
	node --test test-suite/skill-experiments/port-widget/checker.test.mjs

compile-skill:
	test -n "$(SKILL_PATH)"
	cabal run exe:SeaOfGoals-compiler -- "$(SKILL_PATH)" "$(COMPILED_GOALS_OUT)" "$(SKILL_NAME)"

compile-skill-with-preload-planner:
	test -n "$(SKILL_PATH)"
	SOG_COMPILER_PRELOAD_PLANNER=1 cabal run exe:SeaOfGoals-compiler -- "$(SKILL_PATH)" "$(COMPILED_GOALS_OUT)" "$(SKILL_NAME)"

compile-skill-bootstrap:
	test -n "$(SKILL_PATH)"
	cabal run exe:SeaOfGoals-compiler-bootstrap -- "$(SKILL_PATH)" "$(COMPILED_GOALS_OUT)" "$(SKILL_NAME)"

compile-skill-bootstrap-with-preload-planner:
	test -n "$(SKILL_PATH)"
	SOG_COMPILER_PRELOAD_PLANNER=1 cabal run exe:SeaOfGoals-compiler-bootstrap -- "$(SKILL_PATH)" "$(COMPILED_GOALS_OUT)" "$(SKILL_NAME)"

build-workflows:
	$(SCFG_PYTHON) test-suite/skill-experiments/build-workflows.py

smoke-containerd:
	cabal run exe:SeaOfGoals-containerd-smoke

smoke-bwrap:
	cabal run exe:SeaOfGoals-bwrap-smoke

experiment:
	test -n "$(SKILL_EXPERIMENT)"
	bash test-suite/skill-experiments/run-experiment.sh "$(SKILL_EXPERIMENT)"

experiment-concurrent:
	test -n "$(SKILL_EXPERIMENT)"
	SOG_SCHEDULER=concurrent bash test-suite/skill-experiments/run-experiment.sh "$(SKILL_EXPERIMENT)"

experiment-codex:
	test -n "$(SKILL_EXPERIMENT)"
	SOG_AGENT_RUNNER=codex SOG_EXPERIMENT_DRIVER=host bash test-suite/skill-experiments/run-experiment.sh "$(SKILL_EXPERIMENT)"

experiment-codex-fuse:
	test -n "$(SKILL_EXPERIMENT)"
	SOG_AGENT_RUNNER=codex SOG_EXPERIMENT_DRIVER=host SOG_SCHEDULER=concurrent SOG_CONCURRENT_WORKSPACE=fuse SOG_CABAL_FLAGS="-f fuse" bash test-suite/skill-experiments/run-experiment.sh "$(SKILL_EXPERIMENT)"

experiment-codex-fuse-preload:
	test -n "$(SKILL_EXPERIMENT)"
	SOG_AGENT_RUNNER=codex SOG_EXPERIMENT_DRIVER=host SOG_SCHEDULER=concurrent SOG_CONCURRENT_WORKSPACE=fuse SOG_PRELOAD_GOAL_CONTEXT=1 SOG_CABAL_FLAGS="-f fuse" bash test-suite/skill-experiments/run-experiment.sh "$(SKILL_EXPERIMENT)"

experiment-pi:
	test -n "$(SKILL_EXPERIMENT)"
	SOG_AGENT_RUNNER=pi SOG_EXPERIMENT_DRIVER=host bash test-suite/skill-experiments/run-experiment.sh "$(SKILL_EXPERIMENT)"

experiment-pi-concurrent:
	test -n "$(SKILL_EXPERIMENT)"
	SOG_AGENT_RUNNER=pi SOG_EXPERIMENT_DRIVER=host SOG_SCHEDULER=concurrent bash test-suite/skill-experiments/run-experiment.sh "$(SKILL_EXPERIMENT)"

experiment-pi-concurrent-planner:
	test -n "$(SKILL_EXPERIMENT)"
	SOG_AGENT_RUNNER=pi SOG_EXPERIMENT_DRIVER=host SOG_SCHEDULER=concurrent SOG_INCREMENTAL_PLANNER=1 SOG_PRELOAD_GOAL_CONTEXT=1 bash test-suite/skill-experiments/run-experiment.sh "$(SKILL_EXPERIMENT)"

experiment-pi-fuse-concurrent-planner:
	test -n "$(SKILL_EXPERIMENT)"
	SOG_AGENT_RUNNER=pi SOG_EXPERIMENT_DRIVER=host SOG_SCHEDULER=concurrent SOG_CONCURRENT_WORKSPACE=fuse SOG_CABAL_FLAGS="-f fuse" SOG_INCREMENTAL_PLANNER=1 SOG_PRELOAD_GOAL_CONTEXT=1 SOG_PI_HISTORY_HANDOFF=0 SOG_HARNESS_LIFECYCLE=0 bash test-suite/skill-experiments/run-experiment.sh "$(SKILL_EXPERIMENT)"

experiment-no-scfg:
	test -n "$(SKILL_EXPERIMENT)"
	SOG_DISABLE_WORKFLOW=1 SOG_MODEL=gpt-5.5 bash test-suite/skill-experiments/run-experiment.sh "$(SKILL_EXPERIMENT)"

experiment-nextjs-performance:
	bash test-suite/skill-experiments/run-experiment.sh nextjs-performance

experiment-database-migrations:
	bash test-suite/skill-experiments/run-experiment.sh database-migrations

experiment-mysql2postgres:
	bash test-suite/skill-experiments/run-experiment.sh mysql2postgres

experiment-test-with-postgres:
	bash test-suite/skill-experiments/run-experiment.sh test-with-postgres

experiment-docker-development:
	bash test-suite/skill-experiments/run-experiment.sh docker-development

experiments:
	$(MAKE) experiment-nextjs-performance
	$(MAKE) experiment-database-migrations
	$(MAKE) experiment-mysql2postgres
	$(MAKE) experiment-test-with-postgres

experiments-no-scfg:
	SOG_DISABLE_WORKFLOW=1 SOG_MODEL=gpt-5.5 $(MAKE) experiment-nextjs-performance
	SOG_DISABLE_WORKFLOW=1 SOG_MODEL=gpt-5.5 $(MAKE) experiment-database-migrations
	SOG_DISABLE_WORKFLOW=1 SOG_MODEL=gpt-5.5 $(MAKE) experiment-mysql2postgres
	SOG_DISABLE_WORKFLOW=1 SOG_MODEL=gpt-5.5 $(MAKE) experiment-test-with-postgres

view-trace:
	test -n "$(SKILL_EXPERIMENT)"
	python3 test-suite/skill-experiments/view-trace.py "$(SKILL_EXPERIMENT)"

serve-traces:
	python3 test-suite/skill-experiments/serve-traces.py
