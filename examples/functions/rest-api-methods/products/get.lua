-- GET /products — list all products
local cjson = require("cjson")

local function handler(event)
    return {
        status = 200,
        headers = { ["Content-Type"] = "application/json" },
        body = cjson.encode({
            products = {
                { id = 1, name = "Widget", price = 9.99 },
                { id = 2, name = "Gadget", price = 24.99 },
            },
            total = 2,
        }),
    }
end

return handler
