-- feature_wheel_hook.lua
--
-- Round 62: mouse-wheel hotkey support.
--
-- DESIGN ROUND 2 -- the original RegisterHook approach failed because
-- /Script/Engine.PlayerController:InputAxis is a native C++ function,
-- not a UFunction, so UE4SS rejects the hook with "no UFunction with
-- the specified name was found".
--
-- This rewrite uses per-tick polling instead. UE itself surfaces
-- mouse-wheel notches as DISCRETE key events (EKeys::MouseScrollUp /
-- MouseScrollDown), which means PlayerController:WasInputKeyJustPressed
-- returns true on the frame the wheel notched. That UFunction IS
-- exposed (verified in the object dump), and so is IsInputKeyDown
-- which we use for modifier matching.
--
-- Cost: a LoopAsync callback at ~16ms calling two UFunctions per tick
-- (one for up, one for down) plus zero-to-three IsInputKeyDown calls
-- per fire. Well under 0.1% CPU. The loop is gated -- it only runs
-- when at least one wheel binding is registered, so unmodified mods
-- pay nothing.
--
-- Key construction: FKey is a USTRUCT { FName KeyName }, so UE4SS
-- accepts a Lua table { KeyName = FName("MouseScrollUp") } as a
-- direct argument. We build these once at registration time and reuse
-- them across every tick.
--
-- Reload safety: a generation counter keeps stale callbacks from
-- prior reloads no-oping. The poll loop itself is started once and
-- runs forever ; on reload we clear the registry and bump generation,
-- the loop body sees an empty registry and skips dispatch.

local M = {}

-- direction "up"/"down" -> array of { mod_fkeys = {fkey...}, fn = function }
M._cbs = { up = {}, down = {} }
M._generation = 0
M._loop_started = false

-- FName-based UE key lookup. EKeys::MouseScrollUp / MouseScrollDown
-- are the discrete press events that fire once per wheel notch. The
-- modifier names mirror UE's FKey identifiers (LeftControl etc), NOT
-- the VK-based "LEFT_CONTROL" tokens used by RegisterKeyBindAsync.
local _fkey_cache = {}
local function fkey(name)
    local cached = _fkey_cache[name]
    if cached then return cached end
    if not FName then return nil end
    local ok, fn = pcall(function() return FName(name) end)
    if not ok or not fn then return nil end
    local k = { KeyName = fn }
    _fkey_cache[name] = k
    return k
end

-- Modifier-name translation: the picker stores VK-style names
-- (LEFT_CONTROL etc) so existing keyboard bindings stay compatible.
-- For the wheel path we need UE FKey identifiers instead.
local VK_TO_UE_MOD = {
    LEFT_CONTROL  = "LeftControl",
    RIGHT_CONTROL = "RightControl",
    LEFT_SHIFT    = "LeftShift",
    RIGHT_SHIFT   = "RightShift",
    LEFT_ALT      = "LeftAlt",
    RIGHT_ALT     = "RightAlt",
}

local function modifier_fkey_for_token(vk_name)
    local ue_name = VK_TO_UE_MOD[vk_name]
    if not ue_name then return nil end
    return fkey(ue_name)
end

-- Get the local PlayerController. Delegated to feature_net for the
-- canonical multiplayer-correct resolver (IsLocalController()-based).
local feature_net = require("feature_net")
local function get_pc()
    local ok, pc = pcall(function() return feature_net.local_controller() end)
    if ok then return pc end
    print("[RSDWTools.wheel] local controller lookup failed: " .. tostring(pc))
    return nil
end

local function modifiers_held(pc, mod_fkeys)
    if not mod_fkeys or #mod_fkeys == 0 then return true end
    if not pc or not pc.IsInputKeyDown then return false end
    for _, fk in ipairs(mod_fkeys) do
        local ok, held = pcall(function() return pc:IsInputKeyDown(fk) end)
        if not ok or not held then return false end
    end
    return true
end

local function dispatch(pc, list)
    for _, entry in ipairs(list) do
        if entry.gen == M._generation then
            if modifiers_held(pc, entry.mod_fkeys) then
                local ok, err = pcall(entry.fn)
                if not ok then
                    print("[RSDWTools.wheel] callback error: " .. tostring(err))
                end
            end
        end
    end
end

local KEY_WHEEL_UP, KEY_WHEEL_DOWN

local function tick()
    if #M._cbs.up == 0 and #M._cbs.down == 0 then
        return -- registry empty ; cheapest possible path
    end
    KEY_WHEEL_UP   = KEY_WHEEL_UP   or fkey("MouseScrollUp")
    KEY_WHEEL_DOWN = KEY_WHEEL_DOWN or fkey("MouseScrollDown")
    if not KEY_WHEEL_UP or not KEY_WHEEL_DOWN then return end
    local pc = get_pc()
    if not pc or not pc.WasInputKeyJustPressed then return end
    local ok_u, up = pcall(function() return pc:WasInputKeyJustPressed(KEY_WHEEL_UP) end)
    if ok_u and up and #M._cbs.up > 0 then dispatch(pc, M._cbs.up) end
    local ok_d, dn = pcall(function() return pc:WasInputKeyJustPressed(KEY_WHEEL_DOWN) end)
    if ok_d and dn and #M._cbs.down > 0 then dispatch(pc, M._cbs.down) end
end

local POLL_MS = 4   -- ~250Hz. WasInputKeyJustPressed is true for
                    -- exactly one game frame, so a 16ms async poll
                    -- can sample BETWEEN game frames and miss
                    -- notches entirely. 4ms gives 4-8 sample
                    -- opportunities per game frame at typical
                    -- 60-144fps so every notch is caught. Cost is
                    -- still trivial: ~2 UFunction calls per tick on
                    -- a non-render thread.

local function ensure_loop()
    if M._loop_started then return end
    if not LoopAsync then
        print("[RSDWTools.wheel] LoopAsync unavailable -- wheel bindings disabled.")
        return
    end
    M._loop_started = true
    LoopAsync(POLL_MS, function()
        tick()
        return false  -- never exit
    end)
    print(string.format("[RSDWTools.wheel] wheel poll loop ~%dms started.", POLL_MS))
end

-- Public API -------------------------------------------------------------

function M.bump_generation()
    M._generation = M._generation + 1
    M._cbs.up = {}
    M._cbs.down = {}
end

-- direction:    "up" or "down"
-- mod_tokens:   array of VK-style modifier names ("LEFT_CONTROL" etc)
-- callback:     zero-arg function fired on each matching wheel notch
function M.register(direction, mod_tokens, callback)
    if direction ~= "up" and direction ~= "down" then return end
    if type(callback) ~= "function" then return end
    -- Translate VK-style modifier tokens to UE FKey structs once at
    -- register time. Unknown tokens are silently skipped (defensive ;
    -- the picker only emits the six we recognize).
    local mod_fkeys = {}
    if type(mod_tokens) == "table" then
        for _, name in ipairs(mod_tokens) do
            local fk = modifier_fkey_for_token(name)
            if fk then mod_fkeys[#mod_fkeys + 1] = fk end
        end
    end
    table.insert(M._cbs[direction], {
        mod_fkeys = mod_fkeys,
        fn        = callback,
        gen       = M._generation,
    })
    ensure_loop()
end

function M.binding_count()
    return #M._cbs.up + #M._cbs.down
end

return M
