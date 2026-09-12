import fs from "node:fs/promises";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";

const mode = process.argv[2];
if (mode !== "build" && mode !== "test") {
  throw new Error("usage: heavy-compile.mjs <build|test>");
}

const root = process.cwd();
const packageMetadata = JSON.parse(await fs.readFile(path.join(root, "package.json"), "utf8"));
const moduleCount = mode === "build" ? 6000 : 5200;
const workRoot = path.join(root, ".workload", mode);
const sourceRoot = path.join(workRoot, "src");
const outputRoot = mode === "build" ? path.join(root, "dist") : path.join(root, ".test-output", "lib");

await fs.rm(workRoot, { recursive: true, force: true });
await fs.rm(outputRoot, { recursive: true, force: true });
await fs.mkdir(sourceRoot, { recursive: true });
await fs.mkdir(outputRoot, { recursive: true });

const writes = [];
for (let i = 0; i < moduleCount; i += 1) {
  const id = String(i).padStart(4, "0");
  const previous = i === 0 ? "" : "import { value0 } from \"./module0000.js\";\n";
  const expression = i === 0 ? "1" : `value0 + ${i}`;
  const source = `${previous}export const value${i}: number = ${expression};\nexport const label${i}: string = \"${mode}-${id}-${packageMetadata.version}\";\n`;
  writes.push(fs.writeFile(path.join(sourceRoot, `module${id}.ts`), source));
}
await Promise.all(writes);

const lastId = String(moduleCount - 1).padStart(4, "0");
await fs.writeFile(
  path.join(sourceRoot, "index.ts"),
  `export { value${moduleCount - 1}, label${moduleCount - 1} } from \"./module${lastId}.js\";\n`,
);
const tsconfig = {
  compilerOptions: {
    target: "ES2022",
    module: "NodeNext",
    moduleResolution: "NodeNext",
    outDir: outputRoot,
    rootDir: sourceRoot,
    declaration: true,
    strict: true,
    skipLibCheck: true,
  },
  include: [path.join(sourceRoot, "**/*.ts")],
};
const configPath = path.join(workRoot, "tsconfig.json");
await fs.writeFile(configPath, `${JSON.stringify(tsconfig, null, 2)}\n`);

const startedAt = Date.now();
const result = spawnSync("tsc", ["--project", configPath, "--pretty", "false"], {
  cwd: root,
  encoding: "utf8",
  stdio: "pipe",
});
if (result.status !== 0) {
  process.stderr.write(result.stdout ?? "");
  process.stderr.write(result.stderr ?? "");
  process.exit(result.status ?? 1);
}

const outputs = (await fs.readdir(outputRoot)).filter((name) => name.endsWith(".js")).sort();
const digest = createHash("sha256");
for (const name of outputs) {
  digest.update(await fs.readFile(path.join(outputRoot, name)));
}
const report = {
  mode,
  version: packageMetadata.version,
  moduleCount,
  outputFiles: outputs.length,
  compileMilliseconds: Date.now() - startedAt,
  sha256: digest.digest("hex"),
};

if (mode === "build") {
  await fs.writeFile(path.join(root, "dist", "build-manifest.json"), `${JSON.stringify(report, null, 2)}\n`);
} else {
  await fs.mkdir(path.join(root, ".test-output"), { recursive: true });
  await fs.writeFile(path.join(root, ".test-output", "test-report.json"), `${JSON.stringify(report, null, 2)}\n`);
}
console.log(`${mode}: compiled ${moduleCount} TypeScript modules in ${report.compileMilliseconds}ms`);
