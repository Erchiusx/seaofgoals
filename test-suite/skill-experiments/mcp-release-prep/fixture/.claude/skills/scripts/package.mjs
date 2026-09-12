import fs from "node:fs/promises";
import path from "node:path";

const root = process.cwd();
const packageMetadata = JSON.parse(await fs.readFile(path.join(root, "package.json"), "utf8"));
const manifest = JSON.parse(await fs.readFile(path.join(root, "dist", "build-manifest.json"), "utf8"));
if (manifest.version !== packageMetadata.version) {
  throw new Error("build output version does not match package.json");
}

const names = (await fs.readdir(path.join(root, "dist"))).filter((name) => name.endsWith(".js")).sort();
const chunks = [Buffer.from(`${JSON.stringify({ name: packageMetadata.name, version: packageMetadata.version })}\n`)];
for (const name of names) {
  chunks.push(Buffer.from(`--- ${name} ---\n`));
  chunks.push(await fs.readFile(path.join(root, "dist", name)));
}
await fs.mkdir(path.join(root, "release"), { recursive: true });
const artifact = path.join(root, "release", `qsv-mcp-server-${packageMetadata.version}.mcpb`);
await fs.writeFile(artifact, Buffer.concat(chunks));
console.log(artifact);
