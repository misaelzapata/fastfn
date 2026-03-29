-- POST /products — create a product
local cjson = require("cjson")
local shared = require("_shared")

local function handler(event)
    local ok, data = pcall(cjson.decode, event.body or "")
    if not ok then
        return shared.json_response(400, { error = "Invalid JSON" })
    end

    local name = shared.trim_text(data.name or "")
    local price = data.price or 0

    if name == "" then
        return shared.json_response(400, { error = "name is required" })
    end

    return shared.json_response(201, { id = 42, name = name, price = price, created = true })
end

return handler
