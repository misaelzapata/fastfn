const view = document.querySelector("#view");

const state = {
  loading: true,
  error: "",
  goPayload: null,
};

const routes = {
  "/": renderHome,
  "/catalog": renderCatalog,
  "/status": renderStatus,
};

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

async function loadStatus() {
  state.loading = true;
  state.error = "";

  try {
    const response = await fetch("/api-go");
    state.goPayload = await response.json();
  } catch (error) {
    state.error = error instanceof Error ? error.message : String(error);
  } finally {
    state.loading = false;
  }
}

function statusCard() {
  if (state.loading) {
    return '<p class="muted">Loading Go runtime status...</p>';
  }

  if (state.error) {
    return `<p class="muted">Unable to load Go runtime status: ${escapeHtml(state.error)}</p>`;
  }

  return `
    <article class="card">
      <span class="pill">${escapeHtml(state.goPayload.runtime)}</span>
      <h3>${escapeHtml(state.goPayload.title)}</h3>
      <p class="muted">${escapeHtml(state.goPayload.summary)}</p>
      <p class="mono">${escapeHtml(state.goPayload.path)}</p>
    </article>
  `;
}

function renderHome() {
  return `
    <div class="grid">
      <article class="card">
        <span class="pill">Assets</span>
        <h3>Configurable directory</h3>
        <p class="muted">This shell comes from <code>dist/</code>, so the folder is configurable instead of hard-coded to <code>public/</code>.</p>
      </article>
      <article class="card">
        <span class="pill">Precedence</span>
        <h3>Worker-first</h3>
        <p class="muted">The Rust route at <code>/hello</code> wins even though <code>dist/hello/index.html</code> also exists.</p>
      </article>
      ${statusCard()}
    </div>
  `;
}

function renderCatalog() {
  return `
    <h2>Catalog</h2>
    <p class="muted">This route is client-side only. Refreshing on <code>/catalog</code> still works because missing navigations fall back to the main shell.</p>
  `;
}

function renderStatus() {
  return `
    <h2>Status</h2>
    <ul>
      <li><code>/hello</code> is a Rust runtime route.</li>
      <li><code>/api-go</code> is a Go runtime route.</li>
      <li><code>/catalog/overview</code> falls back to the SPA shell from <code>dist/index.html</code>.</li>
    </ul>
  `;
}

function renderNotFound(pathname) {
  return `
    <h2>Client route</h2>
    <p class="muted">FastFN returned the shell for <code>${escapeHtml(pathname)}</code>, and the client router rendered this fallback view.</p>
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
loadStatus().finally(render);
