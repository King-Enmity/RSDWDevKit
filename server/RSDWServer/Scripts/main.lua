-- RSDWServer — headless dedicated-server UE4SS entrypoint.
--
-- No viewport, UMG, hotkeys, gamepad, local-player or camera assumptions are
-- allowed in this runtime. Server features should resolve players explicitly
-- through PlayerController / PlayerState / Pawn context.

local M = {}

local function safe_require(name)
    local ok, mod = pcall(require, name)
    if not ok then
        print(string.format("[RSDWServer] module %s unavailable: %s", tostring(name), tostring(mod)))
        return nil
    end
    return mod
end

local function register_status_command(feature_net)
    if not RegisterConsoleCommandHandler then return end

    RegisterConsoleCommandHandler("rsdws_status", function()
        local mode = feature_net and feature_net.net_mode and feature_net.net_mode() or "Unknown"
        print("[RSDWServer] status netmode=" .. tostring(mode))
        return true
    end)

    RegisterConsoleCommandHandler("rsdws_players", function()
        if not feature_net or not feature_net.json_roster then
            print("[RSDWServer] player roster unavailable")
            return true
        end
        local ok, roster = pcall(function() return feature_net.json_roster() end)
        print(ok and ("[RSDWServer] players " .. tostring(roster)) or ("[RSDWServer] players error: " .. tostring(roster)))
        return true
    end)
end

function M.start()
    print("[RSDWServer] starting headless server runtime")

    -- Compatibility while feature_net is migrated into common/. It already
    -- understands DedicatedServer/ListenServer/Client/Standalone net modes.
    local feature_net = safe_require("feature_net")

    if feature_net and feature_net.net_mode then
        local ok, mode = pcall(function() return feature_net.net_mode() end)
        if ok then print("[RSDWServer] detected netmode=" .. tostring(mode)) end
    end

    register_status_command(feature_net)
end

M.start()
return M
