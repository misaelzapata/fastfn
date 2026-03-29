-- GET /posts/:slug — slug arrives directly from [slug] filename
local cjson = require("cjson")

local function handler(event, params)
    local slug = params.slug or ""
    return {
        status = 200,
        headers = { ["Content-Type"] = "application/json" },
        body = cjson.encode({
            slug = slug,
            title = "Post: " .. slug,
            content = "Lorem ipsum...",
        }),
    }
end

return handler
