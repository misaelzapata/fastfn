local M = {}
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

local function operation_template(runtime, name, version, method)
  local method_upper = string.upper(method)
  local label = runtime .. "/" .. name
  if version then
    label = label .. "@" .. version
  end

  local op = {
    tags = { "functions", name },
    summary = method_upper .. " invoke " .. label,
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

  if method == "post" or method == "put" or method == "patch" then
    op.requestBody = {
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
  end

  return op
end

local function normalized_methods(methods)
  return invoke_rules.normalized_methods(methods, DEFAULT_METHODS)
end

local function methods_operations(runtime, name, version, methods)
  local ops = {}
  for _, method in ipairs(normalized_methods(methods)) do
    local lower = string.lower(method)
    ops[lower] = operation_template(runtime, name, version, lower)
  end
  return ops
end

function M.build(catalog, opts)
  opts = opts or {}

  local server_url = opts.server_url or "http://localhost:8080"
  local title = opts.title or "fastfn API"
  local version = opts.version or "1.0.0"

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
          summary = "Generate function code (optional AI assistant)",
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
                    template = { type = "string", examples = { "hello_json" } },
                    prompt = { type = "string", examples = { "Make an echo handler" } },
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
            { name = "limit", ["in"] = "query", required = false, schema = { type = "integer", minimum = 1, maximum = 200 } },
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
                    runtime = { type = "string" },
                    name = { type = "string" },
                    version = { oneOf = { { type = "string" }, { type = "null" } } },
                    method = { type = "string", enum = { "GET", "POST", "PUT", "PATCH", "DELETE" } },
                    query = { type = "object", additionalProperties = true },
                    headers = { type = "object", additionalProperties = true },
                    body = { oneOf = { { type = "string" }, { type = "object", additionalProperties = true }, { type = "array", items = {} }, { type = "number" }, { type = "boolean" }, { type = "null" } } },
                    context = { type = "object", additionalProperties = true },
                    max_attempts = { type = "integer", minimum = 1, maximum = 10 },
                    retry_delay_ms = { type = "integer", minimum = 0 },
                  },
                  required = { "name" },
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
                    name = { type = "string" },
                    version = { type = "string" },
                    method = { type = "string", enum = { "GET", "POST", "PUT", "PATCH", "DELETE" } },
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
                  required = { "name" },
                },
                examples = {
                  by_name = {
                    value = {
                      name = "hello",
                      method = "GET",
                      query = { name = "World" },
                    },
                  },
                  with_context = {
                    value = {
                      name = "risk_score",
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
            ["409"] = base_error_response("Ambiguous function"),
          },
        },
      },
      ["/_fn/logs"] = {
        get = {
          tags = { "internal" },
          summary = "Tail OpenResty logs",
          operationId = "internal_logs_get",
          parameters = {
            { name = "file", in_ = "query", required = false, schema = { type = "string", enum = { "error", "access" } } },
            { name = "lines", in_ = "query", required = false, schema = { type = "integer", minimum = 1, maximum = 2000 } },
            { name = "format", in_ = "query", required = false, schema = { type = "string", enum = { "text", "json" } } },
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
                  schema = { type = "object", additionalProperties = true },
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
  local seen_default = {}
  local seen_version = {}

  for _, runtime in ipairs(runtime_order) do
    local runtime_entry = runtimes[runtime] or {}
    local functions = runtime_entry.functions or {}

    for _, fn_name in ipairs(sorted_keys(functions)) do
      local fn_entry = functions[fn_name]

      if fn_entry.has_default and not seen_default[fn_name] then
        seen_default[fn_name] = runtime
        local p = string.format("/fn/%s", fn_name)
        spec.paths[p] = methods_operations(runtime, fn_name, nil, fn_entry.policy and fn_entry.policy.methods)
      end

      for _, ver in ipairs(fn_entry.versions or {}) do
        local key = fn_name .. "@" .. ver
        if not seen_version[key] then
          seen_version[key] = runtime
          local p = string.format("/fn/%s@%s", fn_name, ver)
          local ver_policy = (fn_entry.versions_policy or {})[ver] or {}
          spec.paths[p] = methods_operations(runtime, fn_name, ver, ver_policy.methods or (fn_entry.policy and fn_entry.policy.methods))
        end
      end
    end
  end

  local mapped = (catalog and catalog.mapped_routes) or {}
  for _, route in ipairs(sorted_keys(mapped)) do
    local entry = mapped[route]
    if type(entry) == "table" and spec.paths[route] == nil then
      spec.paths[route] = methods_operations(
        entry.runtime or "unknown",
        entry.fn_name or "unknown",
        entry.version,
        entry.methods
      )
    end
  end

  return spec
end

return M
