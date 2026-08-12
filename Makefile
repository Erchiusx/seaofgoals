SKILL_EXPERIMENT ?=
SCFG_PYTHON ?= /home/erchius/development/scfg/scfg-package/.venv/bin/python

.PHONY: lint test build-workflows experiment experiment-nextjs-performance experiment-database-migrations experiment-mysql2postgres experiment-test-with-postgres experiment-docker-development experiments view-trace

lint:
	fourmolu --config ./fourmolu.yaml -i lib/ test/ test-suite/agent-runner/

test:
	cabal test

build-workflows:
	$(SCFG_PYTHON) test-suite/skill-experiments/build-workflows.py

experiment:
	test -n "$(SKILL_EXPERIMENT)"
	bash test-suite/skill-experiments/run-experiment.sh "$(SKILL_EXPERIMENT)"

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

view-trace:
	test -n "$(SKILL_EXPERIMENT)"
	python3 test-suite/skill-experiments/view-trace.py "$(SKILL_EXPERIMENT)"
