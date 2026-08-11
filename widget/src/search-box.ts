export interface WidgetConfig {
  api: string;
  key: string;
}

export function mountSearchBox(shadow: ShadowRoot, cfg: WidgetConfig): void {
  const input = document.createElement('input');
  input.className = 'pb-input';
  input.type = 'search';
  input.placeholder = 'Search products…';
  shadow.appendChild(input);
}
