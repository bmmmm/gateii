// console.js: shared utilities used by overview and compare pages.
// Loaded as a regular <script> with src= — no CSP nonce needed (only inline
// scripts get nonced; src= scripts pass via the same-origin allowance).

const $ = id => document.getElementById(id);
const esc = s => String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');

// Fetch wrapper: credentials:include for cookie-based admin auth, 10s timeout,
// auto-prompt for token on 401 and retry once.
(() => {
  let _loginInProgress = false;
  async function _doLogin() {
    if (_loginInProgress) return;
    _loginInProgress = true;
    const token = prompt('Admin token required:');
    if (!token) { _loginInProgress = false; return; }
    try {
      const r = await window._rawFetch('/internal/admin/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ token }),
        credentials: 'include',
      });
      if (!r.ok) alert('Login failed — check token');
    } catch (e) {
      alert('Login error: ' + e.message);
    }
    _loginInProgress = false;
  }
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
})();

function toast(msg, isError) {
  const t = $('toast');
  if (!t) return;
  t.textContent = msg;
  t.className = 'toast show' + (isError ? ' error' : '');
  clearTimeout(t._tid);
  t._tid = setTimeout(() => t.className = 'toast', 3000);
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
