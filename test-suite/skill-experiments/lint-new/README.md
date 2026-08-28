# lint-new Experiment

Runs the `lint-new` skill against a minimal eslintPluginScraps-like fixture.

The fixture is designed to mix independent files with shared wiring files:

- independent rule implementation: `static/eslint/eslintPluginScraps/src/rules/no-raw-color.ts`
- independent rule test: `static/eslint/eslintPluginScraps/src/rules/no-raw-color.spec.ts`
- shared wiring: `static/eslint/eslintPluginScraps/src/rules/index.ts`
- shared config: `eslint.config.ts`

