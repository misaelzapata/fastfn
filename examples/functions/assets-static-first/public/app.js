const view = document.querySelector("#view");

const state = {
  runtimes: [],
  loading: true,
  error: "",
};

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

async function loadRuntimes() {
  state.loading = true;
  state.error = "";

  try {
    const responses = await Promise.all([
      fetch("/api-node"),
      fetch("/api-python"),
    ]);

    const payloads = await Promise.all(
      responses.map(async (response) => ({
        status: response.status,
        body: await response.json(),
      }))
    );

    state.runtimes = payloads.map((item) => item.body);
  } catch (error) {
    state.error = error instanceof Error ? error.message : String(error);
  } finally {
    state.loading = false;
  }
}

function runtimeCards() {
  if (state.loading) {
    return '<p class="muted">Loading runtime cards...</p>';
  }

  if (state.error) {
    return `<p class="muted">Unable to load runtime data: ${escapeHtml(state.error)}</p>`;
  }

  return state.runtimes
    .map(
      (item) => `
        <article class="card">
          <span class="pill">${escapeHtml(item.runtime)}</span>
          <h3>${escapeHtml(item.title)}</h3>
          <p class="muted">${escapeHtml(item.summary)}</p>
          <p class="mono">route: ${escapeHtml(item.path)}</p>
        </article>
      `
    )
    .join("");
}

function renderOverview() {
  return `
    <div class="grid">
      <article class="card">
        <span class="pill">Mode</span>
        <h3>Static-first</h3>
        <p class="muted">The gateway checks <code>public/</code> before function discovery. If no file matches, it falls back to your handlers.</p>
      </article>
      <article class="card">
        <span class="pill">SPA style</span>
        <h3>Hash navigation</h3>
        <p class="muted">Because this demo stays in strict 404 mode, the client router uses hash URLs for in-page navigation.</p>
      </article>
      <article class="card">
        <span class="pill">API</span>
        <h3>Polyglot</h3>
        <p class="muted">Node and Python power the runtime side while the UI stays fully static.</p>
      </article>
    </div>
  `;
}

function renderRuntimes() {
  return `
    <h2>Runtime APIs</h2>
    <p class="muted">These endpoints are not files under <code>public/</code>, so FastFN falls back to the handlers:</p>
    <div class="grid">${runtimeCards()}</div>
  `;
}

function renderNotes() {
  return `
    <h2>What to try</h2>
    <ul>
      <li><code>/</code> returns <code>public/index.html</code>.</li>
      <li><code>/api-node</code> and <code>/api-python</code> hit their runtime handlers.</li>
      <li><code>/missing/path</code> returns a real <code>404</code> because SPA fallback is disabled here.</li>
    </ul>
  `;
}

function render() {
  const route = window.location.hash || "#/";

  if (route === "#/runtimes") {
    view.innerHTML = renderRuntimes();
    return;
  }

  if (route === "#/notes") {
    view.innerHTML = renderNotes();
    return;
  }

  view.innerHTML = renderOverview();
}

window.addEventListener("hashchange", render);
loadRuntimes().finally(render);
