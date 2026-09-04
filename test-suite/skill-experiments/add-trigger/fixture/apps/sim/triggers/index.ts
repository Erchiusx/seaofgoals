export function buildTriggerSubBlocks(config: Record<string, unknown>) {
  return [
    { id: 'webhookUrl', type: 'webhook-url', mode: 'trigger' },
    ...(config.includeDropdown ? [{ id: 'selectedTriggerId', type: 'dropdown', mode: 'trigger' }] : []),
    ...((config.extraFields as unknown[]) || []),
    { id: 'triggerSave', type: 'trigger-save', mode: 'trigger' },
  ];
}

export function getTrigger(id: string) {
  return TRIGGER_REGISTRY[id];
}

import { TRIGGER_REGISTRY } from './registry';

