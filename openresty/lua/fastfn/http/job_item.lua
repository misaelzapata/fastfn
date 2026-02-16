local guard = require "fastfn.console.guard"
local jobs = require "fastfn.core.jobs"

if not guard.enforce_api() then
  return
end

local m = ngx.re.match(ngx.var.uri or "", [[^/_fn/jobs/([a-zA-Z0-9_.-]+)(?:/(result))?$]], "jo")
if not m then
  guard.write_json(404, { error = "not found" })
  return
end

local id = m[1]
local suffix = m[2]

local method = ngx.req.get_method()
if suffix == "result" then
  if method ~= "GET" then
    guard.write_json(405, { error = "method not allowed" })
    return
  end
  local result = jobs.read_result(id)
  if result then
    guard.write_json(200, result)
    return
  end

  local meta = jobs.get(id)
  if not meta then
    guard.write_json(404, { error = "job not found" })
    return
  end

  local status = tostring(meta.status or "")
  if status == "queued" or status == "running" or status == "retrying" then
    guard.write_json(202, {
      id = id,
      status = status,
      error = "result not ready",
      attempt = meta.attempt,
      max_attempts = meta.max_attempts,
      retry_delay_ms = meta.retry_delay_ms,
    })
    return
  end

  guard.write_json(404, { error = "result not found", status = status })
  return
end

if method ~= "GET" and method ~= "DELETE" then
  guard.write_json(405, { error = "method not allowed" })
  return
end

if method == "GET" then
  local meta = jobs.get(id)
  if not meta then
    guard.write_json(404, { error = "job not found" })
    return
  end
  guard.write_json(200, meta)
  return
end

if not guard.enforce_write() then
  return
end

local meta, status, err = jobs.cancel(id)
if not meta then
  guard.write_json(status or 400, { error = err or "cancel failed" })
  return
end
guard.write_json(status or 200, meta)
