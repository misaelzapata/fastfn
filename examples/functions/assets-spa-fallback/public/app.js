const view = document.querySelector("#view");

const state = {
  loading: true,
  error: "",
  payloads: [],
};

const routes = {
  "/": renderHome,
  "/dashboard": renderDashboard,
  "/settings": renderSettings,
};

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

async function loadPayloads() {
  state.loading = true;
  state.error = "";

  try {
    const responses = await Promise.all([
      fetch("/api-profile"),
      fetch("/api-flags"),
    ]);

    state.payloads = await Promise.all(responses.map((response) => response.json()));
  } catch (error) {
    state.error = error instanceof Error ? error.message : String(error);
  } finally {
    state.loading = false;
  }
}

function payloadCards() {
  if (state.loading) {
    return '<p class="muted">Loading runtime payloads...</p>';
  }

  if (state.error) {
    return `<p class="muted">Unable to load runtime payloads: ${escapeHtml(state.error)}</p>`;
  }

  return state.payloads
    .map(
      (item) => `
        <article class="card">
          <span class="pill">${escapeHtml(item.runtime)}</span>
          <h3>${escapeHtml(item.title)}</h3>
          <p class="muted">${escapeHtml(item.summary)}</p>
          <p class="mono">${escapeHtml(item.path)}</p>
        </article>
      `
    )
    .join("");
}

function renderHome() {
  return `
    <h2>History API shell</h2>
    <p class="muted">Refresh this page on <code>/dashboard</code> or <code>/settings</code> and FastFN serves the same shell from <code>public/index.html</code>.</p>
    <div class="grid">${payloadCards()}</div>
  `;
}

function renderDashboard() {
  return `
    <h2>Dashboard</h2>
    <div class="grid">
      <article class="card">
        <span class="pill">Deep link</span>
        <h3>/dashboard</h3>
        <p class="muted">This path works directly because the gateway falls back to <code>public/index.html</code> for navigations.</p>
      </article>
      <article class="card">
        <span class="pill">API mix</span>
        <h3>PHP + Lua</h3>
        <p class="muted">Server APIs stay normal routes while the UI router owns browser navigation.</p>
      </article>
    </div>
  `;
}

function renderSettings() {
  return `
    <h2>Settings</h2>
    <ul>
      <li><code>/api-profile</code> comes from PHP.</li>
      <li><code>/api-flags</code> comes from Lua.</li>
      <li><code>/missing.js</code> still returns a real <code>404</code>.</li>
    </ul>
  `;
}

function renderNotFound(pathname) {
  return `
    <h2>Client route</h2>
    <p class="muted">FastFN served the SPA shell for <code>${escapeHtml(pathname)}</code>, then the client router rendered this fallback view.</p>
  `;
}

function navigate(pathname) {
  window.history.pushState({}, "", pathname);
  render();
}

function render() {
  const pathname = window.location.pathname;
  const route = routes[pathname];
  view.innerHTML = route ? route() : renderNotFound(pathname);
}

document.addEventListener("click", (event) => {
  const link = event.target.closest("[data-link]");
  if (!link) {
    return;
  }
  event.preventDefault();
  navigate(link.getAttribute("href"));
});

window.addEventListener("popstate", render);
loadPayloads().finally(render);
