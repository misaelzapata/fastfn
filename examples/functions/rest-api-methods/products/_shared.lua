local cjson = require("cjson")

local M = {}

function M.catalog_products()
    return {
        { id = 1, name = "Widget", price = 9.99 },
        { id = 2, name = "Gadget", price = 24.99 },
    }
end

function M.json_response(status, payload)
    return {
        status = status,
        headers = { ["Content-Type"] = "application/json" },
        body = cjson.encode(payload),
    }
end

function M.trim_text(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

return M
