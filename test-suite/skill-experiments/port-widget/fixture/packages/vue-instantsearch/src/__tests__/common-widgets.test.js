export const commonWidgetSuites = {
  'search-box': () => ({ component: 'AisSearchBox' }),
  'color-menu': () => {
    throw new Error('color-menu is not supported in Vue InstantSearch');
  },
};

