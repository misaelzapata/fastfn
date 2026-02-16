exports.handler = async () => ({
  status: 200,
  headers: { 'Content-Type': 'text/html; charset=utf-8' },
  body: `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>FastFn Visual Showcase</title>
    <style>
      :root {
        --bg-a: #0b1020;
        --bg-b: #13233f;
        --panel: rgba(255, 255, 255, 0.1);
        --text: #f8fafc;
        --muted: #cbd5e1;
        --accent: #22c55e;
      }
      * { box-sizing: border-box; }
      body {
        margin: 0;
        min-height: 100vh;
        font-family: "Avenir Next", "Segoe UI", sans-serif;
        color: var(--text);
        background: radial-gradient(circle at 20% 10%, #1d4ed8 0%, transparent 40%),
                    radial-gradient(circle at 80% 90%, #0891b2 0%, transparent 45%),
                    linear-gradient(140deg, var(--bg-a), var(--bg-b));
      }
      main {
        max-width: 1080px;
        margin: 0 auto;
        padding: 56px 20px 64px;
      }
      h1 {
        margin: 0;
        font-size: clamp(2rem, 5vw, 3.5rem);
        letter-spacing: -0.02em;
      }
      .lead {
        margin-top: 14px;
        color: var(--muted);
        font-size: 1.05rem;
        max-width: 720px;
        line-height: 1.6;
      }
      .grid {
        margin-top: 28px;
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
        gap: 16px;
      }
      .tile {
        border: 1px solid rgba(255, 255, 255, 0.2);
        border-radius: 14px;
        padding: 16px;
        background: var(--panel);
        backdrop-filter: blur(8px);
      }
      .tile h2 {
        margin: 0 0 8px;
        font-size: 1rem;
      }
      .tile p {
        margin: 0;
        color: var(--muted);
        line-height: 1.45;
      }
      .form-shell {
        margin-top: 16px;
      }
      .form-help {
        margin-top: 4px;
      }
      .form-grid {
        margin-top: 14px;
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
        gap: 12px;
      }
      .field {
        display: flex;
        flex-direction: column;
        gap: 6px;
      }
      .field.wide {
        grid-column: 1 / -1;
      }
      .field span {
        color: #e2e8f0;
        font-size: 0.86rem;
        font-weight: 600;
      }
      .field input,
      .field select,
      .field textarea {
        border: 1px solid rgba(255, 255, 255, 0.22);
        border-radius: 10px;
        background: rgba(8, 16, 36, 0.6);
        color: var(--text);
        font: inherit;
        padding: 10px 12px;
      }
      .field textarea {
        min-height: 78px;
        resize: vertical;
      }
      .field input:focus,
      .field select:focus,
      .field textarea:focus {
        outline: none;
        border-color: #60a5fa;
        box-shadow: 0 0 0 2px rgba(96, 165, 250, 0.25);
      }
      .preview {
        margin-top: 16px;
        border: 1px solid rgba(255, 255, 255, 0.25);
        border-radius: 14px;
        padding: 14px;
        background: rgba(8, 16, 36, 0.72);
      }
      .preview .kicker {
        color: #93c5fd;
        font-size: 0.75rem;
        text-transform: uppercase;
        letter-spacing: 0.08em;
      }
      .preview h3 {
        margin: 8px 0 6px;
        font-size: 1.2rem;
      }
      .preview p {
        margin: 0;
      }
      .share {
        margin-top: 12px;
        color: #bfdbfe;
        font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
        font-size: 0.85rem;
      }
      .actions {
        margin-top: 12px;
        display: flex;
        flex-wrap: wrap;
        gap: 10px;
        align-items: center;
      }
      .btn {
        border: 1px solid rgba(255, 255, 255, 0.22);
        border-radius: 10px;
        background: rgba(8, 16, 36, 0.65);
        color: #e2e8f0;
        font: inherit;
        padding: 8px 12px;
        cursor: pointer;
      }
      .btn:hover {
        border-color: #93c5fd;
      }
      .status {
        color: #93c5fd;
        font-size: 0.84rem;
      }
      .badge {
        display: inline-block;
        margin-top: 24px;
        border-radius: 999px;
        padding: 8px 14px;
        font-size: 0.85rem;
        font-weight: 700;
        color: #032012;
        background: linear-gradient(90deg, #86efac, #22c55e);
      }
      .code {
        margin-top: 12px;
        color: #bbf7d0;
        font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
        font-size: 0.93rem;
      }
      a {
        color: #93c5fd;
        text-decoration: none;
      }
      a:hover { text-decoration: underline; }
    </style>
  </head>
  <body>
    <main>
      <h1>FastFn Visual Showcase</h1>
      <p class="lead">
        HTML and CSS can be served directly from function files, with the same routing model used for JSON APIs.
      </p>
      <div class="grid">
        <article class="tile">
          <h2>File Route</h2>
          <p><code>showcase/index.js</code> maps to <code>GET /showcase</code>.</p>
        </article>
        <article class="tile">
          <h2>No Templates Required</h2>
          <p>Return <code>text/html</code> and you get full control over markup and styling.</p>
        </article>
        <article class="tile">
          <h2>Pair With API Routes</h2>
          <p>Keep UI pages and JSON endpoints in the same project structure.</p>
        </article>
      </div>
      <section class="tile form-shell">
        <h2>Real-time form demo</h2>
        <p class="form-help">Change fields and preview updates instantly.</p>
        <div class="form-grid">
          <label class="field">
            <span>Name</span>
            <input id="nameInput" value="Builder" />
          </label>
          <label class="field">
            <span>Accent</span>
            <select id="accentInput">
              <option value="#22c55e">Green</option>
              <option value="#38bdf8">Sky</option>
              <option value="#f59e0b">Amber</option>
              <option value="#f472b6">Pink</option>
            </select>
          </label>
          <label class="field wide">
            <span>Message</span>
            <textarea id="messageInput">This preview is rendered from a FastFn function endpoint.</textarea>
          </label>
        </div>
        <article class="preview" id="previewCard">
          <p class="kicker">Preview</p>
          <h3 id="previewTitle">Hello Builder</h3>
          <p id="previewMessage">This preview is rendered from a FastFn function endpoint.</p>
        </article>
        <div class="share">Share URL: <span id="shareUrl"></span></div>
        <div class="actions">
          <button type="button" class="btn" id="savePostBtn">Save with POST</button>
          <button type="button" class="btn" id="savePutBtn">Update with PUT</button>
          <span class="status" id="saveStatus">Loading /showcase/form...</span>
        </div>
      </section>
      <div class="badge">Live from FastFn function runtime</div>
      <div class="code">Try also: <a href="/html?name=Designer">/html?name=Designer</a></div>
    </main>
    <script>
      (() => {
        const ENDPOINT = '/showcase/form';
        const nameInput = document.getElementById('nameInput');
        const accentInput = document.getElementById('accentInput');
        const messageInput = document.getElementById('messageInput');
        const title = document.getElementById('previewTitle');
        const message = document.getElementById('previewMessage');
        const preview = document.getElementById('previewCard');
        const share = document.getElementById('shareUrl');
        const saveStatus = document.getElementById('saveStatus');
        const savePostBtn = document.getElementById('savePostBtn');
        const savePutBtn = document.getElementById('savePutBtn');
        let persistTimer = null;

        const readStateFromForm = () => ({
          name: (nameInput.value || 'Builder').trim() || 'Builder',
          accent: accentInput.value || '#22c55e',
          message: (messageInput.value || 'Live preview').trim() || 'Live preview',
        });

        const applyStateToForm = (state) => {
          if (!state || typeof state !== 'object') return;
          nameInput.value = state.name || 'Builder';
          accentInput.value = state.accent || '#22c55e';
          messageInput.value = state.message || 'Live preview';
        };

        const syncPreview = () => {
          const state = readStateFromForm();
          const name = state.name;
          const accent = state.accent;
          const text = state.message;
          title.textContent = 'Hello ' + name;
          message.textContent = text;
          preview.style.borderColor = accent;
          preview.style.boxShadow = '0 0 0 1px ' + accent + '33, 0 10px 26px ' + accent + '22';
          share.textContent = '/html?name=' + encodeURIComponent(name);
        };

        const saveState = async (method) => {
          saveStatus.textContent = method + ' ' + ENDPOINT + '...';
          try {
            const res = await fetch(ENDPOINT, {
              method,
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify(readStateFromForm()),
            });
            if (!res.ok) {
              throw new Error('HTTP ' + res.status);
            }
            const payload = await res.json();
            applyStateToForm(payload.data);
            syncPreview();
            saveStatus.textContent = method + ' saved';
          } catch (err) {
            saveStatus.textContent = 'Save failed: ' + (err.message || 'unknown error');
          }
        };

        const schedulePostSave = () => {
          if (persistTimer) clearTimeout(persistTimer);
          persistTimer = setTimeout(() => {
            saveState('POST');
          }, 350);
        };

        const loadInitial = async () => {
          saveStatus.textContent = 'Loading ' + ENDPOINT + '...';
          try {
            const res = await fetch(ENDPOINT);
            if (!res.ok) {
              throw new Error('HTTP ' + res.status);
            }
            const payload = await res.json();
            applyStateToForm(payload.data);
            syncPreview();
            saveStatus.textContent = 'Loaded with GET';
          } catch (err) {
            saveStatus.textContent = 'Load failed: ' + (err.message || 'unknown error');
            syncPreview();
          }
        };

        nameInput.addEventListener('input', () => {
          syncPreview();
          schedulePostSave();
        });
        accentInput.addEventListener('change', () => {
          syncPreview();
          schedulePostSave();
        });
        messageInput.addEventListener('input', () => {
          syncPreview();
          schedulePostSave();
        });
        savePostBtn.addEventListener('click', () => saveState('POST'));
        savePutBtn.addEventListener('click', () => saveState('PUT'));

        syncPreview();
        loadInitial();
      })();
    </script>
  </body>
</html>`,
});
