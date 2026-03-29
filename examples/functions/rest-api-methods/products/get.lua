-- GET /products — list all products
local shared = require("_shared")

local function handler(event)
    local products = shared.catalog_products()
    return shared.json_response(200, {
        products = products,
        total = #products,
    })
end

return handler
