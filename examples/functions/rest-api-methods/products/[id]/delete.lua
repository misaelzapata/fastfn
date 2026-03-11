-- DELETE /products/:id — id arrives directly from [id] filename
local cjson = require("cjson")

local function handler(event, params)
    local id = params.id or ""
    return {
        status = 200,
        headers = { ["Content-Type"] = "application/json" },
        body = cjson.encode({
            id = tonumber(id),
            deleted = true,
        }),
    }
end

return handler
