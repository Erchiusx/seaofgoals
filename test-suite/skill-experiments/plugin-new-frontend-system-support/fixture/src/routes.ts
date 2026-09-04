import { createExternalRouteRef, createRouteRef } from '@backstage/core-plugin-api';

export const rootRouteRef = createRouteRef({
  id: 'reports',
});

export const catalogEntityRouteRef = createExternalRouteRef({
  id: 'catalog-entity',
  optional: true,
  params: ['namespace', 'kind', 'name'],
});

