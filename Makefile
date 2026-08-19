SKILL_EXPERIMENT ?=
SKILL_NAME ?= skill
SKILL_PATH ?=
COMPILED_GOALS_OUT ?= compiled-goals.json
SCFG_PYTHON ?= /home/erchius/development/scfg/scfg-package/.venv/bin/python

.PHONY: lint test compile-skill build-workflows smoke-containerd smoke-bwrap experiment experiment-no-scfg experiment-nextjs-performance experiment-database-migrations experiment-mysql2postgres experiment-test-with-postgres experiment-docker-development experiments experiments-no-scfg view-trace

lint:
	fourmolu --config ./fourmolu.yaml -i lib/ test/ test-suite/agent-runner/ compiler/ smoke/ test-fuse/

test:
	cabal test

compile-skill:
	test -n "$(SKILL_PATH)"
	cabal run exe:SeaOfGoals-compiler -- "$(SKILL_PATH)" "$(COMPILED_GOALS_OUT)" "$(SKILL_NAME)"

build-workflows:
	$(SCFG_PYTHON) test-suite/skill-experiments/build-workflows.py

smoke-containerd:
	cabal run exe:SeaOfGoals-containerd-smoke

smoke-bwrap:
	cabal run exe:SeaOfGoals-bwrap-smoke

experiment:
	test -n "$(SKILL_EXPERIMENT)"
	bash test-suite/skill-experiments/run-experiment.sh "$(SKILL_EXPERIMENT)"

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
