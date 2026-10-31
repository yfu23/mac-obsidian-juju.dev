// Editing an unlocked .base like Obsidian: the toolbar's Sort / Filter / Properties / view settings, view tabs
// (add, rename, duplicate, delete, default), column header menus (sort, group, summarize, rename, resize, hide)
// and values in table cells. Settings changes rewrite the whole .base file as YAML, as Obsidian does; a cell
// edit sets that note's property. The app writes the files (only while the base is unlocked) and sends back
// fresh results through window.juju.updateBase.
(() => {
  const ICONS = window.JUJU_ICONS || {};
  const icon = (name) =>
    `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="svg-icon">${ICONS[name] || ''}</svg>`;
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const post = (msg) => window.webkit?.messageHandlers?.juju?.postMessage(msg);
  const el = (tag, cls, html) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (html !== undefined) e.innerHTML = html;
    return e;
  };

  // ------------------------------------------------------------------ YAML (what Obsidian writes)

  const PLAIN_UNSAFE_START = /^[\s\-?:,[\]{}#&*!|>'"%@`]/;
  const RESERVED = /^(true|false|null|yes|no|on|off|~|-?\d+(\.\d+)?([eE][-+]?\d+)?|0x[0-9a-fA-F]+|\.inf|\.nan)$/i;
  function scalar(v) {
    if (v === null || v === undefined) return 'null';
    if (typeof v === 'number' || typeof v === 'boolean') return String(v);
    const s = String(v);
    if (s === '') return '""';
    if (/\n/.test(s)) return JSON.stringify(s);
    if (PLAIN_UNSAFE_START.test(s) || /\s$/.test(s) || /: |\s#/.test(s) || /:$/.test(s) || RESERVED.test(s)) {
      return "'" + s.replace(/'/g, "''") + "'";
    }
    return s;
  }
  const isMap = (v) => v && typeof v === 'object' && !Array.isArray(v);
  function dumpLines(v, ind) {
    const out = [];
    if (Array.isArray(v)) {
      for (const item of v) {
        if (isMap(item) && Object.keys(item).length) {
          const lines = dumpLines(item, ind + '  ');
          lines[0] = ind + '- ' + lines[0].slice(ind.length + 2);
          out.push(...lines);
        } else if (Array.isArray(item)) {
          out.push(ind + '- ' + JSON.stringify(item));
        } else {
          out.push(ind + '- ' + (isMap(item) ? '{}' : scalar(item)));
        }
      }
    } else if (isMap(v)) {
      for (const [k, val] of Object.entries(v)) {
        if (val === undefined) continue;
        const key = scalar(k);
        if (Array.isArray(val)) {
          if (!val.length) out.push(`${ind}${key}: []`);
          else { out.push(`${ind}${key}:`); out.push(...dumpLines(val, ind + '  ')); }
        } else if (isMap(val)) {
          if (!Object.keys(val).length) out.push(`${ind}${key}: {}`);
          else { out.push(`${ind}${key}:`); out.push(...dumpLines(val, ind + '  ')); }
        } else {
          out.push(`${ind}${key}: ${scalar(val)}`);
        }
      }
    }
    return out;
  }
  const dumpYAML = (cfg) => dumpLines(cfg, '').join('\n') + '\n';

  // ------------------------------------------------------------------ properties

  const FILE_PROPS = [
    ['file.name', 'file name'], ['file.basename', 'file base name'], ['file.path', 'file path'], ['file.folder', 'folder'],
    ['file.ext', 'file extension'], ['file.size', 'file size'], ['file.ctime', 'created time'], ['file.mtime', 'modified time'],
    ['file.tags', 'file tags'], ['file.links', 'file links'], ['file.backlinks', 'file backlinks'], ['file.embeds', 'file embeds'],
  ];
  const norm = (id) => (/^(note|file|formula|this)\./.test(id) ? id : 'note.' + id);
  function label(ctx, id) {
    id = norm(String(id));
    const props = ctx.cfg.properties || {};
    const named = props[id]?.displayName ?? (id.startsWith('note.') ? props[id.slice(5)]?.displayName : undefined);
    if (named) return String(named);
    const f = FILE_PROPS.find((p) => p[0] === id);
    if (f) return f[1];
    return id.replace(/^(note|formula)\./, '');
  }
  function propertyGroups(ctx) {
    return [
      ['Note properties', (ctx.props || []).map((p) => 'note.' + p)],
      ['File properties', FILE_PROPS.map((p) => p[0])],
      ['Formulas', Object.keys(ctx.cfg.formulas || {}).map((f) => 'formula.' + f)],
    ];
  }
  function propertySelect(ctx, value, onChange, opts = {}) {
    const sel = el('select', 'dropdown bases-select');
    const current = value == null ? '' : norm(String(value));
    let found = false;
    if (opts.none) sel.appendChild(Object.assign(document.createElement('option'), { value: '', textContent: opts.none }));
    for (const [title, ids] of propertyGroups(ctx)) {
      if (!ids.length) continue;
      const g = document.createElement('optgroup');
      g.label = title;
      for (const id of ids) {
        const o = Object.assign(document.createElement('option'), { value: id, textContent: label(ctx, id) });
        if (id === current) { o.selected = true; found = true; }
        g.appendChild(o);
      }
      sel.appendChild(g);
    }
    if (current && !found) {
      sel.insertBefore(Object.assign(document.createElement('option'), { value: current, textContent: label(ctx, current), selected: true }), sel.firstChild);
    }
    if (!current && opts.none) sel.value = '';
    sel.addEventListener('change', () => onChange(sel.value));
    return sel;
  }
  function select(options, value, onChange) {
    const sel = el('select', 'dropdown bases-select');
    for (const [v, text] of options) sel.appendChild(Object.assign(document.createElement('option'), { value: v, textContent: text }));
    sel.value = value;
    sel.addEventListener('change', () => onChange(sel.value));
    return sel;
  }

  // ------------------------------------------------------------------ popovers and menus

  let pop = null;
  function closePop() {
    if (!pop) return;
    const p = pop;
    pop = null;
    p.el.remove();
    p.onClose?.();
  }
  function openPop(anchor, kind, build, opts = {}) {
    const rect = anchor.getBoundingClientRect();
    closePop();
    const box = el('div', 'bases-popover ' + (opts.cls || ''));
    document.body.appendChild(box);
    pop = { el: box, kind, onClose: opts.onClose };
    build(box);
    const top = rect.bottom + scrollY + 4;
    let left = rect.left + scrollX;
    box.style.top = `${top}px`;
    box.style.left = `${left}px`;
    const w = box.offsetWidth;
    if (left + w > scrollX + innerWidth - 8) box.style.left = `${Math.max(scrollX + 8, rect.right + scrollX - w)}px`;
    return box;
  }
  const isOpen = (kind) => pop && pop.kind === kind;
  document.addEventListener('mousedown', (e) => {
    if (pop && !pop.el.contains(e.target) && !e.target.closest?.('.bases-pop-trigger')) closePop();
  }, true);
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && pop && !e.target.closest?.('.bases-cell-editor')) { e.preventDefault(); e.stopPropagation(); closePop(); }
  }, true);

  // items: { label, action, checked, danger, sep, submenu, disabled }
  function menu(anchor, items, kind = 'menu') {
    openPop(anchor, kind, (box) => {
      for (const it of items) {
        if (!it) continue;
        if (it.sep) { box.appendChild(el('div', 'bases-menu-sep')); continue; }
        const b = el('button', 'bases-menu-item' + (it.danger ? ' mod-warning' : ''),
          `<span class="bases-menu-check">${it.checked ? icon('check') : ''}</span><span class="bases-menu-label">${esc(it.label)}</span>${it.submenu ? icon('chevron-right') : ''}`);
        b.disabled = !!it.disabled;
        b.addEventListener('click', (e) => {
          e.stopPropagation();
          if (it.submenu) { menu(b, it.submenu, kind); return; }
          closePop();
          it.action?.();
        });
        box.appendChild(b);
      }
    }, { cls: 'bases-menu' });
  }

  function prompt(anchor, title, value, onOK, opts = {}) {
    openPop(anchor, 'prompt', (box) => {
      box.appendChild(el('div', 'bases-pop-title', esc(title)));
      const input = el(opts.multiline ? 'textarea' : 'input', 'bases-input');
      input.value = value ?? '';
      if (opts.placeholder) input.placeholder = opts.placeholder;
      const error = el('div', 'bases-pop-error');
      const ok = el('button', 'mod-cta bases-button', esc(opts.button || 'Save'));
      const submit = () => {
        const problem = opts.validate?.(input.value);
        if (problem) { error.textContent = problem; return; }
        closePop();
        onOK(input.value);
      };
      ok.addEventListener('click', submit);
      input.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && (!opts.multiline || e.metaKey || e.ctrlKey)) { e.preventDefault(); submit(); }
      });
      box.append(input, error, ok);
      setTimeout(() => { input.focus(); input.select?.(); }, 0);
    }, { cls: 'bases-prompt' });
  }

  // ------------------------------------------------------------------ the editor for one base

  function viewOf(ctx) {
    if (!Array.isArray(ctx.cfg.views)) ctx.cfg.views = [];
    if (!ctx.cfg.views.length) ctx.cfg.views.push({ type: 'table', name: 'Table' });
    return ctx.cfg.views[Math.min(ctx.selected, ctx.cfg.views.length - 1)];
  }
  const setOrDelete = (obj, key, value) => {
    if (value === undefined || value === null || value === '' || (Array.isArray(value) && !value.length)) delete obj[key];
    else obj[key] = value;
  };
  function viewNameProblem(ctx, name, except) {
    const n = name.trim();
    if (!n) return 'View name cannot be empty.';
    if (ctx.cfg.views.some((v, i) => i !== except && String(v.name ?? '').toLowerCase() === n.toLowerCase())) return 'View name already exists.';
    return null;
  }
  function uniqueViewName(ctx, base) {
    let name = base, i = 2;
    while (ctx.cfg.views.some((v) => String(v.name ?? '').toLowerCase() === name.toLowerCase())) name = `${base} ${i++}`;
    return name;
  }
  const clone = (v) => JSON.parse(JSON.stringify(v));

  // View tabs: "+" adds a view; right-click (or double-click) a tab for its menu.
  function decorateTabs(ctx, box) {
    const tabs = box.querySelector('.bases-view-tabs');
    if (!tabs) return;
    const add = el('button', 'bases-view-tab bases-add-view bases-pop-trigger', icon('plus'));
    add.title = 'Add view';
    add.addEventListener('click', (e) => {
      e.stopPropagation();
      menu(add, [
        { label: 'Table', action: () => addView(ctx, 'table') },
        { label: 'Cards', action: () => addView(ctx, 'cards') },
        { label: 'List', action: () => addView(ctx, 'list') },
      ], 'add-view');
    });
    tabs.appendChild(add);
    tabs.querySelectorAll('.bases-view-tab[data-index]').forEach((tab) => {
      const i = Number(tab.dataset.index);
      const open = (e) => {
        e.preventDefault();
        e.stopPropagation();
        viewMenu(ctx, tab, i);
      };
      tab.addEventListener('contextmenu', open);
      tab.addEventListener('dblclick', open);
    });
  }
  function addView(ctx, type) {
    viewOf(ctx);
    const current = ctx.cfg.views[ctx.selected];
    const name = uniqueViewName(ctx, type[0].toUpperCase() + type.slice(1));
    const view = { type, name };
    if (current?.order) view.order = clone(current.order);
    ctx.cfg.views.push(view);
    ctx.select(ctx.cfg.views.length - 1);
    ctx.save();
  }
  function viewMenu(ctx, anchor, i) {
    viewOf(ctx);
    const views = ctx.cfg.views;
    menu(anchor, [
      { label: 'Rename view…', action: () => prompt(anchor, 'View name', views[i].name ?? '', (name) => {
        views[i].name = name.trim();
        ctx.save();
      }, { validate: (n) => viewNameProblem(ctx, n, i) }) },
      { label: 'Duplicate view', action: () => {
        const copy = clone(views[i]);
        copy.name = uniqueViewName(ctx, String(views[i].name || 'View'));
        views.splice(i + 1, 0, copy);
        ctx.select(i + 1);
        ctx.save();
      } },
      { label: 'Default view', checked: i === 0, disabled: i === 0, action: () => {
        views.unshift(views.splice(i, 1)[0]);
        ctx.select(0);
        ctx.save();
      } },
      { sep: true },
      { label: 'Delete view', danger: true, disabled: views.length < 2, action: () => {
        views.splice(i, 1);
        ctx.select(Math.max(0, Math.min(ctx.selected, views.length - 1)));
        ctx.save();
      } },
    ], 'view-menu');
  }

  // Toolbar buttons (after the result count), as in Obsidian.
  function decorateToolbar(ctx, box) {
    const bar = box.querySelector('.bases-toolbar');
    if (!bar) return;
    const actions = el('div', 'bases-toolbar-actions');
    const button = (kind, iconName, text, open) => {
      const b = el('button', 'bases-toolbar-button bases-pop-trigger', `${icon(iconName)}<span>${esc(text)}</span>`);
      b.dataset.kind = kind;
      b.addEventListener('click', (e) => {
        e.stopPropagation();
        if (isOpen(kind)) { closePop(); return; }
        open(b);
      });
      actions.appendChild(b);
      return b;
    };
    const view = viewOf(ctx);
    const sorts = Array.isArray(view.sort) ? view.sort.length : 0;
    button('sort', 'arrow-up-down', sorts ? `Sort (${sorts})` : 'Sort', (b) => sortPop(ctx, b));
    button('filter', 'list-filter', 'Filter', (b) => filterPop(ctx, b));
    button('properties', 'list', 'Properties', (b) => propertiesPop(ctx, b));
    button('configure', 'sliders-horizontal', 'View', (b) => configurePop(ctx, b));
    bar.appendChild(actions);
  }

  // ---- Sort (and group by)
  function sortPop(ctx, anchor) {
    openPop(anchor, 'sort', (box) => {
      const view = viewOf(ctx);
      const draw = () => {
        box.innerHTML = '';
        box.appendChild(el('div', 'bases-pop-title', 'Sort by'));
        const sorts = Array.isArray(view.sort) ? view.sort : [];
        sorts.forEach((s, i) => {
          const row = el('div', 'bases-pop-row');
          const prop = typeof s === 'string' ? s : s.property;
          const dir = String((typeof s === 'object' && s.direction) || 'ASC').toUpperCase();
          row.appendChild(propertySelect(ctx, prop, (v) => { sorts[i] = { property: v, direction: dir }; commit(); }));
          row.appendChild(select([['ASC', 'A → Z'], ['DESC', 'Z → A']], dir, (v) => { sorts[i] = { property: norm(prop), direction: v }; commit(); }));
          const del = el('button', 'clickable-icon bases-remove', icon('x'));
          del.title = 'Remove sort';
          del.addEventListener('click', () => { sorts.splice(i, 1); commit(); });
          row.appendChild(del);
          box.appendChild(row);
        });
        const add = el('button', 'bases-link-button', `${icon('plus')}<span>Add sort</span>`);
        add.addEventListener('click', () => {
          const sorts2 = Array.isArray(view.sort) ? view.sort : (view.sort = []);
          sorts2.push({ property: 'file.name', direction: 'ASC' });
          commit();
        });
        box.appendChild(add);
        box.appendChild(el('div', 'bases-menu-sep'));
        box.appendChild(el('div', 'bases-pop-title', 'Group by'));
        const g = view.groupBy;
        const gProp = g ? (typeof g === 'string' ? g : g.property) : '';
        const gDir = String((g && typeof g === 'object' && g.direction) || 'ASC').toUpperCase();
        const grow = el('div', 'bases-pop-row bases-group-by');
        grow.appendChild(propertySelect(ctx, gProp || null, (v) => {
          setOrDelete(view, 'groupBy', v ? { property: v, direction: gDir } : null);
          commit();
        }, { none: 'None' }));
        if (gProp) {
          grow.appendChild(select([['ASC', 'A → Z'], ['DESC', 'Z → A']], gDir, (v) => { view.groupBy = { property: norm(gProp), direction: v }; commit(); }));
        }
        box.appendChild(grow);
      };
      const commit = () => {
        if (Array.isArray(view.sort) && !view.sort.length) delete view.sort;
        ctx.save();
        draw();
      };
      draw();
    }, { cls: 'bases-sort-pop' });
  }

  // ---- Filters: Obsidian's simple builder (and/or/not groups of statements), with raw statements as fallback.
  const OPS = [
    ['==', 'is'], ['!=', 'is not'], ['contains', 'contains'], ['!contains', 'does not contain'],
    ['startsWith', 'starts with'], ['endsWith', 'ends with'], ['isEmpty', 'is empty'], ['!isEmpty', 'is not empty'],
    ['>', '>'], ['>=', '≥'], ['<', '<'], ['<=', '≤'],
    ['hasTag', 'has tag'], ['inFolder', 'is in folder'], ['hasLink', 'links to'],
  ];
  const FILE_OPS = new Set(['hasTag', 'inFolder', 'hasLink']);
  const NO_VALUE = new Set(['isEmpty', '!isEmpty']);
  function parseStatement(s) {
    s = String(s).trim();
    let m = /^(!)?\s*([A-Za-z_][\w.]*)\.(contains|startsWith|endsWith|hasTag|inFolder|hasLink|linksTo|isEmpty)\((.*)\)$/.exec(s);
    if (m) {
      const [, neg, prop, method, arg] = m;
      let op = method === 'linksTo' ? 'hasLink' : method;
      if (FILE_OPS.has(op)) { if (prop !== 'file' || neg) return null; return { prop: 'file', op, value: arg }; }
      if (neg) { if (op !== 'contains' && op !== 'isEmpty') return null; op = '!' + op; }
      return { prop, op, value: arg };
    }
    m = /^([A-Za-z_][\w.]*)\s*(==|!=|>=|<=|>|<)\s*(.+)$/.exec(s);
    if (m) return { prop: m[1], op: m[2], value: m[3] };
    return null;
  }
  // The value as shown in the box: a quoted string without its quotes, anything else as written.
  function showValue(v) {
    v = String(v ?? '').trim();
    if (/^"(?:[^"\\]|\\.)*"$/.test(v)) { try { return JSON.parse(v); } catch { return v; } }
    if (/^'[^']*'$/.test(v)) return v.slice(1, -1);
    return v;
  }
  function literal(text) {
    const t = String(text).trim();
    if (/^-?\d+(\.\d+)?$/.test(t) || t === 'true' || t === 'false' || t === 'null') return t;
    if (/^(date|link|now|today|this|file|note|formula|duration|number|list)\b[\w.]*(\(|$)/.test(t)) return t;
    return JSON.stringify(text);
  }
  function composeStatement({ prop, op, value }) {
    const v = literal(value ?? '');
    if (FILE_OPS.has(op)) return `file.${op}(${v})`;
    if (op === 'isEmpty') return `${prop}.isEmpty()`;
    if (op === '!isEmpty') return `!${prop}.isEmpty()`;
    if (op === 'contains' || op === 'startsWith' || op === 'endsWith') return `${prop}.${op}(${v})`;
    if (op === '!contains') return `!${prop}.contains(${v})`;
    return `${prop} ${op} ${v}`;
  }
  const writeProp = (id) => (id.startsWith('note.') && /^[A-Za-z_]\w*$/.test(id.slice(5)) ? id.slice(5) : id);

  function toGroup(f) {
    if (f === undefined || f === null || f === '') return { op: 'and', items: [] };
    if (typeof f === 'string') return { op: 'and', items: [f] };
    if (Array.isArray(f)) return { op: 'and', items: f.slice() };
    for (const op of ['and', 'or', 'not']) if (op in f) return { op, items: Array.isArray(f[op]) ? f[op].slice() : [f[op]] };
    return { op: 'and', items: [] };
  }
  const fromGroup = (g) => ({ [g.op]: g.items.map((x) => (x && x.op ? fromGroup(x) : x)) });
  function deepGroup(f) {
    const g = toGroup(f);
    g.items = g.items.map((x) => (x && typeof x === 'object' && !Array.isArray(x) ? deepGroup(x) : x));
    return g;
  }

  function filterPop(ctx, anchor) {
    let scope = ctx.filterScope || 'view';
    openPop(anchor, 'filter', (box) => {
      const draw = () => {
        box.innerHTML = '';
        const view = viewOf(ctx);
        const tabs = el('div', 'bases-filter-scope');
        for (const [s, text] of [['all', 'All views'], ['view', 'This view']]) {
          const b = el('button', 'bases-filter-scope-tab' + (scope === s ? ' is-active' : ''), esc(text));
          b.addEventListener('click', () => { scope = ctx.filterScope = s; draw(); });
          tabs.appendChild(b);
        }
        box.appendChild(tabs);
        const holder = scope === 'all' ? ctx.cfg : view;
        const root = deepGroup(holder.filters);
        const commit = (redraw) => {
          if (root.items.length) holder.filters = fromGroup(root); else delete holder.filters;
          redraw ? (ctx.save(), draw()) : ctx.saveSoon();
        };
        box.appendChild(groupEditor(ctx, root, commit, 0));
      };
      draw();
    }, { cls: 'bases-filter-pop' });
  }

  function groupEditor(ctx, group, commit, depth, onDelete) {
    const wrap = el('div', 'bases-filter-group' + (depth ? ' is-nested' : ''));
    const head = el('div', 'bases-pop-row');
    head.appendChild(select([['and', 'All the following are true'], ['or', 'Any of the following are true'], ['not', 'None of the following are true']],
      group.op, (v) => { group.op = v; commit(true); }));
    if (onDelete) {
      const del = el('button', 'clickable-icon bases-remove', icon('trash-2'));
      del.title = 'Remove filter group';
      del.addEventListener('click', onDelete);
      head.appendChild(del);
    }
    wrap.appendChild(head);
    group.items.forEach((item, i) => {
      const remove = () => { group.items.splice(i, 1); commit(true); };
      if (item && typeof item === 'object' && item.op) {
        wrap.appendChild(groupEditor(ctx, item, commit, depth + 1, remove));
      } else {
        wrap.appendChild(statementRow(ctx, group, i, commit, remove));
      }
    });
    const foot = el('div', 'bases-pop-row');
    const addF = el('button', 'bases-link-button', `${icon('plus')}<span>Add filter</span>`);
    addF.addEventListener('click', () => { group.items.push('file.name.contains("")'); commit(true); });
    foot.appendChild(addF);
    if (depth < 2) {
      const addG = el('button', 'bases-link-button', `${icon('plus')}<span>Add filter group</span>`);
      addG.addEventListener('click', () => { group.items.push({ op: 'and', items: ['file.name.contains("")'] }); commit(true); });
      foot.appendChild(addG);
    }
    wrap.appendChild(foot);
    return wrap;
  }

  function statementRow(ctx, group, i, commit, remove) {
    const row = el('div', 'bases-pop-row bases-filter-row');
    const text = String(group.items[i] ?? '');
    const parsed = parseStatement(text);
    const raw = !parsed || ctx.rawFilters?.has(text);
    const del = el('button', 'clickable-icon bases-remove', icon('x'));
    del.title = 'Remove filter';
    del.addEventListener('click', remove);
    const mode = el('button', 'clickable-icon bases-filter-mode' + (raw ? ' is-active' : ''), icon('code'));
    mode.title = raw ? 'Simple filter' : 'Advanced filter';
    if (raw) {
      const input = el('input', 'bases-input bases-filter-raw');
      input.value = text;
      input.placeholder = 'Advanced filter';
      input.addEventListener('input', () => { group.items[i] = input.value; ctx.rawFilters?.add(input.value); commit(false); });
      input.addEventListener('change', () => commit(true));
      mode.disabled = !parsed;
      mode.addEventListener('click', () => { ctx.rawFilters?.delete(text); commit(true); });
      row.append(input, mode, del);
      return row;
    }
    const st = { ...parsed };
    const update = (redraw) => { group.items[i] = composeStatement(st); commit(redraw); };
    const propSel = propertySelect(ctx, st.prop === 'file' ? 'file.name' : st.prop, (v) => { st.prop = writeProp(v); update(true); });
    propSel.disabled = FILE_OPS.has(st.op);
    const opSel = select(OPS, st.op, (v) => {
      st.op = v;
      if (FILE_OPS.has(v)) st.prop = 'file';
      else if (st.prop === 'file') st.prop = 'file.name';
      update(true);
    });
    row.append(propSel, opSel);
    if (!NO_VALUE.has(st.op)) {
      const val = el('input', 'bases-input');
      val.value = showValue(st.value);
      val.placeholder = 'Value';
      val.addEventListener('input', () => { st.value = val.value; update(false); });
      row.appendChild(val);
    }
    mode.addEventListener('click', () => { ctx.rawFilters?.add(text); commit(true); });
    row.append(mode, del);
    return row;
  }

  // ---- Properties: which columns show, their order (drag), "Find or create…", formulas.
  function propertiesPop(ctx, anchor) {
    let query = '';
    openPop(anchor, 'properties', (box) => {
      const search = el('input', 'bases-input');
      search.placeholder = 'Find or create…';
      const list = el('div', 'bases-prop-list');
      const foot = el('div', 'bases-pop-row');
      box.append(search, list, foot);
      const draw = () => {
        const view = viewOf(ctx);
        const order = Array.isArray(view.order) ? view.order : [];
        const shown = order.map((x) => norm(String(x)));
        const all = [...shown, ...propertyGroups(ctx).flatMap((g) => g[1]).filter((id) => !shown.includes(id))];
        const q = query.trim().toLowerCase();
        list.innerHTML = '';
        for (const id of all) {
          if (q && !label(ctx, id).toLowerCase().includes(q) && !id.toLowerCase().includes(q)) continue;
          const visible = shown.includes(id);
          const row = el('label', 'bases-prop-row' + (visible ? ' is-visible' : ''));
          if (visible && !q) {
            row.draggable = true;
            row.dataset.id = id;
            row.appendChild(el('span', 'bases-drag', icon('grip-vertical')));
          } else {
            row.appendChild(el('span', 'bases-drag'));
          }
          const cb = Object.assign(document.createElement('input'), { type: 'checkbox', checked: visible });
          cb.addEventListener('change', () => {
            const o = Array.isArray(view.order) ? view.order : (view.order = []);
            if (cb.checked) o.push(id);
            else o.splice(o.findIndex((x) => norm(String(x)) === id), 1);
            ctx.save();
            draw();
          });
          row.append(cb, el('span', 'bases-prop-name', esc(label(ctx, id))), el('span', 'bases-prop-id', esc(id.split('.')[0])));
          list.appendChild(row);
        }
        if (q && !all.some((id) => label(ctx, id).toLowerCase() === q || id.toLowerCase() === 'note.' + q)) {
          const create = el('button', 'bases-link-button', `${icon('plus')}<span>Add “${esc(query.trim())}”</span>`);
          create.addEventListener('click', () => {
            const o = Array.isArray(view.order) ? view.order : (view.order = []);
            o.push('note.' + query.trim());
            query = '';
            search.value = '';
            ctx.save();
            draw();
          });
          list.appendChild(create);
        }
        // Drag to reorder the visible columns.
        let dragId = null;
        list.querySelectorAll('.bases-prop-row[draggable="true"]').forEach((row) => {
          row.addEventListener('dragstart', (e) => { dragId = row.dataset.id; e.dataTransfer.effectAllowed = 'move'; });
          row.addEventListener('dragover', (e) => { e.preventDefault(); row.classList.add('is-drop-target'); });
          row.addEventListener('dragleave', () => row.classList.remove('is-drop-target'));
          row.addEventListener('drop', (e) => {
            e.preventDefault();
            row.classList.remove('is-drop-target');
            const o = view.order;
            const from = o.findIndex((x) => norm(String(x)) === dragId);
            const to = o.findIndex((x) => norm(String(x)) === row.dataset.id);
            if (from < 0 || to < 0 || from === to) return;
            o.splice(to, 0, o.splice(from, 1)[0]);
            ctx.save();
            draw();
          });
        });
        foot.innerHTML = '';
        const formula = el('button', 'bases-link-button', `${icon('plus')}<span>Add formula</span>`);
        formula.addEventListener('click', () => formulaPrompt(ctx, formula, null));
        const hide = el('button', 'bases-link-button', '<span>Hide all</span>');
        hide.addEventListener('click', () => { delete view.order; ctx.save(); draw(); });
        foot.append(formula, hide);
      };
      search.addEventListener('input', () => { query = search.value; draw(); });
      search.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') list.querySelector('.bases-link-button, input[type=checkbox]:not(:checked)')?.click();
      });
      draw();
      setTimeout(() => search.focus(), 0);
    }, { cls: 'bases-properties-pop' });
  }

  function formulaPrompt(ctx, anchor, existing) {
    openPop(anchor, 'prompt', (box) => {
      box.appendChild(el('div', 'bases-pop-title', existing ? 'Edit formula' : 'Add formula'));
      const name = el('input', 'bases-input');
      name.placeholder = 'Property name';
      name.value = existing || '';
      const src = el('textarea', 'bases-input bases-formula');
      src.placeholder = 'Formula, e.g. price / quantity';
      src.value = existing ? String((ctx.cfg.formulas || {})[existing] ?? '') : '';
      const error = el('div', 'bases-pop-error');
      const ok = el('button', 'mod-cta bases-button', 'Save');
      ok.addEventListener('click', () => {
        const n = name.value.trim();
        if (!n) { error.textContent = 'Type a name for the formula.'; return; }
        if (!src.value.trim()) { error.textContent = 'Type a formula.'; return; }
        const formulas = ctx.cfg.formulas && typeof ctx.cfg.formulas === 'object' ? ctx.cfg.formulas : (ctx.cfg.formulas = {});
        if (n !== existing && n in formulas) { error.textContent = 'A formula with that name already exists.'; return; }
        const view = viewOf(ctx);
        if (existing && n !== existing) {
          delete formulas[existing];
          if (Array.isArray(view.order)) view.order = view.order.map((x) => (norm(String(x)) === 'formula.' + existing ? 'formula.' + n : x));
        }
        formulas[n] = src.value.trim();
        if (!existing) (Array.isArray(view.order) ? view.order : (view.order = [])).push('formula.' + n);
        closePop();
        ctx.save();
      });
      box.append(name, src, error, ok);
      setTimeout(() => (existing ? src : name).focus(), 0);
    }, { cls: 'bases-prompt' });
  }

  // ---- View settings: name, layout, limit and the layout's options.
  function configurePop(ctx, anchor) {
    openPop(anchor, 'configure', (box) => {
      const draw = () => {
        box.innerHTML = '';
        const view = viewOf(ctx);
        const field = (text, control, hint) => {
          const row = el('div', 'bases-setting');
          row.appendChild(el('div', 'bases-setting-name', esc(text)));
          row.appendChild(control);
          if (hint) row.appendChild(el('div', 'bases-setting-hint', esc(hint)));
          box.appendChild(row);
          return row;
        };
        box.appendChild(el('div', 'bases-pop-title', 'Configure view'));
        const name = el('input', 'bases-input');
        name.value = view.name ?? '';
        const nameError = el('div', 'bases-pop-error');
        name.addEventListener('input', () => {
          const problem = viewNameProblem(ctx, name.value, ctx.selected);
          nameError.textContent = problem || '';
          if (!problem) { view.name = name.value.trim(); ctx.saveSoon(); }
        });
        field('View name', name).appendChild(nameError);
        field('Layout', select([['table', 'Table'], ['cards', 'Cards'], ['list', 'List']], view.type || 'table', (v) => {
          view.type = v;
          ctx.save();
          draw();
        }));
        const limit = el('input', 'bases-input');
        limit.type = 'number';
        limit.min = '1';
        limit.placeholder = 'e.g. 10';
        limit.value = view.limit ?? '';
        limit.addEventListener('input', () => {
          const n = parseInt(limit.value, 10);
          setOrDelete(view, 'limit', n > 0 ? n : null);
          ctx.saveSoon();
        });
        field('Limit number of results', limit);
        const type = view.type || 'table';
        const slider = (key, min, max, step, def) => {
          const wrap = el('div', 'bases-slider');
          const r = Object.assign(document.createElement('input'), { type: 'range', min, max, step, value: view[key] ?? def });
          const out = el('span', 'bases-slider-value', esc(view[key] ?? def));
          r.addEventListener('input', () => { view[key] = Number(r.value); out.textContent = r.value; ctx.saveSoon(); });
          wrap.append(r, out);
          return wrap;
        };
        if (type === 'table') {
          field('Row height', select([['', 'Short'], ['medium', 'Medium'], ['tall', 'Tall'], ['extra', 'Extra tall']], view.rowHeight ?? '', (v) => {
            setOrDelete(view, 'rowHeight', v);
            ctx.save();
          }));
        } else if (type === 'cards') {
          field('Card size', slider('cardSize', 50, 800, 10, 200));
          field('Image property', propertySelect(ctx, view.image ?? null, (v) => { setOrDelete(view, 'image', v); ctx.save(); }, { none: 'None' }));
          field('Image fit', select([['', 'Cover'], ['contain', 'Contain']], view.imageFit ?? '', (v) => { setOrDelete(view, 'imageFit', v); ctx.save(); }));
          field('Image aspect ratio', slider('imageAspectRatio', 0.25, 2.5, 0.05, 1));
        } else if (type === 'list') {
          field('Markers', select([['bullet', 'Bullet'], ['number', 'Number'], ['none', 'None']], view.markers ?? 'bullet', (v) => {
            setOrDelete(view, 'markers', v === 'bullet' ? null : v);
            ctx.save();
          }));
          const indent = Object.assign(document.createElement('input'), { type: 'checkbox', checked: view.indentProperties === true });
          indent.addEventListener('change', () => { setOrDelete(view, 'indentProperties', indent.checked || null); ctx.save(); draw(); });
          field('Indent properties', indent);
          if (view.indentProperties !== true) {
            const sep = el('input', 'bases-input');
            sep.value = view.separator ?? ', ';
            sep.addEventListener('input', () => { setOrDelete(view, 'separator', sep.value === ', ' ? null : sep.value); ctx.saveSoon(); });
            field('Property separator', sep);
          }
        }
        box.appendChild(el('div', 'bases-menu-sep'));
        const actions = el('div', 'bases-pop-row');
        const dup = el('button', 'bases-link-button', '<span>Duplicate view</span>');
        dup.addEventListener('click', () => {
          const views = ctx.cfg.views;
          const copy = clone(view);
          copy.name = uniqueViewName(ctx, String(view.name || 'View'));
          views.splice(ctx.selected + 1, 0, copy);
          ctx.select(ctx.selected + 1);
          ctx.save();
          closePop();
        });
        const del = el('button', 'bases-link-button mod-warning', '<span>Delete view</span>');
        del.disabled = ctx.cfg.views.length < 2;
        del.addEventListener('click', () => {
          ctx.cfg.views.splice(ctx.selected, 1);
          ctx.select(Math.max(0, ctx.selected - 1));
          ctx.save();
          closePop();
        });
        actions.append(dup, del);
        box.appendChild(actions);
      };
      draw();
    }, { cls: 'bases-configure-pop' });
  }

  // ---- Table: header menus, resizing, summaries and cell editing.
  const SUMMARIES = ['Average', 'Min', 'Max', 'Sum', 'Range', 'Median', 'Stddev', 'Earliest', 'Latest', 'Checked', 'Unchecked', 'Empty', 'Filled', 'Unique'];
  function decorateTable(ctx, box, view) {
    const table = box.querySelector('table.bases-table');
    if (!table) return;
    const vcfg = viewOf(ctx);
    table.classList.add('is-editable');
    table.querySelectorAll('thead th[data-col]').forEach((th) => {
      const id = th.dataset.col;
      th.classList.add('bases-pop-trigger');
      th.addEventListener('click', (e) => {
        if (e.target.closest('.bases-col-resize')) return;
        e.stopPropagation();
        columnMenu(ctx, th, id);
      });
      const handle = el('div', 'bases-col-resize');
      handle.title = 'Drag to resize';
      handle.addEventListener('mousedown', (e) => {
        e.preventDefault();
        e.stopPropagation();
        const startX = e.clientX, startW = th.getBoundingClientRect().width;
        const cells = [...table.querySelectorAll(`[data-col="${CSS.escape(id)}"], td[data-col-id="${CSS.escape(id)}"]`)];
        const move = (ev) => {
          const w = Math.max(40, Math.round(startW + ev.clientX - startX));
          for (const c of cells) Object.assign(c.style, { width: `${w}px`, minWidth: `${w}px`, maxWidth: `${w}px` });
        };
        const up = (ev) => {
          document.removeEventListener('mousemove', move);
          document.removeEventListener('mouseup', up);
          const w = Math.max(40, Math.round(startW + ev.clientX - startX));
          const sizes = vcfg.columnSize && typeof vcfg.columnSize === 'object' ? vcfg.columnSize : (vcfg.columnSize = {});
          sizes[id] = w;
          ctx.save();
        };
        document.addEventListener('mousemove', move);
        document.addEventListener('mouseup', up);
      });
      th.appendChild(handle);
    });
    // Cells: click a note property's cell to edit it (links and checkboxes keep their own behaviour).
    const rows = new Map();
    for (const g of view.groups) for (const r of g.rows) rows.set(r.path, r);
    table.querySelectorAll('tbody tr[data-path] td[data-col]').forEach((td) => {
      const ci = Number(td.dataset.col);
      const col = view.columns[ci];
      if (!col || !col.id.startsWith('note.')) return;
      const row = rows.get(td.parentElement.dataset.path);
      if (!row) return;
      td.classList.add('is-editable');
      const box2 = td.querySelector('input[type=checkbox]');
      if (box2) {
        box2.disabled = false;
        box2.addEventListener('click', (e) => {
          e.stopPropagation();
          post({ type: 'baseCell', path: row.path, property: col.id.slice(5), text: box2.checked ? 'true' : 'false' });
        });
        return;
      }
      td.addEventListener('click', (e) => {
        if (e.target.closest('a, .bases-cell-editor') || e.metaKey || e.ctrlKey) return;
        e.stopPropagation();
        editCell(ctx, td, row, ci, col);
      });
    });
  }

  function editCell(ctx, td, row, ci, col) {
    const raw = (row.raw || [])[ci];
    const isList = Array.isArray(raw);
    const before = isList ? raw.join(', ') : (raw ?? '');
    const input = el('input', 'bases-cell-editor');
    input.value = before;
    if (isList) input.placeholder = 'Comma-separated';
    td.replaceChildren(input);
    input.focus();
    input.select();
    let done = false;
    const finish = (save) => {
      if (done) return;
      done = true;
      if (!save || input.value === before) { ctx.redraw(); return; }
      const msg = { type: 'baseCell', path: row.path, property: col.id.slice(5) };
      if (isList) msg.list = input.value.split(',').map((s) => s.trim()).filter(Boolean);
      else msg.text = input.value;
      post(msg);
    };
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') { e.preventDefault(); finish(true); }
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); finish(false); }
    });
    input.addEventListener('blur', () => finish(true));
  }

  function columnMenu(ctx, th, id) {
    const view = viewOf(ctx);
    const sorts = Array.isArray(view.sort) ? view.sort : [];
    const sorted = sorts.find((s) => norm(String(typeof s === 'string' ? s : s.property)) === id);
    const sortBy = (dir) => { view.sort = [{ property: id, direction: dir }]; ctx.save(); };
    const summaries = view.summaries && typeof view.summaries === 'object' ? view.summaries : {};
    const summaryKey = Object.keys(summaries).find((k) => norm(k) === id);
    const current = summaryKey ? summaries[summaryKey] : null;
    const setSummary = (kind) => {
      const s = view.summaries && typeof view.summaries === 'object' ? view.summaries : (view.summaries = {});
      if (summaryKey) delete s[summaryKey];
      if (kind) s[id] = kind;
      if (!Object.keys(s).length) delete view.summaries;
      ctx.save();
    };
    const custom = Object.keys(ctx.cfg.summaries || {});
    const sized = view.columnSize && typeof view.columnSize === 'object' && Object.keys(view.columnSize).some((k) => norm(k) === id);
    menu(th, [
      { label: 'Sort A → Z', checked: sorted && String(sorted.direction || 'ASC').toUpperCase() === 'ASC', action: () => sortBy('ASC') },
      { label: 'Sort Z → A', checked: sorted && String(sorted.direction).toUpperCase() === 'DESC', action: () => sortBy('DESC') },
      sorted ? { label: 'Clear sort', action: () => { view.sort = sorts.filter((s) => s !== sorted); if (!view.sort.length) delete view.sort; ctx.save(); } } : null,
      { label: 'Group by this property', action: () => { view.groupBy = { property: id, direction: 'ASC' }; ctx.save(); } },
      { sep: true },
      { label: 'Summarize…', submenu: [
        { label: 'None', checked: !current, action: () => setSummary(null) },
        ...[...SUMMARIES, ...custom].map((k) => ({ label: k, checked: current === k, action: () => setSummary(k) })),
      ] },
      id.startsWith('formula.')
        ? { label: 'Edit formula…', action: () => formulaPrompt(ctx, th, id.slice(8)) }
        : { label: 'Edit property…', action: () => prompt(th, 'Display name', label(ctx, id), (name) => {
          const props = ctx.cfg.properties && typeof ctx.cfg.properties === 'object' ? ctx.cfg.properties : (ctx.cfg.properties = {});
          const key = Object.keys(props).find((k) => norm(k) === id) || id;
          const entry = props[key] && typeof props[key] === 'object' ? props[key] : (props[key] = {});
          setOrDelete(entry, 'displayName', name.trim());
          if (!Object.keys(entry).length) delete props[key];
          if (!Object.keys(props).length) delete ctx.cfg.properties;
          ctx.save();
        }, { placeholder: id.replace(/^note\./, '') }) },
      sized ? { label: 'Reset column size', action: () => {
        for (const k of Object.keys(view.columnSize)) if (norm(k) === id) delete view.columnSize[k];
        if (!Object.keys(view.columnSize).length) delete view.columnSize;
        ctx.save();
      } } : null,
      { sep: true },
      { label: 'Hide column', action: () => {
        if (Array.isArray(view.order)) view.order = view.order.filter((x) => norm(String(x)) !== id);
        else view.order = [];
        ctx.save();
      } },
    ], 'column');
  }

  window.JujuBaseEditor = {
    dumpYAML,
    parseStatement,
    composeStatement,
    closePopover: closePop,
    decorate(ctx, box, view) {
      decorateTabs(ctx, box);
      decorateToolbar(ctx, box);
      if ((view.type || 'table') === 'table') decorateTable(ctx, box, view);
    },
  };
})();
