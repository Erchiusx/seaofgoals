import { createPlugin, createRoutableExtension } from '@backstage/core-plugin-api';
import { reportsApiFactory } from './api';
import { rootRouteRef } from './routes';

export const reportsPlugin = createPlugin({
  id: 'reports',
  apis: [reportsApiFactory],
  routes: {
    root: rootRouteRef,
  },
});

export const ReportsPage = reportsPlugin.provide(
  createRoutableExtension({
    name: 'ReportsPage',
    component: () => import('./components/ReportsPage').then(m => m.ReportsPage),
    mountPoint: rootRouteRef,
  }),
);

