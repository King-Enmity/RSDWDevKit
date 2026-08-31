-- RSDWClient — production client presentation/input entrypoint.
--
-- SECURITY / AUTHORITY CONTRACT:
--   * This runtime must not expose generic player/world mutation commands.
--   * No raw RSDWTools command router, cheat manager, or admin SHM bridge.
--   * Client UI may only emit named requests implemented by the server.
--   * The server validates identity, permission, state, arguments and outcome.
--
-- Player-owned clients cannot be made inherently trustworthy; therefore any
-- local modification must be irrelevant to persistent/competitive authority.

local M = {}

local function optional_require(name)
    local ok, mod = pcall(require, name)
    if not ok then
        print(string.format("[RSDWClient] optional module %s unavailable: %s", tostring(name), tostring(mod)))
        return nil
    end
    return mod
end

local function register_player_ready(feature_ui)
    if not RegisterHook or not feature_ui then return end
    pcall(function()
        RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
            if feature_ui.on_player_ready then
                feature_ui.on_player_ready()
            end
        end)
    end)
end

function M.start()
    print("[RSDWClient] starting presentation-only client runtime")

    -- Future production UI module. It may display server-provided state and
    -- issue allow-listed requests (queue, travel, etc.). It must not execute
    -- arbitrary feature/router commands locally.
    local feature_ui = optional_require("client_ui")
    register_player_ready(feature_ui)

    if feature_ui and feature_ui.start then
        pcall(function() feature_ui.start() end)
    end
end

M.start()
return M
