export type ColorMenuConnectorParams = {
  attribute: string;
};

export function connectColorMenu(renderFn: Function) {
  return (widgetParams: ColorMenuConnectorParams) => ({
    $$type: 'ais.colorMenu',
    init() {
      renderFn({ items: [], canRefine: false, refine() {} }, true);
    },
    render() {
      renderFn({ items: [], canRefine: false, refine() {} }, false);
    },
    dispose() {},
    getWidgetRenderState() {
      return { widgetParams, items: [], canRefine: false, refine() {} };
    },
  });
}

