// free.js: OpenRouter free-tier config UI.
// Shows the live :free model list (/internal/admin/openrouter-models?free=1),
// lets the admin build an ordered fallback pool (max 3) and pick a default
// model, then PUTs both to /internal/admin/openrouter-free. Validation is
// server-side; this UI just collects the selection.

let _config = { pool: [], default: '' };
let _live = [];

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
  _config = {
    pool: (cfg && Array.isArray(cfg.pool)) ? cfg.pool.slice(0, 3) : [],
    default: (cfg && typeof cfg.default === 'string') ? cfg.default : '',
  };
  renderModels();
}

async function saveFree(ev) {
  await withBusy(ev?.currentTarget, async () => {
    try {
      const r = await fetch('/internal/admin/openrouter-free', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ pool: _config.pool, default: _config.default }),
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
  refresh();
  pausableInterval(refresh, 60000);
}
