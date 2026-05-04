// agents.js: live view of local omlx-backed agent runs.
// Polls /internal/admin/agents every 2 s, renders active card + history table.

const POLL_MS = 2000;

// Per-section "last rendered payload" cache. We poll every 2s but the
// data rarely changes — re-rendering identical HTML thrashes the DOM,
// kills hover/focus state, and snaps open <select> dropdowns shut. By
// stringifying the input + skipping the renderer when unchanged we get
// a smooth UI without touching the poll cadence.
//
// `active` is intentionally exempt: it carries an elapsed-seconds
// counter that has to update every tick.
const _sig = {};
function _changed(section, payload) {
  const next = JSON.stringify(payload);
  if (_sig[section] === next) return false;
  _sig[section] = next;
  return true;
}

function relTime(epoch) {
  if (!epoch) return '?';
  const dt = Math.max(0, Math.floor(Date.now() / 1000 - epoch));
  if (dt < 60)    return dt + 's ago';
  if (dt < 3600)  return Math.floor(dt / 60) + 'm ago';
  if (dt < 86400) return Math.floor(dt / 3600) + 'h ago';
  return Math.floor(dt / 86400) + 'd ago';
}

function shortModel(m) {
  if (!m) return '?';
  return m
    .replace(/-MLX-4bit$/, '')
    .replace(/-A3B-4bit$/, '-A3B')
    .replace(/-a4b-it-4bit$/, '')
    .replace(/-it-4bit$/, '');     // gemma-4-e2b-it-4bit → gemma-4-e2b
}

async function unloadModel(btn, modelId) {
  if (!confirm(`Unload ${modelId}?\n\nNext request to it will trigger a cold reload (~30-60s for big models).`)) return;
  await withBusy(btn, async () => {
    try {
      const r = await fetch('/internal/admin/models', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'unload', model: modelId }),
      });
      if (r.ok) {
        toast(`unloaded ${modelId}`);
        pollAgents();
      } else {
        const d = await r.json().catch(() => ({}));
        toast((d.error && (d.error.message || d.error)) || `unload failed (HTTP ${r.status})`, true);
      }
    } catch (err) {
      toast('unload error: ' + err.message, true);
    }
  });
}

async function loadModel(btn, modelId) {
  toast(`loading ${modelId}…`);
  await withBusy(btn, async () => {
    try {
      const r = await fetch('/internal/admin/models', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'load', model: modelId }),
      });
      if (r.ok) { toast(`loaded ${modelId}`); pollAgents(); }
      else {
        const d = await r.json().catch(() => ({}));
        toast((d.error && (d.error.message || d.error)) || `load failed (HTTP ${r.status})`, true);
      }
    } catch (err) {
      toast('load error: ' + err.message, true);
    }
  });
}

async function rerunBench(btn, force) {
  const verb = force ? 'force re-run' : 'smart re-run';
  if (!confirm(`Trigger ${verb} of scripts/agent-bench?\n\nThe bench runs in the compose-ctl sidecar, takes 1–6 min depending on which models need to be (re)benched, and writes data/agents/bench-results.json + routing.json on completion. Currently-running indicator shows "bench:" prefix.`)) return;
  await withBusy(btn, async () => {
    try {
      const r = await fetch('/internal/admin/agents/bench', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ force: !!force }),
      });
      const data = await r.json().catch(() => ({}));
      if (r.ok && data.status === 'started') {
        toast('bench started — watch the "Currently running" card');
        pollAgents();
      } else if (r.status === 409) {
        toast(data.error || 'bench already in progress', true);
      } else {
        toast(data.error || `bench start failed (HTTP ${r.status})`, true);
      }
    } catch (err) {
      toast('bench start error: ' + err.message, true);
    }
  });
}

async function unloadAll(ev) {
  // Pull current loaded set from the shared cached omlx_status (last poll).
  const data = window._lastAgentsData;
  const loaded = (data && data.omlx_status && data.omlx_status.models || []).filter(m => m.loaded);
  if (loaded.length === 0) {
    toast('no models loaded — nothing to do');
    return;
  }
  if (!confirm(`Unload all ${loaded.length} loaded models?\n\n${loaded.map(m => '• ' + m.id).join('\n')}\n\nNext request to any of them will trigger a cold reload (~30-60s for big ones).`)) return;
  toast(`unloading ${loaded.length} model(s)…`);
  await withBusy(ev?.currentTarget, async () => {
    const results = await Promise.all(loaded.map(m =>
      fetch('/internal/admin/models', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'unload', model: m.id }),
      }).then(r => ({ model: m.id, ok: r.ok, status: r.status }))
        .catch(err => ({ model: m.id, ok: false, error: err.message }))
    ));
    const ok = results.filter(r => r.ok).length;
    const fail = results.length - ok;
    if (fail === 0) toast(`unloaded ${ok}/${results.length}`);
    else toast(`unloaded ${ok}/${results.length} — ${fail} failed`, true);
    pollAgents();
  });
}

function renderActive(active) {
  const area = $('active-area');
  const count = $('active-count');
  if (!active || !active.task) {
    area.innerHTML = '<div class="empty">no agent currently running</div>';
    count.textContent = '0';
    return;
  }
  count.textContent = '1';
  const elapsed = Math.max(0, Math.floor(Date.now() / 1000 - (active.started_epoch || 0)));
  const cwd = (active.parent && active.parent.cwd) || '?';
  const ppid = (active.parent && active.parent.ppid) || '?';
  const pcmd = (active.parent && active.parent.parent_cmd) || '';
  area.innerHTML = `
    <div class="agent-card">
      <div class="pulse"></div>
      <div style="flex:1;min-width:0">
        <div style="display:flex;align-items:baseline;gap:10px;margin-bottom:4px">
          <span style="font-weight:600;font-size:14px">${esc(active.task)}</span>
          <span style="color:var(--dim);font-family:ui-monospace,monospace;font-size:12px">${esc(shortModel(active.model))}</span>
          <span style="margin-left:auto;color:var(--dim);font-size:12px">${elapsed}s · pid ${esc(active.pid || '?')}</span>
        </div>
        <div class="agent-meta">
          <b>cwd</b>        <span>${esc(cwd)}</span>
          <b>parent pid</b> <span>${esc(ppid)}${pcmd ? ' &mdash; <span style="color:var(--dim)">' + esc(pcmd) + '</span>' : ''}</span>
        </div>
        ${active.prompt_preview ? `<div class="agent-preview">→ ${esc(active.prompt_preview)}</div>` : ''}
      </div>
    </div>`;
}

function renderHistory(recent) {
  const area = $('history-area');
  const count = $('recent-count');
  if (!recent || recent.length === 0) {
    area.innerHTML = '<div class="empty">no history yet — run <code>scripts/agent run &lt;task&gt;</code></div>';
    count.textContent = '0';
    return;
  }
  count.textContent = String(recent.length);
  // Newest first
  const rows = recent.slice().reverse().map(r => {
    const exitCls = (r.exit === 0) ? 'exit-ok' : 'exit-bad';
    const exitTxt = (r.exit === 0) ? '✓' : ('✗' + r.exit);
    const tokens = (r.tokens_in != null || r.tokens_out != null)
      ? `${r.tokens_in || 0}→${r.tokens_out || 0}` : '-';
    const lat = (r.latency_s != null) ? r.latency_s.toFixed(2) + 's' : '-';
    const out = r.output_preview || (r.error ? '⚠ ' + r.error : '');
    return `<tr>
      <td>${esc(r.started_at || '?')}</td>
      <td><b>${esc(r.task || '?')}</b></td>
      <td style="color:var(--dim);font-family:ui-monospace,monospace">${esc(shortModel(r.model))}</td>
      <td class="num">${lat}</td>
      <td class="num">${tokens}</td>
      <td class="num ${exitCls}">${exitTxt}</td>
      <td class="preview-cell" title="${esc(out)}">${esc(out)}</td>
    </tr>`;
  }).join('');
  area.innerHTML = `<table class="hist-table">
    <thead><tr>
      <th>Time</th><th>Task</th><th>Model</th><th>Latency</th><th>Tokens (in→out)</th><th>Exit</th><th>Output</th>
    </tr></thead>
    <tbody>${rows}</tbody>
  </table>`;
}

function renderModels(omlx, usage) {
  const area = $('models-area');
  const meta = $('models-meta');
  if (!omlx || !omlx.models) {
    area.innerHTML = '<div class="empty">omlx not reachable from gateii — check OMLX_URL in .env</div>';
    meta.textContent = 'omlx unreachable';
    return;
  }
  usage = usage || {};
  const totalBytes = omlx.current_model_memory || 0;
  const maxBytes   = omlx.max_model_memory     || 0;
  const totalGB = (totalBytes / (1024**3)).toFixed(1);
  const maxGB   = maxBytes ? (maxBytes / (1024**3)).toFixed(1) : '?';
  const fillPct = maxBytes ? Math.round(totalBytes / maxBytes * 100) : 0;
  // Warning levels: > 80% = orange, > 95% = red. omlx evicts LRU under
  // pressure but big-model loads can still fail when heads are tight.
  let metaCls = '', warnNote = '';
  if (fillPct > 95) { metaCls = 'c-red'; warnNote = ' ⚠ near memory cap — next big load may evict siblings or fail'; }
  else if (fillPct > 80) { metaCls = 'c-yellow'; warnNote = ' ⚠ tight — consider unloading idle models'; }
  meta.innerHTML = `<span class="${metaCls}">${omlx.loaded_count || 0}/${omlx.model_count || 0} loaded · ${totalGB}/${maxGB} GB (${fillPct}%)${esc(warnNote)}</span>`;

  // Sort: loaded first (last_access desc), then unloaded by id
  const models = (omlx.models || []).slice().sort((a, b) => {
    if (a.loaded !== b.loaded) return a.loaded ? -1 : 1;
    if (a.loaded) return (b.last_access || 0) - (a.last_access || 0);
    return a.id.localeCompare(b.id);
  });

  area.innerHTML = `<div class="model-grid">${models.map(m => {
    const sizeGB = (m.estimated_size / (1024**3)).toFixed(1);
    const ctx = m.max_context_window ? (m.max_context_window/1000).toFixed(0)+'k' : '?';
    const thinking = m.thinking_default ? 'on by default' : 'off by default';
    const lastAccess = m.last_access ? relTime(m.last_access) : '—';
    const cls = m.loaded ? 'model-card loaded' : 'model-card';
    const badge = m.loaded
        ? '<span class="badge badge-loaded">loaded</span>'
        : '<span class="badge badge-idle">idle</span>';
    const action = m.loaded
        ? `<button class="btn btn-blue model-act" data-model="${esc(m.id)}" data-action="unload" style="font-size:10px;padding:2px 8px">unload</button>`
        : `<button class="btn btn-blue model-act" data-model="${esc(m.id)}" data-action="load"   style="font-size:10px;padding:2px 8px">load</button>`;
    // Idle-unload UI — checkbox + dropdown. Per-model TTL stored in
    // data/agents/idle-config.json by compose-ctl. Off by default.
    const idleRule = (window._idleConfig && window._idleConfig.models && window._idleConfig.models[m.id]) || {};
    const idleEnabled = idleRule.enabled !== false && (idleRule.ttl_seconds || 0) > 0;
    const idleSel = idleRule.ttl_seconds || 0;
    const idleControls = `
      <div style="margin-top:6px;display:flex;align-items:center;gap:6px;font-size:11px">
        <label style="display:flex;align-items:center;gap:4px;cursor:pointer">
          <input type="checkbox" class="idle-toggle" data-model="${esc(m.id)}" ${idleEnabled ? 'checked' : ''}>
          <span title="When enabled, compose-ctl unloads this model after the selected idle period (last_access from omlx)">auto-unload after</span>
        </label>
        <select class="idle-ttl" data-model="${esc(m.id)}" style="font-size:11px;padding:1px 4px">
          <option value="300"  ${idleSel===300 ?'selected':''}>5 min</option>
          <option value="600"  ${idleSel===600 ?'selected':''}>10 min</option>
          <option value="900"  ${idleSel===900 ?'selected':''}>15 min</option>
          <option value="1800" ${idleSel===1800?'selected':''}>30 min</option>
          <option value="3600" ${idleSel===3600?'selected':''}>1 hour</option>
        </select>
      </div>`;
    // Lifetime usage stats from log.jsonl. Distinct from the Bench matrix
    // below: "ok %" = wrapper calls that exited 0 (curl + omlx both happy);
    // bench pass-rate = format-compliance of the model's output against a
    // per-task regex. Different signals, both useful, hence different labels.
    const u = usage[m.id];
    let usageRows = '';
    if (u && u.runs > 0) {
      const okPct = Math.round(u.pass_rate * 100);
      const okCls = okPct === 100 ? 'c-green' : (okPct >= 70 ? '' : 'c-red');
      usageRows =
        `<b>wrapper runs</b><span>${u.runs}</span>` +
        `<b>avg latency</b><span>${u.latency_avg.toFixed(2)}s</span>` +
        `<b title="Fraction of wrapper invocations that exited 0 — separate from the bench format-compliance pass-rate shown in the matrix below.">ok %</b><span class="${okCls}">${okPct}%</span>` +
        (u.last_used_at ? `<b>last run</b><span>${esc(u.last_used_at)}</span>` : '');
    } else {
      usageRows = '<b>wrapper runs</b><span style="opacity:.5">never used (yet)</span>';
    }
    return `<div class="${cls}">
      <div class="id">${esc(m.id)} ${badge}</div>
      <div class="gb">${sizeGB} GB · ${esc(m.config_model_type || '?')} · ctx ${ctx}</div>
      <div class="meta">
        <b>thinking</b><span>${thinking}</span>
        <b>last call</b><span>${lastAccess}</span>
        ${usageRows}
      </div>
      ${idleControls}
      <div style="margin-top:8px;text-align:right">${action}</div>
    </div>`;
  }).join('')}</div>`;
}

function renderBench(bench) {
  const area = $('bench-area');
  const meta = $('bench-meta');
  if (!bench || !bench.matrix) {
    area.innerHTML = '<div class="empty">no bench data — run <code>scripts/agent-bench</code></div>';
    meta.textContent = 'no bench yet';
    return;
  }
  meta.textContent = `${bench.tasks.length} tasks × ${bench.models.length} models · ${bench.trials_per_cell || '?'} trials each · ${bench.generated_at || ''}`;

  // Build matrix: rows = tasks, cols = models. Each cell shows pass% + p50.
  const headers = bench.models.map(m => `<th title="${esc(m)}">${esc(shortModel(m))}</th>`).join('');
  const rows = bench.tasks.map(task => {
    // Find best (highest pass, then lowest latency) for "winner mark"
    let best = null;
    bench.models.forEach(m => {
      const c = bench.matrix[task + '|' + m];
      if (!c) return;
      if (!best || c.pass_rate > best.pass_rate ||
          (c.pass_rate === best.pass_rate && c.latency_p50 < best.latency_p50)) {
        best = { model: m, ...c };
      }
    });
    const cells = bench.models.map(m => {
      const c = bench.matrix[task + '|' + m];
      if (!c) return '<td class="cell-empty">—</td>';
      const pct = Math.round(c.pass_rate * 100);
      const cls = pct === 100 ? 'cell-pass-100' : (pct > 0 ? 'cell-pass-mid' : 'cell-pass-0');
      const winner = (best && best.model === m) ? '<span class="winner-mark" title="winner"></span>' : '';
      return `<td class="${cls}">${winner}<span class="pct">${pct}%</span><span class="lat">${c.latency_p50.toFixed(2)}s</span></td>`;
    }).join('');
    return `<tr><td class="task-name">${esc(task)}</td>${cells}</tr>`;
  }).join('');

  area.innerHTML = `<table class="bench-matrix">
    <thead><tr><th class="task-name">Task</th>${headers}</tr></thead>
    <tbody>${rows}</tbody>
  </table>
  <div style="font-size:10px;color:var(--dim);margin-top:8px">
    Cell = pass-rate (top) + median latency (bottom). Green = 100%, yellow = partial, red = failed.
    Dot = winner per row (highest pass, ties broken by latency).
  </div>`;
}

function renderRouting(routing) {
  const area = $('routing-area');
  const meta = $('routing-meta');
  if (!routing || !routing.routes) {
    area.innerHTML = '<div class="empty">routing not yet generated — run <code>scripts/agent-bench</code></div>';
    meta.textContent = 'no routing.json yet';
    return;
  }
  meta.textContent = `generated ${routing.generated_at || '?'} · default ${shortModel(routing.default_model)}`;
  const tasks = Object.keys(routing.routes).sort();
  area.innerHTML = tasks.map(t => {
    const r = routing.routes[t];
    const passPct = Math.round((r.pass_rate || 0) * 100);
    const passCls = passPct === 100 ? '' : (passPct >= 50 ? 'partial' : 'fail');
    return `<div class="routing-row">
      <span class="task">${esc(t)}</span>
      <span class="model">${esc(shortModel(r.model))} <span style="opacity:.6">· max ${r.max_tokens || '?'}t · p50 ${(r.latency_p50 || 0).toFixed(2)}s</span></span>
      <span class="pass ${passCls}">${passPct}%</span>
    </div>`;
  }).join('');
}

// Epoch-guard: every poll bumps the counter. After awaits we check we're
// still the latest generation — a late response from a previous poll won't
// overwrite a fresher one. Cheap fix for the "stacked requests arrive out
// of order" failure mode without having to thread AbortControllers through
// every fetch.
let _pollEpoch = 0;
async function pollAgents() {
  const myEpoch = ++_pollEpoch;
  try {
    const r = await fetch('/internal/admin/agents');
    if (myEpoch !== _pollEpoch) return;   // newer poll already in flight
    if (!r.ok) throw new Error('HTTP ' + r.status);
    const data = await r.json();
    if (myEpoch !== _pollEpoch) return;
    window._lastAgentsData = data;   // exposed for unloadAll() / debug
    // Active card has a live elapsed counter — render every tick.
    renderActive(data.active);
    // Other sections: skip the render if the underlying payload is byte-
    // identical to the last render. Avoids tearing down hover/focus and
    // snapping open <select> dropdowns shut every 2 s.
    if (_changed('history', data.recent || []))
      renderHistory(data.recent || []);
    if (_changed('models', { o: data.omlx_status, u: data.usage, c: window._idleConfig }))
      renderModels(data.omlx_status, data.usage);
    if (_changed('bench', data.bench))
      renderBench(data.bench);
    if (_changed('routing', data.routing))
      renderRouting(data.routing);
    const pill = $('status-pill'), txt = $('status-text');
    if (pill && txt) {
      pill.classList.remove('offline');
      pill.classList.add('online');
      txt.textContent = 'live';
    }
    $('last-refresh').textContent = new Date().toLocaleTimeString();
  } catch (err) {
    if (myEpoch !== _pollEpoch) return;
    const pill = $('status-pill'), txt = $('status-text');
    if (pill && txt) {
      pill.classList.remove('online');
      pill.classList.add('offline');
      txt.textContent = 'reconnecting...';
    }
  }
}

async function loadIdleConfig() {
  try {
    const r = await fetch('/internal/admin/agents/idle-config');
    if (r.ok) window._idleConfig = await r.json();
  } catch {}
}

async function saveIdleConfig() {
  // Build the full models map from the current DOM snapshot (every visible
  // checkbox + select). Sending the full picture is simpler than incremental
  // patching and matches the PUT-replaces-state contract.
  const models = {};
  document.querySelectorAll('.idle-toggle').forEach(cb => {
    const id = cb.dataset.model;
    const ttlEl = document.querySelector(`select.idle-ttl[data-model="${id}"]`);
    const ttl = ttlEl ? parseInt(ttlEl.value, 10) : 0;
    models[id] = { enabled: cb.checked, ttl_seconds: ttl };
  });
  try {
    const r = await fetch('/internal/admin/agents/idle-config', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ models, default_ttl_seconds: 0 }),
    });
    if (r.ok) {
      window._idleConfig = await r.json();
      toast('idle-unload config saved');
    } else {
      const d = await r.json().catch(() => ({}));
      toast(d.error || `save failed (HTTP ${r.status})`, true);
    }
  } catch (err) { toast('save error: ' + err.message, true); }
}

async function initAgents() {
  // Wait for the URL-token login (if any) to finish so the first poll
  // doesn't race against an in-flight initial auth.
  await window._initialAuth;
  loadIdleConfig().then(() => pollAgents());
  pausableInterval(pollAgents, POLL_MS);
  const area = $('models-area');
  if (area) {
    // Click handler for load/unload buttons
    area.addEventListener('click', e => {
      const btn = e.target.closest('button.model-act');
      if (!btn) return;
      const model = btn.dataset.model;
      const action = btn.dataset.action;
      if (action === 'unload') unloadModel(btn, model);
      else if (action === 'load') loadModel(btn, model);
    });
    // Change handler for idle-config checkbox + dropdown
    area.addEventListener('change', e => {
      if (e.target.classList.contains('idle-toggle') ||
          e.target.classList.contains('idle-ttl')) {
        saveIdleConfig();
      }
    });
  }
  $('btn-unload-all')?.addEventListener('click', unloadAll);
  $('btn-rerun-bench')?.addEventListener('click', e => rerunBench(e.currentTarget, false));
  $('btn-rerun-bench-force')?.addEventListener('click', e => rerunBench(e.currentTarget, true));
}
