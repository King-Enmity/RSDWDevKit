-- feature_hotkeys.lua
--
-- Round 36: in-game hotkey activation for user-authored mods.
--
-- Reads <Win64>\ue4ss\Mods\RSDWTools\ipc\mods.json (the same file the WPF
-- "Mods" tab edits) and registers every kit + folder hotkey via
-- RegisterKeyBindAsync. Hotkey semantics:
--
--   * Folder hotkey, mode "set"    : on press, fires every mod row in
--     the folder via command_line_router (same as the WPF "Apply All").
--   * Folder hotkey, mode "toggle" : keeps a per-folder state (0 / 1).
--     Press 1 fires the on-values, press 2 fires the off-values, press
--     3 the on-values again, and so on. A blank Off Value skips that
--     row's off press (useful for rows that are one-shots).
--   * Kit hotkey                   : pure gate. Press flips
--     _kit_enabled[kitName]. While disabled, every folder hotkey
--     callback inside that kit early-returns. Folders whose parent kit
--     has no hotkey at all are always armed.
--
-- UE4SS does not expose Unregister, so reload-safety is achieved via a
-- generation counter: every callback captures the generation at which
-- it was registered ; reload bumps the counter and old callbacks check
-- their captured value and bail. Net effect: stale registrations stay
-- in the table but become no-ops.

local mod_paths = require("mod_paths")
local command_line_router = require("command_line_router")

local M = {}

-- =========================================================================
-- Minimal JSON decoder
-- =========================================================================
--
-- We control the writer (System.Text.Json on the WPF side) so the input
-- shape is well-defined. The decoder handles objects, arrays, strings
-- (with \" \\ \n \t \r \/ \uXXXX), numbers, true/false, null and
-- whitespace. No comments, no bare-key shortcut. Errors return nil + a
-- short message so callers can log without crashing the host.

local function json_skip_ws(s, i)
    while i <= #s do
        local c = s:sub(i, i)
        if c ~= " " and c ~= "\t" and c ~= "\n" and c ~= "\r" then return i end
        i = i + 1
    end
    return i
end

local json_decode_value -- forward decl

local function json_decode_string(s, i)
    -- Caller has already consumed the opening quote.
    local out = {}
    local n = #s
    while i <= n do
        local c = s:sub(i, i)
        if c == '"' then
            return table.concat(out), i + 1
        elseif c == '\\' then
            local nx = s:sub(i + 1, i + 1)
            if nx == '"' or nx == '\\' or nx == '/' then
                out[#out + 1] = nx; i = i + 2
            elseif nx == 'n' then out[#out + 1] = '\n'; i = i + 2
            elseif nx == 't' then out[#out + 1] = '\t'; i = i + 2
            elseif nx == 'r' then out[#out + 1] = '\r'; i = i + 2
            elseif nx == 'b' then out[#out + 1] = '\b'; i = i + 2
            elseif nx == 'f' then out[#out + 1] = '\f'; i = i + 2
            elseif nx == 'u' then
                local hex = s:sub(i + 2, i + 5)
                local cp = tonumber(hex, 16) or 0
                -- Best-effort UTF-8 emit ; characters outside BMP fall
                -- back to a literal '?'. Mods.json field values are ASCII
                -- in practice so this is fine.
                if cp < 0x80 then
                    out[#out + 1] = string.char(cp)
                elseif cp < 0x800 then
                    out[#out + 1] = string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
                else
                    out[#out + 1] = string.char(
                        0xE0 + math.floor(cp / 0x1000),
                        0x80 + math.floor(cp / 0x40) % 0x40,
                        0x80 + (cp % 0x40))
                end
                i = i + 6
            else
                return nil, "bad escape \\" .. tostring(nx)
            end
        else
            out[#out + 1] = c; i = i + 1
        end
    end
    return nil, "unterminated string"
end

local function json_decode_number(s, i)
    local start = i
    local n = #s
    if s:sub(i, i) == '-' then i = i + 1 end
    while i <= n do
        local c = s:sub(i, i)
        if (c >= '0' and c <= '9') or c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-' then
            i = i + 1
        else break end
    end
    local num = tonumber(s:sub(start, i - 1))
    if not num then return nil, "bad number" end
    return num, i
end

local function json_decode_array(s, i)
    -- Caller already consumed '['.
    local out = {}
    i = json_skip_ws(s, i)
    if s:sub(i, i) == ']' then return out, i + 1 end
    while true do
        local v, j, err = json_decode_value(s, i)
        if v == nil and err then return nil, err end
        out[#out + 1] = v
        i = json_skip_ws(s, j)
        local c = s:sub(i, i)
        if c == ',' then
            i = json_skip_ws(s, i + 1)
        elseif c == ']' then
            return out, i + 1
        else
            return nil, "expected ',' or ']' in array"
        end
    end
end

local function json_decode_object(s, i)
    -- Caller already consumed '{'.
    local out = {}
    i = json_skip_ws(s, i)
    if s:sub(i, i) == '}' then return out, i + 1 end
    while true do
        if s:sub(i, i) ~= '"' then return nil, "expected key string in object" end
        local key, j, err = json_decode_string(s, i + 1)
        if not key then return nil, err end
        i = json_skip_ws(s, j)
        if s:sub(i, i) ~= ':' then return nil, "expected ':' after key" end
        i = json_skip_ws(s, i + 1)
        local v, k2, verr = json_decode_value(s, i)
        if v == nil and verr then return nil, verr end
        out[key] = v
        i = json_skip_ws(s, k2)
        local c = s:sub(i, i)
        if c == ',' then
            i = json_skip_ws(s, i + 1)
        elseif c == '}' then
            return out, i + 1
        else
            return nil, "expected ',' or '}' in object"
        end
    end
end

json_decode_value = function(s, i)
    i = json_skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '{' then return json_decode_object(s, i + 1) end
    if c == '[' then return json_decode_array(s, i + 1) end
    if c == '"' then return json_decode_string(s, i + 1) end
    if c == 't' and s:sub(i, i + 3) == 'true'  then return true,  i + 4 end
    if c == 'f' and s:sub(i, i + 4) == 'false' then return false, i + 5 end
    if c == 'n' and s:sub(i, i + 3) == 'null'  then return nil,   i + 4 end
    if c == '-' or (c >= '0' and c <= '9') then return json_decode_number(s, i) end
    return nil, "unexpected character at position " .. tostring(i) .. ": '" .. tostring(c) .. "'"
end

local function json_decode(text)
    if type(text) ~= "string" or #text == 0 then return nil, "empty" end
    local v, _, err = json_decode_value(text, 1)
    if v == nil and err then return nil, err end
    return v
end

-- =========================================================================
-- Hotkey state
-- =========================================================================
--
-- _generation increments on every reload so older registered callbacks
-- (which captured the previous value) become no-ops when fired.
--
-- _kit_enabled[kitName] : starts true if the kit has no hotkey, false if
-- it does (a hotkey-gated kit is "armed off" until the player presses).
--
-- _folder_state[folderId] : 0 = next press fires Value, 1 = next press
-- fires ValueOff. Folder id is a stable string composed of kit + folder
-- index because folder rename should not reset the toggle state.

local _generation = 0
local _kit_enabled = {}
local _folder_state = {}

-- Round 60: sub-kits inherit gating from their parent kit. _kit_parents
-- maps a sub-kit's composite name to its parent kit's name (also
-- composite). is_kit_enabled walks the chain ; ANY ancestor being
-- disabled disables this kit. Top-level kits have no entry here, so
-- the walk terminates with their own _kit_enabled state.
local _kit_parents = {}

local function is_kit_enabled(kit_name)
    local cur = kit_name
    while cur ~= nil do
        if _kit_enabled[cur] == false then return false end
        cur = _kit_parents[cur]
    end
    return true
end

-- =========================================================================
-- Gamepad hotkey state (Round 54)
-- =========================================================================
--
-- _gamepad_dispatch[chord_key] = callback
--   chord_key is "<trigger_name>|<sorted_held_names_csv>". Built so a
--   chord like LB+A always normalizes to "Gamepad_FaceButton_Bottom|Gamepad_LeftShoulder"
--   regardless of input order.
--
-- _last_gamepad_buttons is the previous tick's button bitmask so we
-- can edge-detect newly-pressed buttons (button-down transitions only,
-- never level-triggered).
--
-- _gamepad_loop_started gates LoopAsync so reloads don't stack new tick
-- loops on top of the old one. The loop body itself bails on the
-- generation check, but we'd rather not spin a no-op loop every reload.

local _gamepad_dispatch = {}
local _last_gamepad_buttons = 0
local _gamepad_loop_started = false
local _gamepad_log_enabled = false
local GAMEPAD_POLL_MS = 16  -- ~60Hz, well below human chord-detect threshold

-- bit index -> UE-style FKey name. MUST stay in sync with the table in
-- RSDWToolsUE4SS/dllmain.cpp::lua_gamepad_button_names. Bits 10/11 are
-- reserved by XInput and never set ; we leave them out.
--
-- Bug fix: XInput's wButtons layout is
--   bit 6  = LEFT_THUMB    (LSB stick click)
--   bit 7  = RIGHT_THUMB   (RSB stick click)
--   bit 8  = LEFT_SHOULDER  (LB)
--   bit 9  = RIGHT_SHOULDER (RB)
-- Earlier versions had shoulders and thumbsticks swapped, which made
-- LB/RB bindings silently fire on stick clicks instead.
local _GAMEPAD_BIT_NAMES = {
    [0]  = "Gamepad_DPad_Up",
    [1]  = "Gamepad_DPad_Down",
    [2]  = "Gamepad_DPad_Left",
    [3]  = "Gamepad_DPad_Right",
    [4]  = "Gamepad_Special_Right",   -- Start / Menu
    [5]  = "Gamepad_Special_Left",    -- Back / View
    [6]  = "Gamepad_LeftThumbstick",
    [7]  = "Gamepad_RightThumbstick",
    [8]  = "Gamepad_LeftShoulder",
    [9]  = "Gamepad_RightShoulder",
    [12] = "Gamepad_FaceButton_Bottom",
    [13] = "Gamepad_FaceButton_Right",
    [14] = "Gamepad_FaceButton_Left",
    [15] = "Gamepad_FaceButton_Top",
    [16] = "Gamepad_LeftTrigger",
    [17] = "Gamepad_RightTrigger",
}
local _GAMEPAD_NAME_BITS = {}
for bit, name in pairs(_GAMEPAD_BIT_NAMES) do _GAMEPAD_NAME_BITS[name] = bit end

local function folder_key(kit_name, folder_index)
    return tostring(kit_name) .. "::" .. tostring(folder_index)
end

-- =========================================================================
-- Verb construction (mirrors WPF's BuildVerb)
-- =========================================================================
--
-- The C# side already validates value vs kind and routes through
-- command_line_router, so we just need to format the same wire string.
-- "set" kind   -> player.field.set  <reach> <field> <value>
-- "call" kind  -> player.field.call <reach> <field> [args]
-- 'reach' currently is always 'player' (the only supported reach in the
-- schema today) but we keep it parameterized for forward compat.

local function build_verb(mod, override_value)
    local kind  = mod.kind  or "set"
    local reach = mod.reach_spec or "player"
    local field = mod.field or ""
    local value = override_value
    if value == nil then value = mod.value or "" end
    -- Round 48: raw verbs carry the entire IPC line in `value` ; we
    -- forward it to the router untouched so any verb the router
    -- accepts (player.ge.apply, probe.find_class, ui.tab, ...) can be
    -- parked as a mod entry without a reach/field schema.
    if kind == "raw" then
        if value == nil or value == "" then return nil end
        return value
    end
    -- Round 56: "delay" rows are WPF-only pauses inserted between
    -- sends in the .exe Apply-All loop. They have no IPC verb. On the
    -- hotkey path we do not have a free `sleep`, so we silently skip
    -- them and dispatch the remaining rows back-to-back. Folder Apply
    -- via the .exe button is the canonical place to honor delays.
    if kind == "delay" then
        return nil
    end
    -- Round 51: "umg" rows fire an on-screen toast. Schema slots
    --   value     = on-press text          umg_duration     = on seconds
    --   value_off = off-press text         umg_off_duration = off seconds
    -- The hotkey loader passes value_off as `override_value` for the
    -- toggle-off press, which is also our signal to use the off-side
    -- duration. Wire form mirrors `umg <duration> <text>` either way.
    -- Default 3s for missing/invalid duration. Empty text = no toast.
    if kind == "umg" then
        local is_off_press = override_value ~= nil
        local text
        if is_off_press then
            text = override_value
        else
            text = mod.value or mod.name or ""
        end
        if not text or text == "" then return nil end
        local dur_raw = is_off_press and mod.umg_off_duration or mod.umg_duration
        local dur = tonumber(dur_raw) or 3
        if dur <= 0 then dur = 3 end
        return string.format("umg %s %s", tostring(dur), text)
    end
    if field == "" then return nil end
    if kind == "call" then
        if value == nil or value == "" then
            return string.format("player.field.call %s %s", reach, field)
        end
        return string.format("player.field.call %s %s %s", reach, field, value)
    end
    -- Default: set. Empty value is rejected by the router so skip silently.
    if value == nil or value == "" then return nil end
    return string.format("player.field.set %s %s %s", reach, field, value)
end

-- =========================================================================
-- Key/modifier resolution
-- =========================================================================
--
-- Modifiers are stored as "LEFT_CONTROL" / "LEFT_SHIFT" / "LEFT_ALT" so
-- the lookup mirrors the picker dialog. UE4SS's RegisterKeyBindAsync
-- accepts a key plus an optional table of modifier-key constants.

local function resolve_key(name)
    if not name or name == "" then return nil end
    local KeyTbl = rawget(_G, "Key")
    if not KeyTbl then return nil end
    return KeyTbl[name]
end

-- Round 62: WHEEL_UP / WHEEL_DOWN sentinels. These don't exist in
-- UE4SS's Key table -- they're handled by feature_wheel_hook via a
-- per-tick poll on PlayerController:WasInputKeyJustPressed for the
-- discrete EKeys::MouseScrollUp / MouseScrollDown FKeys. Detect them
-- BEFORE calling resolve_key so we don't print a spurious "unknown
-- key" warning.
local function is_wheel_token(name)
    return name == "WHEEL_UP" or name == "WHEEL_DOWN"
end

local function wheel_direction(name)
    if name == "WHEEL_UP"   then return "up"   end
    if name == "WHEEL_DOWN" then return "down" end
    return nil
end

local function resolve_modifiers(list)
    if type(list) ~= "table" or #list == 0 then return nil end
    local ModTbl = rawget(_G, "ModifierKey")
    local out = {}
    for _, raw in ipairs(list) do
        local k = nil
        -- Prefer ModifierKey.* when available ; many UE4SS builds
        -- distinguish modifier constants from normal keys.
        if ModTbl then
            local short = raw
            if raw == "LEFT_CONTROL" or raw == "RIGHT_CONTROL" then short = "CONTROL" end
            if raw == "LEFT_SHIFT"   or raw == "RIGHT_SHIFT"   then short = "SHIFT"   end
            if raw == "LEFT_ALT"     or raw == "RIGHT_ALT"     then short = "ALT"     end
            k = ModTbl[short] or ModTbl[raw]
        end
        if k == nil then k = resolve_key(raw) end
        if k ~= nil then out[#out + 1] = k end
    end
    if #out == 0 then return nil end
    return out
end

-- Tiny safe wrapper so a single bad mod row in a folder doesn't abort
-- the whole apply. Errors print to the UE4SS console.
local function safe_dispatch(line)
    if not line then return end
    local ok, ok2, msg = pcall(function() return command_line_router.handle_line(line) end)
    if not ok then
        print("[RSDWTools.hotkeys] dispatch crash: " .. tostring(ok2))
    elseif ok2 == false then
        print("[RSDWTools.hotkeys] dispatch refused: " .. tostring(msg))
    end
end

-- Round 62: shared startup-folder dispatch. Called from both keyboard
-- and gamepad kit callbacks so arm/disarm semantics stay consistent.
--   on_arm == true  : send each row's Value (build_verb m, nil)
--   on_arm == false : send each row's ValueOff. Mirrors the toggle
--                     mode off-press logic in make_folder_callback :
--                     blank ValueOff is skipped for "set" kinds and
--                     re-sends the on-line for "raw"/"call" toggles.
local function fire_startup_folder(kit_name, kit, on_arm, label)
    if not kit or not kit.startup_folder or kit.startup_folder == "" then return end
    local target_name = kit.startup_folder
    local match
    for _, f in ipairs(kit.folders or {}) do
        if f.name == target_name then match = f; break end
    end
    if not match then
        print(string.format("[RSDWTools.hotkeys] kit '%s' startup '%s' not found ; skipped.",
            kit_name, target_name))
        return
    end
    local rows = match.mods or {}
    print(string.format("[RSDWTools.hotkeys] kit '%s' startup %s '%s' (%d field(s))%s",
        kit_name, on_arm and "ARM ->" or "DISARM ->", target_name, #rows,
        label and (" "..label) or ""))
    if on_arm then
        for _, m in ipairs(rows) do
            safe_dispatch(build_verb(m, nil))
        end
    else
        for _, m in ipairs(rows) do
            local off = m.value_off
            if off ~= nil and off ~= "" then
                safe_dispatch(build_verb(m, off))
            else
                local kind = m.kind or "set"
                if kind == "raw" or kind == "call" then
                    safe_dispatch(build_verb(m, nil))
                end
            end
        end
    end
end

-- =========================================================================
-- Registration
-- =========================================================================

-- Round 62: cascade disarm into descendants. When a parent kit is
-- toggled OFF we walk every sub_kit underneath it ; any descendant
-- that is currently armed gets disarmed too AND its startup folder
-- fires off-values, mirroring the user pressing each sub-kit's hotkey
-- once. Without this, a sub-kit could remember it was armed across a
-- parent disarm/rearm cycle, leaving the in-game state out of sync
-- with the printed kit gate. Composite name format must match
-- register_kit_recursive : parent .. "::" .. sub.name.
local function cascade_disarm_subkits(parent_name, parent_kit, label)
    if not parent_kit then return end
    local subs = parent_kit.sub_kits or {}
    for _, sub in ipairs(subs) do
        local sub_raw = sub.name or "Sub"
        local sub_name = parent_name .. "::" .. sub_raw
        if _kit_enabled[sub_name] then
            _kit_enabled[sub_name] = false
            print(string.format("[RSDWTools.hotkeys] kit '%s' cascade-disarmed%s",
                sub_name, label and (" "..label) or ""))
            fire_startup_folder(sub_name, sub, false, label)
        end
        -- Recurse even if this sub was already disarmed ; a deeper
        -- descendant might still be armed in some unusual flow.
        cascade_disarm_subkits(sub_name, sub, label)
    end
end

-- Build the kit-toggle callback. Same body for keyboard, gamepad, and
-- wheel dispatch -- only the trigger surface differs.
local function make_kit_callback(kit_name, my_gen, kit)
    return function()
        if _generation ~= my_gen then return end -- stale
        -- Round 62: sub-kit toggles inherit parent gating. If ANY
        -- ancestor kit is currently disarmed, swallow the press so a
        -- sub-kit's hotkey can't arm itself (or fire its startup
        -- folder) while its parent is off. Walks parents only ; the
        -- sub-kit's own current state is irrelevant to the gate. Top
        -- level kits have no parent entry so this is a no-op for them.
        local parent = _kit_parents[kit_name]
        if parent ~= nil and not is_kit_enabled(parent) then
            print(string.format("[RSDWTools.hotkeys] kit '%s' press ignored (parent gate down)",
                kit_name))
            return
        end
        local cur = _kit_enabled[kit_name]
        if cur == nil then cur = false end
        local now_enabled = not cur
        _kit_enabled[kit_name] = now_enabled
        print(string.format("[RSDWTools.hotkeys] kit '%s' %s", kit_name,
            now_enabled and "ARMED" or "disarmed"))
        -- Round 51: one-shot startup folder. Round 62: now ALSO fires
        -- on disarm using each row's ValueOff (matching toggle-mode
        -- off-press semantics). Looked up by name so a folder reorder
        -- inside the kit doesn't bind the startup to a different
        -- folder. Silent no-op when kit.startup_folder is nil/empty
        -- or doesn't match any folder name.
        fire_startup_folder(kit_name, kit, now_enabled, nil)
        if not now_enabled then
            cascade_disarm_subkits(kit_name, kit, nil)
        end
    end
end

local function register_kit_hotkey(kit_name, key_token, key_const, mods_table, my_gen, kit)
    local cb = make_kit_callback(kit_name, my_gen, kit)
    -- Round 62: WHEEL_UP/DOWN routes through the InputAxis hook
    -- instead of RegisterKeyBindAsync. mods_table is already a list
    -- of FKeys (resolve_modifiers_as_fkeys) when key_token is a
    -- wheel sentinel.
    if is_wheel_token(key_token) then
        require("feature_wheel_hook").register(
            wheel_direction(key_token), mods_table, cb)
        return
    end
    local ok, err = pcall(function()
        if mods_table then
            RegisterKeyBindAsync(key_const, mods_table, cb)
        else
            RegisterKeyBindAsync(key_const, cb)
        end
    end)
    if not ok then
        print("[RSDWTools.hotkeys] kit '" .. kit_name .. "' bind failed: " .. tostring(err))
    end
end

local function make_folder_callback(kit_name, folder_index, folder, my_gen)
    local fid = folder_key(kit_name, folder_index)
    local mode = folder.hotkey_mode or "set"
    local mods_list = folder.mods or {}
    return function()
        if _generation ~= my_gen then return end -- stale
        if not is_kit_enabled(kit_name) then
            -- Kit (or any ancestor sub-kit's parent) gate down ; silently ignore.
            return
        end
        if mode == "toggle" then
            local state = _folder_state[fid] or 0
            if state == 0 then
                -- ON press: send each row's Value
                for _, m in ipairs(mods_list) do
                    safe_dispatch(build_verb(m, nil))
                end
                _folder_state[fid] = 1
            else
                -- OFF press: send each row's ValueOff. If ValueOff is
                -- blank AND the verb itself is the toggle (raw / call
                -- kinds carry no positional value), re-send the same
                -- on-line so engine-side toggle verbs round-trip
                -- cleanly. For "set" kinds we still skip on blank
                -- because firing the same write twice would not
                -- restore the original field value.
                for _, m in ipairs(mods_list) do
                    local off = m.value_off
                    if off ~= nil and off ~= "" then
                        safe_dispatch(build_verb(m, off))
                    else
                        local kind = m.kind or "set"
                        if kind == "raw" or kind == "call" then
                            safe_dispatch(build_verb(m, nil))
                        end
                    end
                end
                _folder_state[fid] = 0
            end
        else
            -- "set" mode: always fire the on-values.
            for _, m in ipairs(mods_list) do
                safe_dispatch(build_verb(m, nil))
            end
        end
    end
end

local function register_folder_hotkey(kit_name, folder_index, folder, key_token, key_const, mods_table, my_gen)
    local cb = make_folder_callback(kit_name, folder_index, folder, my_gen)
    if is_wheel_token(key_token) then
        require("feature_wheel_hook").register(
            wheel_direction(key_token), mods_table, cb)
        return
    end
    local ok, err = pcall(function()
        if mods_table then
            RegisterKeyBindAsync(key_const, mods_table, cb)
        else
            RegisterKeyBindAsync(key_const, cb)
        end
    end)
    if not ok then
        print(string.format("[RSDWTools.hotkeys] folder '%s/%s' bind failed: %s",
            kit_name, folder.name or "?", tostring(err)))
    end
end

-- =========================================================================
-- Gamepad hotkey registration
-- =========================================================================
--
-- The callback bodies are intentionally identical to the keyboard
-- variants ; only the trigger surface differs. Storing into
-- _gamepad_dispatch instead of calling RegisterKeyBindAsync keeps the
-- gamepad path purely Lua-side: gamepad_tick() does the matching every
-- ~16ms, ONLY when the dispatch table is non-empty.
--
-- chord_key normalization: trigger name + "|" + sorted CSV of held
-- modifier names. Sorting makes "LB+RB+A" and "RB+LB+A" hash to the
-- same key. Empty modifier list means "trigger alone".

local function gamepad_chord_key(trigger_name, modifier_names)
    local mods = {}
    if type(modifier_names) == "table" then
        for _, n in ipairs(modifier_names) do
            if type(n) == "string" and n ~= "" and n ~= trigger_name then
                mods[#mods + 1] = n
            end
        end
        table.sort(mods)
    end
    return tostring(trigger_name) .. "|" .. table.concat(mods, ",")
end

local function register_kit_gamepad_hotkey(kit_name, trigger_name, modifier_names, my_gen, kit)
    local key = gamepad_chord_key(trigger_name, modifier_names)
    _gamepad_dispatch[key] = function()
        if _generation ~= my_gen then return end
        -- Round 62: same parent gate as the keyboard kit callback.
        local parent = _kit_parents[kit_name]
        if parent ~= nil and not is_kit_enabled(parent) then
            print(string.format("[RSDWTools.hotkeys] kit '%s' press ignored (parent gate down, gamepad)",
                kit_name))
            return
        end
        local cur = _kit_enabled[kit_name]
        if cur == nil then cur = false end
        local now_enabled = not cur
        _kit_enabled[kit_name] = now_enabled
        print(string.format("[RSDWTools.hotkeys] kit '%s' %s (gamepad)", kit_name,
            now_enabled and "ARMED" or "disarmed"))
        fire_startup_folder(kit_name, kit, now_enabled, "(gamepad)")
        if not now_enabled then
            cascade_disarm_subkits(kit_name, kit, "(gamepad)")
        end
    end
end

local function register_folder_gamepad_hotkey(kit_name, folder_index, folder, trigger_name, modifier_names, my_gen)
    local fid = folder_key(kit_name, folder_index)
    local mode = folder.hotkey_mode or "set"
    local mods_list = folder.mods or {}
    local key = gamepad_chord_key(trigger_name, modifier_names)
    _gamepad_dispatch[key] = function()
        if _generation ~= my_gen then return end
        if not is_kit_enabled(kit_name) then return end
        if mode == "toggle" then
            local state = _folder_state[fid] or 0
            if state == 0 then
                for _, m in ipairs(mods_list) do safe_dispatch(build_verb(m, nil)) end
                _folder_state[fid] = 1
            else
                for _, m in ipairs(mods_list) do
                    local off = m.value_off
                    if off ~= nil and off ~= "" then
                        safe_dispatch(build_verb(m, off))
                    else
                        local kind = m.kind or "set"
                        if kind == "raw" or kind == "call" then
                            safe_dispatch(build_verb(m, nil))
                        end
                    end
                end
                _folder_state[fid] = 0
            end
        else
            for _, m in ipairs(mods_list) do safe_dispatch(build_verb(m, nil)) end
        end
    end
end

-- Per-tick dispatcher. Pulls one XInput snapshot, edge-detects newly
-- pressed buttons, and fires any matching chord. Held set for chord
-- matching = all OTHER currently-held buttons (i.e. trigger excluded).
-- Free-form modifiers: the user can declare *any* button as a mod.
local function gamepad_tick()
    if next(_gamepad_dispatch) == nil and not _gamepad_log_enabled then
        -- No bindings AND no logger ; cheapest possible path.
        _last_gamepad_buttons = 0
        return
    end
    if not PollGamepadStateCpp then return end
    local state = PollGamepadStateCpp()
    if not state then
        _last_gamepad_buttons = 0
        return
    end
    local cur = state.buttons or 0
    -- Edge-detect newly pressed buttons (bits set in cur but NOT in
    -- prev). Lua 5.1 has no native bitops ; per-bit walk is cheap (at
    -- most 16 bits checked) and avoids depending on bit32 / lua-bitop.
    local prev = _last_gamepad_buttons
    _last_gamepad_buttons = cur
    for bit = 0, 17 do
        local mask = 2 ^ bit
        local cur_bit = (math.floor(cur  / mask) % 2) == 1
        local prev_bit = (math.floor(prev / mask) % 2) == 1
        if cur_bit and not prev_bit then
            local trigger_name = _GAMEPAD_BIT_NAMES[bit]
            if trigger_name then
                -- Held set = all currently-held buttons except trigger.
                local held = {}
                for hb = 0, 17 do
                    if hb ~= bit then
                        local hmask = 2 ^ hb
                        if (math.floor(cur / hmask) % 2) == 1 then
                            local hname = _GAMEPAD_BIT_NAMES[hb]
                            if hname then held[#held + 1] = hname end
                        end
                    end
                end
                table.sort(held)
                local key = trigger_name .. "|" .. table.concat(held, ",")
                if _gamepad_log_enabled then
                    if #held > 0 then
                        print(string.format("[RSDWTools.gamepad] press %s  (held: %s)",
                            trigger_name, table.concat(held, ", ")))
                    else
                        print(string.format("[RSDWTools.gamepad] press %s", trigger_name))
                    end
                end
                local cb = _gamepad_dispatch[key]
                if cb then
                    local ok, err = pcall(cb)
                    if not ok then
                        print("[RSDWTools.hotkeys] gamepad cb crash: " .. tostring(err))
                    end
                end
            end
        end
    end
end

local function start_gamepad_loop()
    if _gamepad_loop_started then return end
    if not LoopAsync then
        print("[RSDWTools.hotkeys] LoopAsync unavailable -- gamepad hotkeys disabled.")
        return
    end
    _gamepad_loop_started = true
    LoopAsync(GAMEPAD_POLL_MS, function()
        gamepad_tick()
        return false  -- never exit
    end)
    print(string.format("[RSDWTools.hotkeys] gamepad poll loop ~%dms started.", GAMEPAD_POLL_MS))
end

-- =========================================================================
-- Load
-- =========================================================================

local function read_json_doc(filename)
    local dir = mod_paths.ipc_dir()
    if not dir then return nil, "ipc dir unresolved" end
    local path = dir .. "\\" .. filename
    local f, err = io.open(path, "rb")
    if not f then return nil, "open failed: " .. tostring(err) end
    local body = f:read("*a")
    f:close()
    if not body or #body == 0 then return nil, "file empty" end
    local doc, derr = json_decode(body)
    if not doc then return nil, "parse failed: " .. tostring(derr) end
    return doc
end

local function read_mods_json()
    return read_json_doc("mods.json")
end

-- Round 49: Camera tab is now a second Mods document. We register hotkeys
-- from BOTH ipc/mods.json and ipc/camera.json in one pass so a single
-- "rsdwt_hotkeys_reload" call rebinds everything. Kit names are scoped
-- with the file label to keep the gate (_kit_enabled) state from
-- colliding when both files happen to use the same kit name.
local function register_doc(doc, scope_label, my_gen)
    if not doc then return 0, 0, 0 end
    local kits = doc.kits or {}
    local kit_count, folder_count = 0, 0

    -- Round 60: nested kits. We register a kit's hotkey + its folders'
    -- hotkeys, then recurse into kit.sub_kits with a composite name and
    -- a parent pointer so is_kit_enabled() can AND-gate the chain.
    local function register_kit_recursive(kit, kit_name, parent_name)
        local kit_hk = kit.hotkey
        local kit_gp = kit.gamepad_hotkey
        -- Gate starts armed only if the kit has NO trigger of any
        -- kind ; either keyboard or gamepad hotkey is enough to
        -- arm-off the kit at startup.
        _kit_enabled[kit_name] = ((kit_hk == nil or kit_hk == "") and (kit_gp == nil or kit_gp == ""))
        if parent_name then _kit_parents[kit_name] = parent_name end
        if kit_hk and kit_hk ~= "" then
            if is_wheel_token(kit_hk) then
                -- Wheel path : pass raw VK-style modifier name list ;
                -- feature_wheel_hook translates them to UE FKey structs
                -- internally for IsInputKeyDown calls.
                register_kit_hotkey(kit_name, kit_hk, nil,
                    kit.modifiers, my_gen, kit)
                kit_count = kit_count + 1
            else
                local kc = resolve_key(kit_hk)
                if kc then
                    register_kit_hotkey(kit_name, kit_hk, kc, resolve_modifiers(kit.modifiers), my_gen, kit)
                    kit_count = kit_count + 1
                else
                    print("[RSDWTools.hotkeys] unknown kit key '" .. tostring(kit_hk) .. "'")
                end
            end
        end
        if kit_gp and kit_gp ~= "" then
            register_kit_gamepad_hotkey(kit_name, kit_gp, kit.gamepad_modifiers, my_gen, kit)
            kit_count = kit_count + 1
        end
        local folders = kit.folders or {}
        for fi, folder in ipairs(folders) do
            local fhk = folder.hotkey
            if fhk and fhk ~= "" then
                if is_wheel_token(fhk) then
                    register_folder_hotkey(kit_name, fi, folder, fhk, nil,
                        folder.modifiers, my_gen)
                    folder_count = folder_count + 1
                else
                    local fkc = resolve_key(fhk)
                    if fkc then
                        register_folder_hotkey(kit_name, fi, folder, fhk, fkc, resolve_modifiers(folder.modifiers), my_gen)
                        folder_count = folder_count + 1
                    else
                        print("[RSDWTools.hotkeys] unknown folder key '" .. tostring(fhk) .. "'")
                    end
                end
            end
            local fgp = folder.gamepad_hotkey
            if fgp and fgp ~= "" then
                register_folder_gamepad_hotkey(kit_name, fi, folder, fgp, folder.gamepad_modifiers, my_gen)
                folder_count = folder_count + 1
            end
        end
        -- Round 60: recurse into nested kits. Sub-kit's composite name
        -- prefixes its parent ; is_kit_enabled walks the chain so a
        -- sub-kit folder hotkey only fires when BOTH the parent kit
        -- gate AND the sub-kit gate are armed.
        local subs = kit.sub_kits or {}
        for _, sub in ipairs(subs) do
            local sub_raw = sub.name or "Sub"
            register_kit_recursive(sub, kit_name .. "::" .. sub_raw, kit_name)
        end
    end

    for _, kit in ipairs(kits) do
        local raw_name = kit.name or "Default"
        register_kit_recursive(kit, scope_label .. "::" .. raw_name, nil)
    end
    -- Top-level Mods (folders without a Mod Kit wrapper). One sentinel
    -- gate per scope so Mods top-level and Camera top-level are
    -- independently armed.
    local TOP = scope_label .. "::__toplevel__"
    _kit_enabled[TOP] = true
    local top_folders = doc.folders or {}
    local top_count = 0
    for fi, folder in ipairs(top_folders) do
        local fhk = folder.hotkey
        if fhk and fhk ~= "" then
            if is_wheel_token(fhk) then
                register_folder_hotkey(TOP, fi, folder, fhk, nil,
                    folder.modifiers, my_gen)
                top_count = top_count + 1
                print(string.format("[RSDWTools.hotkeys] %s top-level '%s' bound to %s",
                    scope_label, folder.name or "?", fhk))
            else
                local fkc = resolve_key(fhk)
                if fkc then
                    register_folder_hotkey(TOP, fi, folder, fhk, fkc, resolve_modifiers(folder.modifiers), my_gen)
                    top_count = top_count + 1
                    print(string.format("[RSDWTools.hotkeys] %s top-level '%s' bound to %s",
                        scope_label, folder.name or "?", fhk))
                else
                    print("[RSDWTools.hotkeys] unknown top-level key '" .. tostring(fhk) .. "'")
                end
            end
        end
        local fgp = folder.gamepad_hotkey
        if fgp and fgp ~= "" then
            register_folder_gamepad_hotkey(TOP, fi, folder, fgp, folder.gamepad_modifiers, my_gen)
            top_count = top_count + 1
            print(string.format("[RSDWTools.hotkeys] %s top-level '%s' bound to gamepad %s",
                scope_label, folder.name or "?", fgp))
        end
    end
    return kit_count, folder_count, top_count
end

function M.load_and_register()
    if not RegisterKeyBindAsync then
        print("[RSDWTools.hotkeys] RegisterKeyBindAsync unavailable -- mod hotkeys disabled.")
        return
    end
    _generation = _generation + 1
    local my_gen = _generation
    -- Reset toggle state and gate state on every reload so the player
    -- gets predictable behavior after editing either JSON file.
    _kit_enabled  = {}
    _kit_parents  = {}
    _folder_state = {}
    -- Reset gamepad dispatch ; old generation callbacks would early-out
    -- via _generation check anyway, but clearing the table keeps it
    -- bounded over many reloads.
    _gamepad_dispatch = {}
    _last_gamepad_buttons = 0

    -- Round 62: bump wheel-hook generation and clear its registry.
    -- The hook itself stays installed across reloads ; only the
    -- per-binding entries get rebuilt.
    local ok_wh, wh = pcall(require, "feature_wheel_hook")
    if ok_wh and wh then wh.bump_generation() end

    local mods_doc,       merr  = read_json_doc("mods.json")
    local camera_doc,     cerr  = read_json_doc("camera.json")
    local building_doc,   berr  = read_json_doc("building.json")
    local player_doc,     perr  = read_json_doc("player.json")
    local essentials_doc, eerr  = read_json_doc("essentials.json")
    if not mods_doc then
        print("[RSDWTools.hotkeys] no mods.json (" .. tostring(merr) .. ").")
    end
    if not camera_doc then
        print("[RSDWTools.hotkeys] no camera.json (" .. tostring(cerr) .. ").")
    end
    if not building_doc then
        print("[RSDWTools.hotkeys] no building.json (" .. tostring(berr) .. ").")
    end
    if not player_doc then
        print("[RSDWTools.hotkeys] no player.json (" .. tostring(perr) .. ").")
    end
    if not essentials_doc then
        print("[RSDWTools.hotkeys] no essentials.json (" .. tostring(eerr) .. ").")
    end

    local mk, mf, mt = register_doc(mods_doc,       "mods",       my_gen)
    local ck, cf, ct = register_doc(camera_doc,     "camera",     my_gen)
    local bk, bf, bt = register_doc(building_doc,   "building",   my_gen)
    local pk, pf, pt = register_doc(player_doc,     "player",     my_gen)
    local ek, ef, et = register_doc(essentials_doc, "essentials", my_gen)

    print(string.format("[RSDWTools.hotkeys] gen=%d mods(k=%d f=%d t=%d) camera(k=%d f=%d t=%d) building(k=%d f=%d t=%d) player(k=%d f=%d t=%d) essentials(k=%d f=%d t=%d) gp_chords=%d registered.",
        my_gen, mk, mf, mt, ck, cf, ct, bk, bf, bt, pk, pf, pt, ek, ef, et,
        (function() local n=0 for _ in pairs(_gamepad_dispatch) do n=n+1 end return n end)()))

    -- Start the gamepad poll loop on first call ; subsequent reloads
    -- just refresh _gamepad_dispatch and the existing loop picks up
    -- the new bindings on its next tick.
    start_gamepad_loop()
end

function M.reload()
    print("[RSDWTools.hotkeys] reload requested.")
    M.load_and_register()
end

-- Toggle the smoke-test logger. When on, every controller press is
-- printed to the UE4SS console along with any held buttons. Useful for
-- verifying XInput plumbing without binding any chord first.
function M.set_gamepad_log(on)
    _gamepad_log_enabled = (on == true)
    -- Make sure the loop is up so the logger has a tick driver even if
    -- no chords are registered yet.
    if _gamepad_log_enabled then start_gamepad_loop() end
    print("[RSDWTools.hotkeys] gamepad log = " .. tostring(_gamepad_log_enabled))
end

-- Dump the currently-registered gamepad chord keys to the UE4SS
-- console. Use this to verify that the chord you bound in the .exe
-- actually made it through reload and matches what the live tick loop
-- is looking up. Format per line:
--   [RSDWTools.hotkeys] chord '<key>' bound
-- where <key> is "<trigger>|<sorted_held_csv>".
function M.dump_gamepad_status()
    local count = 0
    local keys = {}
    for k, _ in pairs(_gamepad_dispatch) do
        keys[#keys + 1] = k
        count = count + 1
    end
    table.sort(keys)
    print(string.format("[RSDWTools.hotkeys] gamepad chord table: %d binding(s), poll_loop=%s, log=%s",
        count, tostring(_gamepad_loop_started), tostring(_gamepad_log_enabled)))
    for _, k in ipairs(keys) do
        print("[RSDWTools.hotkeys]   chord '" .. k .. "' bound")
    end
    -- Also confirm XInput plumbing without any human input.
    if PollGamepadStateCpp then
        local s = PollGamepadStateCpp()
        if s then
            print(string.format("[RSDWTools.hotkeys] xinput live: buttons=0x%05x lt=%d rt=%d packet=%d",
                s.buttons or 0, s.lt or 0, s.rt or 0, s.packet or 0))
        else
            print("[RSDWTools.hotkeys] xinput live: NO CONTROLLER (PollGamepadStateCpp returned nil)")
        end
    else
        print("[RSDWTools.hotkeys] xinput live: PollGamepadStateCpp NOT REGISTERED -- wrapper DLL not loaded")
    end
end

return M
