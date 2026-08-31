-- RSDWClient — client-only UE4SS entrypoint.
--
-- This is intentionally separate from the dedicated-server entrypoint.
-- Client-only systems such as UMG, hotkeys, camera helpers and local IPC
-- belong here as they are migrated from the legacy RSDWTools package.

local M = {}

local function load_optional(name)
    local ok, mod = pcall(require, name)
    if not ok then
        print(string.format("[RSDWClient] optional module %s unavailable: %s", tostring(name), tostring(mod)))
        return nil
    end
    return mod
end

function M.start()
    print("[RSDWClient] starting client-only runtime")

    -- Migration compatibility: these modules currently live in the legacy
    -- RSDWTools script set. The client package builder can include them while
    -- they are moved into explicit client ownership incrementally.
    local feature_hotkeys = load_optional("feature_hotkeys")
    local feature_umg = load_optional("feature_umg")

    if feature_hotkeys and feature_hotkeys.load_and_register then
        pcall(function() feature_hotkeys.load_and_register() end)
    end

    if RegisterHook and feature_umg then
        pcall(function()
            RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
                if feature_umg.on_player_ready then feature_umg.on_player_ready() end
                if feature_hotkeys and feature_hotkeys.on_player_ready then
                    feature_hotkeys.on_player_ready()
                end
            end)
        end)
    end
end

M.start()
return M
