-- GET /files/* — catch-all, path captures everything after /files/
local cjson = require("cjson")

local function handler(event, params)
    local path = params.path or ""
    local segments = {}
    if path ~= "" then
        for seg in path:gmatch("[^/]+") do
            segments[#segments + 1] = seg
        end
    end
    return {
        status = 200,
        headers = { ["Content-Type"] = "application/json" },
        body = cjson.encode({
            path = path,
            segments = segments,
            depth = #segments,
        }),
    }
end

return handler
