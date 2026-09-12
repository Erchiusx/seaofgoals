import fs from "node:fs/promises";
import path from "node:path";

const root = process.cwd();
const expected = "16.2.0";
const requireArtifact = process.argv.includes("--require-artifact");
const read = (relative) => fs.readFile(path.join(root, relative), "utf8");
const json = async (relative) => JSON.parse(await read(relative));
const failures = [];

const packageMetadata = await json("package.json");
const manifest = await json("manifest.json");
const plugin = await json(".claude-plugin/plugin.json");
for (const [name, value] of [["package.json", packageMetadata.version], ["manifest.json", manifest.version], ["plugin.json", plugin.version]]) {
  if (value !== expected) failures.push(`${name} version is ${value}`);
}
if (manifest.minimum_qsv_version !== "2.0.0") failures.push("minimum_qsv_version changed");

for (const relative of ["README-MCP.md", "docs/guides/MACOS-QUICK_START.md", "docs/desktop/README-MCPB.md", "docs/guides/DESKTOP_EXTENSION.md"]) {
  const text = await read(relative);
  if (!text.includes(expected)) failures.push(`${relative} does not mention ${expected}`);
  if (text.includes("16.1.0") && relative !== "docs/guides/DESKTOP_EXTENSION.md") failures.push(`${relative} retains 16.1.0`);
}

const changelog = await read("CHANGELOG.md");
if (changelog.indexOf("## [16.2.0]") < 0 || changelog.indexOf("## [16.2.0]") > changelog.indexOf("## [16.1.0]")) failures.push("16.2.0 changelog entry is missing or misplaced");
if (!/stream/i.test(changelog) || !/preload/i.test(changelog)) failures.push("changelog omits relevant MCP commits");

const testReport = await json(".test-output/test-report.json").catch(() => null);
if (!testReport || testReport.version !== expected || testReport.moduleCount !== 5200) failures.push("test compilation report is missing or invalid");

if (requireArtifact) {
  const buildManifest = await json("dist/build-manifest.json").catch(() => null);
  if (!buildManifest || buildManifest.version !== expected || buildManifest.moduleCount !== 6000) failures.push("build manifest is missing or invalid");
  const artifact = path.join(root, "release", `qsv-mcp-server-${expected}.mcpb`);
  const stat = await fs.stat(artifact).catch(() => null);
  if (!stat || stat.size < 100000) failures.push("versioned MCPB artifact is missing or too small");
}

if (failures.length > 0) {
  console.error(failures.join("\n"));
  process.exit(1);
}
console.log(`release ${expected}: metadata, docs, changelog, tests${requireArtifact ? ", build, and package" : ""} verified`);
