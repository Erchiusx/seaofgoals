import { Content, ContentHeader, PageWithHeader, SupportButton } from '@backstage/core-components';
import type { ReactNode } from 'react';

export interface ReportsPageProps {
  actions?: ReactNode;
}

export function ReportsPageContent(props: ReportsPageProps) {
  return <section>{props.actions}<div>Reports dashboard</div></section>;
}

export function ReportsPage(props: ReportsPageProps) {
  return (
    <PageWithHeader title="Reports" themeId="tool">
      <Content>
        <ContentHeader title="Reports">
          <SupportButton>Review reporting health.</SupportButton>
        </ContentHeader>
        <ReportsPageContent {...props} />
      </Content>
    </PageWithHeader>
  );
}

