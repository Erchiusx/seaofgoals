import { useSearchBox } from 'react-instantsearch-core';
import { SearchBox as SearchBoxUi } from '../ui/SearchBox';

export function SearchBox() {
  const props = useSearchBox();
  return <SearchBoxUi {...props} />;
}

SearchBox.$$widgetType = 'ais.searchBox';

