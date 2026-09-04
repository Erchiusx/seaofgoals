#!/usr/bin/env python3
import pathlib
import sys

widget = sys.argv[1] if len(sys.argv) > 1 else ""
root = pathlib.Path(".")

if widget != "color-menu":
    print(f"unexpected widget {widget}", file=sys.stderr)
    sys.exit(2)

checks = {
    "connector": root / "packages/instantsearch.js/src/connectors/color-menu/connectColorMenu.ts",
    "js_widget": root / "packages/instantsearch.js/src/widgets/color-menu/color-menu.tsx",
    "react_hook": root / "packages/react-instantsearch-core/src/connectors/useColorMenu.ts",
    "react_widget": root / "packages/react-instantsearch/src/widgets/ColorMenu.tsx",
    "vue_widget": root / "packages/vue-instantsearch/src/components/ColorMenu.vue",
}

for name, path in checks.items():
    print(f"{name}: {'yes' if path.exists() else 'no'}")

if checks["connector"].exists() and not checks["vue_widget"].exists():
    print("scope: existing connector; wrappers and shared wiring are missing")

