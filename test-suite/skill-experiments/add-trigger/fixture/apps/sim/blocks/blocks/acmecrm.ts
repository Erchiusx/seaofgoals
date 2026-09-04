import { AcmecrmIcon } from '@/components/icons';
import type { BlockConfig } from '@/blocks/types';

export const AcmecrmBlock: BlockConfig = {
  type: 'acmecrm',
  name: 'Acme CRM',
  subBlocks: [
    { id: 'operation', type: 'dropdown', options: ['createTicket', 'updateTicket'] },
    { id: 'credential', type: 'oauth' },
  ],
  tools: {
    createTicket: {
      name: 'Create Ticket',
      icon: AcmecrmIcon,
    },
  },
};

