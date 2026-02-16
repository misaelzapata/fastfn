local guard = require "fastfn.console.guard"
local auth = require "fastfn.console.auth"

if not guard.enforce_ui() then
  return
end

-- If login is enabled and the user has no session, serve a small login page.
if guard.login_enabled() and not (guard.request_has_admin_token() or guard.request_has_session()) then
  ngx.status = 200
  ngx.header["Content-Type"] = "text/html; charset=utf-8"
  ngx.header["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
  ngx.header["Pragma"] = "no-cache"
  ngx.header["Expires"] = "0"

  ngx.say([[
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>fastfn Console Login</title>
    <link rel="stylesheet" href="/console/assets/console.css" />
  </head>
  <body>
    <div class="layout">
      <main class="main" style="max-width:520px; margin:0 auto;">
        <section class="card" style="margin-top:32px;">
          <h2>Console Login</h2>
          <div class="muted" style="margin-bottom:12px;">This instance requires login to use the Console UI.</div>
          <label>Username</label>
          <input id="loginUser" placeholder="user" />
          <label class="mt">Password</label>
          <input id="loginPass" type="password" placeholder="password" />
          <div class="actions" style="margin-top:12px;">
            <button class="btn" id="loginBtn">Login</button>
          </div>
          <div id="loginStatus" class="status muted"></div>
        </section>
      </main>
    </div>
    <script type="module" src="/console/assets/login.js?v=20260212a"></script>
  </body>
</html>
]])
  return
end

ngx.status = 200
ngx.header["Content-Type"] = "text/html; charset=utf-8"
ngx.header["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
ngx.header["Pragma"] = "no-cache"
ngx.header["Expires"] = "0"

ngx.say([[
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>fastfn Console</title>
    <link rel="stylesheet" href="/console/assets/console.css" />
  </head>
  <body>
    <div class="layout">
      <aside class="sidebar">
        <h1>fastfn Console</h1>
        <div id="meta" class="muted">Loading...</div>
        <div class="label">Search</div>
        <input id="search" placeholder="function@version" />
        <div class="label">Recent</div>
        <div class="list" id="historyList"></div>
        <div class="list" id="fnList"></div>
      </aside>

      <main class="main">
        <nav class="app-nav">
          <div class="segmented" role="tablist" aria-label="Console tabs">
            <button class="tab-btn active" data-tab-btn="explorer">Explorer</button>
            <button class="tab-btn" data-tab-btn="wizard">Wizard</button>
            <button class="tab-btn" data-tab-btn="gateway">Gateway</button>
            <button class="tab-btn" data-tab-btn="configuration">Configuration</button>
            <button class="tab-btn" data-tab-btn="crud">CRUD</button>
          </div>
        </nav>

        <div class="tab-panel active" data-tab-panel="explorer">
          <section class="card">
            <h2>Function Details</h2>
            <div id="details" class="muted">Select a function from the left.</div>
          </section>

          <section class="card">
            <h2>Invoke</h2>
            <div class="row">
              <div>
                <label>Method</label>
                <select id="method">
                  <option>GET</option>
                  <option>POST</option>
                  <option>PUT</option>
                  <option>PATCH</option>
                  <option>DELETE</option>
                </select>
              </div>
              <div>
                <label>Query JSON</label>
                <input id="query" placeholder='{}' />
              </div>
            </div>
            <label class="mt">Context JSON (optional)</label>
            <textarea id="context" placeholder='{"trace_id":"demo-123"}'></textarea>
            <label class="mt">Body (string)</label>
            <textarea id="body" placeholder=""></textarea>
            <div class="actions">
              <button class="btn" id="invokeBtn">Invoke</button>
              <button class="btn secondary" id="enqueueBtn">Enqueue Job</button>
            </div>
            <div id="invokeMeta" class="status muted"></div>
            <pre id="invokeOut">No invocation yet.</pre>
          </section>
        </div>

        <div class="tab-panel" data-tab-panel="wizard">
          <section class="card">
            <h2>Build Your First Function (Step by Step)</h2>
            <div class="muted">
              This wizard is designed for beginners. Pick a language, choose a template, and fastfn will create the files for you.
            </div>
            <div class="muted" style="margin-top:10px;">
              <div><strong>What gets created</strong></div>
              <div><code>&lt;FN_FUNCTIONS_ROOT&gt;/&lt;runtime&gt;/&lt;name&gt;/[&lt;version&gt;]/app.*</code></div>
              <div><code>fn.config.json</code> (methods, defaults, routes) and <code>fn.env.json</code> (env vars).</div>
              <div style="margin-top:8px;"><strong>How requests map</strong></div>
              <div>Query string becomes <code>event.query</code> and the raw body becomes <code>event.body</code>.</div>
              <div style="margin-top:8px;"><strong>Edge passthrough</strong></div>
              <div>The Edge Proxy template returns a <code>proxy</code> directive; fastfn performs the outbound request and returns the upstream response.</div>
            </div>
            <div class="grid" style="margin-top:10px;">
              <div>
                <label>Runtime</label>
                <select id="wizRuntime">
                  <option value="python">python</option>
                  <option value="node">node</option>
                  <option value="php">php</option>
                  <option value="rust">rust</option>
                </select>
              </div>
              <div>
                <label>Function name</label>
                <input id="wizName" placeholder="hello" />
              </div>
              <div>
                <label>Version (optional)</label>
                <input id="wizVersion" placeholder="v2" />
              </div>
              <div>
                <label>Template</label>
                <select id="wizTemplate">
                  <option value="hello_json">Hello (JSON)</option>
                  <option value="hello_ts">Hello (TypeScript)</option>
                  <option value="echo">Echo (query + body)</option>
                  <option value="html">HTML page</option>
                  <option value="csv">CSV export</option>
                  <option value="png">PNG image (base64)</option>
                  <option value="edge_proxy">Edge passthrough (proxy)</option>
                  <option value="edge_filter">Edge filter (auth + rewrite)</option>
                  <option value="edge_auth_gateway">Edge gateway auth (Bearer)</option>
                  <option value="github_webhook_guard">GitHub webhook guard (HMAC)</option>
                  <option value="edge-header-inject">Edge header injection</option>
                  <option value="telegram_ai_reply">Telegram AI reply bot</option>
                  <option value="edge_proxy_ts">Edge proxy (TypeScript)</option>
                </select>
              </div>
            </div>
            <div class="actions" style="margin-top:12px;">
              <button class="btn" id="wizCreateBtn">Create function</button>
              <button class="btn secondary" id="wizCreateOpenBtn">Create and open</button>
            </div>
            <div id="wizStatus" class="status muted"></div>
          </section>

          <section class="card">
            <h2>AI Helper (Optional)</h2>
            <div class="muted">
              If enabled, fastfn can generate starter code for a function. This is disabled by default.
            </div>
            <label class="mt">Prompt</label>
            <textarea id="wizPrompt" placeholder="Make a function that proxies /api/* to https://example.com and adds an x-demo header."></textarea>
            <div class="actions">
              <button class="btn secondary" id="wizAiBtn">Generate code</button>
              <button class="btn" id="wizAiCreateBtn">Create using AI code</button>
            </div>
            <pre id="wizAiOut">No AI output yet.</pre>
          </section>

          <section class="card">
            <h2>Next</h2>
            <div class="muted">
              After creating a function, use the Explorer tab to invoke it, tweak config/env, and edit code.
            </div>
          </section>
        </div>

        <div class="tab-panel" data-tab-panel="gateway">
          <section class="card">
            <h2>Gateway Routes</h2>
            <div class="row">
              <div>
                <label>Route Search</label>
                <input id="routeSearch" placeholder="/api/" />
              </div>
              <div>
                <label>Summary</label>
                <div id="gatewaySummary" class="muted">Loading...</div>
              </div>
            </div>
            <div class="table-wrap" style="margin-top:10px;">
              <table class="table" id="routeTable">
                <thead>
                  <tr>
                    <th>Route</th>
                    <th>Target</th>
                    <th>Methods</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody id="routeTableBody"></tbody>
              </table>
            </div>
          </section>
          <section class="card">
            <h2>Mapped Route Conflicts</h2>
            <div id="routeConflicts" class="muted">No conflicts.</div>
          </section>

          <section class="card">
            <h2>Async Jobs</h2>
            <div class="row">
              <div>
                <label>Jobs</label>
                <div class="actions" style="margin-top:6px;">
                  <button class="btn secondary" id="refreshJobsBtn">Refresh Jobs</button>
                </div>
                <div id="jobsStatus" class="status muted"></div>
              </div>
            </div>
            <div class="table-wrap" style="margin-top:10px;">
              <table class="table" id="jobsTable">
                <thead>
                  <tr>
                    <th>ID</th>
                    <th>Status</th>
                    <th>Target</th>
                    <th>Method</th>
                    <th>Attempt</th>
                  </tr>
                </thead>
                <tbody id="jobsTableBody"></tbody>
              </table>
            </div>
            <pre id="jobDetail" style="margin-top:10px;">No job selected.</pre>
          </section>
        </div>

        <div class="tab-panel" data-tab-panel="configuration">
          <details class="accordion" open>
            <summary>Limits / Config</summary>
            <section class="card">
              <div class="grid">
                <div>
                  <label>timeout_ms</label>
                  <input id="cfgTimeout" type="number" min="1" />
                </div>
                <div>
                  <label>max_concurrency</label>
                  <input id="cfgConc" type="number" min="0" />
                </div>
                <div>
                  <label>max_body_bytes</label>
                  <input id="cfgBody" type="number" min="1" />
                </div>
                <div>
                  <label>group (optional)</label>
                  <input id="cfgGroup" placeholder="demos" />
                </div>
              </div>
              <div class="row" style="margin-top:8px;">
                <div>
                  <label>shared_deps (packs, one per line)</label>
                  <textarea id="cfgSharedDeps" placeholder="qr_packs&#10;common_http"></textarea>
                </div>
              </div>
              <div class="row" style="margin-top:8px;">
                <div>
                  <label>Available Packs (runtime-local)</label>
                  <div class="actions" style="margin-top:6px;">
                    <button class="btn secondary" id="refreshPacksBtn">Refresh Packs</button>
                  </div>
                  <div id="packsList" class="muted" style="margin-top:8px;">No packs loaded.</div>
                </div>
              </div>
              <div class="row" style="margin-top:8px;">
                <div>
                  <label>Allowed Methods</label>
                  <div class="method-flags">
                    <label><input type="checkbox" name="cfgMethods" value="GET" /> GET</label>
                    <label><input type="checkbox" name="cfgMethods" value="POST" /> POST</label>
                    <label><input type="checkbox" name="cfgMethods" value="PUT" /> PUT</label>
                    <label><input type="checkbox" name="cfgMethods" value="PATCH" /> PATCH</label>
                    <label><input type="checkbox" name="cfgMethods" value="DELETE" /> DELETE</label>
                  </div>
                </div>
              </div>
              <div class="row" style="margin-top:8px;">
                <div>
                  <label>Mapped Endpoints (one path per line)</label>
                  <textarea id="cfgRoutes" placeholder="/api/hello&#10;/public/v2/hello"></textarea>
                </div>
              </div>
              <details class="accordion" style="margin-top:8px;">
                <summary>Edge Proxy (optional)</summary>
                <div class="muted" style="margin-top:8px;">
                  Enable this if your handler returns <code>{"proxy": {...}}</code>. By default, edge proxy is disabled per function.
                </div>
                <div class="grid" style="margin-top:10px;">
                  <div>
                    <label>edge.base_url</label>
                    <input id="edgeBaseUrl" placeholder="https://api.example.com" />
                  </div>
                  <div>
                    <label>edge.max_response_bytes</label>
                    <input id="edgeMaxResp" type="number" min="1" placeholder="1048576" />
                  </div>
                </div>
                <div class="row" style="margin-top:8px;">
                  <div>
                    <label>
                      <input id="edgeAllowPrivate" type="checkbox" />
                      edge.allow_private (dev only)
                    </label>
                  </div>
                </div>
                <div style="margin-top:8px;">
                  <label>edge.allow_hosts (one per line)</label>
                  <textarea id="edgeAllowHosts" placeholder="api.example.com"></textarea>
                </div>
              </details>
              <div class="row" style="margin-top:8px;">
                <div>
                  <label>
                    <input id="cfgDebugHeaders" type="checkbox" />
                    include_debug_headers
                  </label>
                </div>
              </div>
              <div class="actions">
                <button class="btn" id="saveCfgBtn">Save Config</button>
                <button class="btn secondary" id="reloadBtn">Reload Catalog</button>
              </div>
              <div id="cfgStatus" class="status muted"></div>
            </section>
          </details>

          <details class="accordion">
            <summary>Schedule (Cron)</summary>
            <section class="card">
              <div class="row">
                <div>
                  <label><input id="schedEnabled" type="checkbox" /> enabled</label>
                </div>
                <div>
                  <label>every_seconds</label>
                  <input id="schedEvery" type="number" min="1" placeholder="60" />
                </div>
              </div>
              <div class="row" style="margin-top:8px;">
                <div>
                  <label>method</label>
                  <select id="schedMethod">
                    <option>GET</option>
                    <option>POST</option>
                    <option>PUT</option>
                    <option>PATCH</option>
                    <option>DELETE</option>
                  </select>
                </div>
                <div>
                  <label>query JSON</label>
                  <input id="schedQuery" placeholder="{}" />
                </div>
              </div>
              <label class="mt">headers JSON (optional)</label>
              <textarea id="schedHeaders" placeholder="{}"></textarea>
              <label class="mt">body (string)</label>
              <textarea id="schedBody" placeholder=""></textarea>
              <label class="mt">context JSON (optional)</label>
              <textarea id="schedContext" placeholder="{}"></textarea>
              <div class="actions">
                <button class="btn" id="saveSchedBtn">Save Schedule</button>
              </div>
              <div id="schedStatus" class="status muted"></div>
              <pre id="schedState" style="margin-top:8px;">No schedule state loaded.</pre>
            </section>
          </details>

          <details class="accordion">
            <summary>Function Env</summary>
            <section class="card">
              <label>fn.env patch (JSON object; supports scalar or {value,is_secret}; use null to remove key)</label>
              <textarea id="envEditor" placeholder='{"API_KEY":{"value":"sk-demo","is_secret":true},"GREETING_PREFIX":"hello","OLD_KEY":null}'></textarea>
              <div class="actions">
                <button class="btn" id="saveEnvBtn">Save Env</button>
              </div>
              <div id="envStatus" class="status muted"></div>
            </section>
          </details>

          <details class="accordion">
            <summary>Code</summary>
            <section class="card">
              <div class="actions" style="margin-bottom:8px;">
                <button class="btn" id="saveCodeBtn">Save Code</button>
              </div>
              <div id="codeStatus" class="status muted"></div>
              <textarea id="codeOut" style="min-height:280px;">No code loaded.</textarea>
            </section>
          </details>
        </div>

        <div class="tab-panel" data-tab-panel="crud">
          <section class="card">
            <h2>Function Management</h2>
            <div class="grid">
              <div>
                <label>runtime</label>
                <select id="crudRuntime"></select>
              </div>
              <div>
                <label>name</label>
                <input id="crudName" placeholder="my_function" />
              </div>
              <div>
                <label>version (optional)</label>
                <input id="crudVersion" placeholder="v2" />
              </div>
            </div>
            <div class="row" style="margin-top:8px;">
              <div>
                <label>endpoint route (optional)</label>
                <input id="crudRoute" placeholder="/api/my-function" />
              </div>
            </div>
            <div class="actions">
              <button class="btn" id="createFnBtn">Create Function</button>
              <button class="btn secondary" id="deleteFnBtn">Delete Selected</button>
            </div>
            <div id="crudStatus" class="status muted"></div>
          </section>

          <section class="card">
            <h2>Console Access</h2>
            <div class="method-flags">
              <label><input type="checkbox" id="uiStateUiEnabled" /> ui_enabled</label>
              <label><input type="checkbox" id="uiStateApiEnabled" /> api_enabled</label>
              <label><input type="checkbox" id="uiStateWriteEnabled" /> write_enabled</label>
              <label><input type="checkbox" id="uiStateLocalOnly" /> local_only</label>
              <label><input type="checkbox" id="uiStateLoginEnabled" /> login_enabled</label>
              <label><input type="checkbox" id="uiStateLoginApiEnabled" /> login_api_enabled</label>
            </div>
            <div class="actions">
              <button class="btn" id="reloadUiStateBtn">Reload State</button>
              <button class="btn secondary" id="saveUiStateBtn">Save State</button>
            </div>
            <div id="uiStateStatus" class="status muted"></div>
          </section>
        </div>
      </main>
    </div>

    <script type="module" src="/console/assets/console.js?v=20260212c"></script>
  </body>
</html>
]])
