const DEFAULT_STATE = {
  name: 'Builder',
  accent: '#22c55e',
  message: 'This preview is rendered from a FastFn function endpoint.',
};

const ALLOWED_ACCENTS = new Set(['#22c55e', '#38bdf8', '#f59e0b', '#f472b6']);
const state = { ...DEFAULT_STATE };

function clampText(value, fallback, maxLength) {
  const text = String(value == null ? '' : value).trim();
  if (!text) return fallback;
  return text.slice(0, maxLength);
}

function sanitizeAccent(value) {
  const accent = String(value == null ? '' : value).trim();
  if (ALLOWED_ACCENTS.has(accent)) return accent;
  return DEFAULT_STATE.accent;
}

function parseJsonBody(body) {
  if (body == null || body === '') return {};
  if (typeof body === 'object') return body;
  if (typeof body !== 'string') return {};
  return JSON.parse(body);
}

function getState() {
  return { ...state };
}

function updateState(input) {
  state.name = clampText(input.name, DEFAULT_STATE.name, 60);
  state.accent = sanitizeAccent(input.accent);
  state.message = clampText(input.message, DEFAULT_STATE.message, 280);
  return getState();
}

module.exports = {
  getState,
  parseJsonBody,
  updateState,
};
