import {ESLintUtils} from '@typescript-eslint/utils';

export const existingRule = ESLintUtils.RuleCreator.withoutDocs({
  meta: {
    type: 'problem',
    docs: {
      description: 'Existing fixture rule',
    },
    schema: [],
    messages: {
      forbidden: 'Existing fixture rule violation',
    },
  },
  create() {
    return {};
  },
});

