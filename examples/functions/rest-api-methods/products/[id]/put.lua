-- PUT /products/:id — id arrives directly from [id] filename
local cjson = require("cjson")

local function handler(event, params)
    local id = params.id or ""
    local ok, data = pcall(cjson.decode, event.body or "")
    if not ok then
        return { status = 400, body = cjson.encode({ error = "Invalid JSON" }) }
    end

    data.id = tonumber(id)
    data.updated = true
    return {
        status = 200,
        headers = { ["Content-Type"] = "application/json" },
        body = cjson.encode(data),
    }
end

return handler
