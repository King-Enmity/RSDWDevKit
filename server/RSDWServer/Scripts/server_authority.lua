-- RSDWServer authority registry.
--
-- This is the only surface that future client UI requests should be allowed to
-- enter. There is intentionally no raw command passthrough. Unknown actions
-- are denied. Registered actions receive a server-resolved player context and
-- must perform their own argument/rate/state validation before mutating game
-- state.

local M = {}

local ACTIONS = {}

local function normalize_action(action)
    action = tostring(action or ""):lower()
    action = action:gsub("^%s+", ""):gsub("%s+$", "")
    return action
end

function M.register(action, handler, options)
    action = normalize_action(action)
    if action == "" then return false, "empty action" end
    if type(handler) ~= "function" then return false, "handler must be a function" end
    if ACTIONS[action] then return false, "action already registered" end

    ACTIONS[action] = {
        handler = handler,
        options = options or {},
    }
    return true
end

function M.is_registered(action)
    return ACTIONS[normalize_action(action)] ~= nil
end

function M.list_actions()
    local out = {}
    for action, entry in pairs(ACTIONS) do
        out[#out + 1] = {
            action = action,
            permission = tostring(entry.options.permission or "player"),
            rate_limit = tonumber(entry.options.rate_limit or 0) or 0,
        }
    end
    table.sort(out, function(a, b) return a.action < b.action end)
    return out
end

-- ctx must be constructed by the server from the actual connection/player.
-- Never trust a client-provided player name, pawn pointer, permission level,
-- inventory, location, damage value, progression state, or destination.
function M.dispatch(action, ctx, args)
    action = normalize_action(action)
    local entry = ACTIONS[action]
    if not entry then
        return false, "action denied"
    end
    if type(ctx) ~= "table" then
        return false, "missing server context"
    end

    local ok, accepted, detail = pcall(entry.handler, ctx, args or {})
    if not ok then
        return false, "handler error: " .. tostring(accepted)
    end
    if accepted ~= true then
        return false, tostring(detail or "request rejected")
    end
    return true, tostring(detail or "ok")
end

-- Safe bootstrap capabilities. These are read/request surfaces only; actual
-- queueing, transfers and persistence are implemented by server modules later.
M.register("session.status", function(ctx)
    return true, "connected"
end, { permission = "player", rate_limit = 2 })

M.register("dungeon.queue", function(ctx, args)
    return false, "dungeon queue service not installed"
end, { permission = "player", rate_limit = 1 })

M.register("raid.queue", function(ctx, args)
    return false, "raid queue service not installed"
end, { permission = "player", rate_limit = 1 })

M.register("pvp.queue", function(ctx, args)
    return false, "pvp queue service not installed"
end, { permission = "player", rate_limit = 1 })

M.register("travel.request", function(ctx, args)
    return false, "server transfer service not installed"
end, { permission = "player", rate_limit = 1 })

return M
