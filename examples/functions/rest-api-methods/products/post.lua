-- POST /products — create a product
local cjson = require("cjson")

local function handler(event)
    local ok, data = pcall(cjson.decode, event.body or "")
    if not ok then
        return { status = 400, body = cjson.encode({ error = "Invalid JSON" }) }
    end

    local name = (data.name or ""):match("^%s*(.-)%s*$")  -- trim
    local price = data.price or 0

    if name == "" then
        return { status = 400, body = cjson.encode({ error = "name is required" }) }
    end

    return {
        status = 201,
        headers = { ["Content-Type"] = "application/json" },
        body = cjson.encode({ id = 42, name = name, price = price, created = true }),
    }
end

return handler
