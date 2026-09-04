import fs from 'node:fs';

const serviceDir = 'apps/sim/triggers/acmecrm';
const requiredFiles = [
  `${serviceDir}/utils.ts`,
  `${serviceDir}/ticket_created.ts`,
  `${serviceDir}/ticket_updated.ts`,
  `${serviceDir}/webhook.ts`,
  `${serviceDir}/index.ts`,
  'apps/sim/triggers/registry.ts',
  'apps/sim/blocks/blocks/acmecrm.ts',
  'apps/sim/triggers/webhook-input.ts',
];

for (const file of requiredFiles) {
  if (!fs.existsSync(file)) {
    throw new Error(`missing ${file}`);
  }
}

const utils = read(`${serviceDir}/utils.ts`);
const created = read(`${serviceDir}/ticket_created.ts`);
const updated = read(`${serviceDir}/ticket_updated.ts`);
const webhook = read(`${serviceDir}/webhook.ts`);
const index = read(`${serviceDir}/index.ts`);
const registry = read('apps/sim/triggers/registry.ts');
const block = read('apps/sim/blocks/blocks/acmecrm.ts');
const input = read('apps/sim/triggers/webhook-input.ts');
const route = read('apps/sim/app/api/webhooks/route.ts');
const cleanup = read('apps/sim/lib/webhooks/provider-subscriptions.ts');

for (const id of ['acmecrm_ticket_created', 'acmecrm_ticket_updated', 'acmecrm_webhook']) {
  assertIncludes(utils, id, `utils should include trigger option ${id}`);
  assertIncludes(registry, id, `registry should include ${id}`);
  assertIncludes(block, id, `block should include ${id}`);
}

assertIncludes(utils, 'acmecrmSetupInstructions', 'utils should define setup instructions');
assertIncludes(utils, 'buildAcmecrmExtraFields', 'utils should define extra fields');
assertIncludes(utils, 'buildAcmecrmOutputs', 'utils should define outputs');
assertIncludes(utils, 'ticketId', 'outputs should expose ticketId');
assertIncludes(utils, 'assigneeEmail', 'outputs should expose assigneeEmail');
assertNotIncludes(utils, 'apiKey', 'manual setup fixture should not add API key extra field');

assertIncludes(created, 'buildTriggerSubBlocks', 'primary trigger should use generic builder');
assertIncludes(created, 'includeDropdown: true', 'primary trigger should include dropdown');
assertIncludes(created, 'acmecrm_ticket_created', 'primary trigger should use created ID');
assertNotIncludes(updated, 'includeDropdown: true', 'secondary trigger must not include dropdown');
assertIncludes(updated, 'acmecrm_ticket_updated', 'secondary trigger should use updated ID');
assertNotIncludes(webhook, 'includeDropdown: true', 'generic webhook trigger must not include dropdown');
assertIncludes(webhook, 'acmecrm_webhook', 'generic trigger should use webhook ID');
assertIncludes(index, 'ticket_created', 'barrel should export created trigger');
assertIncludes(index, 'ticket_updated', 'barrel should export updated trigger');
assertIncludes(index, 'webhook', 'barrel should export generic trigger');

assertIncludes(registry, "from '@/triggers/acmecrm'", 'registry should import from service barrel');
assertIncludes(block, "triggers:", 'block should enable triggers');
assertIncludes(block, 'enabled: true', 'block triggers should be enabled');
assertIncludes(block, "getTrigger('acmecrm_ticket_created').subBlocks", 'block should spread created subBlocks');
assertIncludes(block, "getTrigger('acmecrm_ticket_updated').subBlocks", 'block should spread updated subBlocks');
assertIncludes(block, "getTrigger('acmecrm_webhook').subBlocks", 'block should spread webhook subBlocks');

assertIncludes(input, "provider === 'acmecrm'", 'webhook input should handle acmecrm provider');
assertIncludes(input, 'payload.data', 'webhook input should unwrap data payload');
assertIncludes(input, 'ticketId', 'webhook input should expose ticketId');
assertNotIncludes(route, 'createAcmecrmWebhookSubscription', 'manual setup fixture should not add automatic creation');
assertNotIncludes(cleanup, 'deleteAcmecrmWebhook', 'manual setup fixture should not add automatic cleanup');

console.log('add-trigger fixture checks passed');

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

