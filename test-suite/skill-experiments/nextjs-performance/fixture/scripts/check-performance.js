const fs = require("fs");

const checks = [
  {
    file: "app/dashboard/page.tsx",
    label: "uses Promise.all",
    test: (text) => text.includes("Promise.all"),
  },
  {
    file: "app/dashboard/page.tsx",
    label: "uses Suspense",
    test: (text) => text.includes("Suspense"),
  },
  {
    file: "components/Toolbar.tsx",
    label: "uses direct lucide imports",
    test: (text) => !text.includes('from "lucide-react"') && text.includes("lucide-react/dist/esm/icons"),
  },
  {
    file: "components/ChartPanel.tsx",
    label: "uses next/dynamic",
    test: (text) => text.includes("next/dynamic"),
  },
  {
    file: "app/actions/updateProject.ts",
    label: "checks auth and ownership inside action",
    test: (text) => text.includes("requireUser") && text.includes("assertProjectOwner"),
  },
  {
    file: "next.config.js",
    label: "uses standalone output",
    test: (text) => text.includes('output: "standalone"') || text.includes("output: 'standalone'"),
  },
];

let failed = 0;
for (const check of checks) {
  const text = fs.readFileSync(check.file, "utf8");
  if (check.test(text)) {
    console.log(`ok - ${check.label}`);
  } else {
    console.log(`not ok - ${check.label} (${check.file})`);
    failed += 1;
  }
}

process.exitCode = failed === 0 ? 0 : 1;
