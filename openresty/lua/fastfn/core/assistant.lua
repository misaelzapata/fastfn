local cjson = require "cjson.safe"
local http_client = require "fastfn.core.http_client"

local M = {}

local function env(name, default_value)
  local v = os.getenv(name)
  if v == nil or v == "" then
    return default_value
  end
  return v
end

local function env_bool(name, default_value)
  local raw = os.getenv(name)
  if raw == nil or raw == "" then
    return default_value
  end
  raw = string.lower(raw)
  if raw == "1" or raw == "true" or raw == "yes" or raw == "on" then
    return true
  end
  if raw == "0" or raw == "false" or raw == "no" or raw == "off" then
    return false
  end
  return default_value
end

local function assistant_enabled()
  return env_bool("FN_ASSISTANT_ENABLED", false)
end

local function provider()
  return string.lower(env("FN_ASSISTANT_PROVIDER", "mock"))
end

local function extract_output_text(resp)
  if type(resp) ~= "table" then
    return nil
  end
  local out = {}
  local output = resp.output
  if type(output) ~= "table" then
    return nil
  end
  for _, item in ipairs(output) do
    if type(item) == "table" and item.type == "message" and item.role == "assistant" and type(item.content) == "table" then
      for _, part in ipairs(item.content) do
        if type(part) == "table" and part.type == "output_text" and type(part.text) == "string" then
          out[#out + 1] = part.text
        end
      end
    end
  end
  if #out == 0 then
    return nil
  end
  return table.concat(out, "")
end

local function mock_generate(opts)
  local runtime = tostring(opts.runtime or "python")
  local name = tostring(opts.name or "hello")
  local template = tostring(opts.template or "hello_json")
  local hint = string.format("fastfn assistant (mock) runtime=%s name=%s template=%s", runtime, name, template)

  if runtime == "python" then
    return ([[import json

# %s
def handler(event):
    query = event.get("query") or {}
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"ok": True, "function": %q, "query": query}, separators=(",", ":")),
    }
]]):format(hint, name)
  end

  if runtime == "node" then
    return ([[// %s
exports.handler = async (event) => {
  const query = event.query || {};
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ok: true, function: %q, query }),
  };
};
]]):format(hint, name)
  end

  return "-- unsupported runtime in mock provider\n"
end

local function openai_generate(opts)
  local key = env("OPENAI_API_KEY", "")
  if key == "" then
    return nil, "OPENAI_API_KEY not set"
  end

  local base = env("OPENAI_BASE_URL", "https://api.openai.com/v1")
  base = base:gsub("/+$", "")
  local model = env("OPENAI_MODEL", "gpt-4.1-mini")

  local runtime = tostring(opts.runtime or "python")
  local name = tostring(opts.name or "hello")
  local template = tostring(opts.template or "hello_json")
  local prompt = tostring(opts.prompt or "")

  local system = [[You write tiny serverless handlers for fastfn.
Return only code (no markdown fences, no commentary).
The handler must export/define handler(event) and return {status, headers, body} or {proxy:{...}}.
Use event.context.timeout_ms for timeouts if you do outbound calls.
Keep code minimal and readable for beginners.]]

  local user = string.format([[Generate a %s function named %s using template=%s.
User prompt:
%s
]], runtime, name, template, prompt)

  local payload = {
    model = model,
    input = {
      {
        role = "system",
        content = {
          { type = "input_text", text = system },
        },
      },
      {
        role = "user",
        content = {
          { type = "input_text", text = user },
        },
      },
    },
  }

  local body = cjson.encode(payload)
  if not body then
    return nil, "encode error"
  end

  local resp, err = http_client.request({
    url = base .. "/responses",
    method = "POST",
    timeout_ms = tonumber(opts.timeout_ms) or 8000,
    max_body_bytes = 1024 * 1024,
    headers = {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. key,
    },
    body = body,
  })
  if not resp then
    return nil, err
  end
  if tonumber(resp.status) ~= 200 then
    local msg = "assistant request failed"
    if type(resp.body) == "string" and resp.body ~= "" then
      msg = msg .. ": " .. resp.body
    end
    return nil, msg
  end

  local decoded = cjson.decode(resp.body or "")
  local text = extract_output_text(decoded)
  if not text then
    return nil, "assistant returned no text output"
  end
  return text
end

function M.generate(opts)
  if not assistant_enabled() then
    return nil, "assistant disabled"
  end
  local p = provider()
  if p == "mock" then
    return mock_generate(opts)
  end
  if p == "openai" then
    return openai_generate(opts)
  end
  return nil, "unknown assistant provider"
end

return M

