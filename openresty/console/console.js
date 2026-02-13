import { esc, getJson } from './base.js';
import { initWizard } from './wizard.js';

(() => {
  const LS_SELECTED_KEY = 'fn_console_selected_v1';
  const LS_HISTORY_KEY = 'fn_console_history_v1';
  const LS_UI_KEY = 'fn_console_ui_v1';
  const LS_INVOKE_DRAFTS_KEY = 'fn_console_invoke_drafts_v1';
  const MAX_HISTORY = 12;
  const MAX_DRAFTS = 80;
  const state = {
    catalog: null,
    packs: null,
    selected: null,
    history: [],
    invokeDrafts: {},
    ui: { search: '', routeSearch: '', activeTab: 'explorer' },
  };

  const fnListEl = document.getElementById('fnList');
  const historyListEl = document.getElementById('historyList');
  const detailsEl = document.getElementById('details');
  const codeOutEl = document.getElementById('codeOut');
  const invokeOutEl = document.getElementById('invokeOut');
  const invokeMetaEl = document.getElementById('invokeMeta');
  const cfgStatusEl = document.getElementById('cfgStatus');
  const codeStatusEl = document.getElementById('codeStatus');
  const crudStatusEl = document.getElementById('crudStatus');
  const jobsStatusEl = document.getElementById('jobsStatus');
  const uiStateStatusEl = document.getElementById('uiStateStatus');
  const metaEl = document.getElementById('meta');
  const searchEl = document.getElementById('search');
  const crudRuntimeEl = document.getElementById('crudRuntime');
  const crudNameEl = document.getElementById('crudName');
  const crudVersionEl = document.getElementById('crudVersion');
  const crudRouteEl = document.getElementById('crudRoute');

  const cfgTimeoutEl = document.getElementById('cfgTimeout');
  const cfgConcEl = document.getElementById('cfgConc');
  const cfgBodyEl = document.getElementById('cfgBody');
  const cfgGroupEl = document.getElementById('cfgGroup');
  const cfgDebugHeadersEl = document.getElementById('cfgDebugHeaders');
  const cfgSharedDepsEl = document.getElementById('cfgSharedDeps');
  const cfgRoutesEl = document.getElementById('cfgRoutes');
  const cfgMethodEls = Array.from(document.querySelectorAll('input[name="cfgMethods"]'));
  const edgeBaseUrlEl = document.getElementById('edgeBaseUrl');
  const edgeAllowHostsEl = document.getElementById('edgeAllowHosts');
  const edgeAllowPrivateEl = document.getElementById('edgeAllowPrivate');
  const edgeMaxRespEl = document.getElementById('edgeMaxResp');
  const schedEnabledEl = document.getElementById('schedEnabled');
  const schedEveryEl = document.getElementById('schedEvery');
  const schedMethodEl = document.getElementById('schedMethod');
  const schedQueryEl = document.getElementById('schedQuery');
  const schedHeadersEl = document.getElementById('schedHeaders');
  const schedBodyEl = document.getElementById('schedBody');
  const schedContextEl = document.getElementById('schedContext');
  const schedStatusEl = document.getElementById('schedStatus');
  const schedStateEl = document.getElementById('schedState');
  const envEditorEl = document.getElementById('envEditor');
  const envStatusEl = document.getElementById('envStatus');
  const methodEl = document.getElementById('method');
  const queryEl = document.getElementById('query');
  const contextEl = document.getElementById('context');
  const bodyEl = document.getElementById('body');
  const enqueueBtn = document.getElementById('enqueueBtn');
  const uiStateUiEnabledEl = document.getElementById('uiStateUiEnabled');
  const uiStateApiEnabledEl = document.getElementById('uiStateApiEnabled');
  const uiStateWriteEnabledEl = document.getElementById('uiStateWriteEnabled');
  const uiStateLocalOnlyEl = document.getElementById('uiStateLocalOnly');
  const uiStateLoginEnabledEl = document.getElementById('uiStateLoginEnabled');
  const uiStateLoginApiEnabledEl = document.getElementById('uiStateLoginApiEnabled');
  const routeSearchEl = document.getElementById('routeSearch');
  const gatewaySummaryEl = document.getElementById('gatewaySummary');
  const routeTableBodyEl = document.getElementById('routeTableBody');
  const routeConflictsEl = document.getElementById('routeConflicts');
  const jobsTableBodyEl = document.getElementById('jobsTableBody');
  const jobDetailEl = document.getElementById('jobDetail');
  const refreshJobsBtn = document.getElementById('refreshJobsBtn');
  const packsListEl = document.getElementById('packsList');
  const refreshPacksBtn = document.getElementById('refreshPacksBtn');
  const tabButtons = Array.from(document.querySelectorAll('[data-tab-btn]'));
  const tabPanels = Array.from(document.querySelectorAll('[data-tab-panel]'));
  async function loadPacks() {
    try {
      state.packs = await getJson('/_fn/packs');
    } catch (err) {
      state.packs = null;
      if (packsListEl) packsListEl.textContent = `Failed to load packs: ${String(err && err.message ? err.message : err)}`;
      return;
    }
    if (state.selected && packsListEl) {
      renderPacksForRuntime(state.selected.runtime);
    }
  }

  async function loadJobs() {
    if (!jobsTableBodyEl) return;
    let out;
    try {
      out = await getJson('/_fn/jobs?limit=60');
    } catch (err) {
      if (jobsStatusEl) jobsStatusEl.textContent = String(err && err.message ? err.message : err);
      jobsTableBodyEl.innerHTML = '';
      return;
    }

    const jobs = (out && Array.isArray(out.jobs)) ? out.jobs : [];
    if (jobsStatusEl) jobsStatusEl.textContent = `Jobs loaded: ${jobs.length}`;

    jobsTableBodyEl.innerHTML = '';
    if (jobs.length === 0) {
      const tr = document.createElement('tr');
      const td = document.createElement('td');
      td.colSpan = 5;
      td.className = 'muted';
      td.textContent = 'No jobs yet. Use "Enqueue Job" from a function invoke.';
      tr.appendChild(td);
      jobsTableBodyEl.appendChild(tr);
      return;
    }

    for (const j of jobs) {
      const tr = document.createElement('tr');
      tr.style.cursor = 'pointer';
      tr.addEventListener('click', () => selectJob(j.id));

      const tdId = document.createElement('td');
      tdId.innerHTML = `<code>${esc(j.id || '')}</code>`;
      tr.appendChild(tdId);

      const tdSt = document.createElement('td');
      tdSt.textContent = j.status || '';
      tr.appendChild(tdSt);

      const tdT = document.createElement('td');
      tdT.textContent = `${j.runtime || ''}/${publicLabel(j.name || '', j.version || null)}`;
      tr.appendChild(tdT);

      const tdM = document.createElement('td');
      tdM.textContent = j.method || '';
      tr.appendChild(tdM);

      const tdA = document.createElement('td');
      tdA.textContent = `${j.attempt || 0}/${j.max_attempts || 1}`;
      tr.appendChild(tdA);

      jobsTableBodyEl.appendChild(tr);
    }
  }

  async function selectJob(id) {
    if (!jobDetailEl) return;
    try {
      const meta = await getJson(`/_fn/jobs/${encodeURIComponent(id)}`);
      let result = null;
      try {
        result = await getJson(`/_fn/jobs/${encodeURIComponent(id)}/result`);
      } catch (_) {
        // no result yet
      }
      jobDetailEl.textContent = JSON.stringify({ meta, result }, null, 2);
    } catch (err) {
      jobDetailEl.textContent = `Error: ${String(err && err.message ? err.message : err)}`;
    }
  }

  function renderPacksForRuntime(runtime) {
    if (!packsListEl) return;
    const packs = state.packs && state.packs.runtimes && state.packs.runtimes[runtime] && Array.isArray(state.packs.runtimes[runtime].packs)
      ? state.packs.runtimes[runtime].packs
      : [];
    if (!state.packs) {
      packsListEl.textContent = 'No packs loaded. Click "Refresh Packs".';
      return;
    }
    if (!packs || packs.length === 0) {
      packsListEl.textContent = `No packs for runtime ${runtime}. Create under ${state.packs.packs_root || '<FN_FUNCTIONS_ROOT>/.fastfn/packs'}/${runtime}/...`;
      return;
    }
    packsListEl.innerHTML = packs
      .map((p) => `<div><code>${esc(p.name)}</code></div>`)
      .join('');
  }

  function publicLabel(name, version) {
    return version ? `${name}@${version}` : name;
  }

  function yesNo(v) {
    return v ? 'yes' : 'no';
  }

  function asJson(obj) {
    if (!obj || typeof obj !== 'object') return '{}';
    return JSON.stringify(obj, null, 2);
  }

  function asJsonOneLine(obj) {
    if (!obj || typeof obj !== 'object') return '{}';
    return JSON.stringify(obj);
  }

  function parseJsonObject(raw, label) {
    const trimmed = String(raw || '').trim();
    if (!trimmed) return {};
    let obj;
    try { obj = JSON.parse(trimmed); } catch { throw new Error(`${label} must be valid JSON`); }
    if (!obj || typeof obj !== 'object' || Array.isArray(obj)) {
      throw new Error(`${label} must be a JSON object`);
    }
    return obj;
  }

  function selectionRecord(runtime, name, version) {
    return { runtime, name, version: version || null };
  }

  function selectionKey(runtime, name, version) {
    return `${runtime || ''}/${name || ''}@${version || 'default'}`;
  }

  function parseConsolePath(pathname) {
    const path = String(pathname || '');
    if (path === '/console' || path === '/console/') {
      return { tab: null, selection: null };
    }
    const raw = path.startsWith('/console/') ? path.slice('/console/'.length) : path;
    const segs = raw.split('/').filter(Boolean);
    if (segs.length === 0) return { tab: null, selection: null };

    const knownTabs = new Set(['explorer', 'wizard', 'gateway', 'configuration', 'crud']);
    const first = segs[0];

    // New-style: /console/<tab>/...
    if (knownTabs.has(first)) {
      const tab = first;
      if (tab !== 'explorer') return { tab, selection: null };

      // Explorer deep link: /console/explorer/<runtime>/<name>@<version?>
      if (segs.length >= 3) {
        const runtime = segs[1];
        const fnPart = segs[2];
        const m = String(fnPart).match(/^([A-Za-z0-9_-]+)(?:@([A-Za-z0-9_.-]+))?$/);
        if (m) return { tab, selection: selectionRecord(runtime, m[1], m[2] || null) };
      }
      return { tab, selection: null };
    }

    // Legacy deep link: /console/<runtime>/<name>@<version?>
    if (segs.length >= 2) {
      const runtime = segs[0];
      const fnPart = segs[1];
      const m = String(fnPart).match(/^([A-Za-z0-9_-]+)(?:@([A-Za-z0-9_.-]+))?$/);
      if (m) return { tab: 'explorer', selection: selectionRecord(runtime, m[1], m[2] || null) };
    }

    // Unknown console subpath -> treat as base console.
    return { tab: null, selection: null };
  }

  function buildConsolePath(activeTab, selection) {
    const tab = activeTab || 'explorer';
    if (tab === 'explorer' && selection && selection.runtime && selection.name) {
      return `/console/explorer/${selection.runtime}/${selection.name}${selection.version ? `@${selection.version}` : ''}`;
    }
    return `/console/${tab}`;
  }

  function parseUrlState() {
    const url = new URL(window.location.href);
    const out = { ui: {}, selection: null };

    const byPath = parseConsolePath(url.pathname);
    if (byPath && byPath.tab) out.ui.activeTab = byPath.tab;

    const q = url.searchParams.get('q');
    if (q !== null) out.ui.search = q;
    const rq = url.searchParams.get('rq');
    if (rq !== null) out.ui.routeSearch = rq;

    if (byPath && byPath.selection) out.selection = byPath.selection;

    const runtime = url.searchParams.get('runtime');
    const name = url.searchParams.get('name');
    const version = url.searchParams.get('version');
    if (runtime && name) {
      out.selection = selectionRecord(runtime, name, version || null);
    }
    return out;
  }

  function syncUrl(opts = {}) {
    const replace = opts.replace === true;
    const url = new URL(window.location.href);
    url.pathname = buildConsolePath(state.ui.activeTab, state.selected);
    url.search = '';
    if (state.ui.search && state.ui.search.trim() !== '') {
      url.searchParams.set('q', state.ui.search.trim());
    }
    if (state.ui.routeSearch && state.ui.routeSearch.trim() !== '') {
      url.searchParams.set('rq', state.ui.routeSearch.trim());
    }
    // Preserve selection for non-explorer tabs so refresh/deep links keep context.
    if (state.selected && state.ui.activeTab && state.ui.activeTab !== 'explorer') {
      url.searchParams.set('runtime', state.selected.runtime);
      url.searchParams.set('name', state.selected.name);
      if (state.selected.version) url.searchParams.set('version', state.selected.version);
    }
    const next = `${url.pathname}${url.search}${url.hash}`;
    const current = `${window.location.pathname}${window.location.search}${window.location.hash}`;
    if (next === current) return;
    if (replace) {
      window.history.replaceState({}, '', next);
    } else {
      window.history.pushState({}, '', next);
    }
  }

  function sameSelection(a, b) {
    return !!a && !!b
      && a.runtime === b.runtime
      && a.name === b.name
      && (a.version || null) === (b.version || null);
  }

  function loadPersistedState() {
    try {
      const rawSel = localStorage.getItem(LS_SELECTED_KEY);
      if (rawSel) {
        const parsed = JSON.parse(rawSel);
        if (parsed && parsed.runtime && parsed.name) {
          state.selected = selectionRecord(parsed.runtime, parsed.name, parsed.version || null);
        }
      }
    } catch (_) {}

    try {
      const rawHist = localStorage.getItem(LS_HISTORY_KEY);
      const parsed = rawHist ? JSON.parse(rawHist) : [];
      if (Array.isArray(parsed)) {
        state.history = parsed
          .filter((v) => v && typeof v.runtime === 'string' && typeof v.name === 'string')
          .map((v) => selectionRecord(v.runtime, v.name, v.version || null))
          .slice(0, MAX_HISTORY);
      }
    } catch (_) {
      state.history = [];
    }

    try {
      const rawUi = localStorage.getItem(LS_UI_KEY);
      const parsed = rawUi ? JSON.parse(rawUi) : {};
      if (parsed && typeof parsed === 'object') {
        if (typeof parsed.search === 'string') state.ui.search = parsed.search;
        if (typeof parsed.routeSearch === 'string') state.ui.routeSearch = parsed.routeSearch;
        if (typeof parsed.activeTab === 'string') state.ui.activeTab = parsed.activeTab;
      }
    } catch (_) {}

    try {
      const rawDrafts = localStorage.getItem(LS_INVOKE_DRAFTS_KEY);
      const parsed = rawDrafts ? JSON.parse(rawDrafts) : {};
      if (parsed && typeof parsed === 'object') {
        state.invokeDrafts = parsed;
      }
    } catch (_) {
      state.invokeDrafts = {};
    }
  }

  function savePersistedState() {
    try {
      if (state.selected) localStorage.setItem(LS_SELECTED_KEY, JSON.stringify(state.selected));
      localStorage.setItem(LS_HISTORY_KEY, JSON.stringify(state.history.slice(0, MAX_HISTORY)));
      localStorage.setItem(LS_UI_KEY, JSON.stringify(state.ui));
      localStorage.setItem(LS_INVOKE_DRAFTS_KEY, JSON.stringify(state.invokeDrafts));
    } catch (_) {}
  }

  function addHistory(runtime, name, version) {
    const current = selectionRecord(runtime, name, version);
    state.history = [current, ...state.history.filter((x) => !sameSelection(x, current))].slice(0, MAX_HISTORY);
    savePersistedState();
    renderHistory();
  }

  function selectionExistsInCatalog(sel) {
    if (!sel || !state.catalog) return false;
    const rt = (state.catalog.runtimes || {})[sel.runtime];
    if (!rt) return false;
    const fn = toFunctionArray(rt.functions).find((f) => f.name === sel.name);
    if (!fn) return false;
    if (!sel.version) return !!fn.has_default;
    return toVersionArray(fn.versions).includes(sel.version);
  }

  function firstAvailableSelection() {
    if (!state.catalog) return null;
    for (const runtime of Object.keys(state.catalog.runtimes || {}).sort()) {
      const rt = state.catalog.runtimes[runtime];
      for (const fn of toFunctionArray(rt.functions)) {
        if (fn.has_default) return selectionRecord(runtime, fn.name, null);
        const versions = toVersionArray(fn.versions);
        if (versions.length > 0) return selectionRecord(runtime, fn.name, versions[0]);
      }
    }
    return null;
  }

  function historyFallbackSelection() {
    for (const entry of state.history) {
      if (selectionExistsInCatalog(entry)) return entry;
    }
    return null;
  }

  function renderHistory() {
    if (!historyListEl) return;
    historyListEl.innerHTML = '';
    for (const entry of state.history) {
      if (!selectionExistsInCatalog(entry)) continue;
      const b = document.createElement('button');
      b.textContent = publicLabel(entry.name, entry.version);
      b.onclick = () => selectFn(entry.runtime, entry.name, entry.version);
      if (selectedMatches(entry.runtime, entry.name, entry.version)) b.classList.add('active');
      historyListEl.appendChild(b);
    }
  }

  function ensureMethodOptions(methods, selected) {
    const fallback = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'];
    const options = Array.isArray(methods) && methods.length > 0 ? methods : fallback;
    methodEl.innerHTML = '';
    for (const method of options) {
      const opt = document.createElement('option');
      opt.value = method;
      opt.textContent = method;
      methodEl.appendChild(opt);
    }
    methodEl.value = options.includes(selected) ? selected : options[0];
  }

  function setConfigMethods(methods) {
    const set = new Set(Array.isArray(methods) ? methods.map((m) => String(m).toUpperCase()) : ['GET']);
    for (const el of cfgMethodEls) {
      el.checked = set.has(String(el.value).toUpperCase());
    }
  }

  function normalizeRoutePath(raw) {
    if (typeof raw !== 'string') return null;
    let route = raw.trim();
    if (!route.startsWith('/')) return null;
    route = route.replace(/\/+/g, '/');
    if (route.length > 1) route = route.replace(/\/+$/, '');
    if (!route || route.includes('..')) return null;
    return route;
  }

  function parseRoutesText(raw) {
    const lines = String(raw || '')
      .split(/\r?\n/)
      .map((x) => x.trim())
      .filter(Boolean);
    const out = [];
    const seen = new Set();
    for (const line of lines) {
      const route = normalizeRoutePath(line);
      if (!route) throw new Error(`Invalid route path: ${line}`);
      if (!seen.has(route)) {
        seen.add(route);
        out.push(route);
      }
    }
    return out;
  }

  function parseAllowHostsText(raw) {
    const lines = String(raw || '')
      .split(/\r?\n/)
      .map((x) => x.trim())
      .filter(Boolean);
    const out = [];
    const seen = new Set();
    for (const line of lines) {
      const host = line.trim();
      if (!host) continue;
      if (host.includes('..') || host.includes('/') || host.includes(' ')) {
        throw new Error(`Invalid host entry: ${host}`);
      }
      if (!seen.has(host)) {
        seen.add(host);
        out.push(host);
      }
    }
    return out;
  }

  function saveCurrentInvokeDraft() {
    if (!state.selected) return;
    const key = selectionKey(state.selected.runtime, state.selected.name, state.selected.version);
    state.invokeDrafts[key] = {
      method: methodEl.value,
      query: queryEl.value,
      context: contextEl.value,
      body: bodyEl.value,
    };
    const keys = Object.keys(state.invokeDrafts);
    if (keys.length > MAX_DRAFTS) {
      keys.sort();
      for (const k of keys.slice(0, keys.length - MAX_DRAFTS)) delete state.invokeDrafts[k];
    }
    savePersistedState();
  }

  function applyInvokeDraft(runtime, name, version, defaults) {
    const key = selectionKey(runtime, name, version);
    const draft = state.invokeDrafts[key];
    if (!draft || typeof draft !== 'object') return false;
    ensureMethodOptions(defaults.methods, draft.method || defaults.defaultMethod);
    queryEl.value = typeof draft.query === 'string' ? draft.query : defaults.queryRaw;
    contextEl.value = typeof draft.context === 'string' ? draft.context : '';
    bodyEl.value = typeof draft.body === 'string' ? draft.body : defaults.bodyRaw;
    return true;
  }

  function populateCrudRuntimeOptions() {
    if (!crudRuntimeEl) return;
    const runtimes = Object.keys((state.catalog && state.catalog.runtimes) || {}).sort();
    const selected = crudRuntimeEl.value;
    crudRuntimeEl.innerHTML = '';
    for (const rt of runtimes) {
      const opt = document.createElement('option');
      opt.value = rt;
      opt.textContent = rt;
      crudRuntimeEl.appendChild(opt);
    }
    if (selected && runtimes.includes(selected)) {
      crudRuntimeEl.value = selected;
    } else if (state.selected && runtimes.includes(state.selected.runtime)) {
      crudRuntimeEl.value = state.selected.runtime;
    }
  }

  function getConfigMethods() {
    return cfgMethodEls
      .filter((el) => el.checked)
      .map((el) => String(el.value).toUpperCase());
  }

  function listText(value) {
    if (!Array.isArray(value) || value.length === 0) return 'none';
    return value.join(', ');
  }

  function activateTab(tabName, opts = {}) {
    state.ui.activeTab = tabName;
    savePersistedState();
    if (!opts.skipUrlSync) {
      syncUrl({ replace: opts.replaceUrl !== false });
    }
    for (const btn of tabButtons) {
      btn.classList.toggle('active', btn.dataset.tabBtn === tabName);
    }
    for (const panel of tabPanels) {
      panel.classList.toggle('active', panel.dataset.tabPanel === tabName);
    }
  }

  function toFunctionArray(value) {
    if (Array.isArray(value)) return value;
    if (!value || typeof value !== 'object') return [];
    return Object.keys(value)
      .sort((a, b) => Number(a) - Number(b))
      .map((k) => value[k])
      .filter((v) => v && typeof v === 'object');
  }

  function toVersionArray(value) {
    if (Array.isArray(value)) return value;
    if (!value || typeof value !== 'object') return [];
    return Object.keys(value)
      .sort()
      .filter((k) => value[k] === true || typeof value[k] === 'string' || typeof value[k] === 'number');
  }

  function selectedMatches(runtime, name, version) {
    const s = state.selected;
    return s && s.runtime === runtime && s.name === name && (s.version || null) === (version || null);
  }

  function filterMatch(name, version) {
    const q = searchEl.value.trim().toLowerCase();
    if (!q) return true;
    return publicLabel(name, version).toLowerCase().includes(q);
  }

  function renderList() {
    fnListEl.innerHTML = '';
    if (!state.catalog) return;

    const runtimes = state.catalog.runtimes || {};
    for (const runtime of Object.keys(runtimes).sort()) {
      const rt = runtimes[runtime];
      const wrap = document.createElement('div');
      wrap.style.marginBottom = '12px';

      const up = !!(rt.health && rt.health.up);
      const cls = up ? 'ok' : 'down';
      wrap.innerHTML = `<div><span class="chip ${cls}">${runtime} ${up ? 'UP' : 'DOWN'}</span></div>`;

      for (const fn of toFunctionArray(rt.functions)) {
        const rootGroup = (fn.policy && typeof fn.policy.group === 'string') ? fn.policy.group : '';
        if (fn.has_default && filterMatch(fn.name, null)) {
          const b = document.createElement('button');
          b.innerHTML = `${esc(publicLabel(fn.name, null))}${rootGroup ? ` <small class="muted">(${esc(rootGroup)})</small>` : ''}`;
          b.onclick = () => selectFn(runtime, fn.name, null);
          if (selectedMatches(runtime, fn.name, null)) b.classList.add('active');
          wrap.appendChild(b);
        }

        for (const ver of toVersionArray(fn.versions)) {
          if (!filterMatch(fn.name, ver)) continue;
          const verPolicy = (fn.versions_policy && fn.versions_policy[ver] && typeof fn.versions_policy[ver].group === 'string')
            ? fn.versions_policy[ver].group
            : '';
          const group = verPolicy || rootGroup;
          const b = document.createElement('button');
          b.innerHTML = `${esc(publicLabel(fn.name, ver))}${group ? ` <small class="muted">(${esc(group)})</small>` : ''}`;
          b.onclick = () => selectFn(runtime, fn.name, ver);
          if (selectedMatches(runtime, fn.name, ver)) b.classList.add('active');
          wrap.appendChild(b);
        }
      }

      fnListEl.appendChild(wrap);
    }
    renderHistory();
  }

  // Wizard logic is in openresty/console/wizard.js to keep this file manageable.

  function routeTargetLabel(entry) {
    if (!entry || !entry.runtime || !entry.fn_name) return 'unknown';
    return `${entry.runtime}/${publicLabel(entry.fn_name, entry.version || null)}`;
  }

  function routeFilterMatch(route, entry) {
    const q = String((state.ui && state.ui.routeSearch) || '').trim().toLowerCase();
    if (!q) return true;
    const methods = Array.isArray(entry && entry.methods) ? entry.methods.join(',') : '';
    const text = `${route} ${routeTargetLabel(entry)} ${methods}`.toLowerCase();
    return text.includes(q);
  }

  function renderGateway() {
    if (!gatewaySummaryEl || !routeTableBodyEl || !routeConflictsEl) return;
    const mapped = (state.catalog && state.catalog.mapped_routes) || {};
    const conflictsObj = (state.catalog && state.catalog.mapped_route_conflicts) || {};
    const conflictRoutes = Object.keys(conflictsObj).sort();
    const allRoutes = Object.keys(mapped).sort();
    const visibleRoutes = allRoutes.filter((route) => routeFilterMatch(route, mapped[route]));

    gatewaySummaryEl.textContent = `Mapped routes: ${allRoutes.length} | visible: ${visibleRoutes.length} | conflicts: ${conflictRoutes.length}`;
    routeTableBodyEl.innerHTML = '';

    if (visibleRoutes.length === 0) {
      const tr = document.createElement('tr');
      const td = document.createElement('td');
      td.colSpan = 4;
      td.className = 'muted';
      td.textContent = allRoutes.length === 0 ? 'No mapped routes configured.' : 'No mapped routes match the filter.';
      tr.appendChild(td);
      routeTableBodyEl.appendChild(tr);
    } else {
      for (const route of visibleRoutes) {
        const entry = mapped[route] || {};
        const tr = document.createElement('tr');

        const routeTd = document.createElement('td');
        routeTd.innerHTML = `<code>${esc(route)}</code>`;
        tr.appendChild(routeTd);

        const targetTd = document.createElement('td');
        targetTd.textContent = routeTargetLabel(entry);
        tr.appendChild(targetTd);

        const methodsTd = document.createElement('td');
        methodsTd.textContent = listText(entry.methods || []);
        tr.appendChild(methodsTd);

        const openTd = document.createElement('td');
        openTd.className = 'gateway-actions';
        const openBtn = document.createElement('button');
        openBtn.className = 'btn secondary';
        openBtn.textContent = 'Open';
        if (entry.runtime && entry.fn_name) {
          openBtn.onclick = () => {
            selectFn(entry.runtime, entry.fn_name, entry.version || null).catch((err) => {
              metaEl.textContent = `Error: ${err.message}`;
            });
          };
        } else {
          openBtn.disabled = true;
        }
        openTd.appendChild(openBtn);

        const editBtn = document.createElement('button');
        editBtn.className = 'btn secondary';
        editBtn.textContent = 'Edit mapping';
        editBtn.style.marginLeft = '6px';
        editBtn.setAttribute('data-gateway-edit', route);
        if (entry.runtime && entry.fn_name) {
          editBtn.onclick = () => {
            selectFn(entry.runtime, entry.fn_name, entry.version || null, { activateTab: 'configuration' }).catch((err) => {
              metaEl.textContent = `Error: ${err.message}`;
            });
          };
        } else {
          editBtn.disabled = true;
        }
        openTd.appendChild(editBtn);
        tr.appendChild(openTd);

        routeTableBodyEl.appendChild(tr);
      }
    }

    if (conflictRoutes.length === 0) {
      routeConflictsEl.textContent = 'No conflicts.';
    } else {
      routeConflictsEl.innerHTML = conflictRoutes.map((r) => `<div><code>${esc(r)}</code></div>`).join('');
    }
  }

  async function selectFn(runtime, name, version, opts = {}) {
    if (!selectedMatches(runtime, name, version || null)) {
      saveCurrentInvokeDraft();
    }
    state.selected = selectionRecord(runtime, name, version || null);
    savePersistedState();
    if (!opts.skipUrlSync) {
      syncUrl({ replace: opts.replaceUrl === true });
    }
    if (opts.activateTab) {
      activateTab(opts.activateTab, { replaceUrl: true });
    }
    renderList();

    const q = new URLSearchParams({ runtime, name });
    if (version) q.set('version', version);

    const detail = await getJson(`/_fn/function?${q.toString()}`);
    const p = detail.policy || {};
    const meta = (detail.metadata && typeof detail.metadata === 'object') ? detail.metadata : {};
    const responseMeta = (meta.response && typeof meta.response === 'object') ? meta.response : {};
    const envMeta = (meta.env && typeof meta.env === 'object') ? meta.env : {};
    const pyReq = (meta.python && meta.python.requirements && typeof meta.python.requirements === 'object')
      ? meta.python.requirements
      : {};
    const endpointsMeta = (meta.endpoints && typeof meta.endpoints === 'object') ? meta.endpoints : {};
    const nodeMeta = (meta.node && typeof meta.node === 'object') ? meta.node : {};
    const phpMeta = (meta.php && typeof meta.php === 'object') ? meta.php : {};
    const rustMeta = (meta.rust && typeof meta.rust === 'object') ? meta.rust : {};
    const invoke = (meta.invoke && typeof meta.invoke === 'object') ? meta.invoke : {};
    const scheduleMeta = (meta.schedule && typeof meta.schedule === 'object') ? meta.schedule : {};
    const scheduleCfg = (scheduleMeta.configured && typeof scheduleMeta.configured === 'object') ? scheduleMeta.configured : {};
    const scheduleState = (scheduleMeta.state && typeof scheduleMeta.state === 'object') ? scheduleMeta.state : {};
    const sharedDepsMeta = (meta.shared_deps && typeof meta.shared_deps === 'object') ? meta.shared_deps : {};

    cfgTimeoutEl.value = p.timeout_ms ?? '';
    cfgConcEl.value = p.max_concurrency ?? '';
    cfgBodyEl.value = p.max_body_bytes ?? '';
    if (cfgGroupEl) cfgGroupEl.value = (typeof meta.group === 'string') ? meta.group : '';
    cfgDebugHeadersEl.checked = !!responseMeta.effective_include_debug_headers;
    setConfigMethods(Array.isArray(p.methods) && p.methods.length > 0 ? p.methods : ['GET']);
    cfgRoutesEl.value = Array.isArray(invoke.mapped_routes) ? invoke.mapped_routes.join('\n') : '';
    if (cfgSharedDepsEl) {
      const configured = Array.isArray(sharedDepsMeta.configured) ? sharedDepsMeta.configured : [];
      cfgSharedDepsEl.value = configured.join('\n');
    }

    const edge = (p.edge && typeof p.edge === 'object') ? p.edge : {};
    if (edgeBaseUrlEl) edgeBaseUrlEl.value = typeof edge.base_url === 'string' ? edge.base_url : '';
    if (edgeAllowPrivateEl) edgeAllowPrivateEl.checked = edge.allow_private === true;
    if (edgeMaxRespEl) edgeMaxRespEl.value = edge.max_response_bytes ?? '';
    if (edgeAllowHostsEl) edgeAllowHostsEl.value = Array.isArray(edge.allow_hosts) ? edge.allow_hosts.join('\n') : '';
    envEditorEl.value = asJson(detail.fn_env || {});
    envStatusEl.textContent = '';
    if (schedStatusEl) schedStatusEl.textContent = '';

    const policyMethods = (p && Array.isArray(p.methods) && p.methods.length > 0) ? p.methods : null;
    const methods = policyMethods || (Array.isArray(invoke.methods) ? invoke.methods : ['GET']);
    const defaultMethod = (policyMethods && policyMethods[0]) || invoke.default_method || methods[0] || 'GET';
    const invokeDefaults = {
      methods,
      defaultMethod,
      queryRaw: asJson(invoke.query_example || {}),
      bodyRaw: typeof invoke.body_example === 'string' ? invoke.body_example : '',
    };
    if (!applyInvokeDraft(runtime, name, version || null, invokeDefaults)) {
      ensureMethodOptions(methods, defaultMethod);
      queryEl.value = invokeDefaults.queryRaw;
      contextEl.value = '';
      bodyEl.value = invokeDefaults.bodyRaw;
    }

    const fallbackRoute = `/fn/${name}${version ? `@${version}` : ''}`;
    const publicRoutes = (Array.isArray(endpointsMeta.public_routes) && endpointsMeta.public_routes.length > 0)
      ? endpointsMeta.public_routes
      : [endpointsMeta.public_route || fallbackRoute];
    const publicUrls = (Array.isArray(endpointsMeta.public_urls) && endpointsMeta.public_urls.length > 0)
      ? endpointsMeta.public_urls
      : publicRoutes.map((r) => `${window.location.origin}${r}`);
    const preferredUrl = endpointsMeta.preferred_public_url || publicUrls[0] || `${window.location.origin}${fallbackRoute}`;
    const publicUrlsHtml = publicUrls.map((u) => `<div>${esc(u)}</div>`).join('');

    const showDebug = !!responseMeta.effective_include_debug_headers;
    const advancedHtml = showDebug ? `
      <div class="grid" style="margin-top:10px;">
        <div><label>Debug Headers (effective)</label><div>${esc(yesNo(responseMeta.effective_include_debug_headers))}</div></div>
        <div><label>Function Env Keys</label><div>${esc(listText(envMeta.keys))}</div></div>
      </div>
      <div class="grid" style="margin-top:10px;">
        <div><label>Python Inline Requirements</label><div>${esc(listText(pyReq.inline))}</div></div>
        <div><label>requirements.txt</label><div>${esc(yesNo(pyReq.file_exists))} (${esc(listText(pyReq.file_entries))})</div></div>
        <div><label>Node package.json</label><div>${esc(yesNo(nodeMeta.package_json_exists))} ${nodeMeta.package_name ? `(${esc(nodeMeta.package_name)})` : ''}</div></div>
      </div>
      <div class="grid" style="margin-top:10px;">
        <div><label>Node lock</label><div>${esc(nodeMeta.lock_file || 'none')}</div></div>
        <div><label>Node dependencies</label><div>${esc(listText(nodeMeta.dependencies))}</div></div>
        <div><label>Node devDependencies</label><div>${esc(listText(nodeMeta.dev_dependencies))}</div></div>
      </div>
      <div class="grid" style="margin-top:10px;">
        <div><label>PHP composer.json</label><div>${esc(yesNo(phpMeta.composer_json_exists))}</div></div>
        <div><label>PHP composer.lock</label><div>${esc(yesNo(phpMeta.composer_lock_exists))}</div></div>
        <div><label>PHP dependencies</label><div>${esc(listText(phpMeta.dependencies))}</div></div>
      </div>
      <div class="grid" style="margin-top:10px;">
        <div><label>Rust Cargo.toml</label><div>${esc(yesNo(rustMeta.cargo_toml_exists))}</div></div>
        <div><label>Rust Cargo.lock</label><div>${esc(yesNo(rustMeta.cargo_lock_exists))}</div></div>
        <div><label>Rust dependencies</label><div>${esc(listText(rustMeta.dependencies))}</div></div>
      </div>
    ` : `
      <div class="muted" style="margin-top:8px;">Advanced details hidden (enable include_debug_headers).</div>
      <div class="muted" style="margin-top:4px;">Function Env Keys: ${esc(listText(envMeta.keys))}</div>
    `;

    detailsEl.innerHTML = `
      <div class="grid">
        <div><label>Function Route</label><div>${esc(fallbackRoute)}</div></div>
        <div><label>Preferred URL</label><div>${esc(preferredUrl)}</div></div>
        <div><label>Runtime</label><div>${esc(detail.runtime)}</div></div>
        <div><label>Version</label><div>${esc(detail.version || 'default')}</div></div>
        <div><label>Timeout (ms)</label><div>${esc(p.timeout_ms)}</div></div>
        <div><label>Max Concurrency</label><div>${esc(p.max_concurrency)}</div></div>
        <div><label>Max Body (bytes)</label><div>${esc(p.max_body_bytes)}</div></div>
      </div>
      <div style="margin-top:8px;">
        <label>Public URLs</label>
        ${publicUrlsHtml}
      </div>
      <div class="muted" style="margin-top:8px;">${esc(detail.file_path)}</div>
      <div class="muted" style="margin-top:8px;">Secret env values are masked as &lt;hidden&gt;.</div>
      ${advancedHtml}
    `;

    codeOutEl.value = detail.code || '';
    codeStatusEl.textContent = '';
    cfgStatusEl.textContent = '';
    if (schedEnabledEl) schedEnabledEl.checked = !!scheduleCfg.enabled;
    if (schedEveryEl) schedEveryEl.value = scheduleCfg.every_seconds ?? '';
    if (schedMethodEl) schedMethodEl.value = scheduleCfg.method || 'GET';
    if (schedQueryEl) schedQueryEl.value = asJsonOneLine(scheduleCfg.query || {});
    if (schedHeadersEl) schedHeadersEl.value = asJson(scheduleCfg.headers || {});
    if (schedBodyEl) schedBodyEl.value = typeof scheduleCfg.body === 'string' ? scheduleCfg.body : '';
    if (schedContextEl) schedContextEl.value = asJson(scheduleCfg.context || {});
    if (schedStateEl) schedStateEl.textContent = JSON.stringify(scheduleState || {}, null, 2);
    if (crudRuntimeEl) crudRuntimeEl.value = runtime;
    if (crudNameEl) crudNameEl.value = name;
    if (crudVersionEl) crudVersionEl.value = version || '';
    if (crudRouteEl) crudRouteEl.value = (Array.isArray(invoke.mapped_routes) && invoke.mapped_routes[0]) ? invoke.mapped_routes[0] : '';
    addHistory(runtime, name, version || null);
    renderPacksForRuntime(runtime);
  }

  async function createFunction() {
    const runtime = (crudRuntimeEl.value || '').trim();
    const name = (crudNameEl.value || '').trim();
    const version = (crudVersionEl.value || '').trim();
    const route = (crudRouteEl && crudRouteEl.value ? crudRouteEl.value.trim() : '');
    if (!runtime || !name) throw new Error('runtime and name are required');

    const payload = {
      methods: getConfigMethods(),
      summary: `Function ${name}`,
      query_example: {},
      body_example: '',
    };
    if (route) payload.route = route;

    const q = new URLSearchParams({ runtime, name });
    if (version) q.set('version', version);
    await getJson(`/_fn/function?${q.toString()}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });

    crudStatusEl.textContent = `Created: ${publicLabel(name, version || null)} (${runtime})`;
    await loadCatalog({ refreshSelected: false });
    await selectFn(runtime, name, version || null);
  }

  async function loadUiState() {
    const stateResp = await getJson('/_fn/ui-state');
    uiStateUiEnabledEl.checked = !!stateResp.ui_enabled;
    uiStateApiEnabledEl.checked = !!stateResp.api_enabled;
    uiStateWriteEnabledEl.checked = !!stateResp.write_enabled;
    uiStateLocalOnlyEl.checked = !!stateResp.local_only;
    if (uiStateLoginEnabledEl) uiStateLoginEnabledEl.checked = !!stateResp.login_enabled;
    if (uiStateLoginApiEnabledEl) uiStateLoginApiEnabledEl.checked = !!stateResp.login_api_enabled;
    uiStateStatusEl.textContent = 'State loaded';
  }

  async function saveUiState() {
    const payload = {
      ui_enabled: !!uiStateUiEnabledEl.checked,
      api_enabled: !!uiStateApiEnabledEl.checked,
      write_enabled: !!uiStateWriteEnabledEl.checked,
      local_only: !!uiStateLocalOnlyEl.checked,
    };
    if (uiStateLoginEnabledEl) payload.login_enabled = !!uiStateLoginEnabledEl.checked;
    if (uiStateLoginApiEnabledEl) payload.login_api_enabled = !!uiStateLoginApiEnabledEl.checked;
    const updated = await getJson('/_fn/ui-state', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    uiStateUiEnabledEl.checked = !!updated.ui_enabled;
    uiStateApiEnabledEl.checked = !!updated.api_enabled;
    uiStateWriteEnabledEl.checked = !!updated.write_enabled;
    uiStateLocalOnlyEl.checked = !!updated.local_only;
    if (uiStateLoginEnabledEl) uiStateLoginEnabledEl.checked = !!updated.login_enabled;
    if (uiStateLoginApiEnabledEl) uiStateLoginApiEnabledEl.checked = !!updated.login_api_enabled;
    uiStateStatusEl.textContent = 'State saved';
  }

  async function deleteSelected() {
    if (!state.selected) throw new Error('Select a function first');
    const runtime = state.selected.runtime;
    const name = state.selected.name;
    const version = state.selected.version;
    const q = new URLSearchParams({ runtime, name });
    if (version) q.set('version', version);

    await getJson(`/_fn/function?${q.toString()}`, { method: 'DELETE' });
    crudStatusEl.textContent = `Deleted: ${publicLabel(name, version || null)} (${runtime})`;
    await loadCatalog({ refreshSelected: true });
  }

  async function saveConfig() {
    if (!state.selected) return;
    const payload = {};

    if (cfgTimeoutEl.value !== '') payload.timeout_ms = Number(cfgTimeoutEl.value);
    if (cfgConcEl.value !== '') payload.max_concurrency = Number(cfgConcEl.value);
    if (cfgBodyEl.value !== '') payload.max_body_bytes = Number(cfgBodyEl.value);
    if (cfgGroupEl) payload.group = (cfgGroupEl.value || '').trim() || null;
    payload.include_debug_headers = !!cfgDebugHeadersEl.checked;
    if (cfgSharedDepsEl) {
      const raw = String(cfgSharedDepsEl.value || '');
      const packs = raw
        .split('\n')
        .map((x) => x.trim())
        .filter((x) => x.length > 0);
      payload.shared_deps = packs.length > 0 ? packs : null;
    }
    const methods = getConfigMethods();
    if (methods.length === 0) {
      throw new Error('Select at least one allowed method');
    }
    payload.invoke = { methods };
    payload.invoke.routes = parseRoutesText(cfgRoutesEl.value || '');

    if (edgeBaseUrlEl || edgeAllowHostsEl || edgeAllowPrivateEl || edgeMaxRespEl) {
      const edge = {};
      const baseUrl = edgeBaseUrlEl ? String(edgeBaseUrlEl.value || '').trim() : '';
      const allowHostsRaw = edgeAllowHostsEl ? String(edgeAllowHostsEl.value || '') : '';
      const allowPrivate = !!(edgeAllowPrivateEl && edgeAllowPrivateEl.checked);
      const maxResp = edgeMaxRespEl ? String(edgeMaxRespEl.value || '').trim() : '';

      if (baseUrl) edge.base_url = baseUrl;
      const hosts = parseAllowHostsText(allowHostsRaw);
      if (hosts.length > 0) edge.allow_hosts = hosts;
      if (allowPrivate) edge.allow_private = true;
      if (maxResp !== '') edge.max_response_bytes = Number(maxResp);

      if (Object.keys(edge).length > 0) {
        payload.edge = edge;
      } else {
        payload.edge = null;
      }
    }

    const q = new URLSearchParams({
      runtime: state.selected.runtime,
      name: state.selected.name,
    });
    if (state.selected.version) q.set('version', state.selected.version);

    const updated = await getJson(`/_fn/function-config?${q.toString()}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });

    cfgStatusEl.textContent = `Saved: methods=${(updated.policy.methods || []).join(',')} timeout=${updated.policy.timeout_ms} conc=${updated.policy.max_concurrency} body=${updated.policy.max_body_bytes}`;
    await loadCatalog({ refreshSelected: true });
  }

  async function saveSchedule() {
    if (!state.selected) return;
    const enabled = !!(schedEnabledEl && schedEnabledEl.checked);
    const sched = { enabled };
    if (enabled) {
      const every = Number(schedEveryEl.value || 0);
      if (!every || every <= 0) throw new Error('every_seconds must be > 0');
      sched.every_seconds = every;
      sched.method = String((schedMethodEl && schedMethodEl.value) || 'GET').toUpperCase();
      sched.query = parseJsonObject(schedQueryEl.value, 'query JSON');
      sched.headers = parseJsonObject(schedHeadersEl.value, 'headers JSON');
      sched.body = String(schedBodyEl.value || '');
      sched.context = parseJsonObject(schedContextEl.value, 'context JSON');
    }

    const q = new URLSearchParams({
      runtime: state.selected.runtime,
      name: state.selected.name,
    });
    if (state.selected.version) q.set('version', state.selected.version);

    await getJson(`/_fn/function-config?${q.toString()}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ schedule: sched }),
    });

    if (schedStatusEl) schedStatusEl.textContent = enabled ? 'Saved schedule (enabled)' : 'Saved schedule (disabled)';
    await loadCatalog({ refreshSelected: true });
  }

  async function saveEnv() {
    if (!state.selected) return;

    let payload;
    try {
      payload = JSON.parse(envEditorEl.value || '{}');
    } catch (_) {
      throw new Error('fn.env.json must be valid JSON');
    }
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
      throw new Error('fn.env.json must be a JSON object');
    }

    const q = new URLSearchParams({
      runtime: state.selected.runtime,
      name: state.selected.name,
    });
    if (state.selected.version) q.set('version', state.selected.version);

    await getJson(`/_fn/function-env?${q.toString()}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });

    envStatusEl.textContent = 'Saved fn.env.json';
    await loadCatalog({ refreshSelected: true });
  }

  async function invoke() {
    if (!state.selected) return;

    let queryObj = {};
    const queryRaw = queryEl.value.trim();
    if (queryRaw) {
      try { queryObj = JSON.parse(queryRaw); } catch { throw new Error('Query must be valid JSON object'); }
    }

    const method = methodEl.value;
    const body = bodyEl.value;
    let context;
    const contextRaw = (contextEl.value || '').trim();
    if (contextRaw) {
      try { context = JSON.parse(contextRaw); } catch { throw new Error('Context must be valid JSON object'); }
      if (!context || typeof context !== 'object' || Array.isArray(context)) {
        throw new Error('Context must be a JSON object');
      }
    }

    const payload = {
      runtime: state.selected.runtime,
      name: state.selected.name,
      version: state.selected.version,
      method,
      query: queryObj,
      body,
    };
    if (context) payload.context = context;

    const t0 = performance.now();
    const res = await getJson('/_fn/invoke', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const elapsed = Math.round(performance.now() - t0);

    invokeMetaEl.textContent = `${method} => status ${res.status} | ${res.latency_ms}ms (api ${elapsed}ms)`;

    if (res.is_base64) {
      invokeOutEl.textContent = JSON.stringify({
        status: res.status,
        headers: res.headers,
        is_base64: true,
        body_base64_len: (res.body_base64 || '').length,
      }, null, 2);
      return;
    }

    const out = {
      status: res.status,
      headers: res.headers,
      body: res.body || '',
    };
    try {
      out.body = JSON.parse(out.body);
    } catch (_) {}
    invokeOutEl.textContent = JSON.stringify(out, null, 2);
  }

  async function enqueueJob() {
    if (!state.selected) return;

    let queryObj = {};
    const queryRaw = queryEl.value.trim();
    if (queryRaw) {
      try { queryObj = JSON.parse(queryRaw); } catch { throw new Error('Query must be valid JSON object'); }
    }

    const method = methodEl.value;
    const body = bodyEl.value;
    let context;
    const contextRaw = (contextEl.value || '').trim();
    if (contextRaw) {
      try { context = JSON.parse(contextRaw); } catch { throw new Error('Context must be valid JSON object'); }
      if (!context || typeof context !== 'object' || Array.isArray(context)) {
        throw new Error('Context must be a JSON object');
      }
    }

    const payload = {
      runtime: state.selected.runtime,
      name: state.selected.name,
      version: state.selected.version,
      method,
      query: queryObj,
      body,
      context,
      max_attempts: 1,
      retry_delay_ms: 1000,
    };

    const job = await getJson('/_fn/jobs', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });

    invokeMetaEl.textContent = `Enqueued job ${job.id} (${method} ${publicLabel(job.name, job.version || null)})`;
    await loadJobs();
    await selectJob(job.id);
  }

  async function saveCode() {
    if (!state.selected) return;
    const code = codeOutEl.value || '';
    const q = new URLSearchParams({
      runtime: state.selected.runtime,
      name: state.selected.name,
    });
    if (state.selected.version) q.set('version', state.selected.version);

    const updated = await getJson(`/_fn/function-code?${q.toString()}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code }),
    });

    codeStatusEl.textContent = `Saved: ${updated.file_path || ''}`;
    await loadCatalog({ refreshSelected: true });
  }

  async function reloadCatalog() {
    await getJson('/_fn/reload', { method: 'POST' });
    await loadCatalog({ refreshSelected: true });
  }

  async function loadCatalog(opts = {}) {
    const refreshSelected = opts.refreshSelected !== false;
    const data = await getJson('/_fn/catalog');
    state.catalog = data;
    populateCrudRuntimeOptions();
    const runtimes = Object.keys(data.runtimes || {}).length;
    const mapped = Object.keys(data.mapped_routes || {}).length;
    const conflicts = Object.keys(data.mapped_route_conflicts || {}).length;
    metaEl.textContent = `Runtimes: ${runtimes} | mapped: ${mapped} | conflicts: ${conflicts} | root: ${data.functions_root}`;
    renderList();
    renderGateway();

    if (!refreshSelected) return;

    if (state.selected && selectionExistsInCatalog(state.selected)) {
      await selectFn(state.selected.runtime, state.selected.name, state.selected.version, { replaceUrl: true });
      return;
    }

    const fromHistory = historyFallbackSelection();
    if (fromHistory) {
      await selectFn(fromHistory.runtime, fromHistory.name, fromHistory.version, { replaceUrl: true });
      return;
    }

    const first = firstAvailableSelection();
    if (first) {
      await selectFn(first.runtime, first.name, first.version, { replaceUrl: true });
    }
  }

  document.getElementById('saveCfgBtn').addEventListener('click', () => {
    saveConfig().catch((err) => { cfgStatusEl.textContent = err.message; });
  });

  document.getElementById('reloadBtn').addEventListener('click', () => {
    reloadCatalog().catch((err) => { cfgStatusEl.textContent = err.message; });
  });

  if (refreshPacksBtn) {
    refreshPacksBtn.addEventListener('click', () => {
      loadPacks().catch((err) => { packsListEl.textContent = err.message; });
    });
  }

  if (refreshJobsBtn) {
    refreshJobsBtn.addEventListener('click', () => {
      loadJobs().catch((err) => { if (jobsStatusEl) jobsStatusEl.textContent = err.message; });
    });
  }

  const saveSchedBtn = document.getElementById('saveSchedBtn');
  if (saveSchedBtn) {
    saveSchedBtn.addEventListener('click', () => {
      saveSchedule().catch((err) => { if (schedStatusEl) schedStatusEl.textContent = err.message; });
    });
  }

  document.getElementById('saveEnvBtn').addEventListener('click', () => {
    saveEnv().catch((err) => { envStatusEl.textContent = err.message; });
  });

  document.getElementById('invokeBtn').addEventListener('click', () => {
    invoke().catch((err) => { invokeMetaEl.textContent = err.message; });
  });

  if (enqueueBtn) {
    enqueueBtn.addEventListener('click', () => {
      enqueueJob().catch((err) => { invokeMetaEl.textContent = err.message; });
    });
  }

  document.getElementById('saveCodeBtn').addEventListener('click', () => {
    saveCode().catch((err) => { codeStatusEl.textContent = err.message; });
  });

  document.getElementById('createFnBtn').addEventListener('click', () => {
    createFunction().catch((err) => { crudStatusEl.textContent = err.message; });
  });

  document.getElementById('deleteFnBtn').addEventListener('click', () => {
    deleteSelected().catch((err) => { crudStatusEl.textContent = err.message; });
  });

  document.getElementById('reloadUiStateBtn').addEventListener('click', () => {
    loadUiState().catch((err) => { uiStateStatusEl.textContent = err.message; });
  });

  document.getElementById('saveUiStateBtn').addEventListener('click', () => {
    saveUiState().catch((err) => { uiStateStatusEl.textContent = err.message; });
  });

  searchEl.addEventListener('input', () => {
    state.ui.search = searchEl.value;
    savePersistedState();
    syncUrl({ replace: true });
    renderList();
  });

  if (routeSearchEl) {
    routeSearchEl.addEventListener('input', () => {
      state.ui.routeSearch = routeSearchEl.value;
      savePersistedState();
      syncUrl({ replace: true });
      renderGateway();
    });
  }

  [methodEl, queryEl, contextEl, bodyEl].forEach((el) => {
    el.addEventListener('input', saveCurrentInvokeDraft);
    el.addEventListener('change', saveCurrentInvokeDraft);
  });

  tabButtons.forEach((btn) => {
    btn.addEventListener('click', () => activateTab(btn.dataset.tabBtn));
  });

  initWizard({ state, loadCatalog, selectFn });

  loadPersistedState();
  const initialUrlState = parseUrlState();
  if (initialUrlState.ui) {
    if (typeof initialUrlState.ui.search === 'string') state.ui.search = initialUrlState.ui.search;
    if (typeof initialUrlState.ui.routeSearch === 'string') state.ui.routeSearch = initialUrlState.ui.routeSearch;
    if (typeof initialUrlState.ui.activeTab === 'string') state.ui.activeTab = initialUrlState.ui.activeTab;
  }
  if (initialUrlState.selection) {
    state.selected = initialUrlState.selection;
  }
  if (typeof state.ui.search === 'string') {
    searchEl.value = state.ui.search;
  }
  if (routeSearchEl && typeof state.ui.routeSearch === 'string') {
    routeSearchEl.value = state.ui.routeSearch;
  }
  activateTab(state.ui.activeTab || 'explorer', { replaceUrl: true });
  loadUiState().catch((err) => {
    uiStateStatusEl.textContent = err.message;
  });

  loadPacks().catch((err) => {
    if (packsListEl) packsListEl.textContent = err.message;
  });

  loadJobs().catch((err) => {
    if (jobsStatusEl) jobsStatusEl.textContent = err.message;
  });

  loadCatalog({ refreshSelected: true }).catch((err) => {
    metaEl.textContent = `Error: ${err.message}`;
  });

  window.addEventListener('popstate', () => {
    const s = parseUrlState();
    if (s.ui) {
      state.ui.search = typeof s.ui.search === 'string' ? s.ui.search : '';
      state.ui.routeSearch = typeof s.ui.routeSearch === 'string' ? s.ui.routeSearch : '';
      state.ui.activeTab = typeof s.ui.activeTab === 'string' ? s.ui.activeTab : 'explorer';
    }
    state.selected = s.selection || null;
    if (typeof state.ui.search === 'string') {
      searchEl.value = state.ui.search;
    }
    if (routeSearchEl && typeof state.ui.routeSearch === 'string') {
      routeSearchEl.value = state.ui.routeSearch;
    }
    activateTab(state.ui.activeTab || 'explorer', { skipUrlSync: true });
    loadCatalog({ refreshSelected: true }).catch((err) => {
      metaEl.textContent = `Error: ${err.message}`;
    });
  });
})();
