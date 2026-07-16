// free.js: OpenRouter free-tier config UI.
// Shows the live :free model list (/internal/admin/openrouter-models?free=1),
// lets the admin build an ordered fallback pool (max 3) and pick a default
// model, then PUTs both to /internal/admin/openrouter-free. Validation is
// server-side; this UI just collects the selection.

const CATEGORIES = ['vision', 'long_context', 'coding', 'general'];
const CAT_LABELS = { vision: 'Vision', long_context: 'Long context', coding: 'Coding', general: 'General' };

let _config = { pool: [], default: '', routes: {}, long_context_threshold: 100000 };
let _live = [];

// Budget panel: proxy-side request counts (estimate — success responses carry
// no rate-limit headers) + the exhaustion signal captured from upstream 429s.
function renderBudget(b) {
  const el = $('free-budget');
  if (!el) return;
  if (!b || !b.day) { el.innerHTML = ''; return; }
  const bar = (w) => {
    const pct = w.limit > 0 ? Math.min(100, Math.round(100 * w.used / w.limit)) : 0;
    const color = pct >= 90 ? 'var(--err,#c33)' : pct >= 60 ? 'var(--warn,#c60)' : 'var(--accent)';
    return `<span style="display:inline-block;width:90px;height:6px;background:var(--accent-subtle);border-radius:3px;vertical-align:middle;margin:0 8px">
      <span style="display:block;width:${pct}%;height:6px;background:${color};border-radius:3px"></span></span>`;
  };
  let html = `<div style="font-size:12px">
    <b>Budget</b> (proxy-side estimate) &middot;
    today ${b.day.used}/${b.day.limit}${bar(b.day)}
    this minute ${b.minute.used}/${b.minute.limit}${bar(b.minute)}
  </div>`;
  if (b.exhausted_until) {
    const reset = new Date(b.exhausted_until * 1000);
    const mins = Math.max(0, Math.round((reset - Date.now()) / 60000));
    html += `<div style="font-size:12px;color:var(--err,#c33);margin-top:4px">
      Exhausted — upstream reported the ${b.exhausted_limit === b.minute.limit ? 'per-minute' : 'daily'} cap hit.
      :free requests get 503 until ${reset.toLocaleTimeString()} (~${mins} min).
    </div>`;
  }
  el.innerHTML = html;
}

function ctxLabel(n) {
  if (!n) return '';
  return n >= 1000 ? Math.round(n / 1000) + 'k ctx' : n + ' ctx';
}

function renderModels() {
  const list = $('free-models-list');
  const liveIds = new Set(_live.map(m => m.id));

  // Surface configured ids that are no longer listed so the admin can drop them.
  const extra = [];
  for (const id of _config.pool) {
    if (!liveIds.has(id)) extra.push({ id, name: id, context_length: 0, stale: true });
  }
  if (_config.default && !liveIds.has(_config.default) && !_config.pool.includes(_config.default)) {
    extra.push({ id: _config.default, name: _config.default, context_length: 0, stale: true });
  }
  const all = _live.concat(extra);
  $('free-count').textContent = _live.length;

  if (all.length === 0) {
    list.innerHTML = '<div class="empty">no free models available (OpenRouter list unreachable?)</div>';
    $('default-none').checked = !_config.default;
    return;
  }

  // Pool members first (in pool order), then the rest alphabetically.
  all.sort((a, b) => {
    const ia = _config.pool.indexOf(a.id), ib = _config.pool.indexOf(b.id);
    if (ia !== -1 || ib !== -1) {
      if (ia === -1) return 1;
      if (ib === -1) return -1;
      return ia - ib;
    }
    return a.id.localeCompare(b.id);
  });

  list.innerHTML = all.map(m => {
    const pIdx = _config.pool.indexOf(m.id);
    const inPool = pIdx !== -1;
    const isDefault = _config.default === m.id;
    const order = inPool
      ? `<span style="display:inline-block;min-width:16px;text-align:center;background:var(--accent);color:#fff;border-radius:8px;font-size:10px;font-weight:700;padding:1px 5px;margin-left:6px">${pIdx + 1}</span>`
      : '';
    const staleTag = m.stale ? ' <span style="color:var(--warn,#c60)">· not currently listed</span>' : '';
    return `<div class="user-row">
      <div class="user-info">
        <span class="user-name">
          <label style="cursor:pointer;user-select:none">
            <input type="checkbox" data-pool="${esc(m.id)}" ${inPool ? 'checked' : ''}> pool</label>${order}
          <span style="margin-left:10px;font-family:var(--font-mono,monospace)">${esc(m.id)}</span>
        </span>
        <span class="user-meta">${esc(ctxLabel(m.context_length))}${staleTag}</span>
      </div>
      <div class="user-actions">
        <label style="font-size:12px;color:var(--dim);cursor:pointer;user-select:none">
          <input type="radio" name="free-default" value="${esc(m.id)}" ${isDefault ? 'checked' : ''}> default</label>
      </div>
    </div>`;
  }).join('');

  $('default-none').checked = !_config.default;
}

function renderRoutes() {
  const ed = $('routes-editor');
  if (!ed) return;
  const liveIds = _live.map(m => m.id);
  ed.innerHTML = CATEGORIES.map(cat => {
    const list = Array.isArray(_config.routes[cat]) ? _config.routes[cat] : [];
    const chips = list.length
      ? list.map((id, i) => `<span style="display:inline-flex;align-items:center;gap:4px;background:var(--accent-subtle);color:var(--accent);border-radius:10px;font-size:11px;padding:2px 6px 2px 8px;margin-right:6px">
          <span style="opacity:.6">${i + 1}</span> ${esc(id)}
          <button class="route-x" data-cat="${cat}" data-id="${esc(id)}" style="background:none;border:none;color:var(--accent);cursor:pointer;font-size:13px;line-height:1;padding:0 2px">×</button>
        </span>`).join('')
      : '<span style="color:var(--dim);font-size:12px;opacity:.7">— falls through to general —</span>';
    // add-select: live models not already in this category, only if under cap 3
    const addable = liveIds.filter(id => !list.includes(id));
    const addSel = list.length >= 3
      ? '<span style="color:var(--dim);font-size:11px">max 3</span>'
      : `<select class="input input-sm route-add" data-cat="${cat}" style="width:230px">
          <option value="">+ add model…</option>
          ${addable.map(id => `<option value="${esc(id)}">${esc(id)}</option>`).join('')}
        </select>`;
    return `<div style="display:flex;align-items:center;gap:10px;padding:7px 0;border-top:1px solid var(--border)">
      <span class="form-label" style="min-width:100px">${CAT_LABELS[cat]}</span>
      <span style="flex:1">${chips}</span>
      ${addSel}
    </div>`;
  }).join('');
}

function addToRoute(cat, id) {
  if (!id) return;
  const list = Array.isArray(_config.routes[cat]) ? _config.routes[cat] : [];
  if (list.length >= 3) return toast('Route capped at 3 models', true);
  if (!list.includes(id)) list.push(id);
  _config.routes[cat] = list;
  renderRoutes();
}

function removeFromRoute(cat, id) {
  const list = Array.isArray(_config.routes[cat]) ? _config.routes[cat] : [];
  _config.routes[cat] = list.filter(x => x !== id);
  renderRoutes();
}

function togglePool(id, checked) {
  const i = _config.pool.indexOf(id);
  if (checked) {
    if (i === -1) {
      if (_config.pool.length >= 3) {
        toast('Pool is capped at 3 models (OpenRouter limit)', true);
        renderModels();  // revert the just-checked box
        return;
      }
      _config.pool.push(id);
    }
  } else if (i !== -1) {
    _config.pool.splice(i, 1);
  }
  renderModels();  // refresh order badges + sort
}

async function loadAll() {
  const [live, cfg] = await Promise.all([
    fetch('/internal/admin/openrouter-models?free=1').then(r => r.json()).catch(() => null),
    fetch('/internal/admin/openrouter-free').then(r => r.json()).catch(() => null),
  ]);
  _live = (live && Array.isArray(live.models)) ? live.models : [];
  if (!live || live.error) toast('Live free-model list unavailable' + (live?.error ? ': ' + live.error : ''), true);
  const routes = {};
  if (cfg && cfg.routes && typeof cfg.routes === 'object') {
    for (const cat of CATEGORIES) {
      if (Array.isArray(cfg.routes[cat])) routes[cat] = cfg.routes[cat].slice(0, 3);
    }
  }
  _config = {
    pool: (cfg && Array.isArray(cfg.pool)) ? cfg.pool.slice(0, 3) : [],
    default: (cfg && typeof cfg.default === 'string') ? cfg.default : '',
    routes,
    long_context_threshold: (cfg && Number.isFinite(cfg.long_context_threshold)) ? cfg.long_context_threshold : 100000,
  };
  $('lc-threshold').value = _config.long_context_threshold;
  $('minute-limit').value = (cfg && Number.isFinite(cfg.minute_limit)) ? cfg.minute_limit : 20;
  $('daily-limit').value = (cfg && Number.isFinite(cfg.daily_limit)) ? cfg.daily_limit : 50;
  renderBudget(cfg && cfg.budget);
  renderModels();
  renderRoutes();
}

async function saveFree(ev) {
  // Drop empty routes so the stored config stays compact.
  const routes = {};
  for (const cat of CATEGORIES) {
    if (Array.isArray(_config.routes[cat]) && _config.routes[cat].length) {
      routes[cat] = _config.routes[cat];
    }
  }
  const thr = parseInt($('lc-threshold').value, 10);
  const minLimit = parseInt($('minute-limit').value, 10);
  const dayLimit = parseInt($('daily-limit').value, 10);
  await withBusy(ev?.currentTarget, async () => {
    try {
      const r = await fetch('/internal/admin/openrouter-free', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          pool: _config.pool,
          default: _config.default,
          routes,
          long_context_threshold: (Number.isFinite(thr) && thr >= 1000) ? thr : 100000,
          minute_limit: (Number.isFinite(minLimit) && minLimit >= 1) ? minLimit : 20,
          daily_limit: (Number.isFinite(dayLimit) && dayLimit >= 1) ? dayLimit : 50,
        }),
      });
      if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || 'HTTP ' + r.status);
      await loadAll();  // re-sync to whatever the server normalized
      toast('Free-tier config saved');
    } catch (e) { toast('Save failed: ' + e.message, true); }
  });
}

async function refresh() {
  await refreshHeader();
  try {
    await loadAll();
    $('last-refresh').textContent = new Date().toLocaleTimeString();
  } catch (e) {
    toast('refresh failed: ' + e.message, true, 'free-refresh');
  }
}

async function initFree() {
  await window._initialAuth;
  $('btn-save-free').addEventListener('click', saveFree);
  // Delegated change handler covers the model-list checkboxes/radios AND the
  // out-of-list "No default" radio (both live under .panel-body).
  document.querySelector('.panel-body').addEventListener('change', e => {
    const t = e.target;
    if (t.dataset && t.dataset.pool !== undefined) {
      togglePool(t.dataset.pool, t.checked);
    } else if (t.name === 'free-default') {
      _config.default = t.value || '';
    }
  });
  // Routes editor lives in a second panel: add-select changes + chip removals.
  const ed = $('routes-editor');
  ed.addEventListener('change', e => {
    const sel = e.target.closest('select.route-add');
    if (sel) { addToRoute(sel.dataset.cat, sel.value); }
  });
  ed.addEventListener('click', e => {
    const x = e.target.closest('button.route-x');
    if (x) { removeFromRoute(x.dataset.cat, x.dataset.id); }
  });
  refresh();
  pausableInterval(refresh, 60000);
}
