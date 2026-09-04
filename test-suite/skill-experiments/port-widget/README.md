# port-widget Experiment

Runs the `port-widget` skill against a tiny InstantSearch-like fixture.

The fixture separates flavor-specific work from shared wiring:

- JavaScript widget: `packages/instantsearch.js/src/widgets/color-menu/color-menu.tsx`
- React hook/widget/UI: `packages/react-instantsearch-core/src/connectors/useColorMenu.ts`, `packages/react-instantsearch/src/widgets/ColorMenu.tsx`, `packages/react-instantsearch/src/ui/ColorMenu.tsx`
- Vue wrapper: `packages/vue-instantsearch/src/components/ColorMenu.vue`
- shared wiring likely to conflict: flavor exports, common widget test registrations, and React all-widgets registration

Validation is static and dependency-free:

```sh
cd fixture
node scripts/check-port-widget.js
```

