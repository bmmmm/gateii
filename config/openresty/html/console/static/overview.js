// overview.js: page-specific logic for the console overview.
// Depends on console.js for shared utilities ($, fetch wrapper, fmt, promScalar, …).

const _prev = {};
let _currentWindow = '30d';

// --- Component health chip row ---
async function loadHealth() {
  const bar = $('health-bar');
  if (!bar) return;
  try {
    const data = await fetch('/internal/admin/health').then(r => r.json());
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
  const latStr = lat > 0 ? lat + 'ms' : '-';
  setVal('s-latency', latStr, _prev, 'lat');

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

// --- Plugins, Keys, Users / Limits / Block ---
async function loadOverview() {
  const ov = await fetch('/internal/admin/overview').then(r => r.json());
  $('mode-display').textContent = ov.proxy_mode.toUpperCase()
    + (ov.passthrough_user ? ' (' + ov.passthrough_user + ')' : '');

  // Plugins
  const plugs = ov.plugins || {};
  const pluginEntries = [
    { name: 'console', desc: 'Admin web console', active: plugs.console },
    { name: 'git-tracking', desc: 'Git activity tracking', active: plugs.git_tracking },
  ];
  $('plugins-body').innerHTML = pluginEntries.map(p =>
    `<div style="display:flex;justify-content:space-between;align-items:center;padding:4px 0">
      <span>${p.name} <span style="color:var(--dim);font-size:12px;margin-left:6px">${p.desc}</span></span>
      <span class="badge ${p.active ? 'badge-on' : 'badge-off'}">${p.active ? 'ACTIVE' : 'INACTIVE'}</span>
    </div>`
  ).join('');

  // Keys panel — only visible in apikey mode
  const keysPanel = $('keys-panel');
  if (ov.proxy_mode === 'passthrough') {
    keysPanel.style.display = 'none';
  } else {
    keysPanel.style.display = '';
    try {
      const keys = await fetch('/internal/admin/keys').then(r => r.json());
      $('key-count').textContent = keys.count;
      if (keys.count === 0) {
        $('keys-body').innerHTML = '<div class="empty">no keys — use form below</div>';
      } else {
        $('keys-body').innerHTML = '<table><tr><th>Key</th><th>User</th></tr>' +
          keys.keys.map(k => `<tr><td class="key-masked">${esc(k.key)}</td><td class="key-user">${esc(k.user)}</td></tr>`).join('') +
          '</table>';
      }
    } catch (e) {
      $('keys-body').innerHTML = '<div class="empty">load failed</div>';
    }
  }

  return ov;
}

async function loadUsers() {
  // Active usage per user (with progress bars where limits are set)
  const usageList = await fetch('/internal/admin/usage-all').then(r => r.json()).catch(() => []);
  const status = await fetch('/internal/admin/status').then(r => r.json()).catch(() => ({ blocked: [], limits: [] }));

  const blockedList = Array.isArray(status.blocked) ? status.blocked : [];
  const limitsList = Array.isArray(status.limits) ? status.limits : [];

  const totalManaged = (usageList?.length || 0) + blockedList.length + limitsList.length;
  $('users-count').textContent = totalManaged;

  const barsEl = $('usage-bars');
  if (Array.isArray(usageList) && usageList.length > 0) {
    barsEl.innerHTML = usageList.map(u => {
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

  // Blocked + persistent custom limits below active users
  const managedEl = $('managed-body');
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

// --- Admin actions ---
async function unblock(user) {
  try {
    await fetch('/internal/admin/unblock?user=' + encodeURIComponent(user), { method: 'POST' });
    toast('Unblocked ' + user); refresh();
  } catch (e) { toast('Failed: ' + e.message, true); }
}

async function blockUser() {
  const user = $('block-user').value.trim();
  const ttl = $('block-ttl').value;
  if (!user || !/^[a-zA-Z0-9_-]+$/.test(user)) return toast('Invalid username', true);
  try {
    const r = await fetch(`/internal/admin/block?user=${encodeURIComponent(user)}&ttl=${ttl}`, { method: 'POST' });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    toast('Blocked ' + user); $('block-user').value = ''; refresh();
  } catch (e) { toast('Failed: ' + e.message, true); }
}

function getPresetVal(presetId, customId) {
  const sel = $(presetId).value;
  if (sel === '') return null;
  if (sel === 'custom') return parseInt($(customId).value) || 0;
  return parseInt(sel);
}

function toggleCustom(type) {
  if (type === 'tok') {
    $('limit-tokens-custom').style.display = $('limit-tokens-preset').value === 'custom' ? 'inline-block' : 'none';
  } else {
    $('limit-requests-custom').style.display = $('limit-requests-preset').value === 'custom' ? 'inline-block' : 'none';
  }
}

async function setLimit() {
  const user = $('limit-user').value.trim();
  const tokPerDay = getPresetVal('limit-tokens-preset', 'limit-tokens-custom');
  const reqPerDay = getPresetVal('limit-requests-preset', 'limit-requests-custom');
  if (!user || !/^[a-zA-Z0-9_-]+$/.test(user)) return toast('Invalid username', true);
  if (tokPerDay === null && reqPerDay === null) return toast('Select at least one limit', true);
  const body = {};
  if (tokPerDay !== null) body.tokens_per_day = tokPerDay;
  if (reqPerDay !== null) body.requests_per_day = reqPerDay;
  try {
    const r = await fetch('/internal/admin/limit?user=' + encodeURIComponent(user), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    toast('Limit set for ' + user);
    $('limit-user').value = '';
    $('limit-tokens-preset').value = ''; $('limit-requests-preset').value = '';
    $('limit-tokens-custom').style.display = 'none'; $('limit-requests-custom').style.display = 'none';
    refresh();
  } catch (e) { toast('Failed: ' + e.message, true); }
}

async function removeLimit(user) {
  try {
    const r = await fetch('/internal/admin/limit?user=' + encodeURIComponent(user), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ tokens_per_day: 0, requests_per_day: 0 }),
    });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    toast('Limit removed for ' + user); refresh();
  } catch (e) { toast('Failed: ' + e.message, true); }
}

async function addKey() {
  const user = $('add-user').value.trim();
  if (!user || !/^[a-zA-Z0-9_-]+$/.test(user)) return toast('Invalid username', true);
  const key = 'sk-proxy-' + Array.from(crypto.getRandomValues(new Uint8Array(16))).map(b => b.toString(16).padStart(2,'0')).join('');
  try {
    const r = await fetch('/internal/admin/addkey?user=' + encodeURIComponent(user), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ key }),
    });
    if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || 'HTTP ' + r.status);
    toast('Key added for ' + user);
    $('add-user').value = ''; refresh();
  } catch (e) { toast('Failed: ' + e.message, true); }
}

// --- Master refresh ---
async function refresh() {
  try {
    const h = await fetch('/health').then(r => r.ok);
    $('status-pill').className = h ? 'status-pill online' : 'status-pill offline';
    $('status-text').textContent = h ? 'online' : 'offline';

    const metricsResult = await fetch('/metrics').then(r => r.text()).catch(() => '');
    const metrics = parseMetrics(metricsResult);

    await Promise.allSettled([
      loadHealth(),
      loadOverview(),
      loadStats(metrics),
      loadUsers(),
    ]);
    loadRateLimits(metrics);

    $('last-refresh').textContent = new Date().toLocaleTimeString();
  } catch (e) {
    $('status-pill').className = 'status-pill offline';
    $('status-text').textContent = 'error: ' + e.message;
  }
}

// --- Init ---
function initOverview() {
  $('window-selector').addEventListener('change', e => {
    _currentWindow = e.target.value;
    refresh();
  });
  $('limit-tokens-preset').addEventListener('change', () => toggleCustom('tok'));
  $('limit-requests-preset').addEventListener('change', () => toggleCustom('req'));
  $('btn-block').addEventListener('click', blockUser);
  $('btn-limit').addEventListener('click', setLimit);
  const btnAddKey = $('btn-add-key');
  if (btnAddKey) btnAddKey.addEventListener('click', addKey);

  // Event delegation for dynamically rendered unblock / remove-limit buttons
  $('managed-body').addEventListener('click', e => {
    const btn = e.target.closest('button[data-action]');
    if (!btn) return;
    const user = btn.dataset.user;
    if (btn.dataset.action === 'unblock') unblock(user);
    if (btn.dataset.action === 'remove-limit') removeLimit(user);
  });

  refresh();
  setInterval(refresh, 15000);
}
