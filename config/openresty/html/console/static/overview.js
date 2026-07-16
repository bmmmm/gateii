// overview.js: page-specific logic for the console overview.
// Depends on console.js for shared utilities ($, fetch wrapper, fmt, promScalar, …).

const _prev = {};
let _currentWindow = '30d';

// Per-section signature cache — same idea as agents.js. Skip the
// innerHTML-rebuild when the underlying data hasn't changed. Cuts
// flicker, preserves scroll/hover/focus inside panels.
const _sig = {};
function _changed(section, payload) {
  const next = JSON.stringify(payload);
  if (_sig[section] === next) return false;
  _sig[section] = next;
  return true;
}

// --- Component health chip row ---
async function loadHealth() {
  const bar = $('health-bar');
  if (!bar) return;
  try {
    const data = await fetch('/internal/admin/health').then(r => r.json());
    if (!_changed('health', data.components)) return;
    const labels = { proxy: 'Proxy', prometheus: 'Prometheus', grafana: 'Grafana', upstream: 'Upstream' };
    bar.innerHTML = Object.entries(labels).map(([key, label]) => {
      const c = data.components?.[key];
      if (!c) return '';
      const cls = !c.ok ? 'danger' : 'ok';
      const sub = key === 'upstream' && c.requests > 0
        ? `<span class="chip-sub">${c.errors}/${c.requests} err</span>`
        : c.latency_ms > 0 ? `<span class="chip-sub">${c.latency_ms}ms</span>` : '';
      const title = c.error ? ` title="${esc(c.error)}"` : '';
      return `<span class="chip ${cls}"${title}><span class="chip-dot"></span>${label}${sub}</span>`;
    }).join('');
  } catch (e) {
    if (_changed('health', '__err__'))
      bar.innerHTML = '<span class="chip muted"><span class="chip-dot"></span>health unavailable</span>';
  }
}

// --- Rate limit chips (5h + 7d) ---
function rlClass(util, warn, danger) {
  if (util >= danger) return 'danger';
  if (util >= warn) return 'warn';
  return 'ok';
}

function loadRateLimits(metrics) {
  const bar = $('ratelimit-bar');
  if (!bar) return;
  const get = name => {
    const arr = metrics[name];
    if (!arr || !arr.length) return null;
    return arr[0].v;
  };
  const u5 = get('gateii_rate_limit_5h_utilization');
  const r5 = get('gateii_rate_limit_seconds_until_reset');
  const u7 = get('gateii_rate_limit_7d_utilization');
  const r7 = get('gateii_rate_limit_7d_seconds_until_reset');
  const remaining = get('gateii_rate_limit_tokens_remaining');

  // Bucketize the seconds-until-reset values so a 1-tick countdown doesn't
  // re-render every poll — only meaningful changes (>= 60s) trigger redraw.
  const bucket = s => s == null ? null : Math.floor(s / 60);
  if (!_changed('ratelimit', { u5, u7, r5: bucket(r5), r7: bucket(r7), rem: remaining }))
    return;

  if (u5 == null && u7 == null) {
    bar.innerHTML = '<span class="chip muted"><span class="chip-dot"></span>rate-limit data not available</span>';
    return;
  }

  const chips = [];
  if (u5 != null) {
    const cls = rlClass(u5, 0.7, 0.9);
    const reset = r5 != null ? `resets in ${fmtDuration(r5)}` : '';
    const sub = remaining != null ? `${fmt(remaining)} tok left · ${reset}` : reset;
    chips.push(`<span class="chip ${cls}"><span class="chip-dot"></span>5h: ${(u5*100).toFixed(0)}% <span class="chip-sub">${sub}</span></span>`);
  }
  if (u7 != null) {
    const cls = rlClass(u7, 0.6, 0.85);
    const reset = r7 != null ? `resets in ${fmtDuration(r7)}` : '';
    chips.push(`<span class="chip ${cls}"><span class="chip-dot"></span>7d: ${(u7*100).toFixed(1)}% <span class="chip-sub">${reset}</span></span>`);
  }
  bar.innerHTML = chips.join('');
}

// --- Activity stats (driven by window selector) ---
async function loadStats(metrics) {
  const win = _currentWindow;
  // Try Prometheus for accurate window-based aggregation; fall back to live counter sum.
  const promResults = await Promise.allSettled([
    promScalar(`sum(increase(gateii_requests_total[${win}]))`),
    promScalar(`sum(increase(gateii_tokens_total[${win}]))`),
    promScalar(`sum(increase(gateii_cost_dollars_total[${win}]))`),
    promScalar(`sum(increase(gateii_request_duration_ms_total[${win}])) / clamp_min(sum(increase(gateii_requests_total[${win}])), 1)`),
    promScalar(`sum(increase(gateii_tokens_total{type="input"}[${win}]))`),
    promScalar(`sum(increase(gateii_tokens_total{type="output"}[${win}]))`),
    promScalar(`sum(increase(gateii_tokens_total{type="cache_read"}[${win}]))`),
    promScalar(`sum(increase(gateii_tokens_total{type="cache_creation"}[${win}]))`),
    promScalar('sum(rate(gateii_cost_dollars_total[7d])) * 86400 * 30'),
  ]);
  const [pReq, pTok, pCost, pLat, pIn, pOut, pCacheRd, pCacheWr, pMonthly] =
    promResults.map(r => r.status === 'fulfilled' ? r.value : null);

  const useProm = pReq !== null;
  let req, tok, cost, lat, inTok, outTok, cacheRd, cacheWr;
  if (useProm) {
    req = pReq; tok = pTok; cost = pCost; lat = Math.round(pLat || 0);
    inTok = pIn || 0; outTok = pOut || 0; cacheRd = pCacheRd || 0; cacheWr = pCacheWr || 0;
  } else {
    // Live fallback (sums whatever is currently in shared dict — not window-bounded)
    const sumByType = t => (metrics.gateii_tokens_total || []).filter(e => e.l.type === t).reduce((s, e) => s + e.v, 0);
    req = (metrics.gateii_requests_total || []).reduce((s, e) => s + e.v, 0);
    inTok = sumByType('input'); outTok = sumByType('output');
    cacheRd = sumByType('cache_read'); cacheWr = sumByType('cache_creation');
    tok = inTok + outTok + cacheRd + cacheWr;
    cost = (metrics.gateii_cost_dollars_total || []).reduce((s, e) => s + e.v, 0);
    const latSum = (metrics.gateii_request_duration_ms_total || []).reduce((s, e) => s + e.v, 0);
    lat = req > 0 ? Math.round(latSum / req) : 0;
  }
  const src = useProm ? 'prometheus' : 'live';

  setVal('s-req', fmt(req), _prev, 'req');
  setVal('s-tok', fmt(tok), _prev, 'tok');
  setVal('s-cost', fmtUSD(cost), _prev, 'cost');
  setVal('s-latency', fmtLatencyMs(lat), _prev, 'lat');

  // Sub-text breakdowns
  $('s-req-detail').textContent = `last ${win} · ${src}`;
  // Tokens sub: full breakdown across all 4 types so it sums to total
  $('s-tok-detail').textContent = `${fmt(inTok)} in / ${fmt(outTok)} out · cache ${fmt(cacheRd)}r/${fmt(cacheWr)}w`;
  $('s-cost-detail').textContent = `last ${win}`;
  $('s-latency-detail').textContent = req > 0 ? `${fmt(req)} req` : '';

  // Monthly forecast (always 7d-based, independent of window)
  if (pMonthly !== null) {
    setVal('s-monthly', fmtUSD(pMonthly), _prev, 'monthly');
    threshold($('s-monthly'), pMonthly, 50, 200);
  } else {
    setVal('s-monthly', '-', _prev, 'monthly');
  }

  threshold($('s-cost'), cost, 5, 20);
  threshold($('s-latency'), lat, 5000, 15000);
}

// --- Services panel (live container status + actions) ---
function serviceStateClass(state) {
  if (state === 'running')      return 'ok';
  if (state === 'restarting')   return 'warn';
  if (state === 'paused')       return 'warn';
  if (state === 'not_created')  return 'muted';
  return 'danger';  // exited / dead / created (=stopped)
}

async function loadServices() {
  const body = $('services-body');
  let data;
  try {
    const r = await fetch('/internal/admin/services');
    if (!r.ok) throw new Error('HTTP ' + r.status);
    data = await r.json();
  } catch (e) {
    if (_changed('services', '__err__:' + e.message)) {
      body.innerHTML = `<div class="empty">services unavailable — compose-ctl sidecar not reachable (${esc(e.message)})</div>`;
      $('services-count').textContent = '-';
    }
    return;
  }
  const services = data.services || [];
  // Strip out fields that flap on every poll (image SHA changes, status
  // string ticking up "Up 5 seconds → Up 7 seconds"). Only redraw on
  // service-list changes or state transitions.
  const sigInput = services.map(s => ({ s: s.service, st: s.state }));
  if (!_changed('services', sigInput)) return;
  $('services-count').textContent = services.length;
  if (services.length === 0) {
    body.innerHTML = '<div class="empty">no services found in compose project</div>';
    return;
  }
  body.innerHTML = services.map(s => {
    const cls = serviceStateClass(s.state);
    const isRunning = s.state === 'running';
    const isMissing = s.state === 'not_created';
    const status = esc(s.status || s.state || '?');
    const startStop = isRunning
      ? `<button class="btn btn-danger" data-svc="${esc(s.service)}" data-action="stop">Stop</button>`
      : `<button class="btn btn-primary" data-svc="${esc(s.service)}" data-action="start">Start</button>`;
    const restart = isRunning
      ? `<button class="btn btn-blue" data-svc="${esc(s.service)}" data-action="restart">Restart</button>`
      : '';
    const recreate = !isMissing
      ? `<button class="btn btn-blue" data-svc="${esc(s.service)}" data-action="recreate">Recreate</button>`
      : '';
    return `<div class="user-row">
      <div class="user-info">
        <span class="user-name"><span class="chip ${cls}" style="padding:2px 8px;font-size:10px;margin-right:6px"><span class="chip-dot"></span>${esc(s.state)}</span>${esc(s.service)}</span>
        <span class="user-meta">${status}${s.image ? ' · ' + esc(s.image) : ''}</span>
      </div>
      <div class="user-actions">${startStop} ${restart} ${recreate}</div>
    </div>`;
  }).join('');
}

// Wait for the proxy to come back after a self-restart, then reload the
// page. Polls /health every second up to maxWaitMs; reloads as soon as we
// see a 200. Replaces the old hardcoded 8s setTimeout — that was racy in
// both directions: too short on a slow Docker, and too long when the proxy
// was actually back in 1-2s.
async function waitForProxyAndReload(maxWaitMs = 30000) {
  const deadline = Date.now() + maxWaitMs;
  while (Date.now() < deadline) {
    await new Promise(r => setTimeout(r, 1000));
    try {
      const r = await window._rawFetch('/health', { cache: 'no-store' });
      if (r.ok) { location.reload(); return; }
    } catch { /* still down — keep polling */ }
  }
  toast('proxy did not recover within 30s — reload the page manually', true);
}

async function serviceAction(btn, service, action) {
  // Self-restart of the proxy is a special case: the request dies mid-flight.
  // The sidecar schedules it async + returns 202, we pop a confirm + poll
  // /health, reload as soon as it's back.
  const isProxySelfHit = service === 'openresty' && (action === 'restart' || action === 'recreate' || action === 'stop');
  if (isProxySelfHit) {
    const ok = confirm(`This will ${action} the proxy itself and kill your current console session. Continue?`);
    if (!ok) return;
  }
  await withBusy(btn, async () => {
    try {
      const r = await fetch(`/internal/admin/services/${encodeURIComponent(service)}/${encodeURIComponent(action)}`, { method: 'POST' });
      const result = await r.json().catch(() => ({}));
      if (r.status >= 200 && r.status < 300) {
        toast(`${action} ${service} → ${result.note || 'ok'}`);
        if (isProxySelfHit && action !== 'stop') {
          toast('proxy restarting — reloading when /health is back…');
          waitForProxyAndReload();
        } else {
          // Multi-stage refresh: docker compose may report old state for
          // a moment after restart/recreate before the new container is
          // healthy. A single 1.5s timer often caught the in-between
          // state. Three samples (immediate, 1.5s, 4s) cover a wider
          // window — _changed() in loadServices skips redundant renders.
          loadServices();
          setTimeout(loadServices, 1500);
          setTimeout(loadServices, 4000);
        }
      } else {
        toast(`${action} ${service} failed: ${result.error || 'HTTP ' + r.status}`, true);
      }
    } catch (e) {
      toast(`${action} ${service} failed: ${e.message}`, true);
    }
  });
}

// --- Plugins, Keys, Users / Limits / Block ---
// Render plugins config + keys table from a pre-fetched overview payload.
// Caller (refresh) gets `ov` from refreshHeader so we don't hit /overview twice.
async function renderPluginsAndKeys(ov) {
  if (!ov) return;
  const plugs = ov.plugins || {};
  const pluginEntries = [
    { name: 'console', desc: 'Admin web console', active: plugs.console },
    { name: 'git-tracking', desc: 'Git activity tracking', active: plugs.git_tracking },
  ];
  if (_changed('plugins', plugs)) {
    $('plugins-body').innerHTML = pluginEntries.map(p =>
      `<div style="display:flex;justify-content:space-between;align-items:center;padding:4px 0">
        <span>${p.name} <span style="color:var(--dim);font-size:12px;margin-left:6px">${p.desc}</span></span>
        <span class="badge ${p.active ? 'badge-on' : 'badge-off'}">${p.active ? 'ACTIVE' : 'INACTIVE'}</span>
      </div>`
    ).join('');
  }

  // Keys panel — only visible in apikey mode
  const keysPanel = $('keys-panel');
  if (ov.proxy_mode === 'passthrough') {
    keysPanel.style.display = 'none';
  } else {
    keysPanel.style.display = '';
    loadKeyProviders();  // fill the add-key provider dropdown (once)
    try {
      const keys = await fetch('/internal/admin/keys').then(r => r.json());
      if (_changed('keys', keys)) {
        $('key-count').textContent = keys.count;
        if (keys.count === 0) {
          $('keys-body').innerHTML = '<div class="empty">no keys — use form below</div>';
        } else {
          $('keys-body').innerHTML = '<table><tr><th>Key</th><th>User</th></tr>' +
            keys.keys.map(k => `<tr><td class="key-masked">${esc(k.key)}</td><td class="key-user">${esc(k.user)}</td></tr>`).join('') +
            '</table>';
        }
      }
    } catch (e) {
      if (_changed('keys', '__err__'))
        $('keys-body').innerHTML = '<div class="empty">load failed</div>';
    }
  }
}

async function loadUsers() {
  const [usageData, status] = await Promise.all([
    fetch('/internal/admin/usage-all').then(r => r.json()).catch(() => ({ users: [], truncated: false })),
    fetch('/internal/admin/status').then(r => r.json()).catch(() => ({ blocked: [], limits: [] })),
  ]);
  const usageList = usageData.users || [];

  const blockedList = Array.isArray(status.blocked) ? status.blocked : [];
  const limitsList = Array.isArray(status.limits) ? status.limits : [];

  // Distinct usernames across all three sources (a user can appear in
  // multiple — e.g. limited AND active — naive sum would double-count).
  const known = new Set();
  usageList.forEach(u => u?.user && known.add(u.user));
  blockedList.forEach(b => b?.user && known.add(b.user));
  limitsList.forEach(l => l?.user && known.add(l.user));
  $('users-count').textContent = known.size;
  refreshUserPickers([...known].sort());

  const barsEl = $('usage-bars');
  if (usageList.length > 0) {
    // Skip the rebuild when the usage payload hasn't moved — preserves
    // hover/scroll on the bar list during quiet windows.
    if (_changed('usage', usageList)) barsEl.innerHTML = usageList.map(u => {
      const totalTok = (u.input || 0) + (u.output || 0);
      const tokLimit = u.tokens_limit;
      const reqLimit = u.requests_limit;
      let bars = '';
      if (tokLimit && tokLimit > 0) {
        const pct = Math.min(100, Math.round(totalTok / tokLimit * 100));
        const cls = pct >= 90 ? 'danger' : pct >= 70 ? 'warn' : 'ok';
        bars += `<div class="progress-wrap">
          <span class="progress-label">Tokens</span>
          <div class="progress-bar"><div class="progress-fill ${cls}" style="width:${pct}%"></div></div>
          <span class="progress-pct">${pct}%</span>
        </div>`;
      }
      if (reqLimit && reqLimit > 0) {
        const pct = Math.min(100, Math.round((u.requests || 0) / reqLimit * 100));
        const cls = pct >= 90 ? 'danger' : pct >= 70 ? 'warn' : 'ok';
        bars += `<div class="progress-wrap">
          <span class="progress-label">Requests</span>
          <div class="progress-bar"><div class="progress-fill ${cls}" style="width:${pct}%"></div></div>
          <span class="progress-pct">${pct}%</span>
        </div>`;
      }
      const detail = `${fmt(totalTok)} tokens · ${u.requests || 0} req`
        + (tokLimit ? ` · ${fmt(tokLimit)} tok limit` : '')
        + (reqLimit ? ` · ${reqLimit} req limit` : '');
      return `<div class="usage-card">
        <div class="usage-header">
          <span class="usage-user">${esc(u.user)}</span>
          <span class="usage-detail">${detail}</span>
        </div>
        ${bars || '<div class="usage-detail">no limits set</div>'}
      </div>`;
    }).join('');
  } else {
    barsEl.innerHTML = '<div class="empty">no traffic yet</div>';
  }

  // Blocked + persistent custom limits below active users.
  // Bucket TTL to whole minutes so the BLOCKED banner doesn't re-render
  // every 15 s for a 1-second countdown drift.
  const managedSig = {
    blocked: blockedList.map(b => ({ u: b.user, m: Math.floor((b.ttl || 0) / 60) })),
    limits: limitsList,
  };
  const managedEl = $('managed-body');
  if (!_changed('managed', managedSig)) {
    // unchanged — skip rebuild
  } else {
  let html = '';
  if (blockedList.length > 0) {
    html += blockedList.map(b => {
      const ttl = fmtDuration(b.ttl);
      return `<div class="user-row">
        <div class="user-info">
          <span class="user-name">${esc(b.user)}</span>
          <span class="user-meta" style="color:var(--err)">BLOCKED — ${ttl} remaining</span>
        </div>
        <div class="user-actions">
          <button class="btn btn-primary" data-user="${esc(b.user)}" data-action="unblock">Unblock</button>
        </div>
      </div>`;
    }).join('');
  }
  if (limitsList.length > 0) {
    html += limitsList.map(l => {
      const parts = [];
      if (l.tokens_per_day) parts.push(fmt(l.tokens_per_day) + ' tok/day');
      if (l.requests_per_day) parts.push(l.requests_per_day + ' req/day');
      return `<div class="user-row">
        <div class="user-info">
          <span class="user-name">${esc(l.user)}</span>
          <span class="user-meta" style="color:var(--blue)">LIMIT: ${parts.join(', ')}</span>
        </div>
        <div class="user-actions">
          <button class="btn btn-danger" data-user="${esc(l.user)}" data-action="remove-limit">Remove</button>
        </div>
      </div>`;
    }).join('');
  }
  managedEl.innerHTML = html;
  }
}

// --- User-picker helpers ---
// Two combined controls per row: <select> for known users + a hidden <input>
// that shows up when "+ new user…" is picked. Returns the resolved username
// (trimmed) or '' if neither has a usable value.
function pickedUser(selectId, newId) {
  const sel = $(selectId);
  if (!sel) return '';
  if (sel.value === '__new__') return ($(newId)?.value || '').trim();
  return sel.value.trim();
}

function refreshUserPickers(users) {
  for (const selectId of ['block-user-select', 'limit-user-select']) {
    const sel = $(selectId);
    if (!sel) continue;
    const previous = sel.value;
    const opts = ['<option value="">-- select user --</option>'];
    for (const u of users) {
      opts.push(`<option value="${esc(u)}">${esc(u)}</option>`);
    }
    opts.push('<option value="__new__">+ new user…</option>');
    sel.innerHTML = opts.join('');
    // Restore previous selection if still valid (otherwise leave at default)
    if (previous && (users.includes(previous) || previous === '__new__')) {
      sel.value = previous;
    }
  }
}

function toggleNewUserInput(selectId, newId) {
  const sel = $(selectId);
  const inp = $(newId);
  if (!sel || !inp) return;
  const isNew = sel.value === '__new__';
  inp.style.display = isNew ? 'inline-block' : 'none';
  if (isNew) inp.focus();
  else inp.value = '';
}

// --- Admin actions ---
async function unblock(btn, user) {
  await withBusy(btn, async () => {
    try {
      await fetch('/internal/admin/unblock?user=' + encodeURIComponent(user), { method: 'POST' });
      toast('Unblocked ' + user); refresh();
    } catch (e) { toast('Failed: ' + e.message, true); }
  });
}

async function blockUser(ev) {
  const user = pickedUser('block-user-select', 'block-user-new');
  const ttl = $('block-ttl').value;
  if (!user || !/^[a-zA-Z0-9_-]+$/.test(user)) return toast('Invalid username', true);
  await withBusy(ev?.currentTarget, async () => {
    try {
      const r = await fetch(`/internal/admin/block?user=${encodeURIComponent(user)}&ttl=${ttl}`, { method: 'POST' });
      if (!r.ok) throw new Error('HTTP ' + r.status);
      toast('Blocked ' + user);
      $('block-user-new').value = '';
      $('block-user-select').value = '';
      toggleNewUserInput('block-user-select', 'block-user-new');
      refresh();
    } catch (e) { toast('Failed: ' + e.message, true); }
  });
}

function getPresetVal(presetId, customId) {
  const sel = $(presetId).value;
  if (sel === '') return null;
  if (sel === 'custom') { const n = parseInt($(customId).value); return isNaN(n) ? null : n; }
  return parseInt(sel);
}

function toggleCustom(type) {
  if (type === 'tok') {
    $('limit-tokens-custom').style.display = $('limit-tokens-preset').value === 'custom' ? 'inline-block' : 'none';
  } else {
    $('limit-requests-custom').style.display = $('limit-requests-preset').value === 'custom' ? 'inline-block' : 'none';
  }
}

async function setLimit(ev) {
  const user = pickedUser('limit-user-select', 'limit-user-new');
  const tokPerDay = getPresetVal('limit-tokens-preset', 'limit-tokens-custom');
  const reqPerDay = getPresetVal('limit-requests-preset', 'limit-requests-custom');
  if (!user || !/^[a-zA-Z0-9_-]+$/.test(user)) return toast('Invalid username', true);
  if (tokPerDay === null && reqPerDay === null) return toast('Select at least one limit', true);
  const body = {};
  if (tokPerDay !== null) body.tokens_per_day = tokPerDay;
  if (reqPerDay !== null) body.requests_per_day = reqPerDay;
  await withBusy(ev?.currentTarget, async () => {
    try {
      const r = await fetch('/internal/admin/limit?user=' + encodeURIComponent(user), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (!r.ok) throw new Error('HTTP ' + r.status);
      toast('Limit set for ' + user);
      $('limit-user-new').value = '';
      $('limit-user-select').value = '';
      toggleNewUserInput('limit-user-select', 'limit-user-new');
      $('limit-tokens-preset').value = ''; $('limit-requests-preset').value = '';
      $('limit-tokens-custom').style.display = 'none'; $('limit-requests-custom').style.display = 'none';
      refresh();
    } catch (e) { toast('Failed: ' + e.message, true); }
  });
}

async function removeLimit(btn, user) {
  await withBusy(btn, async () => {
    try {
      const r = await fetch('/internal/admin/limit?user=' + encodeURIComponent(user), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ tokens_per_day: 0, requests_per_day: 0 }),
      });
      if (!r.ok) throw new Error('HTTP ' + r.status);
      toast('Limit removed for ' + user); refresh();
    } catch (e) { toast('Failed: ' + e.message, true); }
  });
}

// Populate the provider <select> in the add-key form from providers.json.
// Runs once (guarded) when the keys panel becomes visible in apikey mode.
let _providersLoaded = false;
async function loadKeyProviders() {
  if (_providersLoaded) return;
  const sel = $('add-provider');
  if (!sel) return;
  try {
    const cfg = await fetch('/internal/admin/providers').then(r => r.json());
    const provs = (cfg && cfg.providers) || [];
    sel.innerHTML = provs
      .map(p => `<option value="${esc(p.id)}">${esc(p.name || p.id)}</option>`)
      .join('');
    _providersLoaded = provs.length > 0;
  } catch (e) { /* leave empty; addKey() guards on empty provider */ }
}

async function addKey(ev) {
  const user = $('add-user').value.trim();
  if (!user || !/^[a-zA-Z0-9_-]+$/.test(user)) return toast('Invalid username', true);
  // addkey requires all three fields — {key, provider, upstream_key}. Sending
  // only `key` (the old behaviour) always 400'd, so key creation was broken.
  const provider = ($('add-provider').value || '').trim();
  if (!provider) return toast('Pick a provider', true);
  const upstreamKey = $('add-upstream-key').value.trim();
  if (upstreamKey.length < 8) return toast('Upstream key too short (min 8 chars)', true);
  const key = 'sk-proxy-' + Array.from(crypto.getRandomValues(new Uint8Array(16))).map(b => b.toString(16).padStart(2,'0')).join('');
  await withBusy(ev?.currentTarget, async () => {
    try {
      const r = await fetch('/internal/admin/addkey?user=' + encodeURIComponent(user), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ key, provider, upstream_key: upstreamKey }),
      });
      if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || 'HTTP ' + r.status);
      toast(`Key added for ${user} — ${key}`);
      $('add-user').value = ''; $('add-upstream-key').value = ''; refresh();
    } catch (e) { toast('Failed: ' + e.message, true); }
  });
}

// --- Master refresh ---
// Epoch-guard: same idea as agents.js. Every refresh() bumps the counter;
// after each await we bail if a newer cycle has started, so a slow upstream
// response can't overwrite fresh data with stale.
let _refreshEpoch = 0;
async function refresh() {
  const myEpoch = ++_refreshEpoch;
  try {
    const [ov, metricsText] = await Promise.all([
      refreshHeader(),
      fetch('/metrics').then(r => r.text()).catch(() => ''),
    ]);
    if (myEpoch !== _refreshEpoch) return;
    const metrics = parseMetrics(metricsText);

    await Promise.allSettled([
      loadHealth(),
      renderPluginsAndKeys(ov),
      loadStats(metrics),
      loadUsers(),
      loadServices(),
    ]);
    if (myEpoch !== _refreshEpoch) return;
    loadRateLimits(metrics);

    $('last-refresh').textContent = new Date().toLocaleTimeString();
  } catch (e) {
    if (myEpoch !== _refreshEpoch) return;
    // Rate-limited: a 15-min proxy outage shouldn't fire 60 separate
    // toasts at the user — same `errorKey` within 20s is suppressed.
    toast('refresh failed: ' + e.message, true, 'overview-refresh');
  }
}

// --- Init ---
async function initOverview() {
  // Wait for the URL-token login (if any) to finish so the first refresh
  // doesn't race against an in-flight initial auth.
  await window._initialAuth;
  $('window-selector').addEventListener('change', e => {
    _currentWindow = e.target.value;
    refresh();
  });
  $('limit-tokens-preset').addEventListener('change', () => toggleCustom('tok'));
  $('limit-requests-preset').addEventListener('change', () => toggleCustom('req'));
  $('block-user-select').addEventListener('change', () => toggleNewUserInput('block-user-select', 'block-user-new'));
  $('limit-user-select').addEventListener('change', () => toggleNewUserInput('limit-user-select', 'limit-user-new'));
  $('btn-block').addEventListener('click', blockUser);
  $('btn-limit').addEventListener('click', setLimit);
  const btnAddKey = $('btn-add-key');
  if (btnAddKey) btnAddKey.addEventListener('click', addKey);

  // Event delegation for dynamically rendered unblock / remove-limit buttons
  $('managed-body').addEventListener('click', e => {
    const btn = e.target.closest('button[data-action]');
    if (!btn) return;
    const user = btn.dataset.user;
    if (btn.dataset.action === 'unblock') unblock(btn, user);
    if (btn.dataset.action === 'remove-limit') removeLimit(btn, user);
  });

  // Event delegation for service action buttons
  $('services-body').addEventListener('click', e => {
    const btn = e.target.closest('button[data-svc]');
    if (!btn) return;
    serviceAction(btn, btn.dataset.svc, btn.dataset.action);
  });

  refresh();
  pausableInterval(refresh, 15000);
}
