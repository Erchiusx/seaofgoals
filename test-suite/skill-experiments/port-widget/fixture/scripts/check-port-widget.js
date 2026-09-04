import fs from 'node:fs';

const requiredFiles = [
  'packages/instantsearch.js/src/connectors/color-menu/connectColorMenu.ts',
  'packages/instantsearch.js/src/widgets/color-menu/color-menu.tsx',
  'packages/react-instantsearch-core/src/connectors/useColorMenu.ts',
  'packages/react-instantsearch/src/ui/ColorMenu.tsx',
  'packages/react-instantsearch/src/widgets/ColorMenu.tsx',
  'packages/vue-instantsearch/src/components/ColorMenu.vue',
  'tests/common/widgets/color-menu/default.ts',
];

for (const file of requiredFiles) {
  if (!fs.existsSync(file)) {
    throw new Error(`missing ${file}`);
  }
}

const connector = read('packages/instantsearch.js/src/connectors/color-menu/connectColorMenu.ts');
const jsWidget = read('packages/instantsearch.js/src/widgets/color-menu/color-menu.tsx');
const jsIndex = read('packages/instantsearch.js/src/widgets/index.ts');
const jsUmd = read('packages/instantsearch.js/src/widgets/index.umd.ts');
const hook = read('packages/react-instantsearch-core/src/connectors/useColorMenu.ts');
const coreIndex = read('packages/react-instantsearch-core/src/index.ts');
const reactUi = read('packages/react-instantsearch/src/ui/ColorMenu.tsx');
const reactWidget = read('packages/react-instantsearch/src/widgets/ColorMenu.tsx');
const reactIndex = read('packages/react-instantsearch/src/widgets/index.ts');
const reactUmd = read('packages/react-instantsearch/src/widgets/index.umd.ts');
const allWidgets = read('packages/react-instantsearch/src/widgets/__tests__/__utils__/all-widgets.tsx');
const vueWidget = read('packages/vue-instantsearch/src/components/ColorMenu.vue');
const vueWidgets = read('packages/vue-instantsearch/src/widgets.js');
const commonTest = read('tests/common/widgets/color-menu/default.ts');
const jsCommon = read('packages/instantsearch.js/src/__tests__/common-widgets.test.js');
const reactCommon = read('packages/react-instantsearch/src/__tests__/common-widgets.test.tsx');
const vueCommon = read('packages/vue-instantsearch/src/__tests__/common-widgets.test.js');

assertIncludes(connector, 'connectColorMenu', 'fixture connector should remain available');
assertIncludes(jsWidget, 'connectColorMenu', 'JS widget should use the existing connector');
assertIncludes(jsWidget, '$$widgetType', 'JS widget should set widget type');
assertIncludes(jsWidget, 'ais.colorMenu', 'JS widget type should be ais.colorMenu');
assertIncludes(jsIndex, 'colorMenu', 'JS index should export colorMenu');
assertIncludes(jsUmd, 'colorMenu', 'JS UMD index should export colorMenu');
assertIncludes(hook, 'connectColorMenu', 'React hook should use connectColorMenu');
assertIncludes(hook, 'useColorMenu', 'React hook should export useColorMenu');
assertIncludes(coreIndex, 'useColorMenu', 'React core index should export useColorMenu');
assertIncludes(reactUi, 'ColorMenu', 'React UI should export ColorMenu');
assertIncludes(reactWidget, 'useColorMenu', 'React widget should use useColorMenu');
assertIncludes(reactWidget, '$$widgetType', 'React widget should set widget type');
assertIncludes(reactWidget, 'ais.colorMenu', 'React widget type should be ais.colorMenu');
assertIncludes(reactIndex, 'ColorMenu', 'React widget index should export ColorMenu');
assertIncludes(reactUmd, 'ColorMenu', 'React UMD index should export ColorMenu');
assertIncludes(allWidgets, 'ColorMenu', 'all-widgets test utility should include ColorMenu');
assertIncludes(vueWidget, 'createWidgetMixin', 'Vue wrapper should use established widget mixin');
assertIncludes(vueWidget, 'connectColorMenu', 'Vue wrapper should use connectColorMenu');
assertIncludes(vueWidget, 'ais.colorMenu', 'Vue widget type should be ais.colorMenu');
assertIncludes(vueWidgets, 'AisColorMenu', 'Vue widgets export should include AisColorMenu');
assertIncludes(commonTest, 'colorMenu', 'common widget test should cover colorMenu');
assertIncludes(jsCommon, 'color-menu', 'JS common widget suite should register color-menu');
assertIncludes(reactCommon, 'color-menu', 'React common widget suite should register color-menu');
assertIncludes(vueCommon, 'color-menu', 'Vue common widget suite should register color-menu');
assertNotIncludes(vueCommon, 'color-menu is not supported', 'Vue placeholder should be replaced');

console.log('port-widget fixture checks passed');

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

