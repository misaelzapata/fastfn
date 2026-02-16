import { esc, getJson } from './base.js';
import { initWizard } from './wizard.js';

const DEFAULT_TABS = new Set(['code', 'test', 'monitor', 'api', 'configuration']);
const ALLOWED_HTTP_METHODS = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'];
const CONFIG_METHOD_TOGGLE_IDS = {
  GET: 'configMethodGet',
  POST: 'configMethodPost',
  PUT: 'configMethodPut',
  PATCH: 'configMethodPatch',
  DELETE: 'configMethodDelete',
};
const EXEC_HISTORY_STORAGE_KEY = 'fastfn_execution_history_v1';
const EXEC_HISTORY_LIMIT_PER_FN = 30;
const AI_CHAT_HISTORY_STORAGE_KEY = 'fastfn_ai_chat_history_v1';
const AI_CHAT_HISTORY_LIMIT_PER_FN = 40;
const AI_MODE_STORAGE_KEY = 'fastfn_ai_mode_v1';

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

function parseRouteParams(route) {
  const specs = [];
  const re = /:([A-Za-z0-9_]+)(\*?)/g;
  let m;
  while ((m = re.exec(String(route || ''))) !== null) {
    specs.push({ name: m[1], catchAll: m[2] === '*' });
  }
  return specs;
}

function defaultParamsForRoute(route) {
  const obj = {};
  for (const spec of parseRouteParams(route)) {
    obj[spec.name] = spec.catchAll ? 'example/a/b' : '123';
  }
  return obj;
}

function parseJsonObject(raw, label) {
  const text = String(raw || '').trim();
  if (!text) return {};
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new Error(`${label} must be valid JSON`);
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error(`${label} must be a JSON object`);
  }
  return parsed;
}

function parseOptionalJsonObject(raw, label) {
  const text = String(raw || '').trim();
  if (!text) return undefined;
  return parseJsonObject(text, label);
}

function formatUnixSeconds(raw) {
  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0) return '';
  try {
    return new Date(value * 1000).toISOString();
  } catch {
    return '';
  }
}

function formatIntervalSeconds(raw) {
  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0) return '';
  const s = Math.floor(value);
  if (s % 3600 === 0) return `${s / 3600}h`;
  if (s % 60 === 0) return `${s / 60}m`;
  return `${s}s`;
}

function scheduleRetrySummary(retry) {
  if (retry === true) return 'retry: enabled (defaults)';
  if (!retry || typeof retry !== 'object') return '';
  if (retry.enabled === false) return 'retry: disabled';
  const maxAttempts = Number(retry.max_attempts);
  const base = Number(retry.base_delay_seconds);
  const maxDelay = Number(retry.max_delay_seconds);
  const jitter = Number(retry.jitter);
  const parts = [];
  if (Number.isFinite(maxAttempts) && maxAttempts > 0) parts.push(`max_attempts=${Math.floor(maxAttempts)}`);
  if (Number.isFinite(base)) parts.push(`base_delay_seconds=${base}`);
  if (Number.isFinite(maxDelay)) parts.push(`max_delay_seconds=${maxDelay}`);
  if (Number.isFinite(jitter)) parts.push(`jitter=${jitter}`);
  if (parts.length === 0) return 'retry: enabled';
  return `retry: ${parts.join(' ')}`;
}

function formatScheduleLabel(schedule) {
  if (!schedule || typeof schedule !== 'object') return '';
  const cron = typeof schedule.cron === 'string' ? schedule.cron.trim() : '';
  const tz = typeof schedule.timezone === 'string' ? schedule.timezone.trim() : '';
  if (cron) {
    if (tz && tz.toLowerCase() !== 'local') return `cron ${cron} (${tz})`;
    return `cron ${cron}`;
  }
  const every = formatIntervalSeconds(schedule.every_seconds);
  if (every) return `every ${every}`;
  return '';
}

function badgeClassForHttpStatus(raw) {
  const code = Number(raw);
  if (!Number.isFinite(code) || code <= 0) return '';
  if (code >= 200 && code < 300) return 'success';
  if (code >= 300 && code < 400) return 'warn';
  return 'danger';
}

function parseCsvList(raw) {
  return String(raw || '')
    .split(/[\n,]/)
    .map((x) => x.trim())
    .filter((x) => x.length > 0);
}

function normalizeMethodsFromCsv(raw) {
  const allowed = new Set(ALLOWED_HTTP_METHODS);
  const out = [];
  const seen = new Set();
  for (const item of parseCsvList(raw)) {
    const m = item.toUpperCase();
    if (allowed.has(m) && !seen.has(m)) {
      seen.add(m);
      out.push(m);
    }
  }
  return out;
}

function normalizeRoutesFromCsv(raw) {
  const out = [];
  const seen = new Set();
  for (const item of parseCsvList(raw)) {
    if (!item.startsWith('/')) continue;
    let route = item.replace(/\/+/g, '/');
    if (route.length > 1) route = route.replace(/\/+$/, '');
    if (route.includes('..') || route.includes('?') || route.includes('#')) continue;
    if (!seen.has(route)) {
      seen.add(route);
      out.push(route);
    }
  }
  return out;
}

function hasConfigMethodToggles() {
  return Object.values(CONFIG_METHOD_TOGGLE_IDS).some((id) => document.getElementById(id));
}

function readMethodsFromToggles() {
  const selected = [];
  for (const method of ALLOWED_HTTP_METHODS) {
    const el = document.getElementById(CONFIG_METHOD_TOGGLE_IDS[method]);
    if (el && el.checked) selected.push(method);
  }
  return selected;
}

function writeMethodsToToggles(methods) {
  const selected = new Set((Array.isArray(methods) ? methods : []).map((m) => String(m || '').toUpperCase()));
  for (const method of ALLOWED_HTTP_METHODS) {
    const el = document.getElementById(CONFIG_METHOD_TOGGLE_IDS[method]);
    if (el) el.checked = selected.has(method);
  }
}

function stringifyPretty(obj) {
  try {
    return JSON.stringify(obj, null, 2);
  } catch {
    return '{}';
  }
}

function parseQueryInput(raw) {
  const text = String(raw || '').trim();
  if (!text) return {};
  if (text.startsWith('{')) {
    return parseJsonObject(text, 'query');
  }
  const queryText = text.startsWith('?') ? text.slice(1) : text;
  if (!queryText.includes('=')) {
    throw new Error('query must be JSON or querystring (?a=1&b=2)');
  }
  const out = {};
  const params = new URLSearchParams(queryText);
  for (const [k, v] of params.entries()) {
    out[k] = v;
  }
  return out;
}

function renderRouteWithParams(route, params) {
  const source = String(route || '');
  return source.replace(/:([A-Za-z0-9_]+)(\*?)/g, (_, key) => {
    const value = params && params[key] !== undefined ? String(params[key]) : '';
    return value;
  });
}

function normalizeMappedEntries(raw) {
  if (!raw || typeof raw !== 'object') return [];
  if (Array.isArray(raw)) return raw.filter((entry) => entry && typeof entry === 'object');
  if (raw.runtime || raw.fn_name || raw.target) return [raw];
  return [];
}

function publicLabel(name, version) {
  return version ? `${name}@${version}` : name;
}

class ConsoleApp {
  constructor() {
    this.currentView = 'functionList';
    this.currentFn = null;
    this.currentDetail = null;
    this.currentTab = 'code';
    this.catalog = null;
    this.functionRows = [];
    this.gatewayRows = [];
    this.currentFile = '';
    this.handlerFile = '';
    this.fileContents = {};
    this.wizardState = {};
    this.currentGatewayRoute = null;
    this.savedEvents = this.loadSavedEvents();
    this.executionHistory = this.loadExecutionHistory();
    this.aiHistory = this.loadAiHistory();
    this.monitorRefreshTimer = null;
    this.catalogRefreshTimer = null;
    this.catalogRefreshInFlight = false;
    this.lastCatalogFingerprint = '';
    this.assistantStatus = null;
    this.assistantStatusAt = 0;
    this.apiPrimary = null;
    this.envUnsupportedEntries = {};
    this.aiMode = this.loadAiMode();
    this.uiState = null;
    this.schedulerSnapshot = null;
  }

  loadSavedEvents() {
    try {
      const raw = localStorage.getItem('fastfn_saved_test_events_v1');
      const parsed = raw ? JSON.parse(raw) : {};
      return parsed && typeof parsed === 'object' ? parsed : {};
    } catch {
      return {};
    }
  }

  persistSavedEvents() {
    try {
      localStorage.setItem('fastfn_saved_test_events_v1', JSON.stringify(this.savedEvents));
    } catch {
      // ignore
    }
  }

  loadExecutionHistory() {
    try {
      const raw = localStorage.getItem(EXEC_HISTORY_STORAGE_KEY);
      const parsed = raw ? JSON.parse(raw) : {};
      return parsed && typeof parsed === 'object' ? parsed : {};
    } catch {
      return {};
    }
  }

  persistExecutionHistory() {
    try {
      localStorage.setItem(EXEC_HISTORY_STORAGE_KEY, JSON.stringify(this.executionHistory));
    } catch {
      // ignore storage errors
    }
  }

  loadAiHistory() {
    try {
      const raw = localStorage.getItem(AI_CHAT_HISTORY_STORAGE_KEY);
      const parsed = raw ? JSON.parse(raw) : {};
      return parsed && typeof parsed === 'object' ? parsed : {};
    } catch {
      return {};
    }
  }

  persistAiHistory() {
    try {
      localStorage.setItem(AI_CHAT_HISTORY_STORAGE_KEY, JSON.stringify(this.aiHistory));
    } catch {
      // ignore storage errors
    }
  }

  loadAiMode() {
    try {
      const raw = String(localStorage.getItem(AI_MODE_STORAGE_KEY) || 'auto').toLowerCase();
      if (raw === 'chat' || raw === 'edit' || raw === 'auto') return raw;
      return 'auto';
    } catch {
      return 'auto';
    }
  }

  persistAiMode() {
    try {
      localStorage.setItem(AI_MODE_STORAGE_KEY, String(this.aiMode || 'auto'));
    } catch {
      // ignore storage errors
    }
  }

  setAiMode(mode) {
    const value = String(mode || '').toLowerCase();
    this.aiMode = (value === 'chat' || value === 'edit' || value === 'auto') ? value : 'auto';
    this.persistAiMode();
    this.updateAiModeSwitch();
  }

  updateAiModeSwitch() {
    const map = {
      auto: document.getElementById('aiModeAuto'),
      chat: document.getElementById('aiModeChat'),
      edit: document.getElementById('aiModeEdit'),
    };
    for (const [key, el] of Object.entries(map)) {
      if (!el) continue;
      el.classList.toggle('active', this.aiMode === key);
    }
  }

  aiHistoryKey() {
    if (!this.currentFn) return '';
    return `${this.currentFn.runtime}/${this.currentFn.name}@${this.currentFn.version || 'default'}`;
  }

  getAiHistoryEntriesForCurrentFn() {
    const key = this.aiHistoryKey();
    if (!key) return [];
    const entries = this.aiHistory[key];
    return Array.isArray(entries) ? entries : [];
  }

  recordAiHistory(role, text) {
    const key = this.aiHistoryKey();
    if (!key) return;
    const content = String(text || '').trim();
    if (!content) return;
    if (!Array.isArray(this.aiHistory[key])) this.aiHistory[key] = [];
    this.aiHistory[key].push({ role: String(role || 'assistant'), text: content, ts: Date.now() });
    if (this.aiHistory[key].length > AI_CHAT_HISTORY_LIMIT_PER_FN) {
      this.aiHistory[key] = this.aiHistory[key].slice(this.aiHistory[key].length - AI_CHAT_HISTORY_LIMIT_PER_FN);
    }
    this.persistAiHistory();
  }

  renderAiHistory() {
    const out = document.getElementById('aiOutput');
    if (!out) return;
    const entries = this.getAiHistoryEntriesForCurrentFn();
    out.innerHTML = '';
    if (entries.length === 0) {
      const msg = document.createElement('div');
      msg.className = 'ai-msg system';
      msg.textContent = 'How can I help you write this function?';
      out.appendChild(msg);
      return;
    }
    for (const entry of entries) {
      if (!entry || typeof entry !== 'object') continue;
      const role = String(entry.role || 'assistant');
      const msg = document.createElement('div');
      msg.className = `ai-msg ${role === 'user' ? 'user' : 'system'}`;
      msg.textContent = String(entry.text || '');
      out.appendChild(msg);
    }
    out.scrollTop = out.scrollHeight;
  }

  clearMonitorAutoRefresh() {
    if (this.monitorRefreshTimer) {
      clearInterval(this.monitorRefreshTimer);
      this.monitorRefreshTimer = null;
    }
  }

  buildCatalogFingerprint(catalog) {
    if (!catalog || typeof catalog !== 'object') return '';
    const fnRows = this.flattenRowsFromCatalog(catalog).map((row) => {
      const methods = Array.isArray(row.methods) ? row.methods.join(',') : '';
      const routes = Array.isArray(row.routes) ? row.routes.join(',') : '';
      return `${row.runtime}/${row.name}@${row.version || 'default'}|m=${methods}|r=${routes}`;
    });
    const gatewayRows = this.flattenGatewayRows(catalog).map((row) => {
      const methods = Array.isArray(row.methods) ? row.methods.join(',') : '';
      return `${row.route}->${row.runtime}/${row.name}@${row.version || 'default'}|m=${methods}|t=${row.target || ''}`;
    });
    const conflicts = Object.keys((catalog.mapped_route_conflicts && typeof catalog.mapped_route_conflicts === 'object')
      ? catalog.mapped_route_conflicts
      : {}).sort();
    return `${fnRows.join('||')}###${gatewayRows.join('||')}###${conflicts.join('||')}`;
  }

  clearCatalogAutoRefresh() {
    if (this.catalogRefreshTimer) {
      clearInterval(this.catalogRefreshTimer);
      this.catalogRefreshTimer = null;
    }
  }

  syncCatalogAutoRefresh() {
    this.clearCatalogAutoRefresh();
    this.catalogRefreshTimer = setInterval(() => {
      if (this.catalogRefreshInFlight) return;
      if (document.visibilityState === 'hidden') return;
      if (this.currentView !== 'functionList' && this.currentView !== 'gateway') return;
      this.catalogRefreshInFlight = true;
      this.loadFunctions({ refreshSelected: false, skipIfUnchanged: true })
        .catch(() => {
          // ignore transient refresh errors
        })
        .finally(() => {
          this.catalogRefreshInFlight = false;
        });
    }, 2500);
  }

  syncMonitorAutoRefresh() {
    this.clearMonitorAutoRefresh();
    if (!this.currentFn || this.currentTab !== 'monitor') return;
    const intervalSelect = document.getElementById('monitorRefreshInterval');
    const seconds = Number(intervalSelect?.value || 0);
    if (!Number.isFinite(seconds) || seconds <= 0) return;
    this.monitorRefreshTimer = setInterval(() => {
      if (this.currentTab === 'monitor' && this.currentFn) {
        this.refreshMonitor().catch(() => {});
      }
    }, Math.round(seconds * 1000));
  }

  eventKey() {
    if (!this.currentFn) return '';
    return `${this.currentFn.runtime}/${this.currentFn.name}@${this.currentFn.version || 'default'}`;
  }

  cloneEnvValue(value) {
    try {
      return JSON.parse(JSON.stringify(value));
    } catch {
      return value;
    }
  }

  normalizeEnvEntry(raw) {
    if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
      const hasValue = Object.prototype.hasOwnProperty.call(raw, 'value');
      const hasSecret = Object.prototype.hasOwnProperty.call(raw, 'is_secret');
      if (hasValue || hasSecret) {
        return {
          type: 'row',
          value: hasValue && raw.value !== undefined && raw.value !== null ? String(raw.value) : '',
          is_secret: raw.is_secret === true,
        };
      }
      return { type: 'unsupported', value: this.cloneEnvValue(raw) };
    }
    if (raw === undefined || raw === null) return { type: 'row', value: '', is_secret: false };
    if (typeof raw === 'string' || typeof raw === 'number' || typeof raw === 'boolean') {
      return { type: 'row', value: String(raw), is_secret: false };
    }
    return { type: 'unsupported', value: this.cloneEnvValue(raw) };
  }

  addEnvDictRow(entry = {}) {
    const container = document.getElementById('envDictRows');
    if (!container) return null;

    const row = document.createElement('div');
    row.className = 'env-dict-row';

    const keyInput = document.createElement('input');
    keyInput.type = 'text';
    keyInput.className = 'env-key';
    keyInput.placeholder = 'API_KEY';
    keyInput.value = String(entry.key || '');
    row.appendChild(keyInput);

    const valueInput = document.createElement('input');
    valueInput.type = 'text';
    valueInput.className = 'env-value';
    valueInput.placeholder = 'value';
    valueInput.value = String(entry.value || '');
    row.appendChild(valueInput);

    const secretCell = document.createElement('div');
    secretCell.className = 'env-secret-cell';
    const secretToggle = document.createElement('input');
    secretToggle.type = 'checkbox';
    secretToggle.className = 'env-secret';
    secretToggle.checked = entry.is_secret === true;
    secretCell.appendChild(secretToggle);
    row.appendChild(secretCell);

    const removeBtn = document.createElement('button');
    removeBtn.type = 'button';
    removeBtn.className = 'btn btn-secondary btn-xs env-remove-btn';
    removeBtn.textContent = 'X';
    removeBtn.addEventListener('click', () => {
      row.remove();
      const hasRows = container.querySelectorAll('.env-dict-row').length > 0;
      if (!hasRows) this.addEnvDictRow();
      this.syncEnvJsonFromDict();
    });
    row.appendChild(removeBtn);

    keyInput.addEventListener('input', () => this.syncEnvJsonFromDict());
    valueInput.addEventListener('input', () => this.syncEnvJsonFromDict());
    secretToggle.addEventListener('change', () => this.syncEnvJsonFromDict());

    container.appendChild(row);
    return row;
  }

  setEnvDictFromPayload(payload) {
    const container = document.getElementById('envDictRows');
    const envJson = document.getElementById('configEnvJson');
    if (!container) {
      if (envJson) envJson.value = stringifyPretty(payload || {});
      return;
    }

    const source = (payload && typeof payload === 'object' && !Array.isArray(payload)) ? payload : {};
    this.envUnsupportedEntries = {};
    container.innerHTML = '';

    const rows = [];
    for (const key of Object.keys(source).sort()) {
      const normalized = this.normalizeEnvEntry(source[key]);
      if (normalized.type === 'row') {
        rows.push({ key, value: normalized.value, is_secret: normalized.is_secret === true });
      } else {
        this.envUnsupportedEntries[key] = normalized.value;
      }
    }

    if (rows.length === 0) rows.push({ key: '', value: '', is_secret: false });
    for (const row of rows) this.addEnvDictRow(row);

    if (envJson) envJson.value = stringifyPretty(source);
    this.syncEnvJsonFromDict();
  }

  readEnvDictPayload(strict = false) {
    const container = document.getElementById('envDictRows');
    if (!container) return {};

    const payload = this.cloneEnvValue(this.envUnsupportedEntries || {}) || {};
    const seen = new Set();
    const rows = Array.from(container.querySelectorAll('.env-dict-row'));
    for (const row of rows) {
      const keyInput = row.querySelector('.env-key');
      const valueInput = row.querySelector('.env-value');
      const secretToggle = row.querySelector('.env-secret');

      const key = String(keyInput?.value || '').trim();
      const value = String(valueInput?.value || '');
      const isSecret = secretToggle?.checked === true;

      if (!key) {
        if (strict && value.trim() !== '') {
          throw new Error('Environment key is required when value is set');
        }
        continue;
      }

      if (seen.has(key)) {
        if (strict) throw new Error(`Duplicate environment key: ${key}`);
        continue;
      }
      seen.add(key);
      payload[key] = isSecret ? { value, is_secret: true } : value;
    }

    return payload;
  }

  syncEnvJsonFromDict() {
    const envJson = document.getElementById('configEnvJson');
    if (!envJson) return;
    const payload = this.readEnvDictPayload(false);
    envJson.value = stringifyPretty(payload);
  }

  applyEnvJsonToDict() {
    const envJson = document.getElementById('configEnvJson');
    const envStatus = document.getElementById('envStatus');
    if (!envJson) return;
    let payload;
    try {
      payload = JSON.parse(String(envJson.value || '{}'));
    } catch {
      throw new Error('Advanced JSON must be valid JSON');
    }
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
      throw new Error('Advanced JSON must be a JSON object');
    }
    this.setEnvDictFromPayload(payload);
    if (envStatus) envStatus.textContent = 'JSON applied to dictionary editor.';
  }

  getExecutionEntriesForCurrentFn() {
    const key = this.eventKey();
    if (!key) return [];
    const entries = this.executionHistory[key];
    return Array.isArray(entries) ? entries : [];
  }

  renderExecutionHistory() {
    const summaryEl = document.getElementById('executionSummary');
    const listEl = document.getElementById('executionList');
    const filterEl = document.getElementById('executionFilter');
    const searchEl = document.getElementById('executionSearch');
    if (!summaryEl || !listEl) return;

    const entries = this.getExecutionEntriesForCurrentFn();
    const filterMode = String(filterEl?.value || 'all');
    const searchNeedle = String(searchEl?.value || '').trim().toLowerCase();
    if (!this.currentFn) {
      summaryEl.textContent = 'Select a function to see execution history.';
      listEl.innerHTML = '<div class="execution-item"><div class="execution-item-meta">No data.</div></div>';
      return;
    }

    if (entries.length === 0) {
      summaryEl.textContent = 'No executions yet.';
      listEl.innerHTML = '<div class="execution-item"><div class="execution-item-meta">Run Test or Invoke to populate history.</div></div>';
      return;
    }

    const filtered = entries.filter((entry) => {
      if (!entry || typeof entry !== 'object') return false;
      if (filterMode === 'ok' && entry.ok !== true) return false;
      if (filterMode === 'fail' && entry.ok === true) return false;
      if (filterMode === 'explorer' && entry.source !== 'explorer') return false;
      if (filterMode === 'test' && entry.source !== 'test') return false;
      if (!searchNeedle) return true;
      const haystack = [
        entry.method,
        entry.route,
        entry.source,
        entry.timestamp,
        String(entry.status ?? ''),
        entry.preview,
      ].join(' ').toLowerCase();
      return haystack.includes(searchNeedle);
    });

    const okCount = filtered.filter((entry) => entry && entry.ok === true).length;
    summaryEl.textContent = `${filtered.length}/${entries.length} execution(s). Success: ${okCount}, failed: ${filtered.length - okCount}.`;

    if (filtered.length === 0) {
      listEl.innerHTML = '<div class="execution-item"><div class="execution-item-meta">No executions match current filters.</div></div>';
      return;
    }

    listEl.innerHTML = filtered.map((entry) => {
      const cls = entry.ok ? 'ok' : 'fail';
      const route = entry.route || '(auto)';
      const preview = entry.preview ? `<div class="execution-item-meta"><code>${esc(entry.preview)}</code></div>` : '';
      return `
        <div class="execution-item ${cls}">
          <div class="execution-item-head">
            <span><strong>${esc(entry.method || 'GET')}</strong> ${esc(route)}</span>
            <span>${esc(String(entry.status || 0))} • ${esc(String(entry.latency_ms || 0))} ms</span>
          </div>
          <div class="execution-item-meta">${esc(entry.timestamp || '')} • source: ${esc(entry.source || 'test')}</div>
          ${preview}
        </div>
      `;
    }).join('');
  }

  clearExecutionHistoryForCurrentFn() {
    const key = this.eventKey();
    if (!key) return;
    delete this.executionHistory[key];
    this.persistExecutionHistory();
    this.renderExecutionHistory();
  }

  recordExecution(payload, response, elapsedMs, out) {
    if (!this.currentFn) return;
    const key = this.eventKey();
    if (!key) return;
    if (!Array.isArray(this.executionHistory[key])) this.executionHistory[key] = [];

    const bodyValue = out && Object.prototype.hasOwnProperty.call(out, 'body') ? out.body : '';
    let preview = '';
    if (bodyValue !== undefined && bodyValue !== null) {
      if (typeof bodyValue === 'string') {
        preview = bodyValue;
      } else {
        try {
          preview = JSON.stringify(bodyValue);
        } catch {
          preview = String(bodyValue);
        }
      }
      if (preview.length > 180) preview = `${preview.slice(0, 180)}...`;
    }

    const explorerPanel = document.querySelector('[data-tab-panel="explorer"]');
    const source = explorerPanel && explorerPanel.classList.contains('active') ? 'explorer' : 'test';
    const entry = {
      timestamp: new Date().toLocaleString(),
      method: String(payload && payload.method ? payload.method : 'GET').toUpperCase(),
      route: String((response && response.route) || (payload && payload.route) || '(auto)'),
      status: Number(response && response.status ? response.status : 0),
      latency_ms: Number((response && response.latency_ms) || elapsedMs || 0),
      ok: Number(response && response.status ? response.status : 0) >= 200 && Number(response && response.status ? response.status : 0) < 300,
      source,
      preview,
    };

    this.executionHistory[key].unshift(entry);
    if (this.executionHistory[key].length > EXEC_HISTORY_LIMIT_PER_FN) {
      this.executionHistory[key] = this.executionHistory[key].slice(0, EXEC_HISTORY_LIMIT_PER_FN);
    }

    this.persistExecutionHistory();
    this.renderExecutionHistory();
  }

  renderSavedEvents() {
    const selectEl = document.getElementById('savedEventSelect');
    if (!selectEl) return;
    const key = this.eventKey();
    const events = (key && this.savedEvents[key] && typeof this.savedEvents[key] === 'object') ? this.savedEvents[key] : {};
    const names = Object.keys(events).sort();
    selectEl.innerHTML = '';

    const empty = document.createElement('option');
    empty.value = '';
    empty.textContent = names.length > 0 ? 'Select saved event' : 'No saved events';
    selectEl.appendChild(empty);

    for (const name of names) {
      const opt = document.createElement('option');
      opt.value = name;
      opt.textContent = name;
      selectEl.appendChild(opt);
    }
  }

  readTestEventObject() {
    const raw = String(document.getElementById('testEventJson')?.value || '{}');
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch {
      parsed = {};
    }
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return {};
    }
    return parsed;
  }

  writeTestEventObject(obj) {
    const event = (obj && typeof obj === 'object' && !Array.isArray(obj)) ? obj : {};
    const testEvent = document.getElementById('testEventJson');
    if (testEvent) testEvent.value = stringifyPretty(event);
    this.applyCompatFromEvent(event);
    this.syncInvokeEventEditor();
  }

  applyCompatFromEvent(event) {
    const route = typeof event.route === 'string' && event.route.trim() !== ''
      ? event.route.trim()
      : (this.currentDetail?.metadata?.invoke?.route || '');
    const params = (event.params && typeof event.params === 'object' && !Array.isArray(event.params))
      ? event.params
      : defaultParamsForRoute(route);
    const query = (event.query && typeof event.query === 'object' && !Array.isArray(event.query))
      ? event.query
      : {};

    const compatRoute = document.getElementById('invokeRoute');
    const compatParams = document.getElementById('pathParams');
    const compatHint = document.getElementById('invokeRouteHint');
    const compatPreview = document.getElementById('invokeUrlPreview');
    const compatQuery = document.getElementById('query');
    if (compatRoute) compatRoute.value = route;
    if (compatParams) {
      const paramsText = stringifyPretty(params);
      compatParams.value = paramsText;
      compatParams.textContent = paramsText;
    }
    if (compatHint) {
      const names = parseRouteParams(route).map((x) => x.name);
      compatHint.textContent = names.length > 0 ? `Required path params: ${names.join(', ')}` : 'No path params required.';
    }
    if (compatPreview) compatPreview.textContent = renderRouteWithParams(route, params);
    if (compatQuery) {
      const hasQueryKeys = query && typeof query === 'object' && !Array.isArray(query) && Object.keys(query).length > 0;
      compatQuery.value = hasQueryKeys ? stringifyPretty(query) : '';
    }
  }

  syncTestEventFromCompatFields() {
    const event = this.readTestEventObject();

    const compatRoute = String(document.getElementById('invokeRoute')?.value || '').trim();
    if (compatRoute) {
      event.route = compatRoute;
    }

    const pathParamsRaw = String(document.getElementById('pathParams')?.value || '{}');
    event.params = parseJsonObject(pathParamsRaw, 'path params');

    const queryRaw = String(document.getElementById('query')?.value || '').trim();
    event.query = queryRaw ? parseQueryInput(queryRaw) : {};

    if (!event.method) {
      const invokeMeta = this.currentDetail?.metadata?.invoke || {};
      event.method = invokeMeta.default_method || 'GET';
    }
    if (event.body === undefined) event.body = '';
    if (!event.context || typeof event.context !== 'object' || Array.isArray(event.context)) {
      event.context = {};
    }

    this.writeTestEventObject(event);
    return event;
  }

  saveCurrentEvent() {
    const nameEl = document.getElementById('savedEventName');
    const metaEl = document.getElementById('invokeMeta') || document.getElementById('testDetailsOutput');
    if (!nameEl || !this.currentFn) return;

    const eventName = String(nameEl.value || '').trim();
    if (!eventName) {
      throw new Error('saved event name is required');
    }

    this.syncTestEventFromCompatFields();
    const currentEvent = this.readTestEventObject();

    const payload = {
      event_json: stringifyPretty(currentEvent),
      route: String(currentEvent.route || this.currentDetail?.metadata?.invoke?.route || ''),
      updated_at: new Date().toISOString(),
    };

    const key = this.eventKey();
    if (!this.savedEvents[key] || typeof this.savedEvents[key] !== 'object') {
      this.savedEvents[key] = {};
    }
    this.savedEvents[key][eventName] = payload;
    this.persistSavedEvents();
    this.renderSavedEvents();
    if (metaEl) metaEl.textContent = `Saved test event: ${eventName}`;
  }

  loadSavedEvent() {
    const selectEl = document.getElementById('savedEventSelect');
    const testEventEl = document.getElementById('testEventJson');
    if (!selectEl || !testEventEl || !this.currentFn) return;

    const name = String(selectEl.value || '');
    if (!name) return;

    const key = this.eventKey();
    const evt = this.savedEvents[key] && this.savedEvents[key][name];
    if (!evt || typeof evt !== 'object') return;

    testEventEl.value = String(evt.event_json || '{}');
    this.applyCompatFromEvent(this.readTestEventObject());
    this.syncInvokeEventEditor();
  }

  bindUi() {
    const search = document.getElementById('globalSearch');
    if (search) {
      search.addEventListener('input', () => {
        this.filterFunctions();
        this.renderGatewayRoutes();
        this.renderSchedulerSnapshot();
      });
    }

    const localFilter = document.getElementById('fnListFilter');
    if (localFilter) {
      localFilter.addEventListener('input', () => this.filterFunctions());
    }

    const routeSearch = document.getElementById('routeSearch');
    if (routeSearch) {
      routeSearch.addEventListener('input', () => this.renderGatewayRoutes());
    }

    const scheduleSearch = document.getElementById('scheduleSearch');
    if (scheduleSearch) {
      scheduleSearch.addEventListener('input', () => this.renderSchedulerSnapshot());
    }

    const executionFilter = document.getElementById('executionFilter');
    const executionSearch = document.getElementById('executionSearch');
    const clearExecutionBtn = document.getElementById('clearExecutionBtn');
    if (executionFilter) executionFilter.addEventListener('change', () => this.renderExecutionHistory());
    if (executionSearch) executionSearch.addEventListener('input', () => this.renderExecutionHistory());
    if (clearExecutionBtn) {
      clearExecutionBtn.addEventListener('click', () => this.clearExecutionHistoryForCurrentFn());
    }

    const monitorLogLines = document.getElementById('monitorLogLines');
    const monitorLogMode = document.getElementById('monitorLogMode');
    const monitorSearch = document.getElementById('monitorSearch');
    const monitorRefreshInterval = document.getElementById('monitorRefreshInterval');
    const triggerMonitorRefresh = () => {
      if (this.currentTab === 'monitor' && this.currentFn) {
        this.refreshMonitor().catch(() => {});
      }
    };
    if (monitorLogLines) monitorLogLines.addEventListener('change', triggerMonitorRefresh);
    if (monitorLogMode) monitorLogMode.addEventListener('change', triggerMonitorRefresh);
    if (monitorSearch) monitorSearch.addEventListener('input', triggerMonitorRefresh);
    if (monitorRefreshInterval) {
      monitorRefreshInterval.addEventListener('change', () => {
        this.syncMonitorAutoRefresh();
        triggerMonitorRefresh();
      });
    }

    const saveEventBtn = document.getElementById('saveEventBtn');
    if (saveEventBtn) {
      saveEventBtn.addEventListener('click', () => {
        try {
          this.saveCurrentEvent();
        } catch (err) {
          alert(err.message || String(err));
        }
      });
    }

    const loadEventBtn = document.getElementById('loadEventBtn');
    if (loadEventBtn) {
      loadEventBtn.addEventListener('click', () => this.loadSavedEvent());
    }

    const apiUsePrimaryBtn = document.getElementById('apiUsePrimaryBtn');
    if (apiUsePrimaryBtn) {
      apiUsePrimaryBtn.addEventListener('click', () => {
        if (!this.apiPrimary) return;
        this.applyApiRoute(this.apiPrimary.route, this.apiPrimary.method, false).catch((err) => {
          alert(err.message || String(err));
        });
      });
    }

    const apiRunPrimaryBtn = document.getElementById('apiRunPrimaryBtn');
    if (apiRunPrimaryBtn) {
      apiRunPrimaryBtn.addEventListener('click', () => {
        if (!this.apiPrimary) return;
        this.applyApiRoute(this.apiPrimary.route, this.apiPrimary.method, true).catch((err) => {
          alert(err.message || String(err));
        });
      });
    }

    const envAddRowBtn = document.getElementById('envAddRowBtn');
    if (envAddRowBtn) {
      envAddRowBtn.addEventListener('click', () => {
        const row = this.addEnvDictRow();
        this.syncEnvJsonFromDict();
        const keyInput = row?.querySelector('.env-key');
        if (keyInput) keyInput.focus();
      });
    }

    const envApplyJsonBtn = document.getElementById('envApplyJsonBtn');
    if (envApplyJsonBtn) {
      envApplyJsonBtn.addEventListener('click', () => {
        try {
          this.applyEnvJsonToDict();
        } catch (err) {
          alert(err.message || String(err));
        }
      });
    }

    const aiModeAuto = document.getElementById('aiModeAuto');
    if (aiModeAuto) aiModeAuto.addEventListener('click', () => this.setAiMode('auto'));
    const aiModeChat = document.getElementById('aiModeChat');
    if (aiModeChat) aiModeChat.addEventListener('click', () => this.setAiMode('chat'));
    const aiModeEdit = document.getElementById('aiModeEdit');
    if (aiModeEdit) aiModeEdit.addEventListener('click', () => this.setAiMode('edit'));
    this.updateAiModeSwitch();

    document.addEventListener('keydown', (ev) => {
      if (ev.altKey && (ev.key === 's' || ev.key === 'S')) {
        ev.preventDefault();
        const input = document.getElementById('globalSearch');
        if (input) input.focus();
      }
    });

    const testEventEl = document.getElementById('testEventJson');
    if (testEventEl) {
      testEventEl.addEventListener('input', () => {
        this.syncInvokeEventEditor();
        this.applyCompatFromEvent(this.readTestEventObject());
      });
    }

    const compatRoute = document.getElementById('invokeRoute');
    if (compatRoute) {
      compatRoute.addEventListener('input', () => {
        const route = String(compatRoute.value || '').trim();
        const params = defaultParamsForRoute(route);
        const hint = document.getElementById('invokeRouteHint');
        const preview = document.getElementById('invokeUrlPreview');
        const pathParams = document.getElementById('pathParams');
        if (hint) {
          const names = parseRouteParams(route).map((x) => x.name);
          hint.textContent = names.length > 0 ? `Required path params: ${names.join(', ')}` : 'No path params required.';
        }
        if (pathParams) {
          const paramsText = stringifyPretty(params);
          pathParams.value = paramsText;
          pathParams.textContent = paramsText;
        }
        if (preview) preview.textContent = renderRouteWithParams(route, params);
      });
    }

    const compatParams = document.getElementById('pathParams');
    if (compatParams) {
      compatParams.addEventListener('input', () => {
        const route = String(document.getElementById('invokeRoute')?.value || '');
        const preview = document.getElementById('invokeUrlPreview');
        try {
          const params = parseJsonObject(compatParams.value || '{}', 'path params');
          if (preview) preview.textContent = renderRouteWithParams(route, params);
        } catch {
          if (preview) preview.textContent = 'Invalid path params JSON';
        }
      });
    }
  }

  bindWizard() {
    initWizard({
      state: this.wizardState,
      loadCatalog: async () => {
        await this.loadFunctions({ refreshSelected: true });
      },
      selectFn: async (runtime, name, version) => {
        await this.openFunction(name, runtime, version, { activateTab: 'code' });
      },
    });
  }

  parseInitialRoute() {
    const path = window.location.pathname || '/console/';
    if (path === '/console/gateway') {
      return { view: 'gateway' };
    }
    if (path === '/console/scheduler') {
      return { view: 'scheduler' };
    }
    if (path === '/console/wizard') {
      return { view: 'wizard' };
    }

    const decodePart = (raw) => {
      try {
        return decodeURIComponent(String(raw || ''));
      } catch {
        return String(raw || '');
      }
    };
    const splitNameVersion = (raw) => {
      const token = String(raw || '');
      const at = token.lastIndexOf('@');
      if (at <= 0) return { name: decodePart(token), version: null };
      return {
        name: decodePart(token.slice(0, at)),
        version: decodePart(token.slice(at + 1)) || null,
      };
    };

    const m1 = path.match(/^\/console\/functions\/([^/]+)\/([^/]+)$/);
    if (m1) {
      const nv = splitNameVersion(m1[2]);
      return {
        view: 'function',
        runtime: decodePart(m1[1]),
        name: nv.name,
        version: nv.version,
      };
    }

    const m2 = path.match(/^\/console\/functions\/([^/]+)$/);
    if (m2) {
      const nv = splitNameVersion(m2[1]);
      return {
        view: 'function',
        runtime: null,
        name: nv.name,
        version: nv.version,
      };
    }

    return { view: 'list' };
  }

  renderConsoleIdentity() {
    const regionEl = document.getElementById('consoleRegion');
    const userEl = document.getElementById('consoleUser');
    const hostLabel = String(window.location.host || '').trim() || 'localhost:8080';
    if (regionEl) regionEl.textContent = hostLabel;

    let userLabel = 'local';
    const state = this.uiState;
    if (state && typeof state.current_user === 'string' && state.current_user.trim() !== '') {
      userLabel = state.current_user.trim();
    } else if (state && state.login_enabled === true) {
      userLabel = 'authenticated';
    }
    if (userEl) userEl.textContent = userLabel;
  }

  async loadUiState() {
    try {
      this.uiState = await getJson('/_fn/ui-state');
    } catch {
      this.uiState = null;
    }
    this.renderConsoleIdentity();
  }

  async init() {
    this.bindUi();
    this.bindWizard();

    const route = this.parseInitialRoute();
    await this.loadUiState();
    await this.loadFunctions({ refreshSelected: false });
    this.syncCatalogAutoRefresh();

    if (route.view === 'gateway') {
      this.showGateway(false);
      return;
    }

    if (route.view === 'scheduler') {
      this.showScheduler(false);
      return;
    }

    if (route.view === 'wizard') {
      this.showWizard(false);
      return;
    }

    if (route.view === 'function') {
      await this.openFunction(route.name, route.runtime, route.version, { pushUrl: false });
      return;
    }

    this.showFunctionList(false);
  }

  setSidebarActive(navId) {
    ['navFunctions', 'navGateway', 'navScheduler', 'navWizard', 'navDashboard'].forEach((id) => {
      const el = document.getElementById(id);
      if (el) el.classList.remove('active');
    });
    const target = document.getElementById(navId);
    if (target) target.classList.add('active');
  }

  updateViewVisibility() {
    const list = document.getElementById('functionListView');
    const gateway = document.getElementById('gatewayView');
    const scheduler = document.getElementById('schedulerView');
    const wizard = document.getElementById('wizardView');
    const detail = document.getElementById('functionDetailView');
    const crumb = document.getElementById('breadcrumbFnName');

    if (this.currentView === 'functionList') {
      if (list) list.style.display = 'block';
      if (gateway) gateway.style.display = 'none';
      if (scheduler) scheduler.style.display = 'none';
      if (wizard) wizard.style.display = 'none';
      if (detail) detail.style.display = 'none';
      if (crumb) crumb.style.display = 'none';
      this.setSidebarActive('navFunctions');
      return;
    }

    if (this.currentView === 'gateway') {
      if (list) list.style.display = 'none';
      if (gateway) gateway.style.display = 'block';
      if (scheduler) scheduler.style.display = 'none';
      if (wizard) wizard.style.display = 'none';
      if (detail) detail.style.display = 'none';
      if (crumb) {
        crumb.style.display = 'inline';
        crumb.textContent = 'Gateway Routes';
      }
      this.setSidebarActive('navGateway');
      return;
    }

    if (this.currentView === 'scheduler') {
      if (list) list.style.display = 'none';
      if (gateway) gateway.style.display = 'none';
      if (scheduler) scheduler.style.display = 'block';
      if (wizard) wizard.style.display = 'none';
      if (detail) detail.style.display = 'none';
      if (crumb) {
        crumb.style.display = 'inline';
        crumb.textContent = 'Scheduler';
      }
      this.setSidebarActive('navScheduler');
      return;
    }

    if (this.currentView === 'wizard') {
      if (list) list.style.display = 'none';
      if (gateway) gateway.style.display = 'none';
      if (scheduler) scheduler.style.display = 'none';
      if (wizard) wizard.style.display = 'block';
      if (detail) detail.style.display = 'none';
      if (crumb) {
        crumb.style.display = 'inline';
        crumb.textContent = 'Wizard';
      }
      this.setSidebarActive('navWizard');
      return;
    }

    if (list) list.style.display = 'none';
    if (gateway) gateway.style.display = 'none';
    if (scheduler) scheduler.style.display = 'none';
    if (wizard) wizard.style.display = 'none';
    if (detail) detail.style.display = 'block';
    if (crumb) {
      crumb.style.display = 'inline';
      const label = this.currentFn ? `${this.currentFn.runtime}/${this.currentFn.name}${this.currentFn.version ? `@${this.currentFn.version}` : ''}` : 'Select a function';
      crumb.textContent = label;
    }
    this.setSidebarActive('navFunctions');
  }

  showFunctionList(pushUrl = true) {
    this.currentView = 'functionList';
    this.updateViewVisibility();
    if (pushUrl) history.pushState({}, '', '/console/');
  }

  showGateway(pushUrl = true) {
    this.currentView = 'gateway';
    this.updateViewVisibility();
    this.renderGatewayRoutes();
    if (pushUrl) history.pushState({}, '', '/console/gateway');
  }

  showScheduler(pushUrl = true) {
    this.currentView = 'scheduler';
    this.updateViewVisibility();
    this.refreshScheduler().catch((err) => alert(err.message || String(err)));
    if (pushUrl) history.pushState({}, '', '/console/scheduler');
  }

  showWizard(pushUrl = true) {
    this.currentView = 'wizard';
    this.updateViewVisibility();
    if (pushUrl) history.pushState({}, '', '/console/wizard');
  }

  setCompatExplorerActive(active) {
    const panel = document.querySelector('[data-tab-panel="explorer"]');
    if (panel) panel.classList.toggle('active', active === true);
    const btn = document.querySelector('[data-tab-btn="explorer"]');
    if (btn) btn.classList.toggle('active', active === true);
  }

  showCompatExplorer() {
    this.currentView = 'functionDetail';
    this.updateViewVisibility();
    this.switchTab('test');
    this.setCompatExplorerActive(true);
  }

  switchTab(tabName) {
    const rawTab = String(tabName || '').trim().toLowerCase();
    const normalizedTab = rawTab === 'swagger' ? 'api' : rawTab;
    const tab = DEFAULT_TABS.has(normalizedTab) ? normalizedTab : 'code';
    this.currentTab = tab;

    document.querySelectorAll('.tab-btn').forEach((btn) => {
      btn.classList.toggle('active', btn.getAttribute('data-tab') === tab);
    });

    document.querySelectorAll('.tab-content').forEach((panel) => {
      panel.classList.toggle('active', panel.id === `tab-${tab}`);
    });

    if (tab === 'monitor') {
      this.syncMonitorAutoRefresh();
      this.refreshMonitor().catch((err) => {
        const logs = document.getElementById('monitorLogs');
        if (logs) logs.textContent = String(err && err.message ? err.message : err);
      });
    } else {
      this.clearMonitorAutoRefresh();
    }
  }

  flattenRowsFromCatalog(catalog) {
    const rows = [];
    if (!catalog || !catalog.runtimes) return rows;

    const mapped = catalog.mapped_routes || {};

    const mappedRoutesFor = (runtime, name, version) => {
      const routes = [];
      for (const route of Object.keys(mapped).sort()) {
        let entries = mapped[route];
        if (entries && typeof entries === 'object' && !Array.isArray(entries) && entries.runtime) {
          entries = [entries];
        }
        if (!Array.isArray(entries)) continue;
        for (const entry of entries) {
          if (!entry || typeof entry !== 'object') continue;
          if (entry.runtime !== runtime) continue;
          if (entry.fn_name !== name) continue;
          if ((entry.version || null) !== (version || null)) continue;
          routes.push(route);
          break;
        }
      }
      return routes;
    };

    for (const runtime of Object.keys(catalog.runtimes).sort()) {
      const rt = catalog.runtimes[runtime];
      const fns = toFunctionArray(rt.functions);
      for (const fn of fns) {
        if (fn.has_default) {
          const routes = mappedRoutesFor(runtime, fn.name, null);
          rows.push({
            runtime,
            name: fn.name,
            version: null,
            methods: Array.isArray(fn.policy?.methods) ? fn.policy.methods : ['GET'],
            routes,
          });
        }

        for (const version of toVersionArray(fn.versions)) {
          const vp = fn.versions_policy && fn.versions_policy[version];
          const routes = mappedRoutesFor(runtime, fn.name, version);
          rows.push({
            runtime,
            name: fn.name,
            version,
            methods: Array.isArray(vp?.methods) ? vp.methods : (Array.isArray(fn.policy?.methods) ? fn.policy.methods : ['GET']),
            routes,
          });
        }
      }
    }

    rows.sort((a, b) => {
      const ar = `${a.runtime}/${a.name}@${a.version || 'default'}`;
      const br = `${b.runtime}/${b.name}@${b.version || 'default'}`;
      return ar.localeCompare(br);
    });

    return rows;
  }

  flattenGatewayRows(catalog) {
    const rows = [];
    const mapped = (catalog && catalog.mapped_routes) || {};
    for (const route of Object.keys(mapped).sort()) {
      for (const entry of normalizeMappedEntries(mapped[route])) {
        if (!entry || typeof entry !== 'object') continue;
        const runtime = String(entry.runtime || '').trim();
        const name = String(entry.fn_name || '').trim();
        if (!runtime || !name) continue;
        rows.push({
          route,
          runtime,
          name,
          version: entry.version || null,
          methods: Array.isArray(entry.methods) ? entry.methods : [],
          target: typeof entry.target === 'string' ? entry.target : '',
          proxyHint: (typeof entry.target === 'string' && /edge|proxy/i.test(entry.target)) ? 'edge/proxy' : '',
        });
      }
    }
    return rows;
  }

  renderGatewayRoutes() {
    const summaryEl = document.getElementById('gatewaySummary');
    const tbody = document.getElementById('routeTableBody');
    const conflictsEl = document.getElementById('routeConflicts');
    if (!summaryEl || !tbody || !conflictsEl) return;

    const mapped = (this.catalog && this.catalog.mapped_routes) || {};
    const allRoutes = Object.keys(mapped).sort();
    const q = String(document.getElementById('routeSearch')?.value || '').trim().toLowerCase();

    const rows = (this.gatewayRows || []).filter((row) => {
      if (!q) return true;
      const text = `${row.route} ${row.runtime} ${row.name} ${row.version || ''} ${row.target} ${(row.methods || []).join(',')} ${row.proxyHint}`.toLowerCase();
      return text.includes(q);
    });

    const conflictsObj = (this.catalog && this.catalog.mapped_route_conflicts) || {};
    const conflictRoutes = Object.keys(conflictsObj).sort();

    summaryEl.textContent = `Mapped routes: ${allRoutes.length} | visible: ${rows.length} | conflicts: ${conflictRoutes.length}`;
    tbody.innerHTML = '';

    if (rows.length === 0) {
      const tr = document.createElement('tr');
      const td = document.createElement('td');
      td.colSpan = 4;
      td.textContent = allRoutes.length === 0 ? 'No mapped routes configured.' : 'No mapped routes match the filter.';
      tr.appendChild(td);
      tbody.appendChild(tr);
    } else {
      for (const row of rows) {
        const tr = document.createElement('tr');

        const routeTd = document.createElement('td');
        routeTd.innerHTML = `<code>${esc(row.route)}</code>`;
        tr.appendChild(routeTd);

        const targetTd = document.createElement('td');
        const label = row.target || `${row.runtime}/${publicLabel(row.name, row.version || null)}`;
        targetTd.innerHTML = `<span class="badge">${esc(row.runtime || 'unknown')}</span> <code>${esc(label)}</code>`;
        tr.appendChild(targetTd);

        const methodsTd = document.createElement('td');
        const methodsText = Array.isArray(row.methods) && row.methods.length > 0 ? row.methods.join(',') : 'GET';
        methodsTd.textContent = row.proxyHint ? `${methodsText} | ${row.proxyHint}` : methodsText;
        tr.appendChild(methodsTd);

        const actionsTd = document.createElement('td');
        const openBtn = document.createElement('button');
        openBtn.className = 'btn btn-xs btn-secondary';
        openBtn.textContent = 'Open';
        openBtn.disabled = !(row.runtime && row.name);
        openBtn.addEventListener('click', () => {
          this.openMappedRoute(row).catch((err) => alert(err.message || String(err)));
        });
        actionsTd.appendChild(openBtn);
        tr.appendChild(actionsTd);

        tbody.appendChild(tr);
      }
    }

    if (conflictRoutes.length === 0) {
      conflictsEl.textContent = 'No conflicts.';
    } else {
      conflictsEl.innerHTML = conflictRoutes.map((route) => `<div><code>${esc(route)}</code></div>`).join('');
    }
  }

  async refreshScheduler() {
    const summaryEl = document.getElementById('scheduleSummary');
    if (summaryEl) summaryEl.textContent = 'Loading scheduler snapshot...';
    try {
      const snapshot = await getJson('/_fn/schedules');
      this.schedulerSnapshot = snapshot;
      this.renderSchedulerSnapshot();
    } catch (err) {
      if (summaryEl) summaryEl.textContent = `Scheduler snapshot error: ${String(err && err.message ? err.message : err)}`;
      throw err;
    }
  }

  renderSchedulerSnapshot() {
    const summaryEl = document.getElementById('scheduleSummary');
    const tbody = document.getElementById('scheduleTableBody');
    const keepWarmTbody = document.getElementById('keepWarmTableBody');
    if (!summaryEl || !tbody || !keepWarmTbody) return;

    const snapshot = this.schedulerSnapshot;
    const schedules = Array.isArray(snapshot?.schedules) ? snapshot.schedules : [];
    const keepWarm = Array.isArray(snapshot?.keep_warm) ? snapshot.keep_warm : [];
    const tsIso = snapshot?.ts ? formatUnixSeconds(snapshot.ts) : '';

    const globalQ = String(document.getElementById('globalSearch')?.value || '').trim().toLowerCase();
    const localQ = String(document.getElementById('scheduleSearch')?.value || '').trim().toLowerCase();
    const q = `${globalQ} ${localQ}`.trim();

    const matches = (rowText) => {
      if (!q) return true;
      return String(rowText || '').toLowerCase().includes(q);
    };

    const filteredSchedules = schedules
      .filter((entry) => {
        const retry = entry?.schedule?.retry;
        const retryText = (retry && typeof retry === 'object')
          ? `${retry.enabled} ${retry.max_attempts || ''} ${retry.base_delay_seconds || ''} ${retry.max_delay_seconds || ''} ${retry.jitter || ''}`
          : String(retry || '');
        const text = `${entry.runtime} ${entry.name} ${entry.version || ''} ${entry?.schedule?.method || ''} ${entry?.schedule?.every_seconds || ''} ${entry?.schedule?.cron || ''} ${entry?.schedule?.timezone || ''} ${retryText} ${entry?.state?.last_status || ''} ${entry?.state?.last_error || ''}`;
        return matches(text);
      })
      .sort((a, b) => {
        const ak = `${a.runtime}/${a.name}@${a.version || ''}`;
        const bk = `${b.runtime}/${b.name}@${b.version || ''}`;
        return ak.localeCompare(bk);
      });

    const filteredKeepWarm = keepWarm
      .filter((entry) => {
        const text = `${entry.runtime} ${entry.name} ${entry.version || ''} ${entry?.state?.warm_state || ''} ${entry?.state?.last_status || ''} ${entry?.state?.last_error || ''}`;
        return matches(text);
      })
      .sort((a, b) => {
        const ak = `${a.runtime}/${a.name}@${a.version || ''}`;
        const bk = `${b.runtime}/${b.name}@${b.version || ''}`;
        return ak.localeCompare(bk);
      });

    summaryEl.textContent = [
      `Active schedules: ${schedules.length} (visible: ${filteredSchedules.length})`,
      `keep_warm: ${keepWarm.length} (visible: ${filteredKeepWarm.length})`,
      tsIso ? `snapshot: ${tsIso}` : null,
    ].filter(Boolean).join(' | ');

    tbody.innerHTML = '';
    if (snapshot == null) {
      const tr = document.createElement('tr');
      const td = document.createElement('td');
      td.colSpan = 7;
      td.textContent = 'No scheduler snapshot loaded yet. Click refresh.';
      tr.appendChild(td);
      tbody.appendChild(tr);
    } else if (filteredSchedules.length === 0) {
      const tr = document.createElement('tr');
      const td = document.createElement('td');
      td.colSpan = 7;
      td.textContent = schedules.length === 0 ? 'No active schedules.' : 'No schedules match the filter.';
      tr.appendChild(td);
      tbody.appendChild(tr);
    } else {
      for (const entry of filteredSchedules) {
        const tr = document.createElement('tr');

        const fnTd = document.createElement('td');
        const label = `${entry.name}${entry.version ? `@${entry.version}` : ''}`;
        fnTd.innerHTML = `<span class="badge">${esc(entry.runtime || '')}</span> <code>${esc(label)}</code>`;
        tr.appendChild(fnTd);

        const scheduleTd = document.createElement('td');
        const schedLabel = formatScheduleLabel(entry?.schedule);
        scheduleTd.textContent = schedLabel;
        const retrySummary = scheduleRetrySummary(entry?.schedule?.retry);
        const titleBits = [];
        if (schedLabel) titleBits.push(schedLabel);
        if (retrySummary) titleBits.push(retrySummary);
        if (titleBits.length > 0) scheduleTd.title = titleBits.join(' | ');
        tr.appendChild(scheduleTd);

        const methodTd = document.createElement('td');
        methodTd.textContent = String(entry?.schedule?.method || 'GET').toUpperCase();
        tr.appendChild(methodTd);

        const nextTd = document.createElement('td');
        const nextRaw = entry?.state?.next;
        nextTd.textContent = formatUnixSeconds(nextRaw) || '';
        if (nextRaw != null) nextTd.title = String(nextRaw);
        tr.appendChild(nextTd);

        const lastTd = document.createElement('td');
        const lastRaw = entry?.state?.last;
        lastTd.textContent = formatUnixSeconds(lastRaw) || '';
        if (lastRaw != null) lastTd.title = String(lastRaw);
        tr.appendChild(lastTd);

        const statusTd = document.createElement('td');
        const statusRaw = entry?.state?.last_status;
        const statusText = (statusRaw != null && statusRaw !== '') ? String(statusRaw) : '-';
        const badgeCls = badgeClassForHttpStatus(statusRaw);
        statusTd.innerHTML = `<span class="badge${badgeCls ? ` ${badgeCls}` : ''}">${esc(statusText)}</span>`;
        const errText = entry?.state?.last_error;
        if (errText != null && String(errText).trim() !== '') statusTd.title = String(errText);
        tr.appendChild(statusTd);

        const actionsTd = document.createElement('td');
        const openBtn = document.createElement('button');
        openBtn.className = 'btn btn-xs btn-secondary';
        openBtn.textContent = 'Open';
        openBtn.disabled = !(entry.runtime && entry.name);
        openBtn.addEventListener('click', () => {
          this.openFunction(entry.name, entry.runtime, entry.version || null).catch((err) => alert(err.message || String(err)));
        });
        actionsTd.appendChild(openBtn);
        tr.appendChild(actionsTd);

        tbody.appendChild(tr);
      }
    }

    keepWarmTbody.innerHTML = '';
    if (snapshot == null) {
      const tr = document.createElement('tr');
      const td = document.createElement('td');
      td.colSpan = 6;
      td.textContent = 'No keep_warm snapshot loaded yet.';
      tr.appendChild(td);
      keepWarmTbody.appendChild(tr);
      return;
    }

    if (filteredKeepWarm.length === 0) {
      const tr = document.createElement('tr');
      const td = document.createElement('td');
      td.colSpan = 6;
      td.textContent = keepWarm.length === 0 ? 'No keep_warm entries.' : 'No keep_warm entries match the filter.';
      tr.appendChild(td);
      keepWarmTbody.appendChild(tr);
      return;
    }

    const warmStateClass = (state) => {
      const v = String(state || '').toLowerCase();
      if (v === 'warm') return 'success';
      if (v === 'stale') return 'warn';
      if (v === 'cold') return 'danger';
      return '';
    };

    for (const entry of filteredKeepWarm) {
      const tr = document.createElement('tr');

      const fnTd = document.createElement('td');
      const label = `${entry.name}${entry.version ? `@${entry.version}` : ''}`;
      fnTd.innerHTML = `<span class="badge">${esc(entry.runtime || '')}</span> <code>${esc(label)}</code>`;
      tr.appendChild(fnTd);

      const stateTd = document.createElement('td');
      const warmState = entry?.state?.warm_state || '';
      const wsCls = warmStateClass(warmState);
      stateTd.innerHTML = `<span class="badge${wsCls ? ` ${wsCls}` : ''}">${esc(warmState || '-')}</span>`;
      tr.appendChild(stateTd);

      const nextTd = document.createElement('td');
      const nextRaw = entry?.state?.next;
      nextTd.textContent = formatUnixSeconds(nextRaw) || '';
      if (nextRaw != null) nextTd.title = String(nextRaw);
      tr.appendChild(nextTd);

      const lastTd = document.createElement('td');
      const lastRaw = entry?.state?.last;
      lastTd.textContent = formatUnixSeconds(lastRaw) || '';
      if (lastRaw != null) lastTd.title = String(lastRaw);
      tr.appendChild(lastTd);

      const statusTd = document.createElement('td');
      const statusRaw = entry?.state?.last_status;
      const statusText = (statusRaw != null && statusRaw !== '') ? String(statusRaw) : '-';
      const badgeCls = badgeClassForHttpStatus(statusRaw);
      statusTd.innerHTML = `<span class="badge${badgeCls ? ` ${badgeCls}` : ''}">${esc(statusText)}</span>`;
      const errText = entry?.state?.last_error;
      if (errText != null && String(errText).trim() !== '') statusTd.title = String(errText);
      tr.appendChild(statusTd);

      const actionsTd = document.createElement('td');
      const openBtn = document.createElement('button');
      openBtn.className = 'btn btn-xs btn-secondary';
      openBtn.textContent = 'Open';
      openBtn.disabled = !(entry.runtime && entry.name);
      openBtn.addEventListener('click', () => {
        this.openFunction(entry.name, entry.runtime, entry.version || null).catch((err) => alert(err.message || String(err)));
      });
      actionsTd.appendChild(openBtn);
      tr.appendChild(actionsTd);

      keepWarmTbody.appendChild(tr);
    }
  }

  renderFunctionList(rows) {
    const tbody = document.getElementById('fnTableBody');
    if (!tbody) return;
    tbody.innerHTML = '';

    if (!rows || rows.length === 0) {
      const tr = document.createElement('tr');
      tr.innerHTML = '<td colspan="4">No functions discovered.</td>';
      tbody.appendChild(tr);
      return;
    }

    for (const row of rows) {
      const tr = document.createElement('tr');

      const tdName = document.createElement('td');
      const btn = document.createElement('button');
      btn.className = 'btn btn-xs btn-secondary';
      btn.style.border = 'none';
      btn.style.background = 'transparent';
      btn.style.padding = '0';
      btn.style.color = '#0073bb';
      btn.style.fontWeight = '700';
      btn.style.cursor = 'pointer';
      btn.textContent = `${row.name}${row.version ? `@${row.version}` : ''}`;
      btn.addEventListener('click', () => {
        this.openFunction(row.name, row.runtime, row.version).catch((err) => alert(err.message || String(err)));
      });
      tdName.appendChild(btn);
      tr.appendChild(tdName);

      const tdRt = document.createElement('td');
      tdRt.innerHTML = `<span class="badge">${esc(row.runtime)}</span>`;
      tr.appendChild(tdRt);

      const tdMethod = document.createElement('td');
      tdMethod.textContent = (row.methods && row.methods.length > 0) ? row.methods.join(',') : 'GET';
      tr.appendChild(tdMethod);

      const tdAction = document.createElement('td');
      tdAction.className = 'actions-cell';
      const openBtn = document.createElement('button');
      openBtn.className = 'btn btn-xs btn-secondary';
      openBtn.textContent = 'View';
      openBtn.addEventListener('click', () => {
        this.openFunction(row.name, row.runtime, row.version).catch((err) => alert(err.message || String(err)));
      });
      tdAction.appendChild(openBtn);
      tr.appendChild(tdAction);

      tbody.appendChild(tr);
    }
  }

  filterFunctions() {
    const local = String(document.getElementById('fnListFilter')?.value || '').trim().toLowerCase();
    const global = String(document.getElementById('globalSearch')?.value || '').trim().toLowerCase();
    const query = `${local} ${global}`.trim();

    if (!query) {
      this.renderFunctionList(this.functionRows);
      return;
    }

    const filtered = this.functionRows.filter((row) => {
      const label = `${row.runtime} ${row.name} ${row.version || ''} ${(row.methods || []).join(' ')} ${(row.routes || []).join(' ')}`.toLowerCase();
      return label.includes(query);
    });
    this.renderFunctionList(filtered);
  }

  async loadFunctions(opts = {}) {
    const nextCatalog = await getJson('/_fn/catalog');
    const nextFingerprint = this.buildCatalogFingerprint(nextCatalog);
    const changed = nextFingerprint !== this.lastCatalogFingerprint;
    if (opts.skipIfUnchanged && !changed) {
      return false;
    }
    this.catalog = nextCatalog;
    this.lastCatalogFingerprint = nextFingerprint;
    this.functionRows = this.flattenRowsFromCatalog(this.catalog);
    this.gatewayRows = this.flattenGatewayRows(this.catalog);
    this.filterFunctions();
    this.renderGatewayRoutes();

    if (opts.refreshSelected && this.currentFn) {
      const exists = this.functionRows.some((row) => (
        row.runtime === this.currentFn.runtime
        && row.name === this.currentFn.name
        && (row.version || null) === (this.currentFn.version || null)
      ));
      if (exists) {
        await this.openFunction(this.currentFn.name, this.currentFn.runtime, this.currentFn.version, {
          pushUrl: false,
          activateTab: this.currentTab,
        });
      }
    }
    return changed;
  }

  resolveFunctionRef(name, runtime, version) {
    if (runtime) {
      return this.functionRows.find((row) => (
        row.runtime === runtime
        && row.name === name
        && (row.version || null) === (version || null)
      ));
    }

    if (version) {
      return this.functionRows.find((row) => row.name === name && (row.version || null) === (version || null));
    }

    return this.functionRows.find((row) => row.name === name) || null;
  }

  buildFunctionUrl(runtime, name, version) {
    return `/console/functions/${encodeURIComponent(runtime)}/${encodeURIComponent(name)}${version ? `@${encodeURIComponent(version)}` : ''}`;
  }

  async openMappedRoute(row) {
    if (!row || !row.runtime || !row.name) return;
    this.currentGatewayRoute = String(row.route || '');
    await this.openFunction(row.name, row.runtime, row.version || null, { activateTab: 'test', preserveGatewayRoute: true });
    if (this.currentGatewayRoute) {
      const event = this.readTestEventObject();
      event.route = this.currentGatewayRoute;
      event.params = defaultParamsForRoute(this.currentGatewayRoute);
      if (!event.query || typeof event.query !== 'object' || Array.isArray(event.query)) event.query = {};
      this.writeTestEventObject(event);
    }
    this.showCompatExplorer();
  }

  async openFunction(name, runtime = null, version = null, opts = {}) {
    const ref = this.resolveFunctionRef(name, runtime, version);
    if (!ref) {
      throw new Error(`Function not found: ${runtime ? `${runtime}/` : ''}${name}${version ? `@${version}` : ''}`);
    }

    this.currentFn = {
      runtime: ref.runtime,
      name: ref.name,
      version: ref.version || null,
    };
    if (!opts.preserveGatewayRoute) this.currentGatewayRoute = null;
    this.currentView = 'functionDetail';

    const fnLabel = `${ref.name}${ref.version ? `@${ref.version}` : ''}`;
    const detailName = document.getElementById('detailFnName');
    const crumb = document.getElementById('breadcrumbFnName');
    const status = document.getElementById('detailStatus');
    const runtimeBadge = document.getElementById('detailRuntime');

    if (detailName) detailName.textContent = fnLabel;
    if (crumb) crumb.textContent = `${ref.runtime}/${fnLabel}`;
    if (status) status.textContent = 'Loading...';
    if (runtimeBadge) runtimeBadge.textContent = ref.runtime;

    this.updateViewVisibility();
    this.setCompatExplorerActive(false);

    const q = new URLSearchParams({
      runtime: ref.runtime,
      name: ref.name,
      include_code: '1',
    });
    if (ref.version) q.set('version', ref.version);

    const detail = await getJson(`/_fn/function?${q.toString()}`);
    this.currentDetail = detail;

    this.handlerFile = String(detail.metadata?.handler_file || detail.file_path?.split('/').pop() || 'handler.js');
    this.fileContents = {
      [this.handlerFile]: String(detail.code || ''),
      'fn.config.json': stringifyPretty({
        policy: detail.policy || {},
        metadata: detail.metadata || {},
      }),
      'fn.env.json': stringifyPretty(detail.fn_env || {}),
    };

    this.currentFile = this.handlerFile;
    this.renderFileTree();
    this.renderEditor();
    this.fillConfigForm(detail);
    this.fillDefaultTestEvent(detail);
    this.updateApiGuide(detail);
    this.renderSavedEvents();
    this.renderExecutionHistory();
    this.renderAiHistory();

    if (runtimeBadge) runtimeBadge.textContent = `${detail.runtime}${detail.version ? `@${detail.version}` : ''}`;
    if (status) status.textContent = 'Active';

    const desiredTab = DEFAULT_TABS.has(opts.activateTab) ? opts.activateTab : (this.currentTab || 'code');
    this.switchTab(desiredTab);

    if (opts.pushUrl !== false) {
      history.pushState({}, '', this.buildFunctionUrl(ref.runtime, ref.name, ref.version));
    }
  }

  renderFileTree() {
    const tree = document.getElementById('fileList');
    if (!tree) return;

    tree.innerHTML = '';
    const files = Object.keys(this.fileContents);
    for (const file of files) {
      const div = document.createElement('div');
      div.className = `file-item ${file === this.currentFile ? 'active' : ''}`;
      div.innerHTML = `<ion-icon name="document-text-outline"></ion-icon> ${esc(file)}`;
      div.addEventListener('click', () => this.switchFile(file));
      tree.appendChild(div);
    }
  }

  renderEditor() {
    const label = document.getElementById('currentFileLabel');
    const editor = document.getElementById('codeEditor');
    const saveBtn = document.getElementById('saveCodeBtn');
    if (label) label.textContent = this.currentFile;
    if (editor) editor.value = this.fileContents[this.currentFile] || '';

    const editable = this.currentFile === this.handlerFile;
    if (editor) {
      editor.readOnly = !editable;
      editor.style.background = editable ? '#fdfdfd' : '#f5f5f5';
    }
    if (saveBtn) {
      saveBtn.disabled = !editable;
      saveBtn.textContent = editable ? 'Deploy' : 'Read only';
    }
  }

  switchFile(file) {
    if (!this.fileContents[file]) return;
    this.currentFile = file;
    this.renderFileTree();
    this.renderEditor();
  }

  fillConfigForm(detail) {
    const policy = detail.policy || {};
    const invoke = detail.metadata?.invoke || {};
    const envView = detail.fn_env || {};
    const scheduleCfg = detail.metadata?.schedule?.configured;

    const timeout = document.getElementById('configTimeout');
    const conc = document.getElementById('configConcurrency');
    const maxBody = document.getElementById('configMaxBody');
    const methodsInput = document.getElementById('configMethods');
    const routes = document.getElementById('configRoutes');
    const deps = document.getElementById('configSharedDeps');
    const handler = document.getElementById('configHandler');
    const scheduleEnabled = document.getElementById('configScheduleEnabled');
    const scheduleEverySeconds = document.getElementById('configScheduleEverySeconds');
    const scheduleMethod = document.getElementById('configScheduleMethod');
    const scheduleQuery = document.getElementById('configScheduleQuery');
    const scheduleHeaders = document.getElementById('configScheduleHeaders');
    const scheduleBody = document.getElementById('configScheduleBody');
    const scheduleContext = document.getElementById('configScheduleContext');
    const env = document.getElementById('configEnvJson');
    const configStatus = document.getElementById('configStatus');
    const envStatus = document.getElementById('envStatus');

    const methods = Array.isArray(invoke.methods) && invoke.methods.length > 0
      ? invoke.methods
      : (Array.isArray(policy.methods) && policy.methods.length > 0 ? policy.methods : ['GET']);
    const mappedRoutes = Array.isArray(invoke.mapped_routes) && invoke.mapped_routes.length > 0
      ? invoke.mapped_routes
      : (Array.isArray(invoke.routes) && invoke.routes.length > 0 ? invoke.routes : (invoke.route ? [invoke.route] : []));

    if (timeout) timeout.value = policy.timeout_ms ?? '';
    if (conc) conc.value = policy.max_concurrency ?? '';
    if (maxBody) maxBody.value = policy.max_body_bytes ?? '';
    if (hasConfigMethodToggles()) {
      writeMethodsToToggles(methods);
    } else if (methodsInput) {
      methodsInput.value = methods.join(',');
    }
    if (routes) routes.value = mappedRoutes.join('\n');

    const configuredDeps = detail.metadata?.shared_deps?.configured;
    if (deps) deps.value = Array.isArray(configuredDeps) ? configuredDeps.join('\n') : '';
    if (handler) handler.value = typeof invoke.handler === 'string' ? invoke.handler : '';
    const hasSchedule = scheduleCfg && typeof scheduleCfg === 'object' && !Array.isArray(scheduleCfg);
    if (scheduleEnabled) scheduleEnabled.checked = hasSchedule && scheduleCfg.enabled === true;
    if (scheduleEverySeconds) {
      scheduleEverySeconds.value = hasSchedule && scheduleCfg.every_seconds != null
        ? String(scheduleCfg.every_seconds)
        : '';
    }
    if (scheduleMethod) {
      const method = hasSchedule && scheduleCfg.method ? String(scheduleCfg.method).toUpperCase() : 'GET';
      scheduleMethod.value = ALLOWED_HTTP_METHODS.includes(method) ? method : 'GET';
    }
    if (scheduleQuery) {
      scheduleQuery.value = hasSchedule && scheduleCfg.query && typeof scheduleCfg.query === 'object'
        ? stringifyPretty(scheduleCfg.query)
        : '';
    }
    if (scheduleHeaders) {
      scheduleHeaders.value = hasSchedule && scheduleCfg.headers && typeof scheduleCfg.headers === 'object'
        ? stringifyPretty(scheduleCfg.headers)
        : '';
    }
    if (scheduleBody) {
      scheduleBody.value = hasSchedule && scheduleCfg.body != null ? String(scheduleCfg.body) : '';
    }
    if (scheduleContext) {
      scheduleContext.value = hasSchedule && scheduleCfg.context && typeof scheduleCfg.context === 'object'
        ? stringifyPretty(scheduleCfg.context)
        : '';
    }
    this.renderScheduleState(detail);

    if (env) env.value = stringifyPretty(envView);
    this.setEnvDictFromPayload(envView);
    if (configStatus) configStatus.textContent = '';
    if (envStatus) envStatus.textContent = '';
  }

  renderScheduleState(detail) {
    const stateEl = document.getElementById('configScheduleState');
    if (!stateEl) return;
    const state = detail?.metadata?.schedule?.state || {};
    const nextRaw = state.next;
    const lastRaw = state.last;
    const lastStatus = state.last_status;
    const lastError = state.last_error;

    const parts = [];
    if (nextRaw != null && nextRaw !== '') {
      const iso = formatUnixSeconds(nextRaw);
      parts.push(`next=${nextRaw}${iso ? ` (${iso})` : ''}`);
    }
    if (lastRaw != null && lastRaw !== '') {
      const iso = formatUnixSeconds(lastRaw);
      parts.push(`last=${lastRaw}${iso ? ` (${iso})` : ''}`);
    }
    if (lastStatus != null && lastStatus !== '') {
      parts.push(`last_status=${lastStatus}`);
    }
    if (lastError != null && String(lastError).trim() !== '') {
      parts.push(`last_error=${String(lastError)}`);
    }

    stateEl.textContent = parts.length > 0
      ? `Scheduler state: ${parts.join(' | ')}`
      : 'Scheduler state: no runs yet.';
  }

  collectApiRoutes(detail) {
    const invoke = detail?.metadata?.invoke || {};
    const endpoints = detail?.metadata?.endpoints || {};
    const routes = [];
    const seen = new Set();

    const pushRoute = (route) => {
      const value = String(route || '').trim();
      if (!value || !value.startsWith('/')) return;
      if (seen.has(value)) return;
      seen.add(value);
      routes.push(value);
    };

    pushRoute(invoke.route);
    if (Array.isArray(invoke.routes)) {
      for (const route of invoke.routes) pushRoute(route);
    }
    if (Array.isArray(invoke.mapped_routes)) {
      for (const route of invoke.mapped_routes) pushRoute(route);
    }
    pushRoute(endpoints.preferred_public_route);
    if (Array.isArray(endpoints.public_routes)) {
      for (const route of endpoints.public_routes) pushRoute(route);
    }
    if (routes.length === 0) {
      pushRoute(`/${detail?.name || ''}${detail?.version ? `@${detail.version}` : ''}`);
    }
    return routes;
  }

  decodeForMonitorMatch(value) {
    const raw = String(value || '');
    if (!raw || raw.indexOf('%') < 0) return raw;
    try {
      return decodeURIComponent(raw);
    } catch {
      try {
        return decodeURIComponent(raw.replace(/%(?![0-9A-Fa-f]{2})/g, '%25'));
      } catch {
        return raw;
      }
    }
  }

  extractAccessPathFromLogLine(line) {
    const raw = String(line || '');
    const match = raw.match(/"[A-Z]+\s+([^"\s]+)\s+HTTP\/[0-9.]+"/);
    if (!match || !match[1]) return '';
    return String(match[1]);
  }

  buildMonitorRelationHints() {
    if (!this.currentFn) return { tokens: [], routePrefixes: [] };

    const runtime = String(this.currentFn.runtime || '').trim();
    const name = String(this.currentFn.name || '').trim();
    const version = String(this.currentFn.version || '').trim();
    const versionLabel = version || 'default';
    const detail = this.currentDetail || {
      runtime,
      name,
      version: version || undefined,
      metadata: { invoke: {} },
    };

    const tokens = new Set();
    const routePrefixes = new Set();

    const addToken = (value) => {
      const text = String(value || '').trim().toLowerCase();
      if (text.length >= 3) tokens.add(text);
    };

    const addRoutePrefix = (value) => {
      const text = String(value || '').trim().toLowerCase();
      if (text.length >= 3 && text !== '/') routePrefixes.add(text);
    };

    const addRoute = (route) => {
      const value = String(route || '').trim();
      if (!value) return;

      addToken(value);
      addToken(this.decodeForMonitorMatch(value));

      const qless = value.split('?')[0];
      addToken(qless);

      const normalizedDynamic = qless
        .replace(/\{[^}]+\}/g, '')
        .replace(/\[[^\]]+\]/g, '')
        .replace(/:[A-Za-z0-9_]+[*+?]?/g, '')
        .replace(/\/+/g, '/');
      addRoutePrefix(normalizedDynamic);

      if (qless.includes('{')) addRoutePrefix(qless.split('{')[0]);
      if (qless.includes('[')) addRoutePrefix(qless.split('[')[0]);
      if (qless.includes('/:')) addRoutePrefix(qless.split('/:')[0]);
    };

    addToken(`${runtime}/${name}`);
    addToken(`${runtime}/${name}@${versionLabel}`);
    addToken(`fn=${runtime}/${name}`);
    addToken(`route=${runtime}/${name}`);
    addToken(`fn=${runtime}/${name}@${versionLabel}`);
    addToken(`route=${runtime}/${name}@${versionLabel}`);
    addToken(`name=${name}`);
    addToken(`name=${encodeURIComponent(name)}`);
    addToken(`runtime=${runtime}&name=${name}`);
    addToken(`runtime=${runtime}&name=${encodeURIComponent(name)}`);
    addToken(`/console/functions/${encodeURIComponent(runtime)}/${encodeURIComponent(name)}`);

    const routes = this.collectApiRoutes(detail);
    for (const route of routes) addRoute(route);

    return {
      tokens: Array.from(tokens),
      routePrefixes: Array.from(routePrefixes),
    };
  }

  lineMatchesMonitorRelation(line, hints) {
    const raw = String(line || '');
    if (!raw) return false;

    const candidates = new Set();
    const addCandidate = (value) => {
      const text = String(value || '').trim().toLowerCase();
      if (text) candidates.add(text);
    };

    addCandidate(raw);
    addCandidate(this.decodeForMonitorMatch(raw));

    const reqPath = this.extractAccessPathFromLogLine(raw);
    if (reqPath) {
      addCandidate(reqPath);
      addCandidate(this.decodeForMonitorMatch(reqPath));
      const noQuery = reqPath.split('?')[0];
      addCandidate(noQuery);
      addCandidate(this.decodeForMonitorMatch(noQuery));
    }

    const tokens = Array.isArray(hints?.tokens) ? hints.tokens : [];
    const routePrefixes = Array.isArray(hints?.routePrefixes) ? hints.routePrefixes : [];
    for (const candidate of candidates) {
      for (const token of tokens) {
        if (token && candidate.includes(token)) return true;
      }
      for (const prefix of routePrefixes) {
        if (prefix && candidate.includes(prefix)) return true;
      }
    }
    return false;
  }

  async applyApiRoute(route, method, runNow = false) {
    if (!this.currentDetail) throw new Error('No function selected');
    const invoke = this.currentDetail.metadata?.invoke || {};
    const event = this.readTestEventObject();
    event.route = String(route || '').trim();
    event.method = String(method || invoke.default_method || event.method || 'GET').toUpperCase();
    event.params = defaultParamsForRoute(event.route);
    event.query = (invoke.query_example && typeof invoke.query_example === 'object' && !Array.isArray(invoke.query_example))
      ? invoke.query_example
      : {};
    if (invoke.body_example !== undefined) event.body = invoke.body_example;
    if (!event.context || typeof event.context !== 'object' || Array.isArray(event.context)) event.context = {};

    this.writeTestEventObject(event);
    this.switchTab('test');
    this.setCompatExplorerActive(true);
    if (runNow) await this.invokeFunction();
  }

  updateApiGuide(detail) {
    const quick = document.getElementById('apiQuick');
    const summary = document.getElementById('apiSummary');
    const routesEl = document.getElementById('apiRoutes');
    const useBtn = document.getElementById('apiUsePrimaryBtn');
    const runBtn = document.getElementById('apiRunPrimaryBtn');
    if (!quick || !summary || !routesEl || !detail) return;

    const invoke = detail.metadata?.invoke || {};
    const methods = Array.isArray(invoke.methods) && invoke.methods.length > 0
      ? invoke.methods
      : (Array.isArray(detail.policy?.methods) && detail.policy.methods.length > 0 ? detail.policy.methods : ['GET']);
    const routes = this.collectApiRoutes(detail);
    const route = routes[0];
    const params = defaultParamsForRoute(route);
    const queryExample = (invoke.query_example && typeof invoke.query_example === 'object' && !Array.isArray(invoke.query_example))
      ? invoke.query_example
      : {};
    const queryPairs = [];
    for (const [k, v] of Object.entries(queryExample)) {
      if (typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean') {
        queryPairs.push([k, String(v)]);
      }
    }
    const queryString = new URLSearchParams(queryPairs).toString();
    const routeWithQuery = queryString ? `${route}?${queryString}` : route;
    const primaryMethod = String(invoke.default_method || methods[0] || 'GET').toUpperCase();

    this.apiPrimary = { route, method: primaryMethod };
    if (useBtn) useBtn.disabled = !route;
    if (runBtn) runBtn.disabled = !route;

    const invokePayload = {
      runtime: detail.runtime,
      name: detail.name,
      method: primaryMethod,
      route,
      params,
      query: queryExample,
      body: invoke.body_example ?? '',
      context: {},
    };
    if (detail.version) invokePayload.version = detail.version;

    const summaryLines = [
      `Function: ${detail.runtime}/${detail.name}${detail.version ? `@${detail.version}` : ''}`,
      `Handler: ${typeof invoke.handler === 'string' && invoke.handler ? invoke.handler : 'handler (default)'}`,
      `Methods: ${methods.join(', ')}`,
      `Primary route: ${route}`,
      `Discovered routes: ${routes.length}`,
      `Path params: ${Object.keys(params).length > 0 ? Object.keys(params).join(', ') : '(none)'}`,
    ];
    summary.textContent = summaryLines.join('\n');

    const lines = [
      `Direct route test (${primaryMethod}):`,
      `curl -sS -X ${primaryMethod} 'http://127.0.0.1:8080${routeWithQuery}'`,
      '',
      'Internal invoke API test:',
      'POST /_fn/invoke',
      stringifyPretty(invokePayload),
      '',
      'Tip: Use "Use Primary Route in Test" to auto-fill the Test event.',
    ];
    quick.textContent = lines.join('\n');

    routesEl.innerHTML = '';
    if (routes.length === 0) {
      routesEl.innerHTML = '<div class="api-route-item"><div class="api-route-main"><div class="api-route-methods">No routes</div><code>Configure invoke.route or mapped routes</code></div></div>';
      return;
    }

    for (const routeItem of routes) {
      const wrapper = document.createElement('div');
      wrapper.className = 'api-route-item';

      const main = document.createElement('div');
      main.className = 'api-route-main';
      main.innerHTML = `<div class="api-route-methods">${esc(methods.join(', '))}</div><code>${esc(routeItem)}</code>`;
      wrapper.appendChild(main);

      const actions = document.createElement('div');
      actions.className = 'api-route-actions';

      const useRouteBtn = document.createElement('button');
      useRouteBtn.className = 'btn btn-xs btn-secondary';
      useRouteBtn.textContent = 'Use in Test';
      useRouteBtn.type = 'button';
      useRouteBtn.addEventListener('click', () => {
        this.applyApiRoute(routeItem, primaryMethod, false).catch((err) => alert(err.message || String(err)));
      });
      actions.appendChild(useRouteBtn);

      const runRouteBtn = document.createElement('button');
      runRouteBtn.className = 'btn btn-xs btn-secondary';
      runRouteBtn.textContent = 'Use + Run';
      runRouteBtn.type = 'button';
      runRouteBtn.addEventListener('click', () => {
        this.applyApiRoute(routeItem, primaryMethod, true).catch((err) => alert(err.message || String(err)));
      });
      actions.appendChild(runRouteBtn);

      wrapper.appendChild(actions);
      routesEl.appendChild(wrapper);
    }
  }

  updateSwaggerQuick(detail) {
    this.updateApiGuide(detail);
  }

  fillDefaultTestEvent(detail) {
    const invoke = detail.metadata?.invoke || {};
    const route = invoke.route || detail.metadata?.endpoints?.preferred_public_route || `/${detail.name}${detail.version ? `@${detail.version}` : ''}`;
    const params = defaultParamsForRoute(route);
    const methods = Array.isArray(invoke.methods) && invoke.methods.length > 0 ? invoke.methods : (Array.isArray(detail.policy?.methods) && detail.policy.methods.length > 0 ? detail.policy.methods : ['GET']);
    const bodyExample = invoke.body_example ?? '';

    const payload = {
      method: invoke.default_method || methods[0] || 'GET',
      route,
      params,
      query: invoke.query_example || {},
      body: bodyExample,
      context: {},
    };
    this.writeTestEventObject(payload);
  }

  syncInvokeEventEditor() {
    const source = document.getElementById('testEventJson');
    const target = document.getElementById('invokeEvent');
    if (!source || !target) return;
    target.value = source.value;
  }

  applyInvokeEventJson(runAfter = false) {
    const source = document.getElementById('invokeEvent');
    if (!source) return;

    let obj;
    try {
      obj = JSON.parse(source.value || '{}');
    } catch {
      throw new Error('Event JSON must be valid JSON');
    }

    this.writeTestEventObject(obj);
    if (runAfter) {
      this.invokeFunction().catch((err) => alert(err.message || String(err)));
    }
  }

  loadTemplate() {
    const selector = document.getElementById('testEventSelector');
    if (!selector || !this.currentFn) return;

    const type = selector.value;
    const invokeMeta = this.currentDetail?.metadata?.invoke || {};
    const fallbackMethod = String(
      invokeMeta.default_method
      || (Array.isArray(invokeMeta.methods) && invokeMeta.methods[0])
      || 'GET'
    ).toUpperCase();
    const fallbackRoute = String(
      invokeMeta.route
      || this.currentDetail?.metadata?.endpoints?.preferred_public_route
      || ''
    ).trim();
    const rawAllowedMethods = (
      Array.isArray(invokeMeta.methods) && invokeMeta.methods.length > 0
        ? invokeMeta.methods
        : (Array.isArray(this.currentDetail?.policy?.methods) && this.currentDetail.policy.methods.length > 0
          ? this.currentDetail.policy.methods
          : [fallbackMethod])
    );
    const allowedMethods = Array.from(new Set(rawAllowedMethods.map((m) => String(m || '').toUpperCase()).filter(Boolean)));
    const supportsPost = allowedMethods.includes('POST');

    const payload = {
      method: fallbackMethod,
      query: {},
      body: invokeMeta.body_example ?? '',
      context: {},
    };

    if (fallbackRoute) {
      payload.route = fallbackRoute;
      payload.params = defaultParamsForRoute(fallbackRoute);
    }

    const hasParams = payload.params && typeof payload.params === 'object' && !Array.isArray(payload.params);

    if (type === 'hello') {
      payload.query = { name: 'World' };
    } else if (type === 'path-query') {
      payload.query = { name: 'Juan', lang: 'en' };
      if (hasParams) {
        const nextParams = {};
        for (const [key, value] of Object.entries(payload.params)) {
          const lower = String(key || '').toLowerCase();
          if (lower === 'id') nextParams[key] = '42';
          else if (lower.includes('slug')) nextParams[key] = 'demo/path';
          else if (lower.includes('name')) nextParams[key] = 'juan';
          else nextParams[key] = String(value || 'sample');
        }
        payload.params = nextParams;
      }
    } else if (type === 'post-json') {
      payload.method = supportsPost ? 'POST' : fallbackMethod;
      payload.query = { dry_run: '1' };
      payload.body = {
        id: `demo-${Date.now()}`,
        name: 'Template Test',
        source: 'console-template',
      };
    } else if (type === 'context-debug') {
      payload.query = { debug: '1' };
      payload.context = {
        request_id: `console-${Date.now()}`,
        user: 'local-tester',
      };
      if (payload.body === '' || payload.body === null || payload.body === undefined) {
        payload.body = { note: 'context template payload' };
      }
    }
    this.writeTestEventObject(payload);
  }

  extractInvokePayload() {
    const raw = String(document.getElementById('testEventJson')?.value || '{}');
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch {
      throw new Error('Event JSON is invalid');
    }

    const structured = parsed && typeof parsed === 'object' && !Array.isArray(parsed)
      && ('method' in parsed || 'query' in parsed || 'body' in parsed || 'context' in parsed || 'route' in parsed || 'params' in parsed);

    const invokeMeta = this.currentDetail?.metadata?.invoke || {};
    const fallbackMethod = invokeMeta.default_method || (Array.isArray(invokeMeta.methods) && invokeMeta.methods[0]) || 'GET';

    const payload = {
      runtime: this.currentFn.runtime,
      name: this.currentFn.name,
      version: this.currentFn.version || undefined,
      method: structured ? String(parsed.method || fallbackMethod).toUpperCase() : fallbackMethod,
    };

    const parsedRoute = (structured && typeof parsed.route === 'string') ? parsed.route.trim() : '';
    const route = parsedRoute || String(invokeMeta.route || '').trim();
    if (route !== '') {
      payload.route = route;
      payload.params = (structured && parsed.params && typeof parsed.params === 'object' && !Array.isArray(parsed.params))
        ? parsed.params
        : defaultParamsForRoute(route);
    }

    if (structured) {
      payload.query = (parsed.query && typeof parsed.query === 'object' && !Array.isArray(parsed.query)) ? parsed.query : {};
      payload.body = ('body' in parsed) ? parsed.body : '';
      if (parsed.context && typeof parsed.context === 'object' && !Array.isArray(parsed.context)) {
        payload.context = parsed.context;
      }
    } else {
      payload.query = {};
      payload.body = parsed;
    }

    return payload;
  }

  async invokeFromCompat() {
    try {
      this.syncTestEventFromCompatFields();
    } catch (err) {
      const invokeMeta = document.getElementById('invokeMeta');
      if (invokeMeta) invokeMeta.textContent = String(err && err.message ? err.message : err);
      throw err;
    }
    await this.invokeFunction();
  }

  async invokeFunction() {
    if (!this.currentFn) return;

    const resultPanel = document.getElementById('testResultPanel');
    const title = document.getElementById('testResultTitle');
    const responseOut = document.getElementById('testResponseOutput');
    const detailsOut = document.getElementById('testDetailsOutput');

    if (resultPanel) resultPanel.style.display = 'none';

    let payload = this.extractInvokePayload();

    const callInvoke = async (body) => getJson('/_fn/invoke', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });

    const start = performance.now();
    let response;
    try {
      response = await callInvoke(payload);
    } catch (err) {
      const msg = String(err && err.message ? err.message : err);
      const shouldRetryWithoutRoute = payload.route
        && (msg.includes('HTTP 404') || msg.includes('invalid route') || msg.includes('no mapped public route'));
      if (!shouldRetryWithoutRoute) {
        throw err;
      }
      const fallbackPayload = { ...payload };
      delete fallbackPayload.route;
      delete fallbackPayload.params;
      payload = fallbackPayload;
      response = await callInvoke(payload);
    }
    const elapsed = Math.round(performance.now() - start);

    if (resultPanel) resultPanel.style.display = 'block';
    if (title) {
      const ok = response.status >= 200 && response.status < 300;
      title.textContent = ok ? 'Execution Result: Succeeded' : 'Execution Result: Failed';
      title.style.color = ok ? '#1e7e34' : '#d13212';
    }

    const out = {
      status: response.status,
      headers: response.headers || {},
      body: response.body,
    };
    try {
      if (typeof out.body === 'string') out.body = JSON.parse(out.body);
    } catch {
      // keep raw body
    }

    if (response.is_base64) {
      out.is_base64 = true;
      out.body_base64 = response.body_base64 || '';
    }

    if (responseOut) responseOut.textContent = stringifyPretty(out);
    if (detailsOut) {
      detailsOut.innerHTML = `
        <div>Status: ${response.status}</div>
        <div>Duration: ${response.latency_ms || elapsed} ms</div>
        <div>Method: ${payload.method}</div>
        <div>Route: ${esc(response.route || payload.route || '(auto)')}</div>
      `;
    }

    const invokeMeta = document.getElementById('invokeMeta');
    const invokeOut = document.getElementById('invokeOut');
    if (invokeMeta) {
      invokeMeta.textContent = `${payload.method} => status ${response.status} | ${response.latency_ms || elapsed} ms`;
    }
    if (invokeOut) {
      invokeOut.textContent = stringifyPretty(out);
    }

    this.recordExecution(payload, response, elapsed, out);

    this.refreshMonitor().catch(() => {
      // ignore monitor errors in invoke flow
    });
  }

  async saveCode() {
    if (!this.currentFn) return;
    if (this.currentFile !== this.handlerFile) {
      alert('Only handler file is editable here.');
      return;
    }

    const editor = document.getElementById('codeEditor');
    const saveBtn = document.getElementById('saveCodeBtn');
    if (!editor || !saveBtn) return;

    const q = new URLSearchParams({ runtime: this.currentFn.runtime, name: this.currentFn.name });
    if (this.currentFn.version) q.set('version', this.currentFn.version);

    saveBtn.disabled = true;
    saveBtn.textContent = 'Saving...';

    try {
      const updated = await getJson(`/_fn/function-code?${q.toString()}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ code: editor.value || '' }),
      });
      this.fileContents[this.handlerFile] = String(updated.code || '');
      saveBtn.textContent = 'Saved';
      setTimeout(() => {
        saveBtn.disabled = false;
        saveBtn.textContent = 'Deploy';
      }, 900);
    } catch (err) {
      saveBtn.disabled = false;
      saveBtn.textContent = 'Deploy';
      throw err;
    }
  }

  appendAiMessage(kind, text, persist = false) {
    const out = document.getElementById('aiOutput');
    if (!out) return;
    const msg = document.createElement('div');
    msg.className = `ai-msg ${kind}`;
    msg.textContent = String(text || '');
    out.appendChild(msg);
    out.scrollTop = out.scrollHeight;
    if (persist) {
      this.recordAiHistory(kind === 'user' ? 'user' : 'assistant', text);
    }
  }

  detectAssistantMode(prompt) {
    const text = String(prompt || '').trim().toLowerCase();
    if (!text) return 'generate';
    const editWords = [
      'change', 'modify', 'update', 'rewrite', 'refactor', 'fix', 'patch', 'replace', 'improve',
      'cambia', 'modifica', 'actualiza', 'reescribe', 'refactoriza', 'corrige', 'ajusta', 'mejora',
      'agrega', 'agregar', 'anade', 'añade', 'quita', 'elimina',
    ];
    if (editWords.some((w) => text.includes(w))) return 'generate';
    if (/[?]$/.test(text)) return 'chat';
    if (text.includes('what does this function do')) return 'chat';
    if (text.includes('que hace esta funcion')) return 'chat';
    if (text.startsWith('what ') || text.startsWith('how ') || text.startsWith('why ')) return 'chat';
    if (text.startsWith('que ') || text.startsWith('como ') || text.startsWith('por que ')) return 'chat';
    if (text.startsWith('explain') || text.startsWith('explica')) return 'chat';
    return 'generate';
  }

  resolveAssistantMode(prompt) {
    const selected = String(this.aiMode || 'auto').toLowerCase();
    if (selected === 'chat') return 'chat';
    if (selected === 'edit') return 'generate';
    return this.detectAssistantMode(prompt);
  }

  extractCodeFromAssistantMessage(message, runtime) {
    const text = String(message || '').trim();
    if (!text) return '';

    const fenced = text.match(/```[a-zA-Z0-9_-]*\s*([\s\S]*?)```/);
    if (fenced && fenced[1] && fenced[1].trim()) {
      return fenced[1].trim();
    }

    const rt = String(runtime || '').toLowerCase();
    const markersByRuntime = {
      node: ['exports.handler', 'module.exports', 'async (event) =>'],
      python: ['def handler(', 'import json'],
      php: ['<?php', 'function handler('],
      lua: ['function handler(', 'local cjson = require'],
      rust: ['fn handler(', 'use serde_json', 'serde_json::json!'],
    };
    const markers = markersByRuntime[rt] || [];
    let best = -1;
    for (const marker of markers) {
      const idx = text.indexOf(marker);
      if (idx >= 0 && (best < 0 || idx < best)) best = idx;
    }
    if (best >= 0) {
      return text.slice(best).trim();
    }
    return '';
  }

  shouldRunAiSmoke(prompt) {
    const text = String(prompt || '').trim().toLowerCase();
    if (!text) return false;
    return text.includes('test')
      || text.includes('smoke')
      || text.includes('probar')
      || text.includes('prueba');
  }

  async runAiSmokeProbe() {
    if (!this.currentFn) return null;
    const payload = this.extractInvokePayload();
    const started = performance.now();
    const response = await getJson('/_fn/invoke', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    return {
      status: Number(response && response.status ? response.status : 0),
      latency_ms: Number((response && response.latency_ms) || Math.round(performance.now() - started)),
      route: String((response && response.route) || payload.route || '(auto)'),
      ok: Number(response && response.status ? response.status : 0) >= 200 && Number(response && response.status ? response.status : 0) < 300,
    };
  }

  async fetchAssistantStatus(force = false) {
    const now = Date.now();
    if (!force && this.assistantStatus && (now - this.assistantStatusAt) < 30000) {
      return this.assistantStatus;
    }
    const status = await getJson('/_fn/assistant/status');
    this.assistantStatus = status;
    this.assistantStatusAt = now;
    return status;
  }

  async generateCode() {
    if (!this.currentFn) return;

    const promptEl = document.getElementById('aiPrompt');
    const prompt = String(promptEl?.value || '').trim();
    if (!prompt) return;
    const priorHistory = this.getAiHistoryEntriesForCurrentFn().slice(-12).map((entry) => ({
      role: String(entry.role || 'assistant'),
      text: String(entry.text || ''),
    }));
    const mode = this.resolveAssistantMode(prompt);

    this.appendAiMessage('user', prompt, true);
    if (promptEl) promptEl.value = '';

    const loading = document.createElement('div');
    loading.className = 'ai-msg system';
    loading.textContent = 'Thinking...';
    const out = document.getElementById('aiOutput');
    if (out) out.appendChild(loading);

    try {
      const status = await this.fetchAssistantStatus();
      if (status && status.enabled === false) {
        if (out && loading.parentNode === out) out.removeChild(loading);
        this.appendAiMessage('system', 'Error: assistant disabled. Enable FN_ASSISTANT_ENABLED.', true);
        return;
      }

      let smokeProbe = null;
      if (mode === 'chat' && this.shouldRunAiSmoke(prompt)) {
        try {
          smokeProbe = await this.runAiSmokeProbe();
          this.appendAiMessage('system', `Smoke probe: status ${smokeProbe.status} (${smokeProbe.latency_ms} ms) route=${smokeProbe.route}`, true);
        } catch (probeErr) {
          const probeMsg = String(probeErr && probeErr.message ? probeErr.message : probeErr);
          smokeProbe = { error: probeMsg };
          this.appendAiMessage('system', `Smoke probe error: ${probeMsg}`, true);
        }
      }

      const result = await getJson('/_fn/assistant/generate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          runtime: this.currentFn.runtime,
          name: this.currentFn.name,
          template: 'hello_json',
          prompt,
          mode,
          current_code: String(this.fileContents[this.handlerFile] || ''),
          chat_history: priorHistory,
          test_result: smokeProbe,
        }),
      });

      if (out) out.removeChild(loading);
      const resolvedMode = String(result.mode || mode);
      const selectedMode = String(this.aiMode || 'auto').toLowerCase();
      const effectiveMode = selectedMode === 'chat'
        ? 'chat'
        : (selectedMode === 'edit' ? 'generate' : resolvedMode);
      const reply = String(result.message || '').trim();
      let code = String(result.code || '');
      if (!code && effectiveMode === 'generate' && reply) {
        code = this.extractCodeFromAssistantMessage(reply, this.currentFn.runtime);
      }

      if (effectiveMode === 'chat') {
        if (reply) {
          this.appendAiMessage('system', reply, true);
        } else {
          this.appendAiMessage('system', 'Assistant returned an empty response.', true);
        }
        return;
      }

      if (!code) {
        if (reply) {
          this.appendAiMessage('system', reply, true);
        } else {
          this.appendAiMessage('system', 'Assistant returned empty code.', true);
        }
        return;
      }

      this.appendAiMessage('system', 'Generated suggestion applied to editor. Review and click Deploy to publish.', true);
      this.fileContents[this.handlerFile] = code;
      this.currentFile = this.handlerFile;
      this.renderFileTree();
      this.renderEditor();
    } catch (err) {
      if (out && loading.parentNode === out) out.removeChild(loading);
      const msg = String(err && err.message ? err.message : err);
      if (msg.includes('assistant disabled')) {
        this.appendAiMessage('system', 'Error: assistant disabled. Enable FN_ASSISTANT_ENABLED to use AI generation.', true);
        return;
      }
      if (msg.includes('console write disabled')) {
        this.appendAiMessage('system', 'Error: console write disabled. Chat works, but code generation needs FN_CONSOLE_WRITE_ENABLED=1 (or admin token).', true);
        return;
      }
      this.appendAiMessage('system', `Error: ${msg}`, true);
    }
  }

  async saveConfig() {
    if (!this.currentFn) return;

    const configStatus = document.getElementById('configStatus');
    const timeout = String(document.getElementById('configTimeout')?.value || '').trim();
    const conc = String(document.getElementById('configConcurrency')?.value || '').trim();
    const maxBody = String(document.getElementById('configMaxBody')?.value || '').trim();
    const methodsCsv = String(document.getElementById('configMethods')?.value || '');
    const routesCsv = String(document.getElementById('configRoutes')?.value || '');
    const depsCsv = String(document.getElementById('configSharedDeps')?.value || '');
    const handlerOverride = String(document.getElementById('configHandler')?.value || '').trim();
    const scheduleEnabled = document.getElementById('configScheduleEnabled')?.checked === true;
    const scheduleEveryRaw = String(document.getElementById('configScheduleEverySeconds')?.value || '').trim();
    const scheduleMethodRaw = String(document.getElementById('configScheduleMethod')?.value || '').trim().toUpperCase();
    const scheduleQueryRaw = String(document.getElementById('configScheduleQuery')?.value || '');
    const scheduleHeadersRaw = String(document.getElementById('configScheduleHeaders')?.value || '');
    const scheduleBodyRaw = String(document.getElementById('configScheduleBody')?.value || '');
    const scheduleContextRaw = String(document.getElementById('configScheduleContext')?.value || '');

    if (configStatus) configStatus.textContent = 'Saving...';
    try {
      const payload = {};

      if (timeout !== '') {
        const value = Number(timeout);
        if (!Number.isFinite(value) || value <= 0) throw new Error('Timeout must be > 0');
        payload.timeout_ms = Math.floor(value);
      }
      if (conc !== '') {
        const value = Number(conc);
        if (!Number.isFinite(value) || value < 0) throw new Error('Max Concurrency must be >= 0');
        payload.max_concurrency = Math.floor(value);
      }
      if (maxBody !== '') {
        const value = Number(maxBody);
        if (!Number.isFinite(value) || value <= 0) throw new Error('Max Body Bytes must be > 0');
        payload.max_body_bytes = Math.floor(value);
      }

      let methods = [];
      if (hasConfigMethodToggles()) {
        methods = readMethodsFromToggles();
      } else {
        methods = normalizeMethodsFromCsv(methodsCsv);
      }
      if (methods.length === 0) methods = ['GET'];

      const routes = normalizeRoutesFromCsv(routesCsv);
      payload.invoke = { methods };
      if (routes.length > 0) payload.invoke.routes = routes;
      if (handlerOverride !== '') {
        payload.invoke.handler = handlerOverride;
      } else {
        payload.invoke.handler = null;
      }

      const deps = parseCsvList(depsCsv);
      payload.shared_deps = deps.length > 0 ? deps : null;

      const hadScheduleConfigured = !!(
        this.currentDetail?.metadata?.schedule?.configured
        && typeof this.currentDetail.metadata.schedule.configured === 'object'
        && !Array.isArray(this.currentDetail.metadata.schedule.configured)
      );
      const hasScheduleInput = scheduleEveryRaw !== ''
        || String(scheduleQueryRaw).trim() !== ''
        || String(scheduleHeadersRaw).trim() !== ''
        || String(scheduleBodyRaw).trim() !== ''
        || String(scheduleContextRaw).trim() !== ''
        || (scheduleMethodRaw !== '' && scheduleMethodRaw !== 'GET');
      if (scheduleEnabled || hasScheduleInput || hadScheduleConfigured) {
        const schedulePayload = { enabled: scheduleEnabled };

        if (scheduleEnabled && scheduleEveryRaw === '') {
          throw new Error('schedule.every_seconds is required when schedule.enabled=true');
        }
        if (scheduleEveryRaw !== '') {
          const every = Number(scheduleEveryRaw);
          if (!Number.isFinite(every) || every <= 0) {
            throw new Error('schedule.every_seconds must be > 0');
          }
          schedulePayload.every_seconds = Math.floor(every);
        }

        if (scheduleMethodRaw !== '') {
          if (!ALLOWED_HTTP_METHODS.includes(scheduleMethodRaw)) {
            throw new Error('schedule.method must be a valid HTTP method');
          }
          schedulePayload.method = scheduleMethodRaw;
        }

        const scheduleQuery = parseOptionalJsonObject(scheduleQueryRaw, 'schedule.query');
        if (scheduleQuery !== undefined) schedulePayload.query = scheduleQuery;

        const scheduleHeaders = parseOptionalJsonObject(scheduleHeadersRaw, 'schedule.headers');
        if (scheduleHeaders !== undefined) schedulePayload.headers = scheduleHeaders;

        const scheduleContext = parseOptionalJsonObject(scheduleContextRaw, 'schedule.context');
        if (scheduleContext !== undefined) schedulePayload.context = scheduleContext;

        if (String(scheduleBodyRaw).trim() !== '') {
          schedulePayload.body = String(scheduleBodyRaw);
        }

        payload.schedule = schedulePayload;
      }

      const q = new URLSearchParams({ runtime: this.currentFn.runtime, name: this.currentFn.name });
      if (this.currentFn.version) q.set('version', this.currentFn.version);

      await getJson(`/_fn/function-config?${q.toString()}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });

      await this.openFunction(this.currentFn.name, this.currentFn.runtime, this.currentFn.version, {
        pushUrl: false,
        activateTab: 'configuration',
      });
      if (configStatus) configStatus.textContent = 'Saved.';
    } catch (err) {
      if (configStatus) configStatus.textContent = `Error: ${String(err && err.message ? err.message : err)}`;
      throw err;
    }
  }

  async saveEnv() {
    if (!this.currentFn) return;

    const envStatus = document.getElementById('envStatus');
    if (envStatus) envStatus.textContent = 'Saving...';

    let payload;
    const hasDictEditor = !!document.getElementById('envDictRows');
    try {
      if (hasDictEditor) {
        payload = this.readEnvDictPayload(true);
      } else {
        const envRaw = String(document.getElementById('configEnvJson')?.value || '{}');
        payload = JSON.parse(envRaw);
      }
    } catch (err) {
      const msg = String(err && err.message ? err.message : err);
      if (envStatus) envStatus.textContent = `Error: ${msg}`;
      throw new Error(msg.includes('JSON') || msg.includes('Environment') ? msg : 'fn.env.json payload must be valid JSON');
    }

    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
      const msg = 'fn.env.json payload must be a JSON object';
      if (envStatus) envStatus.textContent = `Error: ${msg}`;
      throw new Error(msg);
    }

    const q = new URLSearchParams({ runtime: this.currentFn.runtime, name: this.currentFn.name });
    if (this.currentFn.version) q.set('version', this.currentFn.version);

    const updated = await getJson(`/_fn/function-env?${q.toString()}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });

    const nextEnv = updated.fn_env || {};
    this.setEnvDictFromPayload(nextEnv);
    this.fileContents['fn.env.json'] = stringifyPretty(nextEnv);
    if (this.currentFile === 'fn.env.json') {
      this.renderEditor();
    }
    if (envStatus) envStatus.textContent = 'Saved.';
  }

  async refreshMonitor() {
    if (!this.currentFn) return;

    const req = document.getElementById('monitorRequests');
    const err = document.getElementById('monitorErrors');
    const logs = document.getElementById('monitorLogs');
    const statusEl = document.getElementById('monitorStatus');
    const linesInput = document.getElementById('monitorLogLines');
    const modeSelect = document.getElementById('monitorLogMode');
    const searchInput = document.getElementById('monitorSearch');

    let lines = Number(linesInput?.value || 160);
    if (!Number.isFinite(lines)) lines = 160;
    lines = Math.max(20, Math.min(1000, Math.floor(lines)));
    if (linesInput) linesInput.value = String(lines);

    const modeRaw = String(modeSelect?.value || 'function');
    const mode = ['function', 'all', 'errors', 'access'].includes(modeRaw) ? modeRaw : 'function';
    const needle = String(searchInput?.value || '').trim().toLowerCase();
    if (statusEl) statusEl.textContent = 'Loading logs...';

    const [dash, errorLog, accessLog] = await Promise.all([
      getJson('/_fn/dashboard'),
      getJson(`/_fn/logs?file=error&format=json&lines=${lines}`),
      getJson(`/_fn/logs?file=access&format=json&lines=${lines}`),
    ]);

    const relationHints = this.buildMonitorRelationHints();
    const accessLines = Array.isArray(accessLog.data) ? accessLog.data.filter((line) => typeof line === 'string') : [];
    const errorLines = Array.isArray(errorLog.data) ? errorLog.data.filter((line) => typeof line === 'string') : [];
    const fnAccess = accessLines.filter((line) => this.lineMatchesMonitorRelation(line, relationHints));
    const fnErrors = errorLines.filter((line) => this.lineMatchesMonitorRelation(line, relationHints));

    let viewAccess = accessLines;
    let viewErrors = errorLines;
    if (mode === 'function') {
      viewAccess = fnAccess;
      viewErrors = fnErrors;
    } else if (mode === 'errors') {
      viewAccess = [];
      viewErrors = fnErrors;
    } else if (mode === 'access') {
      viewAccess = fnAccess;
      viewErrors = [];
    }

    if (needle) {
      viewAccess = viewAccess.filter((line) => line.toLowerCase().includes(needle));
      viewErrors = viewErrors.filter((line) => line.toLowerCase().includes(needle));
    }

    const tailLimit = Math.min(lines, 60);
    const accessTail = viewAccess.slice(-tailLimit);
    const errorTail = viewErrors.slice(-tailLimit);
    const hasRelatedInFilteredModes = fnAccess.length > 0 || fnErrors.length > 0;

    if (req) {
      const points = Array.isArray(dash.invocations_chart?.data) ? dash.invocations_chart.data.length : 0;
      req.textContent = [
        `Requests 24h: ${dash.requests_24h ?? 0}`,
        `Avg latency: ${dash.avg_latency_ms ?? 0} ms`,
        `Invocation points: ${points}`,
      ].join('\n');
    }

    if (err) {
      err.textContent = [
        `Errors 24h: ${dash.errors_24h ?? 0}`,
        `Related error lines: ${fnErrors.length}`,
        `Visible error lines: ${errorTail.length}`,
        '',
        ...(errorTail.length > 0
          ? errorTail
          : [mode === 'all' ? '(no error lines)' : '(no related error lines)']),
      ].join('\n');
    }

    if (logs) {
      const parts = [];
      parts.push(`[ACCESS ${accessTail.length}]`);
      if (accessTail.length > 0) parts.push(...accessTail);
      else parts.push(mode === 'all' ? '(no access lines)' : '(no related access lines)');
      parts.push('');
      parts.push(`[ERROR ${errorTail.length}]`);
      if (errorTail.length > 0) parts.push(...errorTail);
      else parts.push(mode === 'all' ? '(no error lines)' : '(no related error lines)');
      logs.textContent = parts.join('\n');
    }

    if (statusEl) {
      const filterSuffix = needle ? ` | filter="${needle}"` : '';
      const relatedSuffix = mode === 'all'
        ? ''
        : ` | related_access=${fnAccess.length}/${accessLines.length} | related_errors=${fnErrors.length}/${errorLines.length}${hasRelatedInFilteredModes ? '' : ' | no related lines found'}`;
      statusEl.textContent = `Updated ${new Date().toLocaleTimeString()} | mode=${mode} | lines=${lines}${relatedSuffix}${filterSuffix}`;
    }
  }

  reloadCurrentFunction() {
    if (!this.currentFn) return;
    this.openFunction(this.currentFn.name, this.currentFn.runtime, this.currentFn.version, {
      pushUrl: false,
      activateTab: this.currentTab,
    }).catch((err) => alert(err.message || String(err)));
  }
}

window.app = new ConsoleApp();
window.app.init().catch((err) => {
  // eslint-disable-next-line no-console
  console.error(err);
  alert(err.message || String(err));
});

window.addEventListener('unhandledrejection', (event) => {
  const reason = event && event.reason ? event.reason : new Error('unknown error');
  const message = reason && reason.message ? reason.message : String(reason);
  alert(message);
  event.preventDefault();
});

const runEventBtn = document.getElementById('runEventBtn');
if (runEventBtn) {
  runEventBtn.addEventListener('click', () => {
    try {
      window.app.applyInvokeEventJson(true);
    } catch (err) {
      alert(err.message || String(err));
    }
  });
}
