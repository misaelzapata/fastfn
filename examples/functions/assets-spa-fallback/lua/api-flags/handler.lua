local cjson = require("cjson.safe")

function handler(_event)
  return {
    status = 200,
    headers = { ["Content-Type"] = "application/json" },
    body = cjson.encode({
      runtime = "lua",
      title = "Lua feature flags endpoint",
      summary = "In-process Lua stays available while the browser router handles deep links.",
      path = "/api-flags",
    }),
  }
end
