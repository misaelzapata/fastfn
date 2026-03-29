-- GET /posts/:category/:slug — both params arrive directly
local cjson = require("cjson")

local function handler(event, params)
    local category = params.category or ""
    local slug = params.slug or ""
    return {
        status = 200,
        headers = { ["Content-Type"] = "application/json" },
        body = cjson.encode({
            category = category,
            slug = slug,
            title = category .. "/" .. slug,
            url = "/posts/" .. category .. "/" .. slug,
        }),
    }
end

return handler
