import fs from 'node:fs';

const requiredFiles = [
  'static/eslint/eslintPluginScraps/src/rules/no-raw-color.ts',
  'static/eslint/eslintPluginScraps/src/rules/no-raw-color.spec.ts',
  'static/eslint/eslintPluginScraps/src/rules/index.ts',
  'eslint.config.ts',
];

for (const file of requiredFiles) {
  if (!fs.existsSync(file)) {
    throw new Error(`missing ${file}`);
  }
}

const rule = fs.readFileSync('static/eslint/eslintPluginScraps/src/rules/no-raw-color.ts', 'utf8');
const spec = fs.readFileSync('static/eslint/eslintPluginScraps/src/rules/no-raw-color.spec.ts', 'utf8');
const index = fs.readFileSync('static/eslint/eslintPluginScraps/src/rules/index.ts', 'utf8');
const config = fs.readFileSync('eslint.config.ts', 'utf8');

assertIncludes(rule, 'ESLintUtils.RuleCreator.withoutDocs', 'rule should use RuleCreator.withoutDocs');
assertIncludes(rule, 'noRawColor', 'rule should export noRawColor');
assertIncludes(rule, '#ff0000', 'rule should detect the raw red literal');
assertIncludes(rule, 'theme.colors.danger', 'rule should contain the autofix replacement');
assertIncludes(rule, 'fixable', 'rule should declare autofix metadata');

assertIncludes(spec, 'RuleTester', 'spec should use RuleTester');
assertIncludes(spec, 'noRawColor', 'spec should import the rule');
assertIncludes(spec, '#ff0000', 'spec should include an invalid raw-color case');
assertIncludes(spec, 'theme.colors.danger', 'spec should include expected autofix output');
assertIncludes(spec, 'valid', 'spec should include valid cases');
assertIncludes(spec, 'invalid', 'spec should include invalid cases');

assertIncludes(index, "from './no-raw-color'", 'index should import no-raw-color');
assertIncludes(index, "'no-raw-color'", 'index should register no-raw-color');
assertIncludes(config, '@sentry/scraps/no-raw-color', 'eslint config should enable no-raw-color');

console.log('lint-new fixture checks passed');

function assertIncludes(text, needle, message) {
  if (!text.includes(needle)) {
    throw new Error(message);
  }
}
