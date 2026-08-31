-- Headless multiplayer helpers for RSDWServer.
-- Dedicated servers have no local PlayerController, so this module only uses
-- server-safe world/controller enumeration and never calls local_pawn().

local M = {}

local NET_MODE_NAMES = {
    [0] = "Standalone",
    [1] = "DedicatedServer",
    [2] = "ListenServer",
    [3] = "Client",
}

local function is_valid(obj)
    if type(obj) ~= "userdata" or not obj.IsValid then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid and true or false
end

local function safe(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

local function as_string(value)
    if value == nil then return "" end
    if type(value) == "string" then return value end
    local s = safe(function() return value:ToString() end)
    if type(s) == "string" then return s end
    return tostring(value)
end

function M.net_mode_int()
    local ok, helpers = pcall(require, "UEHelpers")
    if ok and helpers and helpers.GetWorld then
        local world = safe(function() return helpers.GetWorld() end)
        if is_valid(world) and world.GetNetMode then
            local mode = safe(function() return world:GetNetMode() end)
            if type(mode) == "number" then return mode end
        end
    end
    return -1
end

function M.net_mode()
    return NET_MODE_NAMES[M.net_mode_int()] or "Unknown"
end

function M.controllers()
    local result = {}
    local list = FindAllOf and FindAllOf("PlayerController") or nil
    if type(list) ~= "table" then return result end
    for _, pc in pairs(list) do
        if is_valid(pc) then result[#result + 1] = pc end
    end
    return result
end

function M.player_name(pc)
    if not is_valid(pc) then return "" end
    local ps = safe(function() return pc.PlayerState end)
    if is_valid(ps) and ps.GetPlayerName then
        return as_string(safe(function() return ps:GetPlayerName() end))
    end
    return ""
end

function M.find_player(name)
    local needle = tostring(name or ""):lower()
    if needle == "" then return nil, nil end
    for _, pc in ipairs(M.controllers()) do
        if M.player_name(pc):lower() == needle then
            local pawn = safe(function() return pc.Pawn end)
            return pc, is_valid(pawn) and pawn or nil
        end
    end
    return nil, nil
end

function M.roster_text()
    local rows = {}
    for _, pc in ipairs(M.controllers()) do
        local pawn = safe(function() return pc.Pawn end)
        rows[#rows + 1] = string.format(
            "%s|pawn=%s|authority=%s",
            M.player_name(pc),
            tostring(is_valid(pawn)),
            tostring(safe(function() return pc:HasAuthority() end) == true)
        )
    end
    return table.concat(rows, ";")
end

return M
