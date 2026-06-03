local support = require("router_support")
local lazy_feature = support.lazy_feature

local feature_build_preview = lazy_feature("feature_build_preview")

local M = {}

function M.try_handle(line)
    if line == "build.preview.probe" then
        local ok, detail = feature_build_preview.probe()
        if ok then return true, true, "ok build.preview.probe " .. tostring(detail) end
        return true, false, "build.preview.probe failed: " .. tostring(detail)
    end
    if line:sub(1, 22) == "build.preview.attach1 " then
        local ok, detail = feature_build_preview.attach1(line:sub(23))
        if ok then return true, true, "ok build.preview.attach1 " .. tostring(detail) end
        return true, false, "build.preview.attach1 failed: " .. tostring(detail)
    end
    if line:sub(1, 21) == "build.preview.spawn1 " then
        local ok, detail = feature_build_preview.spawn1(line:sub(22))
        if ok then return true, true, "ok build.preview.spawn1 " .. tostring(detail) end
        return true, false, "build.preview.spawn1 failed: " .. tostring(detail)
    end
    if line:sub(1, 22) == "build.preview.preview " then
        local ok, detail = feature_build_preview.preview(line:sub(23))
        if ok then return true, true, "ok build.preview.preview " .. tostring(detail) end
        return true, false, "build.preview.preview failed: " .. tostring(detail)
    end
    if line:sub(1, 27) == "build.preview.preview_full " then
        local ok, detail = feature_build_preview.preview_full(line:sub(28))
        if ok then return true, true, "ok build.preview.preview_full " .. tostring(detail) end
        return true, false, "build.preview.preview_full failed: " .. tostring(detail)
    end
    if line:sub(1, 19) == "build.preview.diag " then
        local ok, detail = feature_build_preview.diag(line:sub(20))
        if ok then return true, true, "ok build.preview.diag " .. tostring(detail) end
        return true, false, "build.preview.diag failed: " .. tostring(detail)
    end
    if line == "build.preview.clear" then
        local ok, detail = feature_build_preview.clear()
        if ok then return true, true, "ok build.preview.clear " .. tostring(detail) end
        return true, false, "build.preview.clear failed: " .. tostring(detail)
    end
    if line == "build.preview.cancel" then
        local ok, detail = feature_build_preview.cancel()
        if ok then return true, true, "ok build.preview.cancel " .. tostring(detail) end
        return true, false, "build.preview.cancel failed: " .. tostring(detail)
    end
    if line == "build.preview.commit" then
        local ok, detail = feature_build_preview.commit("")
        if ok then return true, true, "ok build.preview.commit " .. tostring(detail) end
        return true, false, "build.preview.commit failed: " .. tostring(detail)
    end
    if line:sub(1, 21) == "build.preview.commit " then
        local ok, detail = feature_build_preview.commit(line:sub(22))
        if ok then return true, true, "ok build.preview.commit " .. tostring(detail) end
        return true, false, "build.preview.commit failed: " .. tostring(detail)
    end
    if line:sub(1, 20) == "build.preview.piece " then
        local ok, detail = feature_build_preview.piece(line:sub(21))
        if ok then return true, true, "ok build.preview.piece " .. tostring(detail) end
        return true, false, "build.preview.piece failed: " .. tostring(detail)
    end
    if line == "build.preview.lookat" then
        local ok, detail = feature_build_preview.lookat()
        if ok then return true, true, "ok build.preview.lookat " .. tostring(detail) end
        return true, false, "build.preview.lookat failed: " .. tostring(detail)
    end
    if line == "build.preview.force_place" then
        local ok, detail = feature_build_preview.force_place()
        if ok then return true, true, "ok build.preview.force_place " .. tostring(detail) end
        return true, false, "build.preview.force_place failed: " .. tostring(detail)
    end

    return false, nil, nil
end

return M