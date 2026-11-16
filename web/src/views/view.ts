export interface View {
  title: string;
  subtitle: string;
  /** Auto-refresh period; 0 disables polling. */
  refreshMs: number;
  render(root: HTMLElement): Promise<void>;
  headerControls?: () => string;
  /** Click inside the header controls. `rerender(true)` re-renders immediately. */
  onHeaderClick?: (target: HTMLElement, rerender: (now: boolean) => void) => void;
}
