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

local function provider_raw()
  return string.lower(env("FN_ASSISTANT_PROVIDER", "auto"))
end

local function provider()
  local p = provider_raw()
  if p == "openai" or p == "mock" or p == "claude" then
    return p
  end
  if p == "anthropic" then
    return "claude"
  end
  if p == "auto" then
    if env("OPENAI_API_KEY", "") ~= "" then
      return "openai"
    end
    if env("ANTHROPIC_API_KEY", "") ~= "" then
      return "claude"
    end
    return "mock"
  end
  return p
end

local function normalize_mode(raw)
  local mode = string.lower(tostring(raw or "generate"))
  if mode ~= "generate" and mode ~= "chat" and mode ~= "auto" then
    return "generate"
  end
  return mode
end

local function prompt_looks_like_chat(raw)
  local prompt = string.lower(tostring(raw or "")):gsub("^%s+", ""):gsub("%s+$", "")
  if prompt == "" then
    return false
  end
  if prompt:find("%?$") then
    return true
  end
  local markers = {
    "what does this function do",
    "que hace esta funcion",
    "explain this function",
    "explica esta funcion",
    "help me understand",
    "por que",
    "why ",
    "how ",
  }
  for _, marker in ipairs(markers) do
    if prompt:find(marker, 1, true) then
      return true
    end
  end
  return false
end

local function resolve_mode(opts)
  local mode = normalize_mode(opts and opts.mode)
  if mode ~= "auto" then
    return mode
  end
  if prompt_looks_like_chat(opts and opts.prompt) then
    return "chat"
  end
  return "generate"
end

local function format_chat_history(raw)
  if type(raw) ~= "table" then
    return ""
  end
  local lines = {}
  local start_idx = 1
  if #raw > 12 then
    start_idx = #raw - 11
  end
  for i = start_idx, #raw do
    local item = raw[i]
    if type(item) == "table" then
      local role = string.lower(tostring(item.role or "assistant"))
      local text = tostring(item.text or item.content or "")
      text = text:gsub("^%s+", ""):gsub("%s+$", "")
      if text ~= "" then
        if #text > 400 then
          text = text:sub(1, 400) .. "..."
        end
        lines[#lines + 1] = string.format("%s: %s", role, text)
      end
    end
  end
  return table.concat(lines, "\n")
end

local function format_test_result(raw)
  if type(raw) ~= "table" then
    return ""
  end
  if raw.error then
    return string.format("Smoke probe error: %s", tostring(raw.error))
  end
  local status = tonumber(raw.status) or 0
  local latency = tonumber(raw.latency_ms) or 0
  local route = tostring(raw.route or "")
  local ok = raw.ok == true and "true" or "false"
  return string.format("Smoke probe: status=%d latency_ms=%d route=%s ok=%s", status, latency, route, ok)
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

local function mock_chat(opts)
  local runtime = tostring(opts.runtime or "python")
  local name = tostring(opts.name or "hello")
  local prompt = tostring(opts.prompt or "")
  local code = tostring(opts.current_code or "")
  local history = format_chat_history(opts.chat_history)
  local smoke = format_test_result(opts.test_result)
  local behavior = "returns a standard {status, headers, body} response."
  if code:find("proxy", 1, true) then
    behavior = "returns a proxy instruction for gateway forwarding."
  end
  local history_hint = history ~= "" and ("\nConversation memory:\n" .. history) or ""
  local smoke_hint = smoke ~= "" and ("\n" .. smoke) or ""
  return string.format(
    "This function `%s/%s` %s\nPrompt: %s%s%s\nNote: assistant provider=mock. Set FN_ASSISTANT_PROVIDER=openai or claude for real AI responses.",
    runtime,
    name,
    behavior,
    prompt,
    history_hint,
    smoke_hint
  )
end

local function openai_request_text(opts, system_text, user_text)
  local key = env("OPENAI_API_KEY", "")
  if key == "" then
    return nil, "OPENAI_API_KEY not set"
  end

  local base = env("OPENAI_BASE_URL", "https://api.openai.com/v1")
  base = base:gsub("/+$", "")
  local model = env("OPENAI_MODEL", "gpt-4.1-mini")

  local payload = {
    model = model,
    input = {
      {
        role = "system",
        content = {
          { type = "input_text", text = tostring(system_text or "") },
        },
      },
      {
        role = "user",
        content = {
          { type = "input_text", text = tostring(user_text or "") },
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

local function extract_anthropic_text(resp)
  if type(resp) ~= "table" then
    return nil
  end
  local out = {}
  local content = resp.content
  if type(content) ~= "table" then
    return nil
  end
  for _, item in ipairs(content) do
    if type(item) == "table" and item.type == "text" and type(item.text) == "string" then
      out[#out + 1] = item.text
    end
  end
  if #out == 0 then
    return nil
  end
  return table.concat(out, "")
end

local function claude_request_text(opts, system_text, user_text)
  local key = env("ANTHROPIC_API_KEY", "")
  if key == "" then
    return nil, "ANTHROPIC_API_KEY not set"
  end

  local base = env("ANTHROPIC_BASE_URL", "https://api.anthropic.com")
  base = base:gsub("/+$", "")
  local model = env("ANTHROPIC_MODEL", "claude-3-5-sonnet-latest")

  local payload = {
    model = model,
    max_tokens = tonumber(opts.max_tokens) or 1200,
    system = tostring(system_text or ""),
    messages = {
      {
        role = "user",
        content = tostring(user_text or ""),
      },
    },
  }

  local body = cjson.encode(payload)
  if not body then
    return nil, "encode error"
  end

  local resp, err = http_client.request({
    url = base .. "/v1/messages",
    method = "POST",
    timeout_ms = tonumber(opts.timeout_ms) or 8000,
    max_body_bytes = 1024 * 1024,
    headers = {
      ["Content-Type"] = "application/json",
      ["x-api-key"] = key,
      ["anthropic-version"] = env("ANTHROPIC_VERSION", "2023-06-01"),
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
  local text = extract_anthropic_text(decoded)
  if not text then
    return nil, "assistant returned no text output"
  end
  return text
end

local function openai_generate(opts)
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

  return openai_request_text(opts, system, user)
end

local function claude_generate(opts)
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

  return claude_request_text(opts, system, user)
end

local function openai_chat(opts)
  local runtime = tostring(opts.runtime or "python")
  local name = tostring(opts.name or "hello")
  local prompt = tostring(opts.prompt or "")
  local current_code = tostring(opts.current_code or "")
  local history = format_chat_history(opts.chat_history)
  local smoke = format_test_result(opts.test_result)
  if current_code == "" then
    current_code = "(no code available in editor context)"
  end
  if #current_code > 12000 then
    current_code = current_code:sub(1, 12000) .. "\n...truncated..."
  end

  local system = [[You are a concise FastFn coding assistant.
Reply in plain text. Do not use markdown fences.
If asked what the function does, explain behavior from the provided code context.
If asked to modify code, provide clear concrete changes.
Use conversation memory and smoke test context when provided.]]

  local user = string.format([[Runtime: %s
Function: %s
Current code:
%s

Conversation memory:
%s

Latest smoke probe:
%s

User message:
%s
]], runtime, name, current_code, (history ~= "" and history or "(none)"), (smoke ~= "" and smoke or "(none)"), prompt)

  return openai_request_text(opts, system, user)
end

local function claude_chat(opts)
  local runtime = tostring(opts.runtime or "python")
  local name = tostring(opts.name or "hello")
  local prompt = tostring(opts.prompt or "")
  local current_code = tostring(opts.current_code or "")
  local history = format_chat_history(opts.chat_history)
  local smoke = format_test_result(opts.test_result)
  if current_code == "" then
    current_code = "(no code available in editor context)"
  end
  if #current_code > 12000 then
    current_code = current_code:sub(1, 12000) .. "\n...truncated..."
  end

  local system = [[You are a concise FastFn coding assistant.
Reply in plain text. Do not use markdown fences.
If asked what the function does, explain behavior from the provided code context.
If asked to modify code, provide clear concrete changes.
Use conversation memory and smoke test context when provided.]]

  local user = string.format([[Runtime: %s
Function: %s
Current code:
%s

Conversation memory:
%s

Latest smoke probe:
%s

User message:
%s
]], runtime, name, current_code, (history ~= "" and history or "(none)"), (smoke ~= "" and smoke or "(none)"), prompt)

  return claude_request_text(opts, system, user)
end

function M.status()
  return {
    enabled = assistant_enabled(),
    provider = provider(),
    configured_provider = provider_raw(),
    openai_key_configured = env("OPENAI_API_KEY", "") ~= "",
    anthropic_key_configured = env("ANTHROPIC_API_KEY", "") ~= "",
  }
end

function M.generate(opts)
  opts = opts or {}
  local mode = resolve_mode(opts)
  if not assistant_enabled() then
    return nil, "assistant disabled", mode
  end

  local p = provider()
  if p == "mock" then
    if mode == "chat" then
      return mock_chat(opts), nil, mode
    end
    return mock_generate(opts), nil, mode
  end

  if p == "openai" then
    local text, err
    if mode == "chat" then
      text, err = openai_chat(opts)
    else
      text, err = openai_generate(opts)
    end
    if not text then
      return nil, err or "assistant failed", mode
    end
    return text, nil, mode
  end

  if p == "claude" then
    local text, err
    if mode == "chat" then
      text, err = claude_chat(opts)
    else
      text, err = claude_generate(opts)
    end
    if not text then
      return nil, err or "assistant failed", mode
    end
    return text, nil, mode
  end

  return nil, "unknown assistant provider", mode
end

return M
