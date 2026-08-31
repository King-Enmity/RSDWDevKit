-- RSDWServer — headless dedicated-server UE4SS entrypoint.
--
-- No viewport, UMG, hotkeys, gamepad, local-player or camera assumptions are
-- allowed in this runtime. Server features should resolve players explicitly
-- through PlayerController / PlayerState / Pawn context.

local server_net = require("server_net")
local M = {}

local function register_status_commands()
    if not RegisterConsoleCommandHandler then return end

    RegisterConsoleCommandHandler("rsdws_status", function()
        print("[RSDWServer] status netmode=" .. tostring(server_net.net_mode()))
        return true
    end)

    RegisterConsoleCommandHandler("rsdws_players", function()
        local ok, roster = pcall(function() return server_net.roster_text() end)
        print(ok and ("[RSDWServer] players " .. tostring(roster)) or ("[RSDWServer] players error: " .. tostring(roster)))
        return true
    end)
end

function M.start()
    print("[RSDWServer] starting headless server runtime")
    print("[RSDWServer] detected netmode=" .. tostring(server_net.net_mode()))
    register_status_commands()
end

M.start()
return M
