export interface TriggerOutput {
  type?: string;
  description?: string;
  [key: string]: unknown;
}

export interface TriggerConfig {
  id: string;
  name: string;
  provider: string;
  description: string;
  version: string;
  icon: unknown;
  subBlocks: unknown[];
  outputs: Record<string, TriggerOutput>;
  webhook: {
    method: string;
    headers?: Record<string, string>;
  };
}

