# add-trigger Experiment

Runs the `add-trigger` skill against a tiny Sim-like fixture.

The fixture separates trigger creation from shared wiring:

- independent trigger files: `apps/sim/triggers/acmecrm/*.ts`
- shared trigger utilities: `apps/sim/triggers/acmecrm/utils.ts`
- shared wiring likely to conflict: `apps/sim/triggers/registry.ts`, `apps/sim/blocks/blocks/acmecrm.ts`, and `apps/sim/triggers/webhook-input.ts`

Validation is static and dependency-free:

```sh
cd fixture
node scripts/check-add-trigger.js
```

