// ObsidianJuju reading view: renders Obsidian-flavoured Markdown from a payload prepared in Swift.
// The page is strictly a viewer — nothing here can modify a file. Interaction is reported to
// Swift through window.webkit.messageHandlers.juju.
(() => {
  'use strict';

  const post = (msg) => window.webkit?.messageHandlers?.juju?.postMessage(msg);
  const ICONS = window.JUJU_ICONS || {};
  const icon = (name) =>
    `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="svg-icon">${ICONS[name] || ''}</svg>`;
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const vaultURL = (p) => 'juju://vault/' + p.split('/').map(encodeURIComponent).join('/');
  const hasScheme = (s) => /^[a-z][a-z0-9+.\-]*:/i.test(s);
  const safeDecode = (s) => { try { return decodeURIComponent(s); } catch { return s; } };
  const extOf = (p) => { const m = /\.([^./]+)$/.exec(p); return m ? m[1].toLowerCase() : ''; };
  const KIND = {
    image: ['png', 'jpg', 'jpeg', 'gif', 'bmp', 'svg', 'webp', 'avif', 'heic', 'tif', 'tiff'],
    audio: ['mp3', 'wav', 'm4a', 'ogg', 'flac', '3gp'],
    video: ['mp4', 'webm', 'mov', 'ogv', 'mkv'],
    pdf: ['pdf'],
    base: ['base'],
  };
  const kindOf = (p) => {
    const e = extOf(p);
    if (e === 'md' || e === '') return 'markdown';
    for (const k in KIND) if (KIND[k].includes(e)) return k;
    return 'other';
  };
  const basename = (p) => p.split('/').pop().replace(/\.md$/i, '');

  let payload = { path: '', resolve: {}, embeds: {} };

  // ---------------------------------------------------------------- link resolution

  function resolveLink(target, source) {
    const t = target.trim();
    if (!t) return source;
    return payload.resolve[source + '\n' + t.toLowerCase()] || null;
  }

  function parseWikiInner(inner) {
    let body = inner, alias = null, subpath = null;
    const bar = body.indexOf('|');
    if (bar >= 0) {
      alias = body.slice(bar + 1).trim();
      body = body.slice(0, bar);
      if (body.endsWith('\\')) body = body.slice(0, -1);
    }
    const hash = body.indexOf('#');
    if (hash >= 0) {
      subpath = body.slice(hash + 1).trim();
      body = body.slice(0, hash);
    }
    return { target: body.trim(), subpath: subpath || null, alias: alias || null };
  }

  function linkDisplay(target, subpath) {
    let text = target;
    if (subpath) text += (target ? ' > ' : '') + subpath.replace(/#/g, ' > ');
    return text;
  }

  // ---------------------------------------------------------------- markdown-it setup

  const md = window.markdownit({
    html: true,
    linkify: true,
    breaks: true, // Obsidian's default ("Strict line breaks" off)
    highlight(str, lang) {
      const l = (lang || '').toLowerCase();
      if (l && window.hljs?.getLanguage(l)) {
        try { return window.hljs.highlight(str, { language: l, ignoreIllegals: true }).value; } catch { /* fall through */ }
      }
      return esc(str);
    },
  });
  if (window.markdownitFootnote) md.use(window.markdownitFootnote);
  if (window.markdownitMark) md.use(window.markdownitMark);

  // [[wikilinks]] and ![[embeds]]
  md.inline.ruler.before('link', 'wikilink', (state, silent) => {
    const src = state.src;
    let pos = state.pos;
    let embed = false;
    if (src.charCodeAt(pos) === 0x21 /* ! */) {
      if (!src.startsWith('[[', pos + 1)) return false;
      embed = true;
      pos += 1;
    } else if (!src.startsWith('[[', pos)) return false;
    const end = src.indexOf(']]', pos + 2);
    if (end < 0) return false;
    const inner = src.slice(pos + 2, end);
    if (!inner.trim() || inner.includes('\n') || inner.includes('[[')) return false;
    if (!silent) {
      const t = state.push('wikilink', '', 0);
      t.meta = { inner, embed };
    }
    state.pos = end + 2;
    return true;
  });

  md.renderer.rules.wikilink = (tokens, idx, _o, env) => {
    const { inner, embed } = tokens[idx].meta;
    const link = parseWikiInner(inner);
    const source = env.source || payload.path;
    const resolved = resolveLink(link.target, source);
    return embed ? renderEmbed(link, resolved, source) : renderInternalLink(link, resolved, inner);
  };

  function renderInternalLink(link, resolved, raw) {
    const text = link.alias || linkDisplay(link.target, link.subpath);
    return `<a class="internal-link${resolved ? '' : ' is-unresolved'}" data-href="${esc(raw)}" data-path="${esc(resolved || '')}" data-target="${esc(link.target)}" data-subpath="${esc(link.subpath || '')}">${esc(text)}</a>`;
  }

  function renderEmbed(link, resolved, source) {
    if (!resolved) {
      return `<span class="internal-embed is-unresolved" data-target="${esc(link.target)}">${esc(linkDisplay(link.target, link.subpath))}</span>`;
    }
    const kind = kindOf(resolved);
    const src = vaultURL(resolved);
    const size = /^(\d+)(?:x(\d+))?$/.exec(link.alias || '');
    const dims = size ? ` width="${size[1]}"${size[2] ? ` height="${size[2]}"` : ''}` : '';
    const alt = size ? basename(resolved) : link.alias || basename(resolved);
    switch (kind) {
      case 'image': return `<img class="internal-embed image-embed" src="${src}" alt="${esc(alt)}"${dims}>`;
      case 'audio': return `<audio class="internal-embed" controls src="${src}"></audio>`;
      case 'video': return `<video class="internal-embed" controls src="${src}"${dims}></video>`;
      // The page has an https origin (for YouTube), which blocks juju:// iframes, so PDFs open in a
      // native viewer tab instead of rendering inline.
      case 'pdf': return `<a class="internal-link pdf-embed-card" data-path="${esc(resolved)}" data-target="${esc(link.target)}" data-subpath="">${icon('file-text')}<span>${esc(resolved.split("/").pop())}</span><span class="pdf-embed-hint">Open PDF</span></a>`;
      case 'base':
      case 'markdown': {
        const key = resolved + '#' + (link.subpath || '');
        return `<span class="embed-placeholder" data-key="${esc(key)}" data-source="${esc(source)}"></span>`;
      }
      default:
        return `<a class="internal-link" data-path="${esc(resolved)}" data-target="${esc(link.target)}" data-subpath="">${esc(basename(resolved))}</a>`;
    }
  }

  // #tags
  const TAG_RE = /^#([\p{L}\p{N}_\-/\p{Emoji_Presentation}]+)/u;
  md.inline.ruler.before('link', 'obsidian_tag', (state, silent) => {
    if (state.src.charCodeAt(state.pos) !== 0x23 /* # */) return false;
    const prev = state.pos > 0 ? state.src[state.pos - 1] : ' ';
    if (!/[\s(\[{,;!?"'>]/.test(prev)) return false;
    const m = TAG_RE.exec(state.src.slice(state.pos));
    if (!m) return false;
    const name = m[1].replace(/\/+$/, '');
    if (!name || /^[\d/_-]+$/.test(name)) return false;
    if (!silent) {
      const t = state.push('obsidian_tag', '', 0);
      t.meta = { name };
    }
    state.pos += 1 + name.length;
    return true;
  });
  md.renderer.rules.obsidian_tag = (tokens, idx) => {
    const name = tokens[idx].meta.name;
    return `<a href="#${esc(name)}" class="tag" data-tag="${esc(name)}">#${esc(name)}</a>`;
  };

  // %% comments %% (inline and block) render as nothing.
  md.inline.ruler.before('link', 'obsidian_comment', (state, silent) => {
    if (!state.src.startsWith('%%', state.pos)) return false;
    const end = state.src.indexOf('%%', state.pos + 2);
    state.pos = end < 0 ? state.posMax : end + 2;
    return true;
  });
  md.block.ruler.before('paragraph', 'obsidian_comment', (state, startLine, endLine, silent) => {
    const start = state.bMarks[startLine] + state.tShift[startLine];
    const max = state.eMarks[startLine];
    if (!state.src.startsWith('%%', start)) return false;
    const rest = state.src.slice(start + 2, max);
    let line = startLine;
    if (rest.includes('%%')) {
      if (!rest.trimEnd().endsWith('%%')) return false;
    } else {
      for (line = startLine + 1; line < endLine; line++) {
        if (state.src.slice(state.bMarks[line], state.eMarks[line]).includes('%%')) break;
      }
    }
    if (silent) return true;
    state.line = Math.min(line + 1, endLine);
    return true;
  }, { alt: ['paragraph'] });

  // $inline$ and $$display$$ math via KaTeX.
  const renderMath = (tex, display) => {
    try {
      return window.katex.renderToString(tex, { displayMode: display, throwOnError: false, output: 'html' });
    } catch (e) {
      return `<code>${esc(tex)}</code>`;
    }
  };
  md.inline.ruler.after('escape', 'math_inline', (state, silent) => {
    const src = state.src;
    const pos = state.pos;
    if (src.charCodeAt(pos) !== 0x24 /* $ */) return false;
    if (src.charCodeAt(pos + 1) === 0x24) {
      const end = src.indexOf('$$', pos + 2);
      if (end < 0) return false;
      if (!silent) { const t = state.push('math', '', 0); t.meta = { tex: src.slice(pos + 2, end), display: true }; }
      state.pos = end + 2;
      return true;
    }
    const first = src[pos + 1];
    if (!first || /\s/.test(first)) return false;
    let end = pos + 1;
    for (;;) {
      end = src.indexOf('$', end);
      if (end < 0) return false;
      if (src[end - 1] !== '\\') break;
      end += 1;
    }
    if (/\s/.test(src[end - 1]) || /\d/.test(src[end + 1] || '')) return false;
    if (!silent) { const t = state.push('math', '', 0); t.meta = { tex: src.slice(pos + 1, end), display: false }; }
    state.pos = end + 1;
    return true;
  });
  md.renderer.rules.math = (tokens, idx) => renderMath(tokens[idx].meta.tex, tokens[idx].meta.display);

  md.block.ruler.before('fence', 'math_block', (state, startLine, endLine, silent) => {
    const start = state.bMarks[startLine] + state.tShift[startLine];
    const max = state.eMarks[startLine];
    const first = state.src.slice(start, max).trim();
    if (!first.startsWith('$$')) return false;
    let tex;
    let line = startLine;
    if (first.length > 2 && first.endsWith('$$') && first.length >= 4) {
      tex = first.slice(2, -2);
    } else {
      const parts = [first.slice(2)];
      for (line = startLine + 1; line < endLine; line++) {
        const s = state.src.slice(state.bMarks[line] + state.tShift[line], state.eMarks[line]);
        if (s.trimEnd().endsWith('$$')) { parts.push(s.trimEnd().slice(0, -2)); break; }
        parts.push(s);
      }
      if (line >= endLine) return false;
      tex = parts.join('\n');
    }
    if (silent) return true;
    const t = state.push('math_block', 'div', 0);
    t.meta = { tex };
    t.map = [startLine, line + 1];
    state.line = line + 1;
    return true;
  }, { alt: ['paragraph', 'reference', 'blockquote', 'list'] });
  md.renderer.rules.math_block = (tokens, idx) => `<div class="math-block">${renderMath(tokens[idx].meta.tex, true)}</div>`;

  // Code fences: mermaid diagrams and a copy button.
  const defaultFence = md.renderer.rules.fence;
  md.renderer.rules.fence = (tokens, idx, options, env, self) => {
    const token = tokens[idx];
    const lang = token.info.trim().split(/\s+/)[0].toLowerCase();
    if (lang === 'mermaid') return `<pre class="mermaid">${esc(token.content)}</pre>`;
    if (lang === 'base') {
      const key = (env.source || payload.path) + '\n' + token.content.trim();
      return `<div class="base-placeholder" data-key="${esc(key)}"></div>`;
    }
    const html = defaultFence(tokens, idx, options, env, self);
    return html.replace(/<\/pre>\s*$/, '<button class="copy-code-button">Copy</button></pre>');
  };

  // Callouts: > [!type]+/- Title
  const CALLOUT_ICON = {
    note: 'pencil', abstract: 'clipboard-list', summary: 'clipboard-list', tldr: 'clipboard-list',
    info: 'info', todo: 'circle-check', tip: 'flame', hint: 'flame', important: 'flame',
    success: 'check', check: 'check', done: 'check', question: 'circle-help', help: 'circle-help', faq: 'circle-help',
    warning: 'triangle-alert', caution: 'triangle-alert', attention: 'triangle-alert',
    failure: 'x', fail: 'x', missing: 'x', danger: 'zap', error: 'zap', bug: 'bug', example: 'list', quote: 'quote', cite: 'quote',
  };
  md.core.ruler.after('block', 'callouts', (state) => {
    const tokens = state.tokens;
    const stack = [];
    for (let i = 0; i < tokens.length; i++) {
      const t = tokens[i];
      if (t.type === 'blockquote_open') {
        let callout = null;
        const p = tokens[i + 1];
        const inl = tokens[i + 2];
        if (p?.type === 'paragraph_open' && inl?.type === 'inline' && inl.content.startsWith('[!')) {
          const lines = inl.content.split('\n');
          const m = /^\[!([^\]]+)\]([+-]?)\s*(.*)$/.exec(lines[0]);
          if (m) {
            lines.shift();
            inl.content = lines.join('\n');
            callout = { type: m[1].trim().toLowerCase(), fold: m[2], title: m[3] };
            if (!inl.content.trim()) { p.hidden = true; tokens[i + 3].hidden = true; }
          }
        }
        t.meta = { callout };
        stack.push(t);
      } else if (t.type === 'blockquote_close') {
        const open = stack.pop();
        t.meta = { callout: open?.meta?.callout || null };
      }
    }
  });
  md.renderer.rules.blockquote_open = (tokens, idx, _o, env) => {
    const c = tokens[idx].meta?.callout;
    if (!c) return '<blockquote>\n';
    // Fresh env: sharing it would make the footnote plugin emit footnotes inside the title.
    const title = c.title ? md.renderInline(c.title, { source: env.source }) : esc(c.type.charAt(0).toUpperCase() + c.type.slice(1));
    const foldable = c.fold === '+' || c.fold === '-';
    const cls = `callout${foldable ? ' is-collapsible' : ''}${c.fold === '-' ? ' is-collapsed' : ''}`;
    return `<div class="${cls}" data-callout="${esc(c.type)}"><div class="callout-title"><div class="callout-icon">${icon(CALLOUT_ICON[c.type] || 'pencil')}</div><div class="callout-title-inner">${title}</div>${foldable ? `<div class="callout-fold">${icon('chevron-down')}</div>` : ''}</div><div class="callout-content">\n`;
  };
  md.renderer.rules.blockquote_close = (tokens, idx) => (tokens[idx].meta?.callout ? '</div></div>\n' : '</blockquote>\n');

  // Task lists: - [ ] / - [x] (any character marks the task as done, as in Obsidian).
  md.core.ruler.after('inline', 'tasks', (state) => {
    const tk = state.tokens;
    for (let i = 2; i < tk.length; i++) {
      const inl = tk[i];
      if (inl.type !== 'inline' || tk[i - 1].type !== 'paragraph_open' || tk[i - 2].type !== 'list_item_open') continue;
      const first = inl.children?.[0];
      if (!first || first.type !== 'text') continue;
      const m = /^\[(.)\](?:[ \t]|$)/.exec(first.content);
      if (!m) continue;
      first.content = first.content.slice(m[0].length);
      const checked = m[1] !== ' ';
      const box = new state.Token('html_inline', '', 0);
      box.content = `<input type="checkbox" class="task-list-item-checkbox" disabled${checked ? ' checked' : ''}>`;
      inl.children.unshift(box);
      const li = tk[i - 2];
      li.attrJoin('class', 'task-list-item' + (checked ? ' is-checked' : ''));
      li.attrSet('data-task', m[1]);
    }
  });

  // Markdown links/images pointing into the vault.
  md.renderer.rules.link_open = (tokens, idx, options, env, self) => {
    const t = tokens[idx];
    const href = t.attrGet('href') || '';
    if (href.startsWith('#')) {
      // Footnote references and same-note anchors are left alone.
      return self.renderToken(tokens, idx, options);
    }
    if (hasScheme(href)) {
      if (/^obsidian:/i.test(href)) return self.renderToken(tokens, idx, options);
      t.attrJoin('class', 'external-link');
      return self.renderToken(tokens, idx, options);
    }
    const decoded = safeDecode(href);
    const hash = decoded.indexOf('#');
    const target = hash >= 0 ? decoded.slice(0, hash) : decoded;
    const subpath = hash >= 0 ? decoded.slice(hash + 1) : '';
    const source = env.source || payload.path;
    const resolved = resolveLink(target, source);
    t.attrs = [['class', 'internal-link' + (resolved ? '' : ' is-unresolved')], ['data-path', resolved || ''],
      ['data-target', target], ['data-subpath', subpath], ['data-href', decoded]];
    return self.renderToken(tokens, idx, options);
  };
  md.renderer.rules.image = (tokens, idx, options, env, self) => {
    const t = tokens[idx];
    const src = t.attrGet('src') || '';
    let alt = self.renderInlineAsText(t.children, options, env);
    const size = /\|(\d+)(?:x(\d+))?$/.exec(alt);
    if (size) alt = alt.slice(0, size.index);
    const dims = size ? ` width="${size[1]}"${size[2] ? ` height="${size[2]}"` : ''}` : '';
    // ObsidianJuju syntax for media outside the vault: ![](<juju:name.png>) (see ExternalAttachments.swift).
    const juju = /^juju:(?!\/\/)(.*)$/i.exec(src);
    if (juju) {
      const name = safeDecode(juju[1]).trim();
      const found = (payload.external || {})[name.toLowerCase()];
      if (!found) {
        return `<span class="internal-embed is-unresolved" title="Not found in the vault or the attachment folders">${esc(name)}</span>`;
      }
      switch (kindOf(name)) {
        case 'audio': return `<audio class="internal-embed" controls src="${esc(found)}"></audio>`;
        case 'video': return `<video class="internal-embed" controls src="${esc(found)}"${dims}></video>`;
        default: {
          // JujuPix encrypted photos (.jjpx) show a lock placeholder until unlocked; clicking it asks to unlock.
          const enc = /^juju:\/\/jjpx\//.test(found) ? ' jjpx' : '';
          return `<img class="internal-embed image-embed${enc}" src="${esc(found)}" alt="${esc(alt || name)}"${dims}>`;
        }
      }
    }
    let url = src;
    if (!hasScheme(src)) {
      const decoded = safeDecode(src);
      const resolved = resolveLink(decoded, env.source || payload.path);
      url = resolved ? vaultURL(resolved) : vaultURL(decoded.replace(/^\/+/, ''));
    }
    return `<img src="${esc(url)}" alt="${esc(alt)}"${dims}>`;
  };

  // Heading ids for anchors and the outline.
  md.core.ruler.push('heading_ids', (state) => {
    const used = state.env.usedIds || (state.env.usedIds = new Set());
    const tk = state.tokens;
    for (let i = 0; i < tk.length; i++) {
      if (tk[i].type !== 'heading_open') continue;
      const text = (tk[i + 1].children || []).map((c) => c.content).join('');
      let base = 'h-' + (text.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '-').replace(/^-|-$/g, '') || 'section');
      let id = base;
      for (let n = 1; used.has(id); n++) id = `${base}-${n}`;
      used.add(id);
      tk[i].attrSet('id', id);
      tk[i].attrSet('data-heading', text);
    }
  });

  // ---------------------------------------------------------------- page rendering

  const root = document.getElementById('root');
  const view = document.getElementById('view');

  function renderMarkdown(src, source, usedIds) {
    return md.render(src, { source, usedIds });
  }

  /// Parse HTML into a fragment and remove script-capable bits from note-supplied HTML.
  let currentSource = '';
  function sanitize(html, source) {
    currentSource = source || payload.path;
    const tpl = document.createElement('template');
    tpl.innerHTML = html;
    tpl.content.querySelectorAll('script, object, embed:not(.internal-embed), base, meta, link').forEach((n) => n.remove());
    tpl.content.querySelectorAll('*').forEach((el) => {
      for (const attr of [...el.attributes]) {
        const n = attr.name.toLowerCase();
        if (n.startsWith('on')) el.removeAttribute(attr.name);
        else if ((n === 'href' || n === 'src' || n === 'xlink:href') && /^\s*javascript:/i.test(attr.value)) el.removeAttribute(attr.name);
      }
      if (['IMG', 'VIDEO', 'AUDIO', 'SOURCE'].includes(el.tagName)) {
        const src = el.getAttribute('src') || '';
        if (src && !hasScheme(src) && !src.startsWith('//')) {
          const decoded = safeDecode(src);
          const resolved = resolveLink(decoded, currentSource);
          el.setAttribute('src', vaultURL(resolved || decoded.replace(/^\/+/, '')));
        }
      }
      if (el.tagName === 'A' && !el.classList.contains('internal-link') && !el.classList.contains('tag')) {
        const href = el.getAttribute('href') || '';
        if (hasScheme(href) && !el.classList.contains('external-link')) el.classList.add('external-link');
      }
    });
    return tpl.content;
  }

  // ---------------------------------------------------------------- Bases

  const BASE_VIEW_ICON = { table: 'list', cards: 'clipboard-list', list: 'list-checks' };

  function renderBaseCell(cell, source) {
    if (!cell) return '';
    switch (cell.t) {
      case 'null': return '';
      case 'bool': return `<input type="checkbox" class="task-list-item-checkbox" disabled${cell.bool ? ' checked' : ''}>`;
      case 'num':
      case 'date': return esc(cell.text);
      case 'link':
        return cell.path
          ? `<a class="internal-link" data-path="${esc(cell.path)}" data-target="${esc(cell.text)}" data-subpath="">${esc(cell.text)}</a>`
          : `<span class="internal-link is-unresolved">${esc(cell.text)}</span>`;
      case 'image': {
        const src = cell.path ? vaultURL(cell.path) : cell.text;
        return /^(https?:|juju:)/.test(src) ? `<img class="bases-image" src="${esc(src)}" alt="">` : esc(cell.text);
      }
      case 'list':
        return (cell.items || []).map((c) => `<span class="bases-list-item">${renderBaseCell(c, source)}</span>`).join('');
      default:
        return md.renderInline(cell.text, { source });
    }
  }

  function renderBaseView(view, source, sortable) {
    let html = '';
    if (view.error) html += `<div class="bases-error">${esc(view.error)}</div>`;
    const cols = view.columns;
    const summaries = view.summaries.some(Boolean);
    const groupHeader = (g) => g.key ? `${renderBaseCell(g.key, source) || '<span class="bases-empty">None</span>'}<span class="bases-group-count">${g.rows.length}</span>` : '';
    const supported = ['table', 'cards', 'list'].includes(view.type);
    if (!supported) html += `<div class="bases-note">The “${esc(view.type)}” view isn’t supported yet; showing a table.</div>`;
    const type = supported ? view.type : 'table';
    const opt = view.options || {};
    if (type === 'table') {
      // Column widths from resizing (columnSize) and Obsidian's row height option.
      const width = (c) => {
        const w = (view.columnSize || {})[c.id];
        return w ? ` style="width:${w}px;min-width:${w}px;max-width:${w}px"` : '';
      };
      const rowHeight = ['medium', 'tall', 'extra'].includes(opt.rowHeight) ? ` row-height-${opt.rowHeight}` : '';
      html += `<div class="bases-table-container"><table class="bases-table${rowHeight}"><thead><tr>`;
      // A read-only .base: clicking a header sorts for viewing only (A → Z, Z → A, then the file's own sort).
      const sorted = sortable && view.viewSort;
      const arrow = (c) => sorted && sorted.property === c.id
        ? `<span class="bases-th-sort">${icon(sorted.ascending ? 'arrow-up' : 'arrow-down')}</span>` : '';
      const title = sortable ? ' title="Sort (view only)"' : '';
      html += cols.map((c) => `<th data-col="${esc(c.id)}"${width(c)}${title}><span class="bases-th-name">${esc(c.name)}</span>${arrow(c)}</th>`).join('') + '</tr></thead><tbody>';
      for (const g of view.groups) {
        if (g.key) html += `<tr class="bases-group-row"><td colspan="${cols.length}">${groupHeader(g)}</td></tr>`;
        for (const r of g.rows) {
          html += `<tr data-path="${esc(r.path)}">` + r.cells.map((c, i) =>
            `<td data-col="${i}" data-col-id="${esc(cols[i].id)}"${width(cols[i])}>${renderBaseCell(c, source)}</td>`).join('') + '</tr>';
        }
      }
      html += '</tbody>';
      if (summaries) html += '<tfoot><tr>' + view.summaries.map((s) => `<td>${esc(s)}</td>`).join('') + '</tr></tfoot>';
      html += '</table></div>';
    } else if (type === 'cards') {
      // Obsidian's card options: size (min card width), image fit and aspect ratio (cover height / width).
      const size = Number(opt.cardSize) > 0 ? Number(opt.cardSize) : 0;
      const ratio = Number(opt.imageAspectRatio) > 0 ? Number(opt.imageAspectRatio) : 0;
      const gridStyle = size ? ` style="grid-template-columns:repeat(auto-fill,minmax(${size}px,1fr))"` : '';
      const coverStyle = ratio ? ` style="aspect-ratio:1 / ${ratio}"` : '';
      const fit = opt.imageFit === 'contain' ? ' is-contain' : '';
      for (const g of view.groups) {
        if (g.key) html += `<div class="bases-group-heading">${groupHeader(g)}</div>`;
        html += `<div class="bases-cards"${gridStyle}>`;
        for (const r of g.rows) {
          html += '<div class="bases-card">';
          if (r.image) html += `<div class="bases-card-cover${fit}"${coverStyle}>${renderBaseCell(r.image, source)}</div>`;
          html += `<div class="bases-card-title">${renderBaseCell(r.cells[0], source)}</div>`;
          r.cells.slice(1).forEach((c, i) => {
            const value = renderBaseCell(c, source);
            if (value) html += `<div class="bases-card-property"><span class="bases-card-label">${esc(cols[i + 1].name)}</span><span>${value}</span></div>`;
          });
          html += '</div>';
        }
        html += '</div>';
      }
    } else {
      // Obsidian's list options: markers (bullet/number/none), indented properties or a separator.
      const tag = opt.markers === 'number' ? 'ol' : 'ul';
      const markers = opt.markers === 'none' ? ' no-markers' : '';
      const indent = opt.indentProperties === 'true';
      const sep = opt.separator ?? ', ';
      for (const g of view.groups) {
        if (g.key) html += `<div class="bases-group-heading">${groupHeader(g)}</div>`;
        html += `<${tag} class="bases-list${markers}">`;
        for (const r of g.rows) {
          const rest = r.cells.slice(1).map((c) => renderBaseCell(c, source)).filter(Boolean);
          const props = !rest.length ? ''
            : indent ? '<ul class="bases-list-indented">' + rest.map((x) => `<li>${x}</li>`).join('') + '</ul>'
              : ' <span class="bases-list-props">' + rest.join(esc(sep)) + '</span>';
          html += `<li>${renderBaseCell(r.cells[0], source)}${props}</li>`;
        }
        html += `</${tag}>`;
      }
    }
    if (!view.groups.some((g) => g.rows.length)) html += '<div class="bases-empty-state">No results</div>';
    return html;
  }

  // The view shown per base (by name), kept across re-renders.
  const baseSelection = {};

  /// A base with its view switcher. `source` is the file links in cells resolve from. `edit` ({cfg, props}) makes it
  /// editable (an unlocked .base): bases-edit.js adds the toolbar, menus and cell editing. `sortable` (a read-only
  /// .base tab) lets table headers ask the app for a view-only sort; the file isn't changed.
  function renderBase(result, source, edit, sortable) {
    const box = document.createElement('div');
    box.className = 'bases-view';
    let selected = 0;
    const pick = () => {
      const remembered = baseSelection[source];
      const i = remembered == null ? -1 : result.views.findIndex((v) => v.name === remembered);
      selected = i >= 0 ? i : Math.min(result.selected || 0, result.views.length - 1);
    };
    let saveTimer = null;
    const ctx = edit && {
      source, cfg: edit.cfg, props: edit.props, rawFilters: new Set(),
      get selected() { return selected; },
      select(i) { selected = i; baseSelection[source] = (ctx.cfg.views[i] || {}).name ?? null; },
      save() {
        clearTimeout(saveTimer);
        saveTimer = null;
        post({ type: 'baseSave', path: source, yaml: window.JujuBaseEditor.dumpYAML(ctx.cfg) });
      },
      saveSoon() {
        clearTimeout(saveTimer);
        saveTimer = setTimeout(() => ctx.save(), 400);
      },
      redraw: () => draw(),
    };
    box.__update = (newResult, newEdit) => {
      result = newResult;
      if (ctx && newEdit) {
        // Keep the object open popovers are editing unless the file changed some other way.
        if (!saveTimer && JSON.stringify(newEdit.cfg) !== JSON.stringify(ctx.cfg)) {
          window.JujuBaseEditor.closePopover();
          ctx.cfg = newEdit.cfg;
        }
        ctx.props = newEdit.props;
      }
      pick();
      draw();
    };
    const draw = () => {
      if (!result || !result.views || !result.views.length) {
        box.innerHTML = `<div class="bases-error">${esc(result?.error || 'This base has no views.')}</div>`;
        return;
      }
      selected = Math.min(selected, result.views.length - 1);
      const view = result.views[selected];
      const tabs = result.views.map((v, i) =>
        `<button class="bases-view-tab${i === selected ? ' is-active' : ''}" data-index="${i}">${icon(BASE_VIEW_ICON[v.type] || 'list')}<span>${esc(v.name)}</span></button>`).join('');
      const count = view.total === 1 ? '1 result' : `${view.total} results`;
      box.innerHTML = `<div class="bases-toolbar"><div class="bases-view-tabs">${tabs}</div><div class="bases-count">${count}</div></div>`;
      const body = document.createElement('div');
      body.className = 'bases-body';
      const sorting = sortable && !ctx;
      body.appendChild(sanitize(renderBaseView(view, source, sorting), source));
      box.appendChild(body);
      if (sorting) {
        box.classList.add('is-sortable');
        box.querySelectorAll('table.bases-table thead th[data-col]').forEach((th) => th.addEventListener('click', (ev) => {
          ev.stopPropagation();
          const id = th.dataset.col, cur = view.viewSort;
          const next = !cur || cur.property !== id ? 'ASC' : cur.ascending ? 'DESC' : null;
          post({ type: 'baseSort', path: source, view: view.name, property: next ? id : null, direction: next });
        }));
      }
      box.querySelectorAll('.bases-view-tab[data-index]').forEach((b) => b.addEventListener('click', (ev) => {
        ev.stopPropagation();
        selected = Number(b.dataset.index);
        baseSelection[source] = result.views[selected].name;
        draw();
      }));
      if (ctx && window.JujuBaseEditor) {
        box.classList.add('is-editable');
        window.JujuBaseEditor.decorate(ctx, box, view);
      }
    };
    if (result && result.views && result.views.length) pick();
    draw();
    return box;
  }

  let mainBase = null;
  const baseEdit = (p) => (p.baseEditable && p.baseConfig ? { cfg: JSON.parse(p.baseConfig), props: p.baseProperties || [] } : null);
  // The app re-evaluated this tab's .base (its settings or the notes changed): redraw it in place.
  function updateBase(p) {
    if (!mainBase || !p || p.path !== payload.path) return;
    payload.base = p.base;
    mainBase.__update(p.base, baseEdit(p));
  }

  function fillBaseBlocks(container) {
    container.querySelectorAll('div.base-placeholder').forEach((ph) => {
      const key = ph.dataset.key;
      const source = key.slice(0, key.indexOf('\n'));
      const result = (payload.bases || {})[key];
      ph.replaceWith(result ? renderBase(result, source) : Object.assign(document.createElement('div'), {
        className: 'bases-error', textContent: 'This base could not be evaluated.',
      }));
    });
  }

  function fillEmbeds(container, usedIds, depth) {
    container.querySelectorAll('span.embed-placeholder').forEach((ph) => {
      const key = ph.dataset.key;
      const e = payload.embeds[key];
      const div = document.createElement('div');
      div.className = 'internal-embed markdown-embed';
      const path = e ? e.path : key.split('#')[0];
      const subpath = key.slice(key.indexOf('#') + 1);
      div.dataset.path = path;
      div.dataset.subpath = subpath;
      let html = `<div class="markdown-embed-link" title="Open link">${icon('link')}</div>`;
      if (!subpath) html += `<div class="markdown-embed-title">${esc(basename(path))}</div>`;
      html += '<div class="markdown-embed-content"></div>';
      div.innerHTML = html;
      const content = div.querySelector('.markdown-embed-content');
      if (e && e.kind === 'base') {
        div.className = 'internal-embed markdown-embed bases-embed';
        div.querySelector('.markdown-embed-title')?.remove();
        content.appendChild(renderBase(e.base, e.path));
      } else if (e && e.body != null && depth < 5) {
        content.appendChild(sanitize(renderMarkdown(e.body, e.path, usedIds), e.path));
      } else {
        const msg = !e ? 'Unable to find this note.' : subpath ? `Unable to find section #${subpath} in ${basename(path)}` : basename(path);
        content.innerHTML = `<p class="markdown-embed-empty">${esc(msg)}</p>`;
      }
      // An embed alone in its paragraph replaces the paragraph (a <div> can't sit in a <p>).
      const parent = ph.parentElement;
      if (parent && parent.tagName === 'P' && parent.childNodes.length === 1) parent.replaceWith(div);
      else ph.replaceWith(div);
      fillEmbeds(content, usedIds, depth + 1);
    });
  }

  /// Turns a trailing " ^block-id" into an anchor on its block, like Obsidian hides it.
  function applyBlockIds(container) {
    const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT);
    const hits = [];
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      if (/(?:^|\s)\^([A-Za-z0-9-]+)\s*$/.test(n.nodeValue)) hits.push(n);
    }
    for (const n of hits) {
      const m = /(?:^|\s)\^([A-Za-z0-9-]+)\s*$/.exec(n.nodeValue);
      const block = n.parentElement?.closest('p, li, td, th, div.callout, blockquote, h1, h2, h3, h4, h5, h6');
      if (!block) continue;
      n.nodeValue = n.nodeValue.slice(0, m.index);
      // A standalone ^id paragraph names the block before it.
      const target = !block.textContent.trim() && block.tagName === 'P' ? block.previousElementSibling : block;
      if (!block.textContent.trim() && block.tagName === 'P') block.remove();
      if (target) target.dataset.blockId = m[1];
    }
  }

  function renderProperties(props, source) {
    if (!props || !props.length) return '';
    const rows = props.map(({ key, value }) => {
      const lower = key.toLowerCase();
      const list = Array.isArray(value);
      let iconName = list ? 'list' : 'text';
      let html;
      if (lower === 'tags' || lower === 'tag') {
        iconName = 'tags';
        const items = (list ? value : String(value).split(/[,\s]+/)).filter(Boolean);
        html = items.map((t) => { const n = t.replace(/^#/, ''); return `<a href="#${esc(n)}" class="tag" data-tag="${esc(n)}">${esc(n)}</a>`; }).join('');
      } else if (list) {
        html = value.map((v) => `<span class="multi-select-pill">${md.renderInline(v, { source })}</span>`).join('');
      } else if (value === 'true' || value === 'false') {
        iconName = 'list-checks';
        html = `<input type="checkbox" class="task-list-item-checkbox" disabled${value === 'true' ? ' checked' : ''}>`;
      } else if (/^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2})?)?$/.test(value)) {
        iconName = 'calendar';
        html = esc(value);
      } else if (/^-?\d+(\.\d+)?$/.test(value)) {
        iconName = 'binary';
        html = esc(value);
      } else {
        html = value ? md.renderInline(value, { source }) : '<span class="empty">Empty</span>';
      }
      if (lower === 'aliases' || lower === 'alias') iconName = 'link';
      if (!html) html = '<span class="empty">Empty</span>';
      return `<div class="metadata-property" data-property-key="${esc(key)}"><div class="metadata-property-key"><span class="metadata-property-icon">${icon(iconName)}</span><span class="key-name">${esc(key)}</span></div><div class="metadata-property-value">${html}</div></div>`;
    });
    return `<div class="metadata-container"><div class="metadata-properties-heading">Properties</div><div class="metadata-properties">${rows.join('')}</div></div>`;
  }

  /// Sizes the Properties key column to its longest key so keys aren't truncated (Obsidian uses a
  /// fixed width and cuts them off). Capped at 40% of the panel; longer keys wrap.
  function fitPropertyKeys() {
    const box = root.querySelector('.metadata-properties');
    if (!box) return;
    const keys = [...box.querySelectorAll('.metadata-property-key')];
    if (!keys.length) return;
    box.style.removeProperty('--property-key-width');
    let widest = 0;
    for (const key of keys) {
      // Measure the unwrapped width of icon + gap + name + padding.
      const name = key.querySelector('.key-name');
      name.style.whiteSpace = 'nowrap';
      const style = getComputedStyle(key);
      const width = key.querySelector('.metadata-property-icon').getBoundingClientRect().width
        + parseFloat(style.columnGap || 0) + name.getBoundingClientRect().width
        + parseFloat(style.paddingLeft) + parseFloat(style.paddingRight);
      name.style.whiteSpace = '';
      widest = Math.max(widest, width);
    }
    const cap = box.getBoundingClientRect().width * 0.4;
    box.style.setProperty('--property-key-width', Math.ceil(Math.min(widest, cap)) + 'px');
  }
  if (window.ResizeObserver) new ResizeObserver(() => fitPropertyKeys()).observe(root);

  function renderFileMessage(text) {
    return `<div class="file-message"><p>${esc(text)}</p><button data-action="obsidian">Open in Obsidian</button><button data-action="default-app">Open in default app</button></div>`;
  }

  let mermaidLoading = null;
  let mermaidReady = null;
  function runMermaid() {
    const nodes = root.querySelectorAll('pre.mermaid');
    if (!nodes.length) return;
    // Mermaid is large, so Swift injects it only when a note has a diagram (see mermaidLoaded).
    mermaidLoading = mermaidLoading || (window.mermaid ? Promise.resolve() : new Promise((resolve) => {
      mermaidReady = resolve;
      post({ type: 'loadMermaid' });
    }));
    mermaidLoading.then(() => {
      const dark = matchMedia('(prefers-color-scheme: dark)').matches;
      window.mermaid.initialize({ startOnLoad: false, theme: dark ? 'dark' : 'default', securityLevel: 'strict' });
      window.mermaid.run({ nodes });
    }).catch(() => {});
  }

  function normalizeHeading(s) {
    return s.toLowerCase().replace(/[\[\]#|^:\\]/g, ' ').split(/\s+/).filter(Boolean).join(' ');
  }

  function findSubpath(subpath) {
    if (!subpath) return null;
    if (subpath.startsWith('^')) {
      return root.querySelector(`[data-block-id="${CSS.escape(subpath.slice(1))}"]`);
    }
    const wanted = normalizeHeading(subpath.split('#').filter(Boolean).pop() || subpath);
    const headings = [...root.querySelectorAll('h1, h2, h3, h4, h5, h6')].filter((h) => !h.closest('.markdown-embed'));
    return headings.find((h) => normalizeHeading(h.dataset.heading || h.textContent) === wanted) || null;
  }

  function scrollToSubpath(subpath, flash = true) {
    const el = findSubpath(subpath);
    if (!el) return false;
    el.scrollIntoView({ block: 'start' });
    if (flash) {
      el.classList.remove('is-flashing');
      void el.offsetWidth;
      el.classList.add('is-flashing');
    }
    return true;
  }

  function highlightTerms(terms) {
    const words = (terms || []).map((t) => t.trim()).filter(Boolean);
    if (!words.length) return null;
    const re = new RegExp(words.map((w) => w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|'), 'gi');
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => (n.parentElement.closest('.katex, svg, style, script, .metadata-container') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
    });
    const nodes = [];
    for (let n = walker.nextNode(); n; n = walker.nextNode()) if (re.test(n.nodeValue)) nodes.push(n);
    let first = null;
    for (const n of nodes) {
      re.lastIndex = 0;
      const frag = document.createDocumentFragment();
      let last = 0;
      const text = n.nodeValue;
      for (let m = re.exec(text); m; m = re.exec(text)) {
        if (!m[0]) break;
        frag.append(text.slice(last, m.index));
        const mark = document.createElement('mark');
        mark.className = 'search-highlight';
        mark.textContent = m[0];
        frag.append(mark);
        first = first || mark;
        last = m.index + m[0].length;
      }
      frag.append(text.slice(last));
      n.replaceWith(frag);
    }
    return first;
  }

  function reportOutline() {
    const headings = [...root.querySelectorAll('h1, h2, h3, h4, h5, h6')]
      .filter((h) => !h.closest('.markdown-embed, .callout-title'))
      .map((h) => ({ level: Number(h.tagName[1]), text: h.textContent.trim(), id: h.id }));
    post({ type: 'outline', headings });
  }

  /// Entry point called from Swift: render(payloadJSON, { scrollY, subpath, highlight }).
  function render(json, opts = {}) {
    payload = JSON.parse(json);
    const usedIds = new Set();
    root.innerHTML = '';
    // Bases files use the full pane width, like Obsidian.
    document.body.classList.toggle('is-base-file', payload.kind === 'base');
    switch (payload.kind) {
      case 'markdown': {
        root.insertAdjacentHTML('beforeend', `<div class="inline-title">${esc(payload.title)}</div>`);
        root.appendChild(sanitize(renderProperties(payload.properties, payload.path)));
        fitPropertyKeys();
        const body = document.createElement('div');
        body.className = 'markdown-rendered';
        body.appendChild(sanitize(renderMarkdown(payload.body, payload.path, usedIds)));
        root.appendChild(body);
        fillEmbeds(root, usedIds, 0);
        fillBaseBlocks(root);
        applyBlockIds(root);
        runMermaid();
        break;
      }
      case 'image':
        root.innerHTML = `<div class="image-container"><img src="${vaultURL(payload.path)}" alt="${esc(payload.title)}"></div>`;
        break;
      case 'audio':
        root.innerHTML = `<div class="inline-title">${esc(payload.title)}</div><audio controls src="${vaultURL(payload.path)}"></audio>`;
        break;
      case 'video':
        root.innerHTML = `<div class="inline-title">${esc(payload.title)}</div><video controls src="${vaultURL(payload.path)}"></video>`;
        break;
      case 'base':
        root.insertAdjacentHTML('beforeend', `<div class="inline-title">${esc(payload.title)}</div>`);
        mainBase = renderBase(payload.base, payload.path, baseEdit(payload), true);
        root.appendChild(mainBase);
        break;
      case 'canvas':
        root.innerHTML = renderFileMessage(`Canvas files can't be displayed in the viewer yet.`);
        break;
      default:
        root.innerHTML = renderFileMessage(`${payload.path.split('/').pop()} can't be displayed in the viewer.`);
    }
    reportOutline();

    const firstMark = highlightTerms(opts.highlight);
    if (opts.subpath && scrollToSubpath(opts.subpath)) return;
    if (firstMark) { firstMark.scrollIntoView({ block: 'center' }); return; }
    window.scrollTo(0, opts.scrollY || 0);
  }

  function setOptions(o) {
    if (o.fontSize) document.documentElement.style.setProperty('--font-text-size', o.fontSize + 'px');
    document.body.classList.toggle('is-readable-line-width', !!o.readableLineWidth);
    fitPropertyKeys();
  }

  function scrollToHeadingId(id) {
    const el = document.getElementById(id);
    if (el) el.scrollIntoView({ block: 'start' });
  }

  // ---------------------------------------------------------------- image zoom

  // Click an image to see it large on a dimmed overlay (like Obsidian's image zoom). Scroll or pinch zooms further,
  // drag pans, a click or Esc closes.
  function zoomImage(src, alt) {
    if (!src || document.querySelector('.juju-zoom')) return;
    const overlay = document.createElement('div');
    overlay.className = 'juju-zoom';
    const img = document.createElement('img');
    img.src = src;
    img.alt = alt || '';
    img.draggable = false;
    overlay.appendChild(img);
    document.body.appendChild(overlay);
    void overlay.offsetWidth;   // start the fade-in from opacity 0
    overlay.classList.add('is-open');
    let scale = 1, x = 0, y = 0, drag = null, moved = false;
    const apply = () => { img.style.transform = `translate(${x}px, ${y}px) scale(${scale})`; };
    const close = () => {
      document.removeEventListener('keydown', onKey, true);
      overlay.classList.remove('is-open');
      setTimeout(() => overlay.remove(), 150);
    };
    const onKey = (e) => {
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); close(); }
    };
    document.addEventListener('keydown', onKey, true);
    overlay.addEventListener('wheel', (e) => {
      e.preventDefault();
      const r = img.getBoundingClientRect();
      // Zoom around the pointer.
      const cx = e.clientX - (r.left + r.width / 2), cy = e.clientY - (r.top + r.height / 2);
      const next = Math.min(8, Math.max(1, scale * Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.002))));
      const k = next / scale;
      x -= cx * (k - 1); y -= cy * (k - 1);
      scale = next;
      if (scale === 1) { x = 0; y = 0; }
      apply();
    }, { passive: false });
    overlay.addEventListener('mousedown', (e) => {
      moved = false;
      if (scale > 1) { drag = { sx: e.clientX - x, sy: e.clientY - y }; overlay.classList.add('is-dragging'); }
    });
    overlay.addEventListener('mousemove', (e) => {
      if (!drag) return;
      moved = true;
      x = e.clientX - drag.sx; y = e.clientY - drag.sy;
      apply();
    });
    overlay.addEventListener('mouseup', () => { drag = null; overlay.classList.remove('is-dragging'); });
    overlay.addEventListener('click', (e) => {
      e.stopPropagation();
      if (!moved) close();
    });
  }

  // ---------------------------------------------------------------- image hover toolbar

  // Hovering an image shows "Copy name" / "Copy path" in its top-right corner; the app resolves the file on disk.
  const imageBar = document.createElement('div');
  imageBar.className = 'juju-image-bar';
  imageBar.innerHTML = `<button data-what="name" title="Copy file name">${icon('copy')}<span>Name</span></button>`
    + `<button data-what="path" title="Copy full file path">${icon('copy')}<span>Path</span></button>`;
  let barImage = null, barHide = null;
  const hideBar = () => { imageBar.classList.remove('is-shown'); barImage = null; };
  const hoverable = (img) => img && img.closest('#root') && !img.closest('.juju-zoom') && /^(juju|https?):/.test(img.currentSrc || img.src);
  document.addEventListener('mouseover', (e) => {
    if (e.target.closest && e.target.closest('.juju-image-bar')) { clearTimeout(barHide); return; }
    const img = e.target.closest && e.target.closest('img');
    if (!hoverable(img)) return;
    clearTimeout(barHide);
    if (!imageBar.isConnected) document.body.appendChild(imageBar);
    barImage = img;
    const r = img.getBoundingClientRect();
    imageBar.style.top = `${r.top + scrollY + 6}px`;
    imageBar.style.left = `${r.right + scrollX - 6}px`;
    imageBar.classList.add('is-shown');
  });
  document.addEventListener('mouseout', (e) => {
    const from = e.target.closest && (e.target.closest('.juju-image-bar') || e.target.closest('img'));
    if (!from || !barImage) return;
    const to = e.relatedTarget;
    if (to && (to === barImage || (to.closest && to.closest('.juju-image-bar')))) return;
    clearTimeout(barHide);
    barHide = setTimeout(hideBar, 250);
  });
  imageBar.addEventListener('click', (e) => {
    const b = e.target.closest('button');
    e.preventDefault();
    e.stopPropagation();
    if (!b || !barImage) return;
    post({ type: 'copyImageFile', src: barImage.getAttribute('src') || barImage.src, what: b.dataset.what });
  });

  // ---------------------------------------------------------------- interaction

  document.addEventListener('click', (e) => {
    const mods = { meta: e.metaKey, ctrl: e.ctrlKey, alt: e.altKey, shift: e.shiftKey };

    const jjpx = e.target.closest('img.jjpx');
    if (jjpx) {
      // Locked: asks to unlock. Unlocked: the app calls back zoomImage.
      post({ type: 'jjpx', src: jjpx.getAttribute('src') || '' });
      return;
    }

    const zoomable = e.target.closest('img');
    if (zoomable && !zoomable.closest('a, .bases-card, .callout-icon, .juju-zoom') && !mods.meta && !mods.ctrl) {
      e.preventDefault();
      zoomImage(zoomable.currentSrc || zoomable.src, zoomable.alt);
      return;
    }

    const copy = e.target.closest('.copy-code-button');
    if (copy) {
      e.preventDefault();
      const code = copy.parentElement.querySelector('code');
      post({ type: 'copy', text: code ? code.textContent : '' });
      copy.textContent = 'Copied!';
      setTimeout(() => { copy.textContent = 'Copy'; }, 1200);
      return;
    }

    const fold = e.target.closest('.callout.is-collapsible > .callout-title');
    if (fold && !e.target.closest('a')) {
      fold.parentElement.classList.toggle('is-collapsed');
      return;
    }

    const embedLink = e.target.closest('.markdown-embed-link');
    if (embedLink) {
      const embed = embedLink.closest('.markdown-embed');
      post({ type: 'open', path: embed.dataset.path, subpath: embed.dataset.subpath || null, target: embed.dataset.path, mods });
      return;
    }

    const action = e.target.closest('.file-message button');
    if (action) {
      post({ type: action.dataset.action === 'obsidian' ? 'openInObsidian' : 'openDefaultApp', path: payload.path });
      return;
    }

    const unresolvedEmbed = e.target.closest('span.internal-embed.is-unresolved');
    if (unresolvedEmbed) {
      post({ type: 'open', path: null, target: unresolvedEmbed.dataset.target, subpath: null, mods });
      return;
    }

    const a = e.target.closest('a');
    if (!a) return;
    if (a.classList.contains('internal-link')) {
      e.preventDefault();
      const path = a.dataset.path || null;
      const subpath = a.dataset.subpath || null;
      if (path === payload.path && subpath && !mods.meta && !mods.ctrl) {
        scrollToSubpath(subpath);
        return;
      }
      post({ type: 'open', path, target: a.dataset.target || a.dataset.href || '', subpath, mods });
      return;
    }
    if (a.classList.contains('tag')) {
      e.preventDefault();
      post({ type: 'tag', tag: a.dataset.tag });
      return;
    }
    const href = a.getAttribute('href') || '';
    if (href.startsWith('#')) {
      e.preventDefault();
      const el = document.getElementById(safeDecode(href.slice(1)));
      if (el) el.scrollIntoView({ block: 'center' });
      return;
    }
    if (hasScheme(href)) {
      e.preventDefault();
      post({ type: 'external', url: a.href });
    }
  });

  // Right-click on a vault link: tell Swift what it points at, so the menu can offer "Open in new tab".
  document.addEventListener('contextmenu', (e) => {
    const a = e.target.closest('a.internal-link');
    const embed = e.target.closest('.markdown-embed');
    let link = null;
    if (a) link = { path: a.dataset.path || null, target: a.dataset.target || a.dataset.href || '', subpath: a.dataset.subpath || null };
    else if (embed && embed.dataset.path) link = { path: embed.dataset.path, target: embed.dataset.path, subpath: embed.dataset.subpath || null };
    post({ type: 'context', link });
  });

  let scrollTimer = null;
  window.addEventListener('scroll', () => {
    clearTimeout(scrollTimer);
    scrollTimer = setTimeout(() => post({ type: 'scroll', y: window.scrollY }), 150);
  }, { passive: true });

  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
    if (root.querySelector('pre.mermaid[data-processed]')) post({ type: 'rerender' });
  });

  window.juju = { render, setOptions, scrollToSubpath, scrollToHeadingId, zoomImage, updateBase, mermaidLoaded: () => mermaidReady && mermaidReady() };
  post({ type: 'ready' });
})();
