import assert from 'node:assert/strict';
import { cpSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const fixture = fileURLToPath(new URL('./fixture/', import.meta.url));
const common = 'tests/common/widgets/color-menu/default.ts';
const vueCommon = 'packages/vue-instantsearch/src/__tests__/common-widgets.test.js';

// A minimal completed layout for the static checker, not a working component port.
const sources = {
  'packages/instantsearch.js/src/widgets/color-menu/color-menu.tsx':
    "import { connectColorMenu } from '../../connectors/color-menu/connectColorMenu';\nexport const colorMenu = { connector: connectColorMenu, $$widgetType: 'ais.colorMenu' };\n",
  'packages/instantsearch.js/src/widgets/index.ts':
    "export { colorMenu } from './color-menu/color-menu';\n",
  'packages/instantsearch.js/src/widgets/index.umd.ts':
    "export { colorMenu } from './color-menu/color-menu';\n",
  'packages/react-instantsearch-core/src/connectors/useColorMenu.ts':
    "import { connectColorMenu } from 'instantsearch.js/es/connectors';\nexport function useColorMenu(props) { return connectColorMenu(() => {})(props).getWidgetRenderState(); }\n",
  'packages/react-instantsearch-core/src/index.ts':
    "export { useColorMenu } from './connectors/useColorMenu';\n",
  'packages/react-instantsearch/src/ui/ColorMenu.tsx':
    'export function ColorMenu() { return null; }\n',
  'packages/react-instantsearch/src/widgets/ColorMenu.tsx':
    "import { useColorMenu } from 'react-instantsearch-core';\nexport function ColorMenu(props) { useColorMenu(props); return null; }\nColorMenu.$$widgetType = 'ais.colorMenu';\n",
  'packages/react-instantsearch/src/widgets/index.ts':
    "export { ColorMenu } from './ColorMenu';\n",
  'packages/react-instantsearch/src/widgets/index.umd.ts':
    "export { ColorMenu } from './ColorMenu';\n",
  'packages/react-instantsearch/src/widgets/__tests__/__utils__/all-widgets.tsx':
    "import { ColorMenu } from '../../ColorMenu';\nexport const allWidgets = { ColorMenu: <ColorMenu attribute=\"color\" /> };\n",
  'packages/vue-instantsearch/src/components/ColorMenu.vue':
    "<script>\nimport { connectColorMenu } from 'instantsearch.js/es/connectors';\nimport { createWidgetMixin } from '../mixins/widget';\nexport default { mixins: [createWidgetMixin({ connector: connectColorMenu, $$widgetType: 'ais.colorMenu' })] };\n</script>\n",
  'packages/vue-instantsearch/src/widgets.js':
    "export { default as AisColorMenu } from './components/ColorMenu.vue';\n",
  'packages/instantsearch.js/src/__tests__/common-widgets.test.js':
    "export const commonWidgetSuites = ['search-box', 'color-menu'];\n",
  'packages/react-instantsearch/src/__tests__/common-widgets.test.tsx':
    "export const commonWidgetSuites = ['search-box', 'color-menu'];\n",
  [vueCommon]:
    "export const commonWidgetSuites = { 'color-menu': () => ({ component: 'AisColorMenu' }) };\n",
  [common]: "export const tests = ['color-menu renders'];\n",
};

function prepare(t) {
  const root = mkdtempSync(join(tmpdir(), 'sog-port-widget-checker-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  cpSync(fixture, root, { recursive: true });
  for (const [path, content] of Object.entries(sources)) {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), content);
  }
  return root;
}

function check(root) {
  const result = spawnSync(process.execPath, ['scripts/check-port-widget.js'], {
    cwd: root,
    encoding: 'utf8',
  });
  assert.ifError(result.error);
  return result;
}

test('neighboring kebab-case test format passes without a widget constant', (t) => {
  const result = check(prepare(t));
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /static smoke checks passed/);
  assert.match(result.stdout, /behavior and types not verified/);
});

test('camelCase test labels also pass', (t) => {
  const root = prepare(t);
  writeFileSync(join(root, common), "export const tests = ['colorMenu renders'];\n");
  const result = check(root);
  assert.equal(result.status, 0, result.stderr);
});

test('missing shared fixture still fails', (t) => {
  const root = prepare(t);
  rmSync(join(root, common));
  const result = check(root);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /missing tests\/common\/widgets\/color-menu\/default.ts/);
});

test('empty shared fixture still fails', (t) => {
  const root = prepare(t);
  writeFileSync(join(root, common), ' \n');
  const result = check(root);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /common widget test fixture must not be empty/);
});

test('missing suite registration still fails', (t) => {
  const root = prepare(t);
  writeFileSync(join(root, vueCommon), 'export const commonWidgetSuites = {};\n');
  const result = check(root);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Vue common widget suite should register color-menu/);
});

test('unsupported Vue placeholder still fails', (t) => {
  const root = prepare(t);
  writeFileSync(join(root, vueCommon), "throw new Error('color-menu is not supported');\n");
  const result = check(root);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Vue placeholder should be replaced/);
});
