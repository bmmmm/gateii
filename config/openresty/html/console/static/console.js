// console.js: shared utilities used by overview and compare pages.
// Loaded as a regular <script> with src= — no CSP nonce needed (only inline
// scripts get nonced; src= scripts pass via the same-origin allowance).

const $ = id => document.getElementById(id);
const esc = s => String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');

// Fetch wrapper: credentials:include for cookie-based admin auth, 10s timeout,
// auto-prompt-for-token on 401 (via in-page modal — replaces the old
// blocking prompt() that broke headless flows and looked unstyled).
//
// Also exposes `window._initialAuth` — a promise that resolves once the
// `?token=…` URL-param login (if any) has finished. Each page's init*()
// awaits this before kicking off polling, so we never race a first fetch
// against an in-flight initial login.
(() => {
  // --- Login modal ---------------------------------------------------------
  function _ensureAuthModal() {
    if (document.getElementById('auth-overlay')) return;
    const overlay = document.createElement('div');
    overlay.id = 'auth-overlay';
    overlay.className = 'diag-overlay';
    overlay.innerHTML = `<div class="diag-modal" style="max-width:420px" onclick="event.stopPropagation()">
      <div class="diag-head"><h3>Admin Login</h3></div>
      <div class="diag-body" style="padding:14px 16px">
        <p style="margin-bottom:10px;font-size:13px;color:var(--dim)">Admin token required for this console.</p>
        <input type="password" id="auth-token-input" class="input" style="width:100%" autocomplete="off" placeholder="paste ADMIN_TOKEN…">
        <p id="auth-error" style="color:var(--err);font-size:12px;min-height:1.4em;margin-top:6px"></p>
        <div style="display:flex;gap:8px;justify-content:flex-end;margin-top:6px">
          <button class="btn btn-danger" id="auth-cancel">Cancel</button>
          <button class="btn btn-primary" id="auth-submit">Login</button>
        </div>
      </div>
    </div>`;
    document.body.appendChild(overlay);
  }

  function _showAuthModal() {
    _ensureAuthModal();
    return new Promise(resolve => {
      const overlay = document.getElementById('auth-overlay');
      const input = document.getElementById('auth-token-input');
      const errEl = document.getElementById('auth-error');
      const submitBtn = document.getElementById('auth-submit');
      const cancelBtn = document.getElementById('auth-cancel');
      errEl.textContent = '';
      input.value = '';
      overlay.classList.add('show');
      // Defer focus until after the layout settles so the field accepts input
      setTimeout(() => input.focus(), 50);
      const cleanup = () => {
        overlay.classList.remove('show');
        submitBtn.onclick = cancelBtn.onclick = null;
        input.onkeydown = null;
      };
      const submit = () => {
        const v = input.value.trim();
        if (!v) { errEl.textContent = 'Token cannot be empty'; return; }
        cleanup(); resolve(v);
      };
      const cancel = () => { cleanup(); resolve(null); };
      submitBtn.onclick = submit;
      cancelBtn.onclick = cancel;
      input.onkeydown = e => {
        if (e.key === 'Enter') submit();
        if (e.key === 'Escape') cancel();
      };
    });
  }

  // Coalesce concurrent 401s onto a single in-flight login attempt so we
  // don't pop up four overlapping modals when four polls fail simultaneously.
  let _loginPromise = null;
  async function _doLogin() {
    if (_loginPromise) return _loginPromise;
    _loginPromise = (async () => {
      try {
        const token = await _showAuthModal();
        if (!token) return false;
        const r = await window._rawFetch('/internal/admin/login', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ token }),
          credentials: 'include',
        });
        if (!r.ok) {
          if (typeof toast === 'function') toast('Login failed — check token', true);
          return false;
        }
        return true;
      } catch (e) {
        if (typeof toast === 'function') toast('Login error: ' + e.message, true);
        return false;
      } finally {
        _loginPromise = null;
      }
    })();
    return _loginPromise;
  }

  // --- Fetch wrapper -------------------------------------------------------
  window._rawFetch = window.fetch.bind(window);
  window.fetch = (url, opts) => {
    opts = opts || {};
    const merged = { credentials: 'include', ...opts };
    if (merged.headers) {
      delete merged.headers['X-Admin-Token'];
      delete merged.headers['x-admin-token'];
    }
    if (!merged.signal && typeof AbortSignal !== 'undefined' && AbortSignal.timeout) {
      merged.signal = AbortSignal.timeout(10000);
    }
    return window._rawFetch(url, merged).then(async r => {
      if (r.status === 401 && typeof url === 'string' && !url.includes('/login')) {
        await _doLogin();
        return window._rawFetch(url, merged);
      }
      return r;
    }).catch(err => {
      if (err && err.name === 'AbortError') {
        throw new Error('Request timed out after 10s — check proxy/network');
      }
      throw err;
    });
  };

  // --- Initial auth (URL-param flow) --------------------------------------
  // Resolves to true on a successful URL-token login, false otherwise.
  // Pages await this in their init*() before any first fetch so we never
  // 401 into a modal while a valid URL-token is still mid-flight.
  window._initialAuth = (async () => {
    const urlToken = new URLSearchParams(window.location.search).get('token');
    if (!urlToken) return false;
    try {
      const r = await window._rawFetch('/internal/admin/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ token: urlToken }),
        credentials: 'include',
      });
      if (r.ok) {
        // Strip the token from the URL so it doesn't persist in history
        const url = new URL(window.location.href);
        url.searchParams.delete('token');
        window.history.replaceState({}, '', url.toString());
        return true;
      }
      if (typeof toast === 'function') toast('URL token rejected by server', true);
      return false;
    } catch (e) {
      if (typeof toast === 'function') toast('Initial auth failed: ' + e.message, true);
      return false;
    }
  })();
})();

function toast(msg, isError) {
  const t = $('toast');
  if (!t) return;
  t.textContent = msg;
  t.className = 'toast show' + (isError ? ' error' : '');
  clearTimeout(t._tid);
  t._tid = setTimeout(() => t.className = 'toast', 3000);
}

// Shared tab navigation — single source of truth so adding/renaming a
// tab is a one-line change instead of four. Each page mounts an empty
// <nav class="tabs" id="tabs-mount" data-active="overview"></nav> and
// console.js renderTabs() fills it. Active tab comes from data-active.
const _TAB_HTML = `
    <a href="/console/" class="tab" data-tab="overview">Overview</a>
    <a href="/console/compare" class="tab" data-tab="compare">Compare</a>
    <a href="/console/git" class="tab" data-tab="git">Git</a>
    <a href="/console/agents" class="tab" data-tab="agents">Agents</a>
    <span class="ext">
      <a href="http://localhost:3001/d/gateii-cost" target="_blank">Cost</a>
      <a href="http://localhost:3001/d/gateii-eff" target="_blank">Efficiency</a>
      <a href="http://localhost:3001/d/gateii-ops" target="_blank">Ops</a>
      <a href="http://localhost:9090" target="_blank">Prometheus</a>
      <a href="/metrics" target="_blank">Raw</a>
      <button class="btn btn-blue" id="btn-diag" style="padding:4px 10px;font-size:11px">Diagnostics</button>
      <span class="mode-tag">Mode: <b id="mode-display">-</b></span>
    </span>`;

function renderTabs() {
  const mount = document.getElementById('tabs-mount');
  if (!mount) return;
  mount.innerHTML = _TAB_HTML;
  const active = mount.dataset.active;
  if (active) {
    const tab = mount.querySelector(`[data-tab="${active}"]`);
    if (tab) tab.classList.add('active');
  }
}

// setInterval replacement that pauses while the tab is hidden and fires
// once on resume (so a returning user sees fresh data immediately, not
// after another full interval). Replaces raw setInterval in all four
// page scripts — saves background-tab fetches without changing the
// foreground feel.
function pausableInterval(fn, ms) {
  let timer = null;
  const start = () => {
    if (timer != null) return;
    timer = setInterval(fn, ms);
  };
  const stop = () => {
    if (timer == null) return;
    clearInterval(timer); timer = null;
  };
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      stop();
    } else {
      // Catch up immediately on resume, then resume the cadence
      try { fn(); } catch (e) { console.warn('pausableInterval fn threw:', e); }
      start();
    }
  });
  start();
  return { stop, start };
}

// Wraps an async action so the triggering button (or any element with
// `aria-busy` capability) is disabled for the duration. Prevents
// double-submit on rapid clicks. Pass either a button element or an event
// (the helper picks the closest <button>). Restores `disabled` to its
// pre-busy value, not unconditionally — buttons that were already disabled
// by other logic stay disabled.
async function withBusy(btn, fn) {
  const el = btn && btn.tagName ? btn : (btn && btn.currentTarget) || null;
  const wasDisabled = el ? el.disabled : false;
  if (el) el.disabled = true;
  try { return await fn(); }
  finally { if (el && !wasDisabled) el.disabled = false; }
}

function fmt(n) {
  if (n >= 1e6) return (n / 1e6).toFixed(1) + 'M';
  if (n >= 1e3) return (n / 1e3).toFixed(1) + 'K';
  return Math.round(n).toString();
}

function fmtUSD(n) {
  if (n >= 1) return '$' + n.toFixed(2);
  if (n >= 0.01) return '$' + n.toFixed(3);
  return '$' + n.toFixed(4);
}

function fmtDuration(seconds) {
  if (seconds == null || isNaN(seconds) || seconds < 0) return '-';
  if (seconds < 60) return Math.round(seconds) + 's';
  if (seconds < 3600) return Math.round(seconds / 60) + 'm';
  if (seconds < 86400) {
    const h = Math.floor(seconds / 3600);
    const m = Math.round((seconds % 3600) / 60);
    return m > 0 ? `${h}h${m}m` : `${h}h`;
  }
  const d = Math.floor(seconds / 86400);
  const h = Math.round((seconds % 86400) / 3600);
  return h > 0 ? `${d}d${h}h` : `${d}d`;
}

function setVal(id, val, prevMap, key) {
  const el = $(id);
  if (!el) return;
  const previous = prevMap?.[key];
  el.textContent = val;
  if (previous !== undefined && previous !== val) {
    el.classList.add('flash');
    el.addEventListener('animationend', () => el.classList.remove('flash'), { once: true });
  }
  if (prevMap) prevMap[key] = val;
}

function threshold(el, val, y, r) {
  if (!el) return;
  const hadFlash = el.classList.contains('flash');
  el.className = 'stat-val ' + (val >= r ? 'c-red' : val >= y ? 'c-yellow' : 'c-green');
  if (hadFlash) el.classList.add('flash');
}

function parseMetrics(text) {
  try {
    const m = {};
    for (const line of text.split('\n')) {
      if (line.startsWith('#') || !line.trim()) continue;
      const match = line.match(/^(\w+)\{([^}]*)\}\s+(.+)$/);
      if (match) {
        const [, name, labels, value] = match;
        if (!m[name]) m[name] = [];
        const lo = {};
        labels.split(',').forEach(l => {
          const eq = l.indexOf('=');
          if (eq > 0) lo[l.slice(0, eq)] = l.slice(eq + 1).replace(/"/g, '');
        });
        m[name].push({ l: lo, v: parseFloat(value) });
      } else {
        // Bare metric (no labels): name value
        const bare = line.match(/^(\w+)\s+(.+)$/);
        if (bare) {
          if (!m[bare[1]]) m[bare[1]] = [];
          m[bare[1]].push({ l: {}, v: parseFloat(bare[2]) });
        }
      }
    }
    return m;
  } catch (err) {
    console.warn('parseMetrics failed:', err);
    return {};
  }
}

let _promAvailable = null;
async function promScalar(expr) {
  try {
    const r = await fetch(`/internal/prometheus/api/v1/query?query=${encodeURIComponent(expr)}`);
    if (!r.ok) { _promAvailable = false; return null; }
    const data = await r.json();
    if (data.status !== 'success' || !data.data.result.length) return null;
    _promAvailable = true;
    return parseFloat(data.data.result[0].value[1]) || 0;
  } catch (e) { _promAvailable = false; return null; }
}

async function promVector(expr) {
  try {
    const r = await fetch(`/internal/prometheus/api/v1/query?query=${encodeURIComponent(expr)}`);
    if (!r.ok) { _promAvailable = false; return null; }
    const data = await r.json();
    if (data.status !== 'success') { _promAvailable = false; return null; }
    _promAvailable = true;
    return data.data.result.map(r => ({ labels: r.metric, value: parseFloat(r.value[1]) || 0 }));
  } catch (e) { _promAvailable = false; return null; }
}

function isPromAvailable() { return _promAvailable; }

// Diagnostics modal — wired by initDiagnostics() (called from each page).
// Fetches /internal/admin/diagnostics, shows pretty-printed JSON, offers
// "Copy" so the operator can paste it into a chat / bug report without
// clipboard juggling. Closes on Esc or backdrop click.
async function showDiagnostics() {
  const overlay = $('diag-overlay');
  const body = $('diag-body');
  if (!overlay || !body) return;
  body.innerHTML = '<pre>fetching diagnostics…</pre>';
  overlay.classList.add('show');
  try {
    const r = await fetch('/internal/admin/diagnostics');
    const text = await r.text();
    let pretty;
    try { pretty = JSON.stringify(JSON.parse(text), null, 2); }
    catch (_) { pretty = text; }
    body.innerHTML = `<pre>${esc(pretty)}</pre>`;
    body._raw = pretty;  // for copy
  } catch (e) {
    body.innerHTML = `<pre class="err">fetch failed: ${esc(e.message)}</pre>`;
  }
}

function closeDiagnostics() {
  $('diag-overlay')?.classList.remove('show');
}

async function copyDiagnostics() {
  const text = $('diag-body')?._raw;
  if (!text) return;
  try {
    await navigator.clipboard.writeText(text);
    toast('Copied to clipboard');
  } catch (e) {
    toast('Copy failed — select the text manually', true);
  }
}

function initDiagnostics() {
  // Inject the modal markup once (every page includes console.js, so we
  // guard against double-injection).
  if ($('diag-overlay')) return;
  const overlay = document.createElement('div');
  overlay.id = 'diag-overlay';
  overlay.className = 'diag-overlay';
  overlay.innerHTML = `
    <div class="diag-modal" onclick="event.stopPropagation()">
      <div class="diag-head">
        <h3>Diagnostics</h3>
        <div class="diag-actions">
          <button class="btn btn-blue" id="diag-copy">Copy</button>
          <button class="btn btn-primary" id="diag-refresh">Refresh</button>
          <button class="btn btn-danger" id="diag-close">Close</button>
        </div>
      </div>
      <div class="diag-body" id="diag-body"><pre>—</pre></div>
    </div>`;
  overlay.addEventListener('click', closeDiagnostics);  // backdrop click
  document.body.appendChild(overlay);
  $('diag-copy').addEventListener('click', copyDiagnostics);
  $('diag-refresh').addEventListener('click', showDiagnostics);
  $('diag-close').addEventListener('click', closeDiagnostics);
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape') closeDiagnostics();
  });
  // Wire the trigger button on the page (each page renders one with id="btn-diag")
  $('btn-diag')?.addEventListener('click', showDiagnostics);
}

// Shared header refresh: online/offline pill + mode-display tag.
// Used by every page's refresh() so the per-page logic only owns its own
// section. Returns the parsed overview object (or null on failure) so the
// caller can chain off it without an extra fetch.
async function refreshHeader() {
  try {
    const h = await fetch('/health').then(r => r.ok);
    $('status-pill').className = h ? 'status-pill online' : 'status-pill offline';
    $('status-text').textContent = h ? 'online' : 'offline';
  } catch (e) {
    $('status-pill').className = 'status-pill offline';
    $('status-text').textContent = 'error: ' + e.message;
  }
  let ov = null;
  try {
    ov = await fetch('/internal/admin/overview').then(r => r.json());
    if ($('mode-display')) {
      $('mode-display').textContent = (ov.proxy_mode || '?').toUpperCase()
        + (ov.passthrough_user ? ' (' + ov.passthrough_user + ')' : '');
    }
  } catch (e) { /* mode-display stays at last value */ }
  return ov;
}
