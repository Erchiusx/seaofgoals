import fs from 'node:fs';

const requiredFiles = [
  'src/alpha.tsx',
  'src/apis.ts',
  'src/components/ReportsPage.tsx',
  'src/routes.ts',
  'src/index.ts',
  'package.json',
];

for (const file of requiredFiles) {
  if (!fs.existsSync(file)) {
    throw new Error(`missing ${file}`);
  }
}

const alpha = read('src/alpha.tsx');
const apis = read('src/apis.ts');
const page = read('src/components/ReportsPage.tsx');
const routes = read('src/routes.ts');
const index = read('src/index.ts');
const plugin = read('src/plugin.ts');
const pkg = JSON.parse(read('package.json'));

assertIncludes(plugin, 'createPlugin', 'old plugin entry should remain intact');
assertIncludes(plugin, 'createRoutableExtension', 'old routable extension should remain intact');
assertIncludes(page, 'NfsReportsPage', 'NFS page variant should be exported');
assertIncludes(page, 'ReportsPageContent', 'page should share content between old and new variants');

const nfsBody = bodyOf(page, 'NfsReportsPage');
assertNotIncludes(nfsBody, 'PageWithHeader', 'NFS page must not render PageWithHeader');
assertNotIncludes(nfsBody, '<Page', 'NFS page must not render old Page shell');
assertNotIncludes(nfsBody, 'ContentHeader', 'NFS page must not render old ContentHeader');

assertIncludes(routes, "defaultTarget: 'catalog.catalogEntity'", 'external route ref should have default target');
assertIncludes(apis, 'ApiBlueprint.make', 'API factory should be converted to ApiBlueprint');
assertIncludes(apis, 'reportsApiRef', 'API blueprint should provide reportsApiRef');
assertIncludes(apis, 'pluginId', 'API ownership should be explicit or preserved in ref setup');
assertIncludes(alpha, 'createFrontendPlugin', 'alpha should create frontend plugin');
assertIncludes(alpha, 'PageBlueprint.make', 'alpha should define a PageBlueprint');
assertIncludes(alpha, 'rootRouteRef', 'alpha should reuse rootRouteRef');
assertNotIncludes(alpha, 'convertLegacyRouteRef', 'alpha should not convert legacy route refs');
assertNotIncludes(alpha, 'compatWrapper', 'alpha should not use compatWrapper');
assertIncludes(alpha, 'reportsApi', 'alpha should include API blueprint extension');
assertIncludes(alpha, 'NfsReportsPage', 'alpha loader should render the NFS page variant');
assertIncludes(alpha, 'export { NfsReportsPage as ReportsPage }', 'alpha should re-export override component as ReportsPage');
assertNotIncludes(alpha, 'reportsApiRef', 'alpha should not re-export API refs');
assertNotIncludes(alpha, 'rootRouteRef as', 'alpha should not re-export route refs');
assertIncludes(index, 'reportsApiRef', 'main entry should export API ref');
assertIncludes(index, 'rootRouteRef', 'main entry should export route ref');
assertIncludes(index, 'catalogEntityRouteRef', 'main entry should export external route ref');

assertEqual(pkg.exports['./alpha'], './src/alpha.tsx', 'package exports should include ./alpha');
assertEqual(pkg.typesVersions['*'].alpha[0], 'src/alpha.tsx', 'typesVersions should include alpha');
assertHasDependency(pkg, '@backstage/frontend-plugin-api');
if (alpha.includes('@backstage/ui') || page.includes('@backstage/ui')) {
  assertHasDependency(pkg, '@backstage/ui');
}

console.log('plugin-new-frontend-system-support fixture checks passed');

function read(file) {
  return fs.readFileSync(file, 'utf8');
}

function assertIncludes(text, needle, message) {
  if (!text.includes(needle)) {
    throw new Error(message);
  }
}

function assertNotIncludes(text, needle, message) {
  if (text.includes(needle)) {
    throw new Error(message);
  }
}

function assertEqual(actual, expected, message) {
  if (actual !== expected) {
    throw new Error(`${message}: expected ${expected}, got ${actual}`);
  }
}

function assertHasDependency(pkg, name) {
  if (!pkg.dependencies || !pkg.dependencies[name]) {
    throw new Error(`missing dependency ${name}`);
  }
}

function bodyOf(text, functionName) {
  const start = text.indexOf(functionName);
  if (start === -1) return '';
  return text.slice(start, text.indexOf('\n}\n', start) + 2);
}

