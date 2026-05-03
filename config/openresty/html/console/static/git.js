// git.js: per-repo git-tracking config UI.
// Loads /internal/admin/git-tracking, lets user CRUD repos, PUTs back the
// full config. Validation happens server-side; this UI just collects fields.

const PLATFORM_LABELS = {
  forgejo: 'Forgejo',
  github: 'GitHub',
  gitlab: 'GitLab',
  gitea: 'Gitea',
  codeberg: 'Codeberg',
  bitbucket: 'Bitbucket',
  local: 'Local',
  other: 'Other',
};

let _config = { default_author: '', interval: 300, repos: [] };

function platformBadge(platform) {
  if (!platform) return '';
  const label = PLATFORM_LABELS[platform] || platform;
  return `<span class="comp-vendor" title="platform">${esc(label)}</span>`;
}

function renderRepos() {
  const list = $('repos-list');
  $('repos-count').textContent = _config.repos.length;
  if (_config.repos.length === 0) {
    list.innerHTML = '<div class="empty">no repos tracked yet — add one below</div>';
    return;
  }
  list.innerHTML = _config.repos.map((r, i) => {
    const alias = r.alias || r.path.split('/').pop();
    const authorSub = r.author ? `author: ${esc(r.author)}` : '<span style="opacity:.6">default author</span>';
    return `<div class="user-row">
      <div class="user-info">
        <span class="user-name">${esc(alias)} ${platformBadge(r.platform)}</span>
        <span class="user-meta">${esc(r.path)} &middot; ${authorSub}</span>
      </div>
      <div class="user-actions">
        <button class="btn btn-danger" data-idx="${i}">Remove</button>
      </div>
    </div>`;
  }).join('');
}

async function loadConfig() {
  const data = await fetch('/internal/admin/git-tracking').then(r => r.json()).catch(() => null);
  if (!data) {
    toast('Failed to load git-tracking config', true);
    return;
  }
  _config = {
    default_author: data.default_author || '',
    interval: data.interval || 300,
    repos: Array.isArray(data.repos) ? data.repos : [],
  };
  $('default-author').value = _config.default_author;
  $('interval').value = _config.interval;
  renderRepos();
}

async function saveConfig() {
  const r = await fetch('/internal/admin/git-tracking', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(_config),
  });
  if (!r.ok) {
    const err = await r.json().catch(() => ({}));
    throw new Error(err.error || 'HTTP ' + r.status);
  }
}

async function saveSettings() {
  _config.default_author = $('default-author').value.trim();
  const intv = parseInt($('interval').value, 10);
  if (isNaN(intv) || intv < 30) return toast('Interval must be ≥ 30 seconds', true);
  _config.interval = intv;
  try {
    await saveConfig();
    toast('Settings saved');
  } catch (e) { toast('Save failed: ' + e.message, true); }
}

async function addRepo() {
  const path = $('new-path').value.trim();
  const alias = $('new-alias').value.trim();
  const author = $('new-author').value.trim();
  const platform = $('new-platform').value;
  if (!path) return toast('Path required', true);
  if (!path.startsWith('/')) return toast('Path must be absolute', true);
  if (path.includes('..')) return toast('Path must not contain ".."', true);
  if (_config.repos.some(r => r.path === path)) return toast('Path already tracked', true);
  const entry = { path };
  if (alias) entry.alias = alias;
  if (author) entry.author = author;
  if (platform) entry.platform = platform;
  _config.repos.push(entry);
  try {
    await saveConfig();
    toast('Added ' + (alias || path));
    $('new-path').value = ''; $('new-alias').value = ''; $('new-author').value = '';
    $('new-platform').value = '';
    renderRepos();
  } catch (e) {
    _config.repos.pop();
    toast('Add failed: ' + e.message, true);
  }
}

async function removeRepo(idx) {
  const removed = _config.repos[idx];
  _config.repos.splice(idx, 1);
  try {
    await saveConfig();
    toast('Removed ' + (removed.alias || removed.path));
    renderRepos();
  } catch (e) {
    _config.repos.splice(idx, 0, removed);
    toast('Remove failed: ' + e.message, true);
    renderRepos();
  }
}

async function refresh() {
  try {
    const h = await fetch('/health').then(r => r.ok);
    $('status-pill').className = h ? 'status-pill online' : 'status-pill offline';
    $('status-text').textContent = h ? 'online' : 'offline';

    const ov = await fetch('/internal/admin/overview').then(r => r.json()).catch(() => ({ proxy_mode: '?' }));
    $('mode-display').textContent = (ov.proxy_mode || '?').toUpperCase()
      + (ov.passthrough_user ? ' (' + ov.passthrough_user + ')' : '');

    await loadConfig();
    $('last-refresh').textContent = new Date().toLocaleTimeString();
  } catch (e) {
    $('status-pill').className = 'status-pill offline';
    $('status-text').textContent = 'error: ' + e.message;
  }
}

function initGit() {
  $('btn-save-settings').addEventListener('click', saveSettings);
  $('btn-add-repo').addEventListener('click', addRepo);
  $('repos-list').addEventListener('click', e => {
    const btn = e.target.closest('button[data-idx]');
    if (!btn) return;
    removeRepo(parseInt(btn.dataset.idx, 10));
  });
  refresh();
  setInterval(refresh, 30000);
}
