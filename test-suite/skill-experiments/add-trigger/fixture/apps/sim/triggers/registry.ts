import type { TriggerConfig } from '@/triggers/types';

export type TriggerRegistry = Record<string, TriggerConfig>;

export const TRIGGER_REGISTRY: TriggerRegistry = {};

