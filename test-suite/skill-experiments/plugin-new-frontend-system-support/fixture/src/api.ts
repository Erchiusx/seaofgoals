import { createApiRef, discoveryApiRef, fetchApiRef } from '@backstage/core-plugin-api';

export interface ReportsApi {
  listReports(): Promise<string[]>;
}

export const reportsApiRef = createApiRef<ReportsApi>({
  id: 'plugin.reports.service',
});

export class ReportsClient implements ReportsApi {
  constructor(private readonly deps: { discoveryApi: typeof discoveryApiRef; fetchApi: typeof fetchApiRef }) {}

  async listReports() {
    return ['weekly'];
  }
}

export const reportsApiFactory = {
  api: reportsApiRef,
  deps: { discoveryApi: discoveryApiRef, fetchApi: fetchApiRef },
  factory: ({ discoveryApi, fetchApi }: any) => new ReportsClient({ discoveryApi, fetchApi }),
};

