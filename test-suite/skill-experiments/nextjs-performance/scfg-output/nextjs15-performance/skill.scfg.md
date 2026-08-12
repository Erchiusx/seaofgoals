---
name: nextjs15-performance
description: Next.js 15 critical performance fixes. Use when writing React components, data fetching, Server Actions, or optimizing bundle size.
---

## Before writing Next.js code:

### Step N001. Before writing Next.js code
First run `echo "[AgentSanitizer] M_N001_begin"`.

1. Read `docs/agent/architecture/nextjs-critical-fixes.md` for full patterns
2. Check existing components in `apps/frontend/components/` for examples

On completion of this node, run `echo "[AgentSanitizer] M_N001_end"`.
This step can be the first step if necessary.
After this step, continue to any of Steps `N002`, `N003`, `N004`, `N005` if necessary.

## Critical Rules (always apply):

### Step N002. Waterfalls
First run `echo "[AgentSanitizer] M_N002_begin"`.

- Use `Promise.all()` for independent fetches
- Wrap slow data in `<Suspense>` boundaries
- Defer `await` into branches where needed

On completion of this node, run `echo "[AgentSanitizer] M_N002_end"`.
After this step, continue to any of Steps `N006` if necessary.

### Step N003. Bundle Size
First run `echo "[AgentSanitizer] M_N003_begin"`.

- NO barrel imports: `import X from 'lucide-react'` ❌
- YES direct imports: `import X from 'lucide-react/dist/esm/icons/x'` ✅
- Use `next/dynamic` for heavy components (editors, charts, PDF viewers)
- Defer analytics with `ssr: false`

On completion of this node, run `echo "[AgentSanitizer] M_N003_end"`.
After this step, continue to any of Steps `N006` if necessary.

### Step N004. Server Actions
First run `echo "[AgentSanitizer] M_N004_begin"`.

- ALWAYS check auth INSIDE the action, not just middleware
- Verify resource ownership before mutations

On completion of this node, run `echo "[AgentSanitizer] M_N004_end"`.
After this step, continue to any of Steps `N006` if necessary.

### Step N005. Production Build
First run `echo "[AgentSanitizer] M_N005_begin"`.

- Users run `npm run build && npm run start`, NOT `npm run dev`
- Docker must use standalone output, not dev mode

On completion of this node, run `echo "[AgentSanitizer] M_N005_end"`.
After this step, continue to any of Steps `N006` if necessary.

## Quick Check Before PR:

### Step N006. Quick Check Before PR
First run `echo "[AgentSanitizer] M_N006_begin"`.

```
[ ] No sequential awaits for independent data
[ ] Icons imported directly
[ ] Heavy components use next/dynamic
[ ] Server Actions have auth inside
[ ] Suspense around slow fetches
```

On completion of this node, run `echo "[AgentSanitizer] M_N006_end"`.
After this step, the skill may stop if necessary.
