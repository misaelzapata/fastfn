local M = {}
local cjson = require "cjson.safe"
local invoke_rules = require "fastfn.core.invoke_rules"
local DEFAULT_METHODS = invoke_rules.DEFAULT_METHODS

local function sorted_keys(tbl)
  local keys = {}
  for k, _ in pairs(tbl or {}) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return keys
end

local function base_error_response(description)
  return {
    description = description,
    content = {
      ["application/json"] = {
        schema = {
          type = "object",
          properties = {
            error = { type = "string" },
          },
          required = { "error" },
        },
      },
    },
  }
end

local function success_response()
  return {
    description = "Function response payload",
    content = {
      ["application/json"] = {
        schema = {
          type = "object",
          additionalProperties = true,
        },
        examples = {
          json = {
            value = {
              ok = true,
              message = "function response",
            },
          },
        },
      },
      ["text/plain"] = {
        schema = { type = "string" },
        examples = {
          text = {
            value = "plain text response",
          },
        },
      },
    },
  }
end

local function clone_path_parameters(path_parameters)
  local out = {}
  for _, p in ipairs(path_parameters or {}) do
    out[#out + 1] = {
      name = p.name,
      ["in"] = "path",
      required = true,
      schema = { type = "string" },
      description = p.description,
    }
  end
  return out
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function schema_from_value(value)
  local t = type(value)
  if t == "boolean" then
    return { type = "boolean" }
  end
  if t == "number" then
    if math.type and math.type(value) == "integer" then
      return { type = "integer" }
    end
    if value % 1 == 0 then
      return { type = "integer" }
    end
    return { type = "number" }
  end
  if t == "table" then
    local has_array_values = false
    local count = 0
    for k, _ in pairs(value) do
      count = count + 1
      if type(k) == "number" then
        has_array_values = true
      else
        has_array_values = false
        break
      end
    end
    if has_array_values and count > 0 then
      return { type = "array", items = {} }
    end
    return { type = "object", additionalProperties = true }
  end
  return { type = "string" }
end

local function decode_json_string_if_possible(raw)
  if type(raw) ~= "string" then
    return raw
  end
  local stripped = trim(raw)
  if stripped == "" then
    return raw
  end
  local decoded = cjson.decode(stripped)
  if decoded == nil then
    return raw
  end
  return decoded
end

local function append_query_parameters(op, invoke_meta)
  if type(invoke_meta) ~= "table" then
    return
  end
  if type(invoke_meta.query_example) ~= "table" then
    return
  end

  op.parameters = op.parameters or {}
  local seen = {}
  for _, p in ipairs(op.parameters) do
    if type(p) == "table" and type(p.name) == "string" and type(p["in"]) == "string" then
      seen[p["in"] .. ":" .. p.name] = true
    end
  end

  for _, key in ipairs(sorted_keys(invoke_meta.query_example)) do
    local value = invoke_meta.query_example[key]
    local schema = schema_from_value(value)
    local example = value
    if type(value) == "table" then
      local encoded = cjson.encode(value)
      if type(encoded) == "string" then
        schema = { type = "string" }
        example = encoded
      end
    end

    local sig = "query:" .. key
    if not seen[sig] then
      op.parameters[#op.parameters + 1] = {
        name = key,
        ["in"] = "query",
        required = false,
        schema = schema,
        example = example,
      }
      seen[sig] = true
    end
  end
end

local function build_request_body(method, invoke_meta)
  if method ~= "post" and method ~= "put" and method ~= "patch" and method ~= "delete" then
    return nil
  end

  local default_body = {
    required = false,
    content = {
      ["application/json"] = {
        schema = {
          oneOf = {
            { type = "object", additionalProperties = true },
            { type = "array", items = {} },
            { type = "string" },
            { type = "number" },
            { type = "boolean" },
            { type = "null" },
          },
        },
        examples = {
          object = { value = { name = "World" } },
          string = { value = "raw-body" },
        },
      },
    },
  }

  if type(invoke_meta) ~= "table" then
    return default_body
  end

  local body_example = invoke_meta.body_example
  if body_example == nil or body_example == "" then
    return default_body
  end

  local content_type = trim(invoke_meta.content_type)
  if content_type == "" then
    content_type = "application/json"
  end
  local normalized = string.lower(content_type)

  if normalized:find("application/json", 1, true) then
    local parsed = decode_json_string_if_possible(body_example)
    local schema = schema_from_value(parsed)
    return {
      required = false,
      content = {
        ["application/json"] = {
          schema = schema,
          examples = {
            primary = { value = parsed },
          },
        },
      },
    }
  end

  local body_text = body_example
  if type(body_text) ~= "string" then
    local encoded = cjson.encode(body_text)
    if type(encoded) == "string" then
      body_text = encoded
    else
      body_text = tostring(body_text)
    end
  end

  return {
    required = false,
    content = {
      [content_type] = {
        schema = { type = "string" },
        examples = {
          primary = { value = body_text },
        },
      },
    },
  }
end

local function operation_template(runtime, name, version, method, path_parameters, invoke_meta)
  local method_upper = string.upper(method)
  local label = runtime .. "/" .. name
  if version then
    label = label .. "@" .. version
  end

  local summary = method_upper .. " invoke " .. label
  if type(invoke_meta) == "table" and type(invoke_meta.summary) == "string" and trim(invoke_meta.summary) ~= "" then
    summary = method_upper .. " " .. trim(invoke_meta.summary)
  end

  local op = {
    tags = { "functions" },
    summary = summary,
    operationId = (method .. "_" .. runtime .. "_" .. name .. "_" .. (version or "default")):gsub("[^%w_]", "_"),
    responses = {
      ["200"] = success_response(),
      ["405"] = base_error_response("Method not allowed"),
      ["404"] = base_error_response("Unknown function or version"),
      ["413"] = base_error_response("Payload too large"),
      ["429"] = base_error_response("Concurrency limit exceeded"),
      ["502"] = base_error_response("Invalid runtime response"),
      ["503"] = base_error_response("Function runtime unavailable"),
      ["504"] = base_error_response("Runtime timeout"),
    },
  }

  op.requestBody = build_request_body(method, invoke_meta)

  if type(path_parameters) == "table" and #path_parameters > 0 then
    op.parameters = clone_path_parameters(path_parameters)
  end
  append_query_parameters(op, invoke_meta)

  return op
end

local function normalized_methods(methods)
  return invoke_rules.normalized_methods(methods, DEFAULT_METHODS)
end

local function methods_operations(runtime, name, version, methods, path_parameters, invoke_meta_lookup)
  local ops = {}
  local invoke_meta = nil
  if type(invoke_meta_lookup) == "function" then
    invoke_meta = invoke_meta_lookup(runtime, name, version)
  end
  for _, method in ipairs(normalized_methods(methods)) do
    local lower = string.lower(method)
    ops[lower] = operation_template(runtime, name, version, lower, path_parameters, invoke_meta)
  end
  return ops
end

local function mapped_route_entries(raw_entry)
  if type(raw_entry) ~= "table" then
    return {}
  end

  -- Backward-compatible shape: { runtime=..., fn_name=..., version=..., methods=... }
  if raw_entry.runtime ~= nil or raw_entry.fn_name ~= nil or raw_entry.version ~= nil or raw_entry.methods ~= nil then
    return { raw_entry }
  end

  -- Current shape: array of route entries (one entry per target/method set).
  local out = {}
  for _, item in ipairs(raw_entry) do
    if type(item) == "table" then
      out[#out + 1] = item
    end
  end
  return out
end

local function route_to_openapi_path_and_parameters(route)
  local raw = tostring(route or "")
  if raw == "" then
    return nil, {}
  end
  if raw == "/" then
    return "/", {}
  end

  local segments = {}
  local path_parameters = {}
  local seen = {}
  for seg in raw:gmatch("[^/]+") do
    local name, catch_all = seg:match("^:([A-Za-z0-9_]+)(%*?)$")
    if name then
      segments[#segments + 1] = "{" .. name .. "}"
      if not seen[name] then
        seen[name] = true
        local p = {
          name = name,
          ["in"] = "path",
          required = true,
          schema = { type = "string" },
        }
        if catch_all == "*" then
          p.description = "Catch-all path parameter; value may include '/' segments."
        end
        path_parameters[#path_parameters + 1] = p
      end
    elseif seg == "*" then
      local wildcard_name = "wildcard"
      if seen[wildcard_name] then
        local i = 2
        while seen[wildcard_name .. tostring(i)] do
          i = i + 1
        end
        wildcard_name = wildcard_name .. tostring(i)
      end
      seen[wildcard_name] = true
      segments[#segments + 1] = "{" .. wildcard_name .. "}"
      path_parameters[#path_parameters + 1] = {
        name = wildcard_name,
        ["in"] = "path",
        required = true,
        schema = { type = "string" },
        description = "Catch-all path parameter; value may include '/' segments.",
      }
    else
      segments[#segments + 1] = seg
    end
  end

  if #segments == 0 then
    return "/", path_parameters
  end
  return "/" .. table.concat(segments, "/"), path_parameters
end

function M.build(catalog, opts)
  opts = opts or {}

  local server_url = opts.server_url or "http://localhost:8080"
  local title = opts.title or "fastfn API"
  local version = opts.version or "1.0.0"
  local ui_state_schema = {
    type = "object",
    properties = {
      ui_enabled = { type = "boolean", default = false },
      api_enabled = { type = "boolean", default = true },
      admin_api_enabled = { type = "boolean", default = true },
      write_enabled = { type = "boolean", default = false },
      local_only = { type = "boolean", default = true },
      login_enabled = { type = "boolean", default = false },
      login_api_enabled = { type = "boolean", default = false },
    },
  }

  local function make_target_parameters(include_code)
    local params = {
      {
        name = "runtime",
        ["in"] = "query",
        required = true,
        schema = { type = "string", pattern = "^[a-zA-Z0-9_-]+$" },
        description = "Runtime id (for example: node, python, php, lua, rust).",
      },
      {
        name = "name",
        ["in"] = "query",
        required = true,
        schema = { type = "string" },
        description = "Function name or file target.",
      },
      {
        name = "version",
        ["in"] = "query",
        required = false,
        schema = { type = "string", pattern = "^[a-zA-Z0-9_.-]+$" },
        description = "Optional function version.",
      },
    }
    if include_code then
      params[#params + 1] = {
        name = "include_code",
        ["in"] = "query",
        required = false,
        schema = {
          type = "string",
          enum = { "0", "1" },
          default = "1",
        },
        description = "Set to 0 to omit source code from the response.",
      }
    end
    return params
  end

  local spec = {
    openapi = "3.1.0",
    info = {
      title = title,
      version = version,
      description = "OpenAPI spec generated from discovered functions",
    },
    servers = {
      { url = server_url },
    },
    paths = {
      ["/_fn/openapi.json"] = {
        get = {
          tags = { "internal" },
          summary = "OpenAPI schema document",
          operationId = "internal_openapi_get",
          responses = {
            ["200"] = {
              description = "OpenAPI JSON",
              content = {
                ["application/json"] = {
                  schema = { type = "object", additionalProperties = true },
                },
              },
            },
            ["404"] = base_error_response("Docs disabled"),
          },
        },
      },
      ["/_fn/docs"] = {
        get = {
          tags = { "internal" },
          summary = "Swagger UI",
          operationId = "internal_docs_get",
          responses = {
            ["200"] = {
              description = "Swagger HTML",
              content = {
                ["text/html"] = {
                  schema = { type = "string" },
                },
              },
            },
            ["404"] = base_error_response("Docs disabled"),
          },
        },
      },
      ["/_fn/health"] = {
        get = {
          tags = { "internal" },
          summary = "Runtime health status",
          operationId = "internal_health_get",
          responses = {
            ["200"] = {
              description = "Health snapshot",
              content = {
                ["application/json"] = {
                  schema = { type = "object", additionalProperties = true },
                },
              },
            },
          },
        },
      },
      ["/_fn/reload"] = {
        get = {
          tags = { "internal" },
          summary = "Reload runtime catalog",
          operationId = "internal_reload_get",
          responses = {
            ["200"] = {
              description = "Reload completed",
              content = {
                ["application/json"] = {
                  schema = {
                    type = "object",
                    properties = { ok = { type = "boolean" } },
                  },
                },
              },
            },
            ["403"] = base_error_response("Forbidden"),
          },
        },
        post = {
          tags = { "internal" },
          summary = "Reload runtime catalog",
          operationId = "internal_reload_post",
          responses = {
            ["200"] = {
              description = "Reload completed",
              content = {
                ["application/json"] = {
                  schema = {
                    type = "object",
                    properties = { ok = { type = "boolean" } },
                  },
                },
              },
            },
            ["403"] = base_error_response("Forbidden"),
          },
        },
      },
      ["/_fn/catalog"] = {
        get = {
          tags = { "internal" },
          summary = "Catalog of discovered functions",
          operationId = "internal_catalog_get",
          responses = {
            ["200"] = {
              description = "Catalog snapshot",
              content = {
                ["application/json"] = {
                  schema = { type = "object", additionalProperties = true },
                },
              },
            },
            ["403"] = base_error_response("Forbidden"),
          },
        },
      },
      ["/_fn/packs"] = {
        get = {
          tags = { "internal" },
          summary = "Shared dependency packs snapshot",
          operationId = "internal_packs_get",
          responses = {
            ["200"] = {
              description = "Packs snapshot",
              content = {
                ["application/json"] = {
                  schema = { type = "object", additionalProperties = true },
                },
              },
            },
            ["403"] = base_error_response("Forbidden"),
          },
        },
      },
      ["/_fn/assistant/generate"] = {
        post = {
          tags = { "internal" },
          summary = "Assistant endpoint (generate code or chat response)",
          operationId = "internal_assistant_generate_post",
          requestBody = {
            required = true,
            content = {
              ["application/json"] = {
                schema = {
                  type = "object",
                  properties = {
                    runtime = { type = "string", examples = { "python" } },
                    name = { type = "string", examples = { "hello" } },
                    template = { type = "string", examples = { "hello-json" } },
                    mode = { type = "string", examples = { "generate", "chat", "auto" } },
                    prompt = { type = "string", examples = { "Make an echo handler" } },
                    current_code = { type = "string", examples = { "exports.handler = async () => ({ status: 200, body: \"ok\" });" } },
                    chat_history = {
                      type = "array",
                      items = {
                        type = "object",
                        properties = {
                          role = { type = "string", examples = { "user" } },
                          text = { type = "string", examples = { "What does this function do?" } },
                        },
                      },
                    },
                    test_result = { type = "object", additionalProperties = true },
                  },
                  required = { "runtime", "name" },
                },
              },
            },
          },
          responses = {
            ["200"] = {
              description = "Generated code",
              content = {
                ["application/json"] = {
                  schema = { type = "object", additionalProperties = true },
                },
              },
            },
            ["400"] = base_error_response("Bad request"),
            ["403"] = base_error_response("Forbidden"),
            ["404"] = base_error_response("Assistant disabled"),
          },
        },
      },
      ["/_fn/assistant/status"] = {
        get = {
          tags = { "internal" },
          summary = "Assistant status (enabled/provider/key-configured)",
          operationId = "internal_assistant_status_get",
          responses = {
            ["200"] = {
              description = "Assistant status",
              content = {
                ["application/json"] = {
                  schema = { type = "object", additionalProperties = true },
                },
              },
            },
            ["403"] = base_error_response("Forbidden"),
          },
        },
      },
      ["/_fn/schedules"] = {
        get = {
          tags = { "internal" },
          summary = "Scheduler snapshot (enabled schedules + state)",
          operationId = "internal_schedules_get",
          responses = {
            ["200"] = {
              description = "Scheduler snapshot",
              content = {
                ["application/json"] = {
                  schema = { type = "object", additionalProperties = true },
                },
              },
            },
            ["403"] = base_error_response("Forbidden"),
          },
        },
      },
      ["/_fn/jobs"] = {
        get = {
          tags = { "internal" },
          summary = "List recent async jobs",
          operationId = "internal_jobs_get",
          parameters = {
            {
              name = "limit",
              ["in"] = "query",
              required = false,
              schema = { type = "integer", minimum = 1, maximum = 200, default = 50 },
              description = "How many recent jobs to return (1-200).",
            },
          },
          responses = {
            ["200"] = {
              description = "Jobs list",
              content = {
                ["application/json"] = {
                  schema = { type = "object", additionalProperties = true },
                },
              },
            },
            ["403"] = base_error_response("Forbidden"),
          },
        },
        post = {
          tags = { "internal" },
          summary = "Enqueue async job (invoke a function later)",
          operationId = "internal_jobs_post",
          requestBody = {
            required = true,
            content = {
              ["application/json"] = {
                schema = {
                  type = "object",
                  properties = {
                    runtime = { type = "string", pattern = "^[a-zA-Z0-9_-]+$" },
                    name = { type = "string" },
                    version = { oneOf = { { type = "string", pattern = "^[a-zA-Z0-9_.-]+$" }, { type = "null" } } },
                    method = { type = "string", enum = { "GET", "POST", "PUT", "PATCH", "DELETE" }, default = "GET" },
                    route = { type = "string" },
                    params = {
                      type = "object",
                      additionalProperties = {
                        oneOf = { { type = "string" }, { type = "number" }, { type = "boolean" }, { type = "null" } },
                      },
                    },
                    query = { type = "object", additionalProperties = true },
                    headers = { type = "object", additionalProperties = true },
                    body = { oneOf = { { type = "string" }, { type = "object", additionalProperties = true }, { type = "array", items = {} }, { type = "number" }, { type = "boolean" }, { type = "null" } } },
                    context = { type = "object", additionalProperties = true },
                    max_attempts = { type = "integer", minimum = 1, maximum = 10, default = 1 },
                    retry_delay_ms = { type = "integer", minimum = 0, default = 1000 },
                  },
                  required = { "runtime", "name" },
                },
              },
            },
          },
          responses = {
            ["201"] = {
              description = "Job enqueued",
              content = { ["application/json"] = { schema = { type = "object", additionalProperties = true } } },
            },
            ["400"] = base_error_response("Invalid payload"),
            ["403"] = base_error_response("Forbidden"),
            ["404"] = base_error_response("Function not found"),
            ["405"] = base_error_response("Method not allowed"),
            ["409"] = base_error_response("Ambiguous function"),
            ["413"] = base_error_response("Payload too large"),
          },
        },
      },
      ["/_fn/jobs/{id}"] = {
        get = {
          tags = { "internal" },
          summary = "Get job metadata",
          operationId = "internal_job_get",
          parameters = {
            { name = "id", ["in"] = "path", required = true, schema = { type = "string" } },
          },
          responses = {
            ["200"] = { description = "Job metadata", content = { ["application/json"] = { schema = { type = "object", additionalProperties = true } } } },
            ["404"] = base_error_response("Job not found"),
            ["403"] = base_error_response("Forbidden"),
          },
        },
        delete = {
          tags = { "internal" },
          summary = "Cancel queued job",
          operationId = "internal_job_delete",
          parameters = {
            { name = "id", ["in"] = "path", required = true, schema = { type = "string" } },
          },
          responses = {
            ["200"] = { description = "Canceled", content = { ["application/json"] = { schema = { type = "object", additionalProperties = true } } } },
            ["404"] = base_error_response("Job not found"),
            ["409"] = base_error_response("Job not queued"),
            ["403"] = base_error_response("Forbidden"),
          },
        },
      },
      ["/_fn/jobs/{id}/result"] = {
        get = {
          tags = { "internal" },
          summary = "Get job result (if completed)",
          operationId = "internal_job_result_get",
          parameters = {
            { name = "id", ["in"] = "path", required = true, schema = { type = "string" } },
          },
          responses = {
            ["200"] = { description = "Job result", content = { ["application/json"] = { schema = { type = "object", additionalProperties = true } } } },
            ["202"] = base_error_response("Result not ready"),
            ["404"] = base_error_response("Result not found"),
            ["403"] = base_error_response("Forbidden"),
          },
        },
      },
      ["/_fn/function"] = {
        get = {
          tags = { "internal" },
          summary = "Get function detail",
          operationId = "internal_function_get",
          parameters = make_target_parameters(true),
          responses = {
            ["200"] = {
              description = "Function detail",
              content = {
                ["application/json"] = {
                  schema = { type = "object", additionalProperties = true },
                },
              },
            },
            ["404"] = base_error_response("Function not found"),
          },
        },
        post = {
          tags = { "internal" },
          summary = "Create function",
          operationId = "internal_function_post",
          parameters = make_target_parameters(false),
          requestBody = {
            required = false,
            content = {
              ["application/json"] = {
                schema = {
                  type = "object",
                  additionalProperties = true,
                },
              },
            },
          },
          responses = {
            ["201"] = {
              description = "Function created",
              content = {
                ["application/json"] = {
                  schema = { type = "object", additionalProperties = true },
                },
              },
            },
            ["400"] = base_error_response("Invalid payload"),
            ["403"] = base_error_response("Forbidden"),
          },
        },
        delete = {
          tags = { "internal" },
          summary = "Delete function or function version",
          operationId = "internal_function_delete",
          parameters = make_target_parameters(false),
          responses = {
            ["200"] = {
              description = "Function deleted",
              content = {
                ["application/json"] = {
                  schema = { type = "object", additionalProperties = true },
                },
              },
            },
            ["400"] = base_error_response("Delete failed"),
            ["403"] = base_error_response("Forbidden"),
          },
        },
      },
      ["/_fn/function-config"] = {
        get = {
          tags = { "internal" },
          summary = "Read function config and effective policy",
          operationId = "internal_function_config_get",
          parameters = make_target_parameters(false),
          responses = {
            ["200"] = {
              description = "Function config view",
              content = {
                ["application/json"] = {
                  schema = { type = "object", additionalProperties = true },
                },
              },
            },
            ["404"] = base_error_response("Function not found"),
          },
        },
        put = {
          tags = { "internal" },
          summary = "Update function policy (limits, methods, debug headers)",
          operationId = "internal_function_config_put",
          parameters = make_target_parameters(false),
          requestBody = {
            required = true,
            content = {
              ["application/json"] = {
                schema = {
                  type = "object",
                  properties = {
                    timeout_ms = { type = "integer", minimum = 1 },
                    max_concurrency = { type = "integer", minimum = 0 },
                    max_body_bytes = { type = "integer", minimum = 1 },
                    include_debug_headers = { type = "boolean" },
                    invoke = {
                      type = "object",
                      properties = {
                        methods = {
                          type = "array",
                          items = { type = "string", enum = { "GET", "POST", "PUT", "PATCH", "DELETE" } },
                        },
                        routes = {
                          type = "array",
                          items = { type = "string" },
                        },
                        handler = {
                          type = "string",
                          description = "Optional runtime handler override (for example: main).",
                        },
                      },
                    },
                  },
                },
              },
            },
          },
          responses = {
            ["200"] = {
              description = "Function config updated",
              content = {
                ["application/json"] = {
                  schema = { type = "object", additionalProperties = true },
                },
              },
            },
            ["400"] = base_error_response("Invalid payload"),
            ["403"] = base_error_response("Forbidden"),
            ["404"] = base_error_response("Function not found"),
          },
        },
      },
      ["/_fn/function-env"] = {
        get = {
          tags = { "internal" },
          summary = "Read function env file",
          operationId = "internal_function_env_get",
          parameters = make_target_parameters(false),
          responses = {
            ["200"] = {
              description = "Function env",
              content = {
                ["application/json"] = {
                  schema = {
                    type = "object",
                    additionalProperties = {
                      type = "object",
                      properties = {
                        value = { oneOf = { { type = "string" }, { type = "number" }, { type = "boolean" }, { type = "null" } } },
                        is_secret = { type = "boolean" },
                      },
                      required = { "value", "is_secret" },
                    },
                  },
                },
              },
            },
            ["404"] = base_error_response("Function not found"),
          },
        },
        put = {
          tags = { "internal" },
          summary = "Write function env file",
          operationId = "internal_function_env_put",
          parameters = make_target_parameters(false),
          requestBody = {
            required = true,
            content = {
              ["application/json"] = {
                schema = {
                  type = "object",
                  additionalProperties = {
                    oneOf = {
                      { type = "string" },
                      { type = "number" },
                      { type = "boolean" },
                      { type = "null" },
                      {
                        type = "object",
                        properties = {
                          value = { oneOf = { { type = "string" }, { type = "number" }, { type = "boolean" }, { type = "null" } } },
                          is_secret = { type = "boolean" },
                        },
                        required = { "value" },
                      },
                    },
                  },
                },
                examples = {
                  simple = {
                    value = {
                      GREETING_PREFIX = "hello",
                    },
                  },
                  secret = {
                    value = {
                      API_KEY = { value = "sk-demo", is_secret = true },
                    },
                  },
                },
              },
            },
          },
          responses = {
            ["200"] = {
              description = "Function env updated",
              content = {
                ["application/json"] = {
                  schema = { type = "object", additionalProperties = true },
                },
              },
            },
            ["400"] = base_error_response("Invalid payload"),
            ["403"] = base_error_response("Forbidden"),
            ["404"] = base_error_response("Function not found"),
          },
        },
      },
      ["/_fn/invoke"] = {
        post = {
          tags = { "internal" },
          summary = "Invoke function through console API",
          operationId = "internal_invoke_post",
          requestBody = {
            required = true,
            content = {
              ["application/json"] = {
                schema = {
                  type = "object",
                  properties = {
                    runtime = { type = "string", pattern = "^[a-zA-Z0-9_-]+$" },
                    name = { type = "string" },
                    version = { oneOf = { { type = "string", pattern = "^[a-zA-Z0-9_.-]+$" }, { type = "null" } } },
                    method = { type = "string", enum = { "GET", "POST", "PUT", "PATCH", "DELETE" }, default = "GET" },
                    route = { type = "string" },
                    params = {
                      type = "object",
                      additionalProperties = {
                        oneOf = { { type = "string" }, { type = "number" }, { type = "boolean" }, { type = "null" } },
                      },
                    },
                    query = { type = "object", additionalProperties = true },
                    body = {
                      oneOf = {
                        { type = "string" },
                        { type = "object", additionalProperties = true },
                        { type = "array", items = {} },
                        { type = "number" },
                        { type = "boolean" },
                        { type = "null" },
                      },
                    },
                    context = { type = "object", additionalProperties = true },
                  },
                  required = { "runtime", "name" },
                },
                examples = {
                  by_name = {
                    value = {
                      runtime = "python",
                      name = "hello",
                      method = "GET",
                      query = { name = "World" },
                    },
                  },
                  with_context = {
                    value = {
                      runtime = "python",
                      name = "risk-score",
                      method = "POST",
                      body = { email = "user@example.com" },
                      context = { trace_id = "trace-123" },
                    },
                  },
                },
              },
            },
          },
          responses = {
            ["200"] = {
              description = "Invocation result envelope",
              content = {
                ["application/json"] = {
                  schema = { type = "object", additionalProperties = true },
                },
              },
            },
            ["400"] = base_error_response("Invalid request"),
            ["404"] = base_error_response("Function not found"),
            ["405"] = base_error_response("Method not allowed"),
            ["413"] = base_error_response("Payload too large"),
            ["502"] = base_error_response("Invalid runtime response"),
            ["503"] = base_error_response("Function runtime unavailable"),
            ["504"] = base_error_response("Runtime timeout"),
          },
        },
      },
      ["/_fn/logs"] = {
        get = {
          tags = { "internal" },
          summary = "Tail OpenResty logs",
          operationId = "internal_logs_get",
          parameters = {
            { name = "file", ["in"] = "query", required = false, schema = { type = "string", enum = { "error", "access" }, default = "error" } },
            { name = "lines", ["in"] = "query", required = false, schema = { type = "integer", minimum = 1, maximum = 2000, default = 200 } },
            { name = "format", ["in"] = "query", required = false, schema = { type = "string", enum = { "text", "json" }, default = "text" } },
          },
          responses = {
            ["200"] = {
              description = "Log tail",
              content = {
                ["text/plain"] = { schema = { type = "string" } },
                ["application/json"] = { schema = { type = "object", additionalProperties = true } },
              },
            },
            ["400"] = base_error_response("Invalid request"),
            ["403"] = base_error_response("Forbidden"),
            ["404"] = base_error_response("Not found"),
          },
        },
      },
      ["/_fn/ui-state"] = {
        get = {
          tags = { "internal" },
          summary = "Read console UI/API/write state",
          operationId = "internal_ui_state_get",
          responses = {
            ["200"] = {
              description = "Current console state",
              content = {
                ["application/json"] = {
                  schema = ui_state_schema,
                },
              },
            },
            ["403"] = base_error_response("Forbidden"),
          },
        },
        put = {
          tags = { "internal" },
          summary = "Update console UI/API/write state (requires write permission)",
          operationId = "internal_ui_state_put",
          requestBody = {
            required = true,
            content = {
              ["application/json"] = {
                schema = {
                  type = "object",
                  properties = {
                    ui_enabled = { type = "boolean" },
                    api_enabled = { type = "boolean" },
                    write_enabled = { type = "boolean" },
                    local_only = { type = "boolean" },
                    login_enabled = { type = "boolean" },
                    login_api_enabled = { type = "boolean" },
                  },
                },
              },
            },
          },
          responses = {
            ["200"] = {
              description = "Updated console state",
              content = {
                ["application/json"] = {
                  schema = { type = "object", additionalProperties = true },
                },
              },
            },
            ["400"] = base_error_response("Invalid payload"),
            ["403"] = base_error_response("Forbidden"),
          },
        },
        post = {
          tags = { "internal" },
          summary = "Update console UI/API/write state (requires write permission)",
          operationId = "internal_ui_state_post",
          requestBody = {
            required = true,
            content = {
              ["application/json"] = {
                schema = {
                  type = "object",
                  properties = {
                    ui_enabled = { type = "boolean" },
                    api_enabled = { type = "boolean" },
                    write_enabled = { type = "boolean" },
                    local_only = { type = "boolean" },
                    login_enabled = { type = "boolean" },
                    login_api_enabled = { type = "boolean" },
                  },
                },
              },
            },
          },
          responses = {
            ["200"] = {
              description = "Updated console state",
              content = {
                ["application/json"] = {
                  schema = { type = "object", additionalProperties = true },
                },
              },
            },
            ["400"] = base_error_response("Invalid payload"),
            ["403"] = base_error_response("Forbidden"),
          },
        },
        patch = {
          tags = { "internal" },
          summary = "Partially update console UI/API/write state (requires write permission)",
          operationId = "internal_ui_state_patch",
          requestBody = {
            required = true,
            content = {
              ["application/json"] = {
                schema = {
                  type = "object",
                  properties = {
                    ui_enabled = { type = "boolean" },
                    api_enabled = { type = "boolean" },
                    write_enabled = { type = "boolean" },
                    local_only = { type = "boolean" },
                    login_enabled = { type = "boolean" },
                    login_api_enabled = { type = "boolean" },
                  },
                },
              },
            },
          },
          responses = {
            ["200"] = {
              description = "Updated console state",
              content = {
                ["application/json"] = {
                  schema = { type = "object", additionalProperties = true },
                },
              },
            },
            ["400"] = base_error_response("Invalid payload"),
            ["403"] = base_error_response("Forbidden"),
          },
        },
        delete = {
          tags = { "internal" },
          summary = "Reset console UI/API/write state overrides (requires write permission)",
          operationId = "internal_ui_state_delete",
          responses = {
            ["200"] = {
              description = "Console state reset to environment defaults",
              content = {
                ["application/json"] = {
                  schema = { type = "object", additionalProperties = true },
                },
              },
            },
            ["403"] = base_error_response("Forbidden"),
          },
        },
      },
      ["/_fn/login"] = {
        post = {
          tags = { "internal" },
          summary = "Console login (sets session cookie)",
          operationId = "internal_login_post",
          requestBody = {
            required = true,
            content = {
              ["application/json"] = {
                schema = {
                  type = "object",
                  properties = {
                    username = { type = "string" },
                    password = { type = "string" },
                  },
                  required = { "username", "password" },
                },
              },
            },
          },
          responses = {
            ["200"] = { description = "Logged in", content = { ["application/json"] = { schema = { type = "object", additionalProperties = true } } } },
            ["401"] = base_error_response("Invalid credentials"),
            ["404"] = base_error_response("Login disabled"),
            ["500"] = base_error_response("Misconfigured"),
          },
        },
      },
      ["/_fn/logout"] = {
        post = {
          tags = { "internal" },
          summary = "Console logout (clears session cookie)",
          operationId = "internal_logout_post",
          responses = {
            ["200"] = { description = "Logged out", content = { ["application/json"] = { schema = { type = "object", additionalProperties = true } } } },
          },
        },
      },
      ["/_fn/function-code"] = {
        put = {
          tags = { "internal" },
          summary = "Write function code file",
          operationId = "internal_function_code_put",
          parameters = make_target_parameters(false),
          requestBody = {
            required = true,
            content = {
              ["application/json"] = {
                schema = {
                  type = "object",
                  properties = {
                    code = { type = "string" },
                  },
                  required = { "code" },
                },
              },
            },
          },
          responses = {
            ["200"] = {
              description = "Function code updated",
              content = {
                ["application/json"] = {
                  schema = { type = "object", additionalProperties = true },
                },
              },
            },
            ["400"] = base_error_response("Invalid payload"),
            ["403"] = base_error_response("Forbidden"),
            ["404"] = base_error_response("Function not found"),
          },
        },
      },
    },
    tags = {
      { name = "internal", description = "Gateway internal endpoints" },
      { name = "functions", description = "Invocable functions" },
    },
  }

  local runtimes = (catalog and catalog.runtimes) or {}
  local runtime_order = opts.runtime_order or sorted_keys(runtimes)
  local include_internal = opts.include_internal == true
  local invoke_meta_lookup = opts.invoke_meta_lookup

  if not include_internal then
    for p, _ in pairs(spec.paths) do
      if type(p) == "string" and p:sub(1, 5) == "/_fn/" then
        spec.paths[p] = nil
      end
    end
    spec.tags = {
      { name = "functions", description = "Invocable functions" },
    }
  end

  local mapped = (catalog and catalog.mapped_routes) or {}
  for _, route in ipairs(sorted_keys(mapped)) do
    local openapi_path, path_parameters = route_to_openapi_path_and_parameters(route)
    if openapi_path and spec.paths[openapi_path] == nil then
      local ops = {}
      for _, entry in ipairs(mapped_route_entries(mapped[route])) do
        if type(entry.runtime) == "string" and entry.runtime ~= ""
          and type(entry.fn_name) == "string" and entry.fn_name ~= "" then
          local invoke_meta = nil
          if type(invoke_meta_lookup) == "function" then
            invoke_meta = invoke_meta_lookup(entry.runtime, entry.fn_name, entry.version)
          end
          for _, method in ipairs(normalized_methods(entry.methods)) do
            local lower = string.lower(method)
            if not ops[lower] then
              ops[lower] = operation_template(
                entry.runtime,
                entry.fn_name,
                entry.version,
                lower,
                path_parameters,
                invoke_meta
              )
            end
          end
        end
      end
      if next(ops) ~= nil then
        spec.paths[openapi_path] = ops
      end
    end
  end

  return spec
end

return M
