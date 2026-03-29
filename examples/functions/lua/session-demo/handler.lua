-- Session & cookie demo — shows how to access event.session in Lua.
--
-- Usage:
--   Send a request with Cookie header: session_id=abc123; theme=dark
--   The handler reads event.session.cookies, event.session.id, and prints debug info.
--
-- event.session shape:
--   - id:      auto-detected from session_id / sessionid / sid cookies (or nil)
--   - raw:     the full Cookie header string
--   - cookies: table of parsed cookie key/value pairs

local cjson = require("cjson.safe")

function handler(event)
  local session = event.session or {}
  local cookies = session.cookies or {}

  -- Demonstrate stdout capture — this will appear in Quick Test > stdout
  print("[session-demo] session_id = " .. tostring(session.id))
  print("[session-demo] cookies = " .. (cjson.encode(cookies) or "{}"))

  -- Check for authentication
  if not session.id then
    return {
      status = 401,
      headers = { ["Content-Type"] = "application/json" },
      body = cjson.encode({
        error = "No session cookie found",
        hint = "Send Cookie: session_id=your-token",
      }),
    }
  end

  return {
    status = 200,
    headers = { ["Content-Type"] = "application/json" },
    body = cjson.encode({
      authenticated = true,
      session_id = session.id,
      theme = cookies.theme or "light",
      all_cookies = cookies,
    }),
  }
end
