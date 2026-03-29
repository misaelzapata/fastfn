local guard = require "fastfn.console.guard"

if not guard.enforce_ui() then
  return
end

local function set_no_cache_html_headers()
  ngx.status = 200
  ngx.header["Content-Type"] = "text/html; charset=utf-8"
  ngx.header["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
  ngx.header["Pragma"] = "no-cache"
  ngx.header["Expires"] = "0"
end

local function serve_html_file(path)
  local f, err = io.open(path, "rb")
  if not f then
    ngx.status = 500
    ngx.header["Content-Type"] = "text/plain; charset=utf-8"
    ngx.say("console unavailable")
    return
  end
  local body = f:read("*a")
  f:close()
  ngx.print(body or "")
end

-- If login is enabled and the user has no session, serve a small login page.
if guard.login_enabled() and not (guard.request_has_admin_token() or guard.request_has_session()) then
  set_no_cache_html_headers()
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

set_no_cache_html_headers()
local prefix = ngx.config.prefix() or ""
serve_html_file(prefix .. "console/index.html")
