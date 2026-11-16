const HTML_ESCAPES: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

/** Every value that originates from requests (client names, models, errors) goes through this. */
export function esc(value: unknown): string {
  return String(value ?? "").replace(/[&<>"']/g, (c) => HTML_ESCAPES[c] ?? c);
}

export const GiB = 1024 ** 3;

export function gb(bytes: number | null | undefined, digits = 1): string {
  if (bytes == null || !Number.isFinite(bytes)) return "—";
  return `${(bytes / GiB).toFixed(digits)} GB`;
}

export function int(n: number | null | undefined): string {
  if (n == null || !Number.isFinite(n)) return "—";
  return new Intl.NumberFormat("es-MX").format(Math.round(n));
}

export function compact(n: number | null | undefined): string {
  if (n == null || !Number.isFinite(n)) return "—";
  return new Intl.NumberFormat("es-MX", { notation: "compact", maximumFractionDigits: 1 }).format(n);
}

export function fixed(n: number | null | undefined, digits = 1, suffix = ""): string {
  if (n == null || !Number.isFinite(n)) return "—";
  return `${n.toFixed(digits)}${suffix}`;
}

export function ms(n: number | null | undefined): string {
  if (n == null || !Number.isFinite(n)) return "—";
  return n >= 1000 ? `${(n / 1000).toFixed(2)} s` : `${Math.round(n)} ms`;
}

export function pct(part: number, total: number): string {
  if (!total) return "—";
  return `${((part / total) * 100).toFixed(1)}%`;
}

export function timeLabel(unixSeconds: number, bucketSeconds: number, spanSeconds = 0): string {
  const d = new Date(unixSeconds * 1000);
  if (bucketSeconds >= 86_400) return d.toLocaleDateString("es-MX", { day: "2-digit", month: "short" });
  if (bucketSeconds >= 7200 || spanSeconds > 20 * 3600) {
    return `${d.toLocaleDateString("es-MX", { day: "2-digit", month: "short" })} ${d.toLocaleTimeString("es-MX", { hour: "2-digit", minute: "2-digit" })}`;
  }
  return d.toLocaleTimeString("es-MX", { hour: "2-digit", minute: "2-digit" });
}

export function relative(iso: string | undefined): string {
  if (!iso) return "—";
  const diff = (Date.now() - new Date(iso).getTime()) / 1000;
  if (diff < 0) {
    const s = -diff;
    return s < 60 ? `en ${Math.round(s)} s` : s < 3600 ? `en ${Math.round(s / 60)} min` : `en ${(s / 3600).toFixed(1)} h`;
  }
  if (diff < 60) return `hace ${Math.round(diff)} s`;
  if (diff < 3600) return `hace ${Math.round(diff / 60)} min`;
  if (diff < 86_400) return `hace ${(diff / 3600).toFixed(1)} h`;
  return new Date(iso).toLocaleString("es-MX");
}

export function duration(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  return h > 0 ? `${h} h ${m} min` : `${m} min`;
}
