// Small, safe Markdown renderer for model output. Everything is escaped first;
// only a fixed set of tags is produced, and links are limited to http(s)/mailto.

import { esc } from "../format";

function inline(text: string): string {
  const codes: string[] = [];
  let s = esc(text).replace(/`([^`\n]+)`/g, (_, c: string) => {
    codes.push(`<code>${c}</code>`);
    return `\u0000${codes.length - 1}\u0000`;
  });
  s = s
    .replace(/\[([^\]\n]+)\]\(((?:https?:\/\/|mailto:)[^\s)]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>')
    .replace(/(^|[\s(])(https?:\/\/[^\s<)]+[^\s<).,;:!?])/g, '$1<a href="$2" target="_blank" rel="noopener noreferrer">$2</a>')
    .replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>")
    .replace(/__([^_\n]+)__/g, "<strong>$1</strong>")
    .replace(/(^|[^*\w])\*([^*\n]+)\*(?!\w)/g, "$1<em>$2</em>")
    .replace(/(^|[^_\w])_([^_\n]+)_(?!\w)/g, "$1<em>$2</em>")
    .replace(/~~([^~\n]+)~~/g, "<del>$1</del>");
  return s.replace(/\u0000(\d+)\u0000/g, (_, i: string) => codes[Number(i)] ?? "");
}

function splitRow(line: string): string[] {
  return line.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((c) => c.trim());
}

function blocks(text: string): string {
  const lines = text.split("\n");
  const out: string[] = [];
  let para: string[] = [];
  const flush = (): void => {
    if (para.length) out.push(`<p>${para.map(inline).join("<br>")}</p>`);
    para = [];
  };

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    const t = line.trim();
    if (!t) { flush(); continue; }

    const h = /^(#{1,6})\s+(.*)$/.exec(t);
    if (h) { flush(); const n = Math.min(h[1]!.length + 2, 6); out.push(`<h${n}>${inline(h[2]!)}</h${n}>`); continue; }

    if (/^([-*_])\1{2,}$/.test(t.replace(/\s/g, ""))) { flush(); out.push("<hr>"); continue; }

    // Table: header row + separator row.
    const next = lines[i + 1]?.trim() ?? "";
    if (t.includes("|") && /^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$/.test(next)) {
      flush();
      const head = splitRow(t);
      const align = splitRow(next).map((c) => (c.endsWith(":") ? (c.startsWith(":") ? "center" : "right") : ""));
      const rows: string[][] = [];
      i += 2;
      while (i < lines.length && lines[i]!.includes("|") && lines[i]!.trim()) rows.push(splitRow(lines[i++]!));
      i--;
      const cell = (tag: string, c: string, k: number): string =>
        `<${tag}${align[k] ? ` style="text-align:${align[k]}"` : ""}>${inline(c)}</${tag}>`;
      out.push(`<div class="md-table"><table><thead><tr>${head.map((c, k) => cell("th", c, k)).join("")}</tr></thead><tbody>${rows
        .map((r) => `<tr>${r.map((c, k) => cell("td", c, k)).join("")}</tr>`)
        .join("")}</tbody></table></div>`);
      continue;
    }

    if (t.startsWith(">")) {
      flush();
      const quote: string[] = [];
      while (i < lines.length && lines[i]!.trim().startsWith(">")) quote.push(lines[i++]!.trim().replace(/^>\s?/, ""));
      i--;
      out.push(`<blockquote>${blocks(quote.join("\n"))}</blockquote>`);
      continue;
    }

    const li = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/.exec(line);
    if (li) {
      flush();
      const ordered = /\d/.test(li[2]!);
      const items: string[] = [];
      while (i < lines.length) {
        const m = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/.exec(lines[i]!);
        if (m && /\d/.test(m[2]!) === ordered && m[1]!.length <= li[1]!.length + 1) {
          items.push(inline(m[3]!));
        } else if (m || (lines[i]!.startsWith("  ") && lines[i]!.trim() && items.length)) {
          // Nested list / continuation: append to the current item.
          items[items.length - 1] += `<br>${m ? `${m[2]!.match(/\d/) ? m[2] : "•"} ${inline(m[3]!)}` : inline(lines[i]!.trim())}`;
        } else break;
        i++;
      }
      i--;
      const start = ordered ? Number.parseInt(li[2]!, 10) : 1;
      out.push(ordered
        ? `<ol${start !== 1 ? ` start="${start}"` : ""}>${items.map((x) => `<li>${x}</li>`).join("")}</ol>`
        : `<ul>${items.map((x) => `<li>${x}</li>`).join("")}</ul>`);
      continue;
    }

    para.push(t);
  }
  flush();
  return out.join("");
}

/** Renders Markdown. An unterminated ``` fence (mid-stream) is shown as code up to the end. */
export function renderMarkdown(src: string): string {
  const parts: string[] = [];
  const fence = /^([ \t]*)(```|~~~)[ \t]*([\w+#.-]*)[^\n]*\n([\s\S]*?)(?:^\1?\2[ \t]*$|(?![\s\S]))/gm;
  let last = 0;
  let m: RegExpExecArray | null;
  while ((m = fence.exec(src)) !== null) {
    if (m.index > last) parts.push(blocks(src.slice(last, m.index)));
    const lang = m[3] ?? "";
    const code = (m[4] ?? "").replace(/\n$/, "");
    parts.push(`<div class="md-code"><div class="md-code-head"><span>${esc(lang || "código")}</span>
      <button type="button" class="md-copy" data-copy-code>Copiar</button></div><pre><code>${esc(code)}</code></pre></div>`);
    last = fence.lastIndex;
    if (m[0].length === 0) fence.lastIndex++;
  }
  if (last < src.length) parts.push(blocks(src.slice(last)));
  return parts.join("");
}
