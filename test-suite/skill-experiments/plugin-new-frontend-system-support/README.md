# plugin-new-frontend-system-support Experiment

Runs the `plugin-new-frontend-system-support` skill against a small Backstage plugin fixture.

The fixture separates independent migration work from shared metadata:

- page variant: `src/components/ReportsPage.tsx`
- API blueprint: `src/apis.ts`
- route default target: `src/routes.ts`
- alpha entry point: `src/alpha.tsx`
- shared wiring likely to conflict: `package.json` exports/typesVersions and public exports in `src/index.ts`

Validation is static and dependency-free:

```sh
cd fixture
node scripts/check-plugin-nfs.js
```

