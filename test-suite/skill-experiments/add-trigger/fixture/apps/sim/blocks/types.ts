export interface BlockConfig {
  type: string;
  name: string;
  triggers?: {
    enabled: boolean;
    available: string[];
  };
  subBlocks: unknown[];
}

