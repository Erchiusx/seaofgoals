# port-widget Experiment

Runs the `port-widget` skill against a tiny InstantSearch-like fixture.

The fixture separates flavor-specific work from shared wiring:

- JavaScript widget: `packages/instantsearch.js/src/widgets/color-menu/color-menu.tsx`
- React hook/widget/UI: `packages/react-instantsearch-core/src/connectors/useColorMenu.ts`, `packages/react-instantsearch/src/widgets/ColorMenu.tsx`, `packages/react-instantsearch/src/ui/ColorMenu.tsx`
- Vue wrapper: `packages/vue-instantsearch/src/components/ColorMenu.vue`
- shared wiring likely to conflict: flavor exports, common widget test registrations, and React all-widgets registration

Validation is a static, dependency-free smoke check. It checks required files,
source mentions, and suite registration markers; it does not execute components,
resolve imports, type-check code, or prove behavior. The common test arrays are
fixture metadata rather than executable tests. Follow the neighboring SearchBox
format: `export const tests = ['color-menu renders'];` is accepted without an
extra `widget` constant or a camelCase label. Missing or empty shared fixtures
and missing registration markers still fail.

Run this in a completed experiment workspace (the seed intentionally lacks the
port and will fail):

```sh
node scripts/check-port-widget.js
```

Checker regression tests run outside the agent workspace:

```sh
make test-port-widget-fixture
```

In helped-explore mode, explicit G000 file plans are not capped by
`SOG_PRELOAD_MAX_FILES`; that setting only limits automatic selection when no
plan exists. Per-file size limits still produce explicit omission messages.
