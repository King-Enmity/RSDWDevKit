-- Player "cheats" feature: value writes and RPC calls on the local pawn.
--
-- Every verb here targets the local player character (the pawn returned by
-- feature_actor.get_local_pawn()). Field-name choices were validated against
-- a fresh introspection dump (Dumps/ipc/player/actor_info.json) so we know:
--
--   * the field/method *exists* on the pawn or its class chain, and
--   * its type matches what the UI sends (float / int32 / boolean).
--
-- Design contract:
--   * Every public function is called from the game thread. main.lua wraps
--     command_line_router.handle_line() in ExecuteInGameThread already, so
--     we do NOT wrap again here (wrapping would make the call async and we'd
--     lose the return value, which is how feature_actor.goto_actor originally
--     regressed with "actor.goto failed: nil").
--   * Every native touch is pcall-guarded. We cannot trap a native AV this
--     way (Lua pcall can't unwind the C stack) but we CAN trap Lua-level
--     binding errors (wrong arg type, missing getter, etc).
--   * Return shape is always (ok, detail_or_error):
--       ok=true  -> detail is a short human string for the ack ("ok <verb> <value>")
--       ok=false -> detail is an error string
--
-- The router layer wraps our return into the final ack string the WPF side
-- reads. So "ok, '1.5'" becomes "ack: ok player.time 1.5" on the wire.

local M = {}

local feature_actor = require("feature_actor")

local function get_pawn()
    local pawn = feature_actor.get_local_pawn()
    if not pawn or not feature_actor.is_valid_object(pawn) then
        return nil
    end
    return pawn
end

-- Coerces on/off/0/1/true/false-ish strings into an honest boolean.
-- Mirrors the parser in feature_actor; duplicated rather than imported to
-- keep this module free of cross-feature coupling beyond the pawn lookup.
local function parse_bool(v)
    if type(v) == "boolean" then return v end
    local s = tostring(v or ""):lower()
    if s == "on" or s == "1" or s == "true" or s == "yes" then return true end
    if s == "off" or s == "0" or s == "false" or s == "no" then return false end
    return nil
end

local function parse_number(v)
    local n = tonumber(v)
    if not n then return nil end
    return n
end

-- Write a simple field value. Logs verbosely because these are rare,
-- user-triggered events and the before/after is useful when something
-- doesn't take (e.g. a native setter clamps the value silently).
local function write_field(pawn, name, value)
    local before
    local ok_read, read_val = pcall(function() return pawn[name] end)
    if ok_read then before = read_val end

    local ok_write, err = pcall(function() pawn[name] = value end)
    if not ok_write then
        return false, "write failed: " .. tostring(err)
    end

    -- Read back so the ack reflects reality (some fields clamp).
    local after = value
    local ok_after, v_after = pcall(function() return pawn[name] end)
    if ok_after then after = v_after end

    print(string.format("[RSDWTools] player.%s: %s -> %s",
        name, tostring(before), tostring(after)))
    return true, tostring(after)
end

-- Call a pawn method that takes a single boolean argument (most of the
-- Server_Set* / Server_Disable* RPCs look like this).
local function call_bool_method(pawn, method_name, value)
    if type(pawn[method_name]) ~= "function" and not pawn[method_name] then
        return false, "method '" .. method_name .. "' not found on pawn"
    end
    local ok, err = pcall(function() pawn[method_name](pawn, value and true or false) end)
    if not ok then
        return false, method_name .. " failed: " .. tostring(err)
    end
    print(string.format("[RSDWTools] player.%s(%s)",
        method_name, tostring(value and true or false)))
    return true, value and "on" or "off"
end

-- ---------- Movement ----------

function M.set_time_dilation(value_str)
    local n = parse_number(value_str)
    if not n then return false, "time dilation must be a number" end
    -- 0 is allowed and produces a hard pawn-pause (CustomTimeDilation = 0
    -- freezes this actor's tick). The engine accepts it; only WorldSettings
    -- TimeDilation has the > 0 clamp. Upper bound stays at 10 so we don't
    -- skew frame timing badly enough to drop inputs.
    if n < 0 then n = 0 end
    if n > 10.0 then n = 10.0 end
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    return write_field(pawn, "CustomTimeDilation", n)
end

function M.set_jump_count(value_str)
    local n = parse_number(value_str)
    if not n then return false, "jump count must be a number" end
    -- Engine stores this as int32; floor to be explicit rather than rely on
    -- Lua->int coercion (which varies by binding).
    n = math.floor(n + 0.5)
    if n < 0 then n = 0 end
    if n > 20 then n = 20 end
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    return write_field(pawn, "JumpMaxCount", n)
end

function M.set_jump_hold(value_str)
    local n = parse_number(value_str)
    if not n then return false, "jump hold must be a number" end
    if n < 0 then n = 0 end
    if n > 10 then n = 10 end
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    return write_field(pawn, "JumpMaxHoldTime", n)
end

-- ---------- Combat ----------

function M.set_can_damage_buildings(value_str)
    local b = parse_bool(value_str)
    if b == nil then return false, "expected on|off" end
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    return call_bool_method(pawn, "Server_SetCanDamageBuildings", b)
end

-- Invisibility via HideCharacter(bShouldHide, LockerObj). LockerObj is a
-- ref-count *handle* the game uses to arbitrate stacked hide/show calls from
-- different systems -- passing nil was silently failing handle registration,
-- which is why the character stayed visible. Passing the pawn itself as the
-- locker is the simplest stable UObject we have, so on=hide goes through and
-- off=show releases the same handle (the game matches show-locker to the
-- hide-locker it recorded).
function M.set_invisible(value_str)
    local b = parse_bool(value_str)
    if b == nil then return false, "expected on|off" end
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    if not pawn.HideCharacter then return false, "HideCharacter method missing" end
    local ok, err = pcall(function() pawn:HideCharacter(b and true or false, pawn) end)
    if not ok then return false, "HideCharacter failed: " .. tostring(err) end
    print(string.format("[RSDWTools] player.HideCharacter(%s, locker=<pawn>)", tostring(b)))
    return true, b and "on" or "off"
end

function M.set_soul_rift_immunity(value_str)
    local b = parse_bool(value_str)
    if b == nil then return false, "expected on|off" end
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    return call_bool_method(pawn, "Server_SetSoulRiftImmunity", b)
end

-- NOTE: set_damageable, set_disable_ai_attacks, set_disable_ai_movement,
-- cheat_fly, cheat_ghost, cheat_walk were removed on 2026-04-16 -- see
-- NOTES/cheats-to-revisit.md for the diagnosis and revisit plan. Short
-- version: bCanBeDamaged is the wrong gate (damage is routed through
-- UPlayerDamageComponent), the Server_DisableAI* RPCs silently drop from
-- a non-authoritative client, and the stock ClientCheat* RPCs appear to
-- be stripped from shipping builds of this game.

-- ---------- Round 3: component-backed cheats ----------
--
-- Every verb below routes through one of the pawn's actor components:
--   * HealthComponent              -> pawn.HealthComponent   (dumped as BP_Components_Health)
--   * PlayerDamageComponent        -> pawn.PlayerDamageComponent (dumped as BP_Components_PlayerDamage)
--   * CharacterMovement            -> pawn.CharacterMovement (UDominionMovementComponent / UCharacterMovementComponent)
--
-- Field / method names here were validated against
-- Dumps/ipc/components/{42_BP_Components_PlayerDamage, 61_BP_Components_Health,
-- 111_CharacterMovement}.json. When a value can be reached via several aliases
-- (e.g. HealthComponent and BP_Components_Health both point at the same
-- object), we try the canonical UE name first, then fall back to the blueprint
-- declaration name. First non-nil wins.

-- Resolves a component on the pawn by trying a list of field aliases.
-- Returns (component_userdata, alias_name_used) on success or (nil, err) on
-- failure. We keep this dead simple and pcall-wrap every indexing read: some
-- components are exposed under variant names in different class layouts and
-- the cheapest way to find out which is live is to probe.
local function get_component(pawn, aliases)
    for i = 1, #aliases do
        local name = aliases[i]
        local ok, val = pcall(function() return pawn[name] end)
        if ok and val ~= nil then
            return val, name
        end
    end
    return nil, "component not found (tried: " .. table.concat(aliases, ", ") .. ")"
end

-- Writes a field on an already-resolved component. Same before/after logging
-- as write_field so clamping surprises show up in the console.
local function write_comp_field(comp, alias, name, value)
    local before
    local ok_read, read_val = pcall(function() return comp[name] end)
    if ok_read then before = read_val end

    local ok_write, err = pcall(function() comp[name] = value end)
    if not ok_write then
        return false, "write " .. alias .. "." .. name .. " failed: " .. tostring(err)
    end

    local after = value
    local ok_after, v_after = pcall(function() return comp[name] end)
    if ok_after then after = v_after end

    print(string.format("[RSDWTools] %s.%s: %s -> %s",
        alias, name, tostring(before), tostring(after)))
    return true, tostring(after)
end

-- Calls a component method with arbitrary args. Returns (true, return_value)
-- or (false, err). The method-existence check uses rawequal(nil,...) on the
-- indexed value because some bindings return a zero-arg wrapper even for
-- missing methods -- checking for literal nil is the most reliable probe we
-- have.
local function call_comp_method(comp, alias, method_name, ...)
    local ok_probe, method = pcall(function() return comp[method_name] end)
    if not ok_probe or method == nil then
        return false, alias .. "." .. method_name .. " not found"
    end
    local args = {...}
    local ok, result = pcall(function()
        return comp[method_name](comp, table.unpack(args))
    end)
    if not ok then
        return false, alias .. ":" .. method_name .. " failed: " .. tostring(result)
    end
    return true, result
end

-- Canonical names first, blueprint-declaration names second. The dumped
-- names all worked, but the canonical forms are stable across game patches.
local HEALTH_ALIASES   = { "HealthComponent",       "BP_Components_Health" }
local DAMAGE_ALIASES   = { "PlayerDamageComponent", "BP_Components_PlayerDamage", "DamageComponent" }
local MOVEMENT_ALIASES = { "CharacterMovement" }

-- ---------- Vitals ----------

-- Invincible: UDamageComponent.bCanTakeDamage is the REAL damage gate in this
-- game (bCanBeDamaged on AActor is bypassed by custom damage routing, which
-- is why the old 'damageable' cheat did nothing). `on` means invincible, so
-- the SetCanTakeDamage call gets inverted.
function M.set_invincible(value_str)
    local b = parse_bool(value_str)
    if b == nil then return false, "expected on|off" end
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, DAMAGE_ALIASES)
    if not comp then return false, alias end
    local ok, result = call_comp_method(comp, alias, "SetCanTakeDamage", not b)
    if not ok then return false, result end
    print(string.format("[RSDWTools] invincible=%s (bCanTakeDamage=%s)",
        tostring(b), tostring(not b)))
    return true, b and "on" or "off"
end

-- Immortal: UHealthComponent.bCanDie. Flipping this off prevents the death
-- event from firing even at 0 HP. Technically redundant with invincible in
-- single-player (no damage -> never reaches 0 HP) but useful as a
-- belt-and-suspenders toggle, or by itself to survive scripted death events.
function M.set_immortal(value_str)
    local b = parse_bool(value_str)
    if b == nil then return false, "expected on|off" end
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, HEALTH_ALIASES)
    if not comp then return false, alias end
    local ok, result = call_comp_method(comp, alias, "SetCanDie", not b)
    if not ok then return false, result end
    print(string.format("[RSDWTools] immortal=%s (bCanDie=%s)",
        tostring(b), tostring(not b)))
    return true, b and "on" or "off"
end

-- NOTE: M.revive was removed on 2026-04-17 -- see NOTES/cheats-to-revisit.md
-- section 4. HealthComponent.Revive() does fire, but the respawn pipeline
-- (BP_Components_PlayerRespawn) ran in parallel and still teleported the
-- player to their bed, making the button functionally identical to dying.
-- Proper revive needs the respawn flow to be canceled first; deferred.

-- SetHealth(Value: float, Context: FString). The Context arg feeds into damage
-- floaties and analytics; we pass a fixed tag so the game's damage log shows
-- rsdw-originated edits as distinct from gameplay events.
function M.set_health(value_str)
    local n = parse_number(value_str)
    if not n then return false, "health must be a number" end
    if n < 0 then n = 0 end
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, HEALTH_ALIASES)
    if not comp then return false, alias end
    local ok, result = call_comp_method(comp, alias, "SetHealth", n, "rsdw.set")
    if not ok then return false, result end
    return true, string.format("%.6g", n)
end

-- Heal: read max, then SetHealth(max). We do not use IncreaseHealth(math.huge)
-- because some branches of the health pipeline treat +inf as an arithmetic
-- NaN instead of clamping.
function M.heal_full()
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, HEALTH_ALIASES)
    if not comp then return false, alias end
    local ok_max, max_v = call_comp_method(comp, alias, "GetMaxHealth")
    if not ok_max then return false, max_v end
    local max_n = tonumber(max_v) or 100
    local ok, result = call_comp_method(comp, alias, "SetHealth", max_n, "rsdw.heal")
    if not ok then return false, result end
    return true, string.format("%.6g", max_n)
end

function M.damage_self(value_str)
    local n = parse_number(value_str) or 10
    if n < 0 then n = 0 end
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, HEALTH_ALIASES)
    if not comp then return false, alias end
    local ok, result = call_comp_method(comp, alias, "DecreaseHealth", n, "rsdw.damage_self")
    if not ok then return false, result end
    return true, string.format("-%.6g", n)
end

-- NOTE: M.set_max_health was removed on 2026-04-17 -- see
-- NOTES/cheats-to-revisit.md section 5. The player's MaxHealth is derived
-- from the attribute system (GE_ModifyMaxHealth gameplay effect chain), not
-- from UHealthComponent.MaxHealth. Writing the cached field succeeded but
-- the attribute system overwrote it each tick. Proper implementation needs
-- to apply GE_ModifyMaxHealth_C via BP_Components_PlayerGameplayEffects;
-- deferred until we do a gameplay-effects pass.

-- ---------- Movement (component-backed) ----------

function M.set_fall_immune(value_str)
    local b = parse_bool(value_str)
    if b == nil then return false, "expected on|off" end
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, MOVEMENT_ALIASES)
    if not comp then return false, alias end
    local ok, result = call_comp_method(comp, alias, "SetFallDamageImmune", b)
    if not ok then return false, result end
    return true, b and "on" or "off"
end

-- Generic numeric setter that writes a clamped float to a named field on
-- the movement component. Factored to keep set_walkspeed / set_jumpvel /
-- set_gravity / set_air_control / set_speedmult down to one line each.
local function set_movement_float(pawn, field, min_v, max_v, value_str)
    local n = parse_number(value_str)
    if not n then return false, field .. " must be a number" end
    if n < min_v then n = min_v end
    if n > max_v then n = max_v end
    local comp, alias = get_component(pawn, MOVEMENT_ALIASES)
    if not comp then return false, alias end
    return write_comp_field(comp, alias, field, n)
end

function M.set_walkspeed(value_str)
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    return set_movement_float(pawn, "MaxWalkSpeed", 0, 20000, value_str)
end

function M.set_jumpvel(value_str)
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    return set_movement_float(pawn, "JumpZVelocity", 0, 5000, value_str)
end

function M.set_gravity(value_str)
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    return set_movement_float(pawn, "GravityScale", -10, 10, value_str)
end

function M.set_air_control(value_str)
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    return set_movement_float(pawn, "AirControl", 0, 1, value_str)
end

-- MovementSpeedMultiplier lives on the Dominion (game-specific) subclass of
-- the movement component, not stock UCharacterMovementComponent. It feeds
-- into GetMaxSpeed() as a post-multiplier, so it stacks cleanly on top of
-- MaxWalkSpeed rather than replacing it.
function M.set_speed_mult(value_str)
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    return set_movement_float(pawn, "MovementSpeedMultiplier", 0.01, 20, value_str)
end

-- EMovementMode: None=0, Walking=1, NavWalking=2, Falling=3, Swimming=4,
-- Flying=5, Custom=6. Callers pass the word form; we translate. Swimming is
-- still in the table for completeness (the game exposes the enum even though
-- there's no actual swim implementation in Dragonwilds -- see
-- cheats-to-revisit.md section 6) but the UI no longer surfaces it.
local MOVEMENT_MODES = {
    none = 0, walk = 1, walking = 1, nav = 2, navwalking = 2,
    fall = 3, falling = 3, swim = 4, swimming = 4,
    fly = 5, flying = 5, custom = 6,
}

-- set_movement_mode ALWAYS normalizes the noclip-adjacent state before
-- applying the requested mode. Before round 6 this was a thin SetMovementMode
-- wrapper, which meant:
--   * noclip-on -> Default (walk)  left bCheatFlying=true + collision=off.
--     Result: walk mode with no collision, player fell through the floor or
--     read as "frozen in place" (no ground contact -> no walk velocity).
--   * noclip-on -> Fly             left collision=off. Result: Fly mode that
--     still behaved like noclip.
-- Fix: clear bCheatFlying and re-enable actor collision on every mode
-- transition here; M.set_noclip is the one path that intentionally overrides
-- those after-the-fact, so the normalization below is only visible to the
-- regular Default / Fly buttons.
function M.set_movement_mode(value_str)
    local key = tostring(value_str or ""):lower()
    local mode = MOVEMENT_MODES[key]
    if mode == nil then
        return false, "expected walk|fly|fall|custom|none"
    end
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, MOVEMENT_ALIASES)
    if not comp then return false, alias end

    -- Reset noclip leftovers. Swallow write/call failures silently: if the
    -- pawn never entered noclip these are effectively no-ops, and a failure
    -- here shouldn't block the user's mode change.
    pcall(function() comp.bCheatFlying = false end)
    pcall(function() pawn:SetActorEnableCollision(true) end)

    local ok, result = call_comp_method(comp, alias, "SetMovementMode", mode, 0)
    if not ok then return false, result end
    return true, key
end

-- Noclip = Flying mode + bCheatFlying + actor-level collision disabled.
--
-- Round 3 shipped just (bCheatFlying + SetMovementMode Flying) which turned
-- out to be indistinguishable from plain Fly in-game: the player could float
-- but still bounced off walls. The missing piece is AActor-level collision:
-- in stock UE the capsule sweep is what pushes characters out of walls, and
-- bCheatFlying only bypasses the sweep during PhysFlying's Acceleration.Z
-- handling, not during the capsule's own move. Calling
-- SetActorEnableCollision(false) disables the whole actor's collision
-- response so the player actually phases through geometry. Turning noclip
-- off restores collision + drops back to Walking.
--
-- Side-effect warning: with actor collision off the player also won't
-- trigger volumes (water, damage zones, doors). That's expected for noclip.
function M.set_noclip(value_str)
    local b = parse_bool(value_str)
    if b == nil then return false, "expected on|off" end
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, MOVEMENT_ALIASES)
    if not comp then return false, alias end

    -- Toggle the movement flag + mode via the component (order: set flag
    -- first so PhysFlying immediately picks up the new value).
    write_comp_field(comp, alias, "bCheatFlying", b)
    local mode = b and 5 or 1
    call_comp_method(comp, alias, "SetMovementMode", mode, 0)

    -- Toggle actor-level collision on the pawn itself. This is the step
    -- that actually produces noclip behavior; skipping it means the
    -- capsule keeps colliding and you just get fly mode.
    local ok_col, err_col = pcall(function()
        pawn:SetActorEnableCollision(not b)
    end)
    if not ok_col then
        print("[RSDWTools] noclip: SetActorEnableCollision failed: " .. tostring(err_col))
    else
        print(string.format("[RSDWTools] noclip=%s (collision=%s)", tostring(b), tostring(not b)))
    end
    return true, b and "on" or "off"
end

-- ---------- New movement sliders (round 4) ----------

function M.set_flyspeed(value_str)
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    return set_movement_float(pawn, "MaxFlySpeed", 0, 20000, value_str)
end

-- M.set_swimspeed was removed in round 5 -- swimming isn't a real state in
-- this game, MaxSwimSpeed has no observable effect. See
-- cheats-to-revisit.md section 6.

-- MaxAcceleration controls how quickly the player reaches MaxWalkSpeed; low
-- values feel like ice, high values feel like instant-on. Useful alongside
-- walkspeed for a "zoom" preset.
function M.set_acceleration(value_str)
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    return set_movement_float(pawn, "MaxAcceleration", 1, 100000, value_str)
end

-- ---------- Component readers (prime the UI) ----------

-- Read a simple field off a component. Mirrors read_simple_field, but takes
-- the component alias list so callers stay one-liners.
local function read_comp_field(aliases, field)
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, aliases)
    if not comp then return false, alias end
    local ok, val = pcall(function() return comp[field] end)
    if not ok then return false, "read failed: " .. tostring(val) end
    if val == nil then return false, "nil" end
    if type(val) == "number" then return true, string.format("%.6g", val) end
    if type(val) == "boolean" then return true, val and "true" or "false" end
    return true, tostring(val)
end

-- Read via method call (used for MaxHealth / Health since those are
-- recomputed from the attributes system and the raw field isn't live).
local function read_comp_call(aliases, method_name)
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, aliases)
    if not comp then return false, alias end
    local ok, val = call_comp_method(comp, alias, method_name)
    if not ok then return false, val end
    if type(val) == "number" then return true, string.format("%.6g", val) end
    return true, tostring(val)
end

function M.get_health()       return read_comp_call(HEALTH_ALIASES, "GetLocalHealth") end
function M.get_max_health()   return read_comp_call(HEALTH_ALIASES, "GetMaxHealth") end
function M.get_walkspeed()    return read_comp_field(MOVEMENT_ALIASES, "MaxWalkSpeed") end
function M.get_jumpvel()      return read_comp_field(MOVEMENT_ALIASES, "JumpZVelocity") end
function M.get_gravity()      return read_comp_field(MOVEMENT_ALIASES, "GravityScale") end
function M.get_air_control()  return read_comp_field(MOVEMENT_ALIASES, "AirControl") end
function M.get_speed_mult()   return read_comp_field(MOVEMENT_ALIASES, "MovementSpeedMultiplier") end
function M.get_flyspeed()     return read_comp_field(MOVEMENT_ALIASES, "MaxFlySpeed") end
function M.get_acceleration() return read_comp_field(MOVEMENT_ALIASES, "MaxAcceleration") end

-- ---------- Round 4: Survival stats / Stealth / Stamina / Sleep ----------
--
-- Survival stats (hydration, sustenance, endurance) and toxicity are all
-- simple replicated float fields on their respective components. Writing
-- to CurrentX directly takes effect immediately -- the OnRep_* handler
-- fires and propagates to the UI. Max values are attribute-driven (same
-- gameplay-effect pipeline that gates max health), so we only expose the
-- current-value setters; topping up = writing max as the new current.
--
-- Field / method names validated against
-- Dumps/ipc/components/{04_BP_HydrationComponent, 05_BP_SustenanceComponent,
-- 07_BP_EnduranceComponent, 06_BP_Components_Toxicity,
-- 51_BP_Components_PlayerStealth, 59_BP_Components_Stamina,
-- 36_BP_Components_Sleep}.json.

local HYDRATION_ALIASES  = { "BP_HydrationComponent",       "HydrationComponent" }
local SUSTENANCE_ALIASES = { "BP_SustenanceComponent",      "SustenanceComponent" }
local ENDURANCE_ALIASES  = { "BP_EnduranceComponent",       "EnduranceComponent" }
local TOXICITY_ALIASES   = { "BP_Components_Toxicity",      "ToxicityComponent" }
local STEALTH_ALIASES    = { "BP_Components_PlayerStealth", "PlayerStealthComponent" }
local STAMINA_ALIASES    = { "BP_Components_Stamina",       "StaminaComponent" }
local REST_ALIASES       = { "BP_Components_Sleep",         "BP_Components_Rest",
                             "PlayerRestComponent" }

-- Writes a clamped current-value onto a survival stat component.
-- Factored because hydration/sustenance/endurance all share the same
-- pattern (CurrentX is the writable, OnRep is automatic).
local function set_stat_current(aliases, field_name, min_v, max_v, value_str)
    local n = parse_number(value_str)
    if not n then return false, field_name .. " must be a number" end
    if n < min_v then n = min_v end
    if n > max_v then n = max_v end
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, aliases)
    if not comp then return false, alias end
    return write_comp_field(comp, alias, field_name, n)
end

function M.set_hydration(v)  return set_stat_current(HYDRATION_ALIASES,  "CurrentHydration",  0, 100000, v) end
function M.set_sustenance(v) return set_stat_current(SUSTENANCE_ALIASES, "CurrentSustenance", 0, 100000, v) end
function M.set_endurance(v)  return set_stat_current(ENDURANCE_ALIASES,  "CurrentEndurance",  0, 100000, v) end
function M.set_toxicity(v)   return set_stat_current(TOXICITY_ALIASES,   "CurrentToxicity",   0, 100000, v) end

-- DecayBuffer is the "free decay" pool drained before CurrentX itself
-- starts ticking down. Setting it to a huge number (100000) effectively
-- pauses decay for that survival stat indefinitely; the buffer drains at
-- DecayRatePerHour so 100000 / (default ~5) ~= 20000 game-hours.
-- Reuses set_stat_current for clamping/component lookup.
function M.set_hydration_decaybuffer(v)
    return set_stat_current(HYDRATION_ALIASES,  "DecayBuffer", 0, 100000, v)
end
function M.set_sustenance_decaybuffer(v)
    return set_stat_current(SUSTENANCE_ALIASES, "DecayBuffer", 0, 100000, v)
end
function M.set_endurance_decaybuffer(v)
    return set_stat_current(ENDURANCE_ALIASES,  "DecayBuffer", 0, 100000, v)
end

-- Top-up helpers: read GetMaxX (or the CurrentMaxX field), then write
-- that value back into CurrentX. Mirrors heal_full for health.
local function refill_stat(aliases, field_name, max_field_alt, max_getter)
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, aliases)
    if not comp then return false, alias end
    local max_n
    if max_getter then
        local ok, v = call_comp_method(comp, alias, max_getter)
        if ok and type(v) == "number" then max_n = v end
    end
    if not max_n and max_field_alt then
        local ok, v = pcall(function() return comp[max_field_alt] end)
        if ok and type(v) == "number" then max_n = v end
    end
    if not max_n then max_n = 100 end
    local ok_w, err = write_comp_field(comp, alias, field_name, max_n)
    if not ok_w then return false, err end
    return true, string.format("%.6g", max_n)
end

function M.refill_hydration()  return refill_stat(HYDRATION_ALIASES,  "CurrentHydration",  "CurrentMaxHydration",  "GetMaxHydration")  end
function M.refill_sustenance() return refill_stat(SUSTENANCE_ALIASES, "CurrentSustenance", "CurrentMaxSustenance", "GetMaxSustenance") end
function M.refill_endurance()  return refill_stat(ENDURANCE_ALIASES,  "CurrentEndurance",  nil,                    "GetMaxEndurance")  end

-- Clear toxicity entirely (Set to 0).
function M.clear_toxicity()
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, TOXICITY_ALIASES)
    if not comp then return false, alias end
    return write_comp_field(comp, alias, "CurrentToxicity", 0)
end

-- Stealth toggle via Multicast_EnterStealth / Multicast_ExitStealth. These
-- are server-multicast RPCs but in single-player we act as both server and
-- client, so the call goes through locally. Reads back IsInStealth for the
-- ack payload so the UI can keep its checkbox in sync with reality.
function M.set_stealth(value_str)
    local b = parse_bool(value_str)
    if b == nil then return false, "expected on|off" end
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, STEALTH_ALIASES)
    if not comp then return false, alias end
    local method = b and "Multicast_EnterStealth" or "Multicast_ExitStealth"
    local ok, result = call_comp_method(comp, alias, method)
    if not ok then return false, result end
    return true, b and "on" or "off"
end

-- Stamina refill: DecreaseStamina accepts negative amounts to add stamina.
-- We pass -GetMaxStamina() so the stamina pool always tops to full
-- regardless of current reading (DecreaseStamina clamps on the high end).
function M.refill_stamina()
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, STAMINA_ALIASES)
    if not comp then return false, alias end
    local ok_max, max_v = call_comp_method(comp, alias, "GetMaxStamina")
    local max_n = (ok_max and tonumber(max_v)) or 100
    local ok, result = call_comp_method(comp, alias, "DecreaseStamina", -max_n)
    if not ok then return false, result end
    call_comp_method(comp, alias, "ResetRegen")
    return true, string.format("+%.6g", max_n)
end

-- Wake up: Server_RequestWakeUp on the Rest/Sleep component. Useful if
-- the player is stuck in a sleep transition or the wake prompt failed to
-- appear. No-op if the player isn't actually sleeping.
function M.wake_up()
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, REST_ALIASES)
    if not comp then return false, alias end
    local ok, result = call_comp_method(comp, alias, "Server_RequestWakeUp")
    if not ok then return false, result end
    return true, "wake"
end

-- Readers for UI priming -------------------------------------------------

function M.get_hydration()   return read_comp_field(HYDRATION_ALIASES,  "CurrentHydration")  end
function M.get_sustenance()  return read_comp_field(SUSTENANCE_ALIASES, "CurrentSustenance") end
function M.get_endurance()   return read_comp_field(ENDURANCE_ALIASES,  "CurrentEndurance")  end
function M.get_toxicity()    return read_comp_field(TOXICITY_ALIASES,   "CurrentToxicity")   end
function M.get_stamina()     return read_comp_call(STAMINA_ALIASES,     "GetStamina")        end
function M.get_max_stamina() return read_comp_call(STAMINA_ALIASES,     "GetMaxStamina")     end
function M.get_stealth()     return read_comp_call(STEALTH_ALIASES,     "IsInStealth")       end

-- ---------- Teleport tweaks ----------
--
-- These fields live directly on the pawn (inherited from ADominionCharacterBase
-- or similar). Default values observed in the dump: LoadingScreenDelay=0.2,
-- BeginVFXDelay=3, Timeout=20. Setting any of them to 0 effectively skips
-- that stage of the teleport sequence.

function M.set_tp_loading_delay(value_str)
    local n = parse_number(value_str)
    if not n then return false, "delay must be a number" end
    if n < 0 then n = 0 end
    if n > 60 then n = 60 end
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    return write_field(pawn, "TeleportLoadingScreenDelay", n)
end

function M.set_tp_vfx_delay(value_str)
    local n = parse_number(value_str)
    if not n then return false, "delay must be a number" end
    if n < 0 then n = 0 end
    if n > 60 then n = 60 end
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    return write_field(pawn, "TeleportBeginVFXDelay", n)
end

function M.set_tp_timeout(value_str)
    local n = parse_number(value_str)
    if not n then return false, "timeout must be a number" end
    if n < 1 then n = 1 end
    if n > 600 then n = 600 end
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    return write_field(pawn, "TeleportTimeout", n)
end

-- ---------- Read helpers (used by the UI on first-open to prime controls) ----

-- Reads a simple field from the pawn. Returns a stringified value the WPF
-- side can parse. We stringify numeric values with a trailing decimal so
-- the UI's number parser never misinterprets an integer as a float-less
-- value (e.g. "1" vs "1.0" both parse fine, but "1" would be stored
-- without a decimal by ToString on some cultures; using invariant "%.6g"
-- on the Lua side means the ack is always culture-neutral).
local function read_simple_field(name)
    local pawn = get_pawn()
    if not pawn then return false, "no local pawn" end
    local ok, val = pcall(function() return pawn[name] end)
    if not ok then return false, "read failed: " .. tostring(val) end
    if val == nil then return false, "nil" end
    local t = type(val)
    if t == "number" then
        return true, string.format("%.6g", val)
    elseif t == "boolean" then
        return true, val and "true" or "false"
    end
    return true, tostring(val)
end

-- Expose individual readers so the router can bind them to short verbs.
-- Using a function-per-field (rather than a generic "read N") keeps the
-- router's verb surface explicit and lets us add per-field normalization
-- later without breaking wire compatibility.
function M.get_time_dilation()       return read_simple_field("CustomTimeDilation") end
function M.get_jump_count()           return read_simple_field("JumpMaxCount") end
function M.get_jump_hold()            return read_simple_field("JumpMaxHoldTime") end
function M.get_can_damage_buildings() return read_simple_field("bCanDamageBuildings") end
function M.get_tp_loading_delay()     return read_simple_field("TeleportLoadingScreenDelay") end
function M.get_tp_vfx_delay()         return read_simple_field("TeleportBeginVFXDelay") end
function M.get_tp_timeout()           return read_simple_field("TeleportTimeout") end

-- ===========================================================================
-- Round 5: Items / Interaction / Camera / Stealth-noise / Evade-surge
-- ===========================================================================
--
-- All of the component names + field / method signatures below are validated
-- against the dumps under Dumps/ipc/components/ (captured by the "Dump All
-- Components" tool). Each section cites the source dump so future editors can
-- confirm the wire contract without re-dumping.

-- Component aliases. Primary key first (BP_ override), stock UE class second
-- so we can still find the component on unmodded class layouts.
local DURABILITY_ALIASES  = { "BP_Components_ItemDurability", "ItemDurabilityComponent" }
local MAGNET_ALIASES      = { "BP_Components_ItemMagnet",     "ItemMagnet" }
local INTERACT_ALIASES    = { "BP_Components_InteractionDetector", "InteractableDetectorComponent" }
local NOISE_ALIASES       = { "BP_Components_NoiseEmitter",   "PlayerNoiseEmitterComponent",
                              "NoiseEmitterComponent" }
local EVADE_ALIASES       = { "BP_Components_Evade",          "PlayerEvadeComponent" }
-- Round 6 additions.
local BLOCKING_ALIASES    = { "BP_Components_PlayerBlocking", "PlayerBlockingComponent" }
local LOCKON_ALIASES      = { "BP_Components_LockOnTargeting", "LockOnTargetingComponent" }
-- Round 7 additions. (REST_ALIASES already defined up top for wake_up();
-- reuse it for WellRestedDurationSeconds writes below.)
local DAMAGE_ALIASES      = { "BP_Components_PlayerDamage",   "PlayerDamageComponent" }
local HITREACT_ALIASES    = { "BP_Components_PlayerHitReactions", "PlayerHitReactionsComponent",
                              "HitReactionsComponent" }
local RANGED_ALIASES      = { "BP_Components_PlayerRangedAttack", "PlayerRangedAttackComponent" }
-- Both magic components derive from UPlayerMagicComponent. We always write
-- to both so the toggle covers combat and utility spells uniformly.
local COMBAT_MAGIC_ALIASES  = { "BP_Components_PlayerCombatMagic",  "PlayerCombatMagicComponent" }
local UTILITY_MAGIC_ALIASES = { "BP_Components_PlayerUtilityMagic", "PlayerUtilityMagicComponent" }

-- ---------- Item durability (31_BP_Components_ItemDurability.json +
--            42_BP_Components_PlayerDamage.json) ---------------------------
--
-- Two independent sources of durability loss:
--   1. Wear-from-use: UItemDurabilityComponent.DurabilityLossRate (int32, =5).
--      Every swing / block / pickaxe strike multiplies its loss by this rate.
--      Zeroing it = no wear from using gear.
--   2. Wear-from-damage: UDamageComponent.DamagedByDurabilityMultiplier
--      (float, =1) on the player damage component. This scales equipment
--      durability loss when the PLAYER takes a hit (armor/weapon take damage
--      when you get hit). Zeroing it = armor never degrades from being hit.
-- Round 7 flips both together so "No Durability Loss" is a single truthful
-- checkbox. Previously we only wrote (1), which left gear degrading during
-- combat.

function M.set_no_durability_loss(value_str)
    local b = parse_bool(value_str)
    if b == nil then return false, "expected on|off" end
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end

    -- (1) Wear-from-use on the durability component.
    local comp1, alias1 = get_component(pawn, DURABILITY_ALIASES)
    if not comp1 then return false, alias1 end
    local rate = b and 0 or 5
    local ok1, err1 = write_comp_field(comp1, alias1, "DurabilityLossRate", rate)
    if not ok1 then return false, err1 end

    -- (2) Wear-from-damage on the player damage component. The multiplier
    -- lives on the UDamageComponent parent of BP_Components_PlayerDamage,
    -- so the alias list below finds the same component the damage pipeline
    -- checks. Not-fatal if this write fails (best-effort): some builds may
    -- strip the field and we still want (1) to land.
    local comp2, alias2 = get_component(pawn, DAMAGE_ALIASES)
    if comp2 then
        local mult = b and 0 or 1
        pcall(function() comp2.DamagedByDurabilityMultiplier = mult end)
        -- Ignore the alias unused-warning; write_comp_field would also work
        -- but we keep the direct write so a missing field doesn't abort the
        -- outer `return true` below.
        local _ = alias2
    end

    return true, b and "on" or "off"
end

function M.get_no_durability_loss()
    local ok, val = read_comp_field(DURABILITY_ALIASES, "DurabilityLossRate")
    if not ok then return false, val end
    -- Translate int rate back to on/off so the checkbox can prime correctly.
    local n = tonumber(val)
    if n == nil then return false, "not numeric" end
    return true, (n == 0) and "true" or "false"
end

-- Potion Slots removed in round 7.
--
-- Writing UPotionComponent.MaxPotionSlots did round-trip correctly (the field
-- accepted the new value and `player.get potion.slots` echoed it back) but
-- the actual consume-potion path in the game overwrites the single active
-- slot rather than appending to ActivePotionSlots, so drinking a new potion
-- visually replaces the previous buff regardless of the cap we set. We'd
-- need to patch the BP-level consume function to actually grow the array.
-- See NOTES/cheats-to-revisit.md section 8.

-- ---------- Item magnet (58_BP_Components_ItemMagnet.json) ----------
--
-- UItemMagnet.MagnetRange is a float radius. The component's only job is to
-- sweep for droppable items within that radius each tick and pull them to
-- the player -- so writing a bigger value means a bigger pickup bubble.
-- Default 350 (about two room-lengths), we cap the slider at 10000 which is
-- "pulls everything in a small village".

function M.set_magnet_range(value_str)
    local n = tonumber(value_str)
    if n == nil then return false, "expected number" end
    if n < 0 then n = 0 end
    if n > 10000 then n = 10000 end
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, MAGNET_ALIASES)
    if not comp then return false, alias end
    return write_comp_field(comp, alias, "MagnetRange", n)
end

function M.get_magnet_range() return read_comp_field(MAGNET_ALIASES, "MagnetRange") end

-- ---------- Interaction range -- DISABLED in round 6 -----------------------
--
-- Round 5 scaled DetectionRange / CharacterTraceDistance / CameraRayLength on
-- BP_Components_InteractionDetector. Verified in-game: that had no observable
-- effect on interaction distance. The real gate is
-- UInteractableDetectorComponent.InteractionRanges, a
-- TMap<EInteractionDistance, float>, which we don't have a clean way to
-- rewrite from Lua (UE4SS lacks TMap<enum, float> mutation helpers at the
-- script layer, and rebuilding the map wholesale risks corrupting keys).
--
-- The set_/get_interact_scale functions are removed. The slider + router
-- verb + XAML control were also removed in round 6. Documented in
-- NOTES/cheats-to-revisit.md section 7. If UE4SS grows better TMap tooling
-- we can revive this by writing InteractionRanges[<enum>] = base * scale for
-- each enum variant we care about.

-- ---------- FOV (APlayerController::FOV / APlayerCameraManager) ------------
--
-- Round 5 wrote FollowCamera.FieldOfView (via SetFieldOfView and field write
-- fallback). That didn't stick: in 39_BP_PlayerCameraController.json the
-- Dominion camera controller is driving the follow camera from a
-- UCameraProfile every tick (see its ZoomFactor / OffsetFactor / timeline
-- callbacks), so the per-frame profile apply overwrites any FOV we poked at
-- the camera component level.
--
-- Round 6 routes through APlayerController::FOV(NewFOV) instead (verified
-- present as method index 95 on ABP_PlayerController_C in
-- 67_PlayerController.json). That path writes DefaultFOV on the
-- PlayerCameraManager, which is applied AFTER the profile stage and so wins
-- the last-write race. Readback reads PlayerCameraManager.DefaultFOV
-- directly; if that's unavailable on a stripped build we fall back to the
-- follow camera's field so the slider still primes with something sensible
-- instead of erroring out.

local function get_player_controller(pawn)
    local ok, pc = pcall(function() return pawn:GetController() end)
    if ok and pc ~= nil then return pc end
    ok, pc = pcall(function() return pawn.Controller end)
    if ok and pc ~= nil then return pc end
    return nil
end

local function get_camera_manager(pawn)
    local pc = get_player_controller(pawn)
    if not pc then return nil end
    local ok, cm = pcall(function() return pc.PlayerCameraManager end)
    if ok and cm ~= nil then return cm end
    return nil
end

function M.set_fov(value_str)
    local n = tonumber(value_str)
    if n == nil then return false, "expected number" end
    if n < 30 then n = 30 end
    if n > 170 then n = 170 end
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end

    -- Primary path: PlayerController::FOV(NewFOV). This is the exec
    -- console command and winds up setting PlayerCameraManager.DefaultFOV
    -- which survives the camera profile update each tick.
    local pc = get_player_controller(pawn)
    if pc == nil then return false, "no player controller" end
    local ok = pcall(function() pc:FOV(n) end)
    if not ok then
        -- Fallback: write DefaultFOV on the camera manager directly.
        local cm = get_camera_manager(pawn)
        if cm == nil then return false, "FOV unavailable on this build" end
        local ok2, err2 = pcall(function() cm.DefaultFOV = n end)
        if not ok2 then return false, "FOV write failed: " .. tostring(err2) end
    end

    -- Also nudge the follow camera field so anything reading directly off
    -- the camera component (e.g. our own readback on stripped paths) sees
    -- the same value. Best-effort; ignore failures.
    pcall(function() pawn.FollowCamera.FieldOfView = n end)

    print(string.format("[RSDWTools] player.fov = %.1f", n))
    return true, string.format("%.1f", n)
end

function M.get_fov()
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    local cm = get_camera_manager(pawn)
    if cm ~= nil then
        local ok, val = pcall(function() return cm.DefaultFOV end)
        if ok and val ~= nil and type(val) == "number" and val > 0 then
            return true, string.format("%.6g", val)
        end
    end
    -- Fallback: the camera component's field. Useful when the manager
    -- hasn't been hit yet (fresh load, before our set_fov runs).
    local ok, cam = pcall(function() return pawn.FollowCamera end)
    if ok and cam ~= nil then
        local ok2, val = pcall(function() return cam.FieldOfView end)
        if ok2 and val ~= nil then return true, string.format("%.6g", val) end
    end
    return false, "FOV unavailable"
end

-- ---------- Silent / noise emitter (47_BP_Components_NoiseEmitter.json) -----
--
-- UNoiseEmitterComponent has four ENoisePreset fields (Stealth / Idle /
-- Walking / Sprinting). The enum appears to be: 0=Silent, 1=Quiet, 2=Normal,
-- 3=Loud (inferred from the vanilla values: Stealth=3 looks wrong at first
-- glance, but the "Stealth" here is the component-level *stealth-aware*
-- preset, not the stealth state itself). We don't need to know the exact
-- semantic of each value though -- setting all four to 0 kills any noise
-- the character broadcasts, which is what the cheat wants.

local NOISE_FIELDS = { "StealthLoudness", "IdleLoudness", "WalkingLoudness", "SprintingLoudness" }
local NOISE_DEFAULTS = { StealthLoudness=3, IdleLoudness=3, WalkingLoudness=1, SprintingLoudness=0 }

function M.set_silent(value_str)
    local b = parse_bool(value_str)
    if b == nil then return false, "expected on|off" end
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, NOISE_ALIASES)
    if not comp then return false, alias end
    for i = 1, #NOISE_FIELDS do
        local f = NOISE_FIELDS[i]
        local v = b and 0 or NOISE_DEFAULTS[f]
        local ok, err = write_comp_field(comp, alias, f, v)
        if not ok then return false, err end
    end
    return true, b and "on" or "off"
end

function M.get_silent()
    -- "Silent" means all four fields are 0. Any non-zero means off.
    local ok, val = read_comp_field(NOISE_ALIASES, "WalkingLoudness")
    if not ok then return false, val end
    local n = tonumber(val)
    if n == nil then return false, "not numeric" end
    return true, (n == 0) and "true" or "false"
end

-- ---------- Evade / surge (44_BP_Components_Evade.json) ---------------------
--
-- UPlayerEvadeComponent exposes a first-class `EnableSurge(bEnable: boolean)`
-- method. Surge is the "big-energy evade" state -- normally you get 3
-- uses before the effect expires, and SurgeEvadeStaminaMultiplier (0 by
-- default on this component) zeroes out the stamina cost per evade while
-- active. The usage cap is controlled by a writable int32 field:
--   SurgeEffectMaxUsages = 3
-- Round 5 only called EnableSurge(true), which honored that cap of 3.
-- Round 6 bumps the field to a large integer BEFORE enabling so the effect
-- grants effectively unlimited uses; disabling restores the stock 3 so the
-- game's UI counter / skill prompts don't break if the player toggles off.
-- Round 7 also bumps SurgeEffectDuration (float seconds, vanilla 120) so the
-- effect doesn't expire by timer either -- without this you'd get 9999 uses
-- but only for the first two minutes after toggling.
local SURGE_MAX_USAGES_DEFAULT   = 3
local SURGE_MAX_USAGES_UNLIMITED = 9999
local SURGE_DURATION_DEFAULT     = 120
local SURGE_DURATION_UNLIMITED   = 99999

function M.set_surge(value_str)
    local b = parse_bool(value_str)
    if b == nil then return false, "expected on|off" end
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, EVADE_ALIASES)
    if not comp then return false, alias end

    -- Order matters: write the cap AND the duration FIRST so EnableSurge(true)
    -- picks up the bumped values when it seeds the internal usage counter and
    -- starts the expiry timer. If duration isn't bumped, the effect expires
    -- by timer at 120s even with 9999 uses available.
    local cap = b and SURGE_MAX_USAGES_UNLIMITED or SURGE_MAX_USAGES_DEFAULT
    local dur = b and SURGE_DURATION_UNLIMITED   or SURGE_DURATION_DEFAULT
    pcall(function() comp.SurgeEffectMaxUsages = cap end)
    pcall(function() comp.SurgeEffectDuration  = dur end)

    local ok, result = call_comp_method(comp, alias, "EnableSurge", b)
    if not ok then return false, result end
    return true, b and "on" or "off"
end

function M.get_surge() return read_comp_field(EVADE_ALIASES, "bShouldShowSurgeFX") end

-- ===========================================================================
-- Round 6: Combat (parry window + block angle) and Targeting (lock-on range)
-- ===========================================================================

-- ---------- Parry / block (54_BP_Components_PlayerBlocking.json) -----------
--
-- UPlayerBlockingComponent fields (vanilla):
--   ParryWindowLength = 100  (milliseconds window for counting a block as a parry)
--   BlockingAngle     = 120  (degrees of front arc that qualify as "blocked")
-- Both are floats we can write directly; no attribute indirection.
-- ParryWindowLength is clamped to sensible values (1..60000) so a typo in the
-- UI doesn't turn parry into a never-closing window the game may not expect.

function M.set_parry_window(value_str)
    local n = tonumber(value_str)
    if n == nil then return false, "expected number" end
    if n < 1     then n = 1     end
    if n > 60000 then n = 60000 end
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, BLOCKING_ALIASES)
    if not comp then return false, alias end
    return write_comp_field(comp, alias, "ParryWindowLength", n)
end

function M.get_parry_window() return read_comp_field(BLOCKING_ALIASES, "ParryWindowLength") end

function M.set_block_angle(value_str)
    local n = tonumber(value_str)
    if n == nil then return false, "expected number" end
    if n < 1   then n = 1   end
    if n > 360 then n = 360 end
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, BLOCKING_ALIASES)
    if not comp then return false, alias end
    return write_comp_field(comp, alias, "BlockingAngle", n)
end

function M.get_block_angle() return read_comp_field(BLOCKING_ALIASES, "BlockingAngle") end

-- ---------- Lock-on range (02_BP_Components_LockOnTargeting.json) ----------
--
-- ULockOnTargetingComponent exposes four independent distance knobs. Rather
-- than exposing all four in the UI (overwhelming, and the ratios between
-- them are tuned), we take a single multiplier and scale each from its
-- vanilla baseline. That preserves the design intent (e.g. TraceRadius and
-- SphereOverlapRadius differ by 4x in vanilla) while letting the player
-- reach further or rein things in.
--
-- Vanilla values from the dump:
--   TraceRadius          = 500
--   TraceDistance        = 3000
--   MaxTargetDistance    = 3200
--   SphereOverlapRadius  = 2000
-- get_lockon_scale derives the current multiplier from MaxTargetDistance
-- (the most user-visible of the four), same trick we used for interact.

local LOCKON_DEFAULTS = {
    TraceRadius         = 500,
    TraceDistance       = 3000,
    MaxTargetDistance   = 3200,
    SphereOverlapRadius = 2000,
}

function M.set_lockon_scale(value_str)
    local n = tonumber(value_str)
    if n == nil then return false, "expected number" end
    if n < 0.1 then n = 0.1 end
    if n > 50  then n = 50  end
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, LOCKON_ALIASES)
    if not comp then return false, alias end
    for field, base in pairs(LOCKON_DEFAULTS) do
        local ok, err = write_comp_field(comp, alias, field, base * n)
        if not ok then return false, err end
    end
    return true, string.format("%.3g", n)
end

function M.get_lockon_scale()
    local ok, val = read_comp_field(LOCKON_ALIASES, "MaxTargetDistance")
    if not ok then return false, val end
    local n = tonumber(val)
    if n == nil then return false, "not numeric" end
    return true, string.format("%.3g", n / LOCKON_DEFAULTS.MaxTargetDistance)
end

-- ===========================================================================
-- Round 7: damage i-frames, rest duration, poise, ranged tuning, magic movement
-- ===========================================================================

-- ---------- Respawn invulnerability (42_BP_Components_PlayerDamage.json) ---
--
-- UPlayerDamageComponent.RespawnInvulnerabilityLength (float, vanilla 3). How
-- many seconds after respawn the player is immune to damage. Direct field
-- write; the damage pipeline reads it on each incoming hit.

function M.set_respawn_invul(value_str)
    local n = tonumber(value_str)
    if n == nil then return false, "expected number" end
    if n < 0   then n = 0   end
    if n > 600 then n = 600 end
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, DAMAGE_ALIASES)
    if not comp then return false, alias end
    return write_comp_field(comp, alias, "RespawnInvulnerabilityLength", n)
end

function M.get_respawn_invul() return read_comp_field(DAMAGE_ALIASES, "RespawnInvulnerabilityLength") end

-- ---------- Well Rested duration (36_BP_Components_Sleep.json) -------------
--
-- UPlayerRestComponent.WellRestedDurationSeconds (float, vanilla 180). The
-- component has to finish its rested-grant flow to apply it, so changing the
-- field mid-rest doesn't retroactively extend an already-running buff;
-- the next sleep cycle picks up the new value.

function M.set_well_rested(value_str)
    local n = tonumber(value_str)
    if n == nil then return false, "expected number" end
    if n < 0     then n = 0     end
    if n > 36000 then n = 36000 end
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, REST_ALIASES)
    if not comp then return false, alias end
    return write_comp_field(comp, alias, "WellRestedDurationSeconds", n)
end

function M.get_well_rested() return read_comp_field(REST_ALIASES, "WellRestedDurationSeconds") end

-- ---------- Poise / stagger resistance (52_BP_Components_PlayerHitReactions.json) --
--
-- UHitReactionsComponent has three float force thresholds that decide what
-- hit-reaction plays when something hits the player:
--   LightForceThreshold   = 150   -> below this, no reaction at all
--   HeavyForceThreshold   = 250   -> crossing this upgrades to a heavy stagger
--   KnockDownForceThreshold = 100000  -> crossing this is a knockdown
-- Pushing all three to 1e9 means nothing the AI throws at you crosses the
-- "play a stagger" threshold, so hits no longer interrupt your attack /
-- casting / sprint animations. Damage still lands -- this is purely about
-- the reaction animation, not mitigation.

local POISE_DEFAULTS    = { LightForceThreshold = 150, HeavyForceThreshold = 250, KnockDownForceThreshold = 100000 }
local POISE_UNBREAKABLE = 1e9

function M.set_poise(value_str)
    local b = parse_bool(value_str)
    if b == nil then return false, "expected on|off" end
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, HITREACT_ALIASES)
    if not comp then return false, alias end
    for field, base in pairs(POISE_DEFAULTS) do
        local v = b and POISE_UNBREAKABLE or base
        local ok, err = write_comp_field(comp, alias, field, v)
        if not ok then return false, err end
    end
    return true, b and "on" or "off"
end

function M.get_poise()
    local ok, val = read_comp_field(HITREACT_ALIASES, "LightForceThreshold")
    if not ok then return false, val end
    local n = tonumber(val)
    if n == nil then return false, "not numeric" end
    -- Any value well above vanilla means poise is on. We check >= 1e6 to be
    -- tolerant of rounding when the field round-trips through floats.
    return true, (n >= 1e6) and "true" or "false"
end

-- ---------- Ranged tuning (41_BP_Components_PlayerRangedAttack.json) -------
--
-- Two independent toggles on UPlayerRangedAttackComponent:
--   Perfect Aim:   BaseInaccuracy (4)    -> 0
--                  MinimumInaccuracy (0) -> 0   (already 0, but we still
--                                                assert to survive any
--                                                mid-session field reset)
--   Instant Draw:  PreChargeUpDuration (1)  -> 0
--                  ChargeUpDuration (1)      -> 0
-- GetCurrentArrowInaccuracy() / GetChargeUpProgressNormalized() derive from
-- these, so writing the fields flows through all downstream math without any
-- further mutation needed.

local PERFECT_AIM_DEFAULTS = { BaseInaccuracy = 4, MinimumInaccuracy = 0 }

function M.set_perfect_aim(value_str)
    local b = parse_bool(value_str)
    if b == nil then return false, "expected on|off" end
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, RANGED_ALIASES)
    if not comp then return false, alias end
    for field, base in pairs(PERFECT_AIM_DEFAULTS) do
        local v = b and 0 or base
        local ok, err = write_comp_field(comp, alias, field, v)
        if not ok then return false, err end
    end
    return true, b and "on" or "off"
end

function M.get_perfect_aim()
    local ok, val = read_comp_field(RANGED_ALIASES, "BaseInaccuracy")
    if not ok then return false, val end
    local n = tonumber(val)
    if n == nil then return false, "not numeric" end
    return true, (n == 0) and "true" or "false"
end

-- Instant Draw + Cast While Moving were removed in round 8 after testing
-- showed the component-level fields don't actually gate the behavior:
--   * Instant Draw:  zeroing PreChargeUpDuration / ChargeUpDuration sped up
--     the "ready" meter but the damage-vs-draw-time curve is baked into the
--     per-weapon PlayerRangedAttackData asset (TirednessNormalizedCurve /
--     bow-specific damage curve), so short-draw shots still landed reduced
--     damage. Editing UCurveFloat keys through UE4SS reflection isn't
--     straightforward. See NOTES/cheats-to-revisit.md section 9.
--   * Cast While Moving: flipping bShouldBlockMovement on both magic
--     components had no visible effect -- the spell-cast montages have
--     Root Motion Enabled on the anim-montage asset itself, which locks
--     movement regardless of the component flag. See section 10.
-- The aliases COMBAT_MAGIC_ALIASES / UTILITY_MAGIC_ALIASES are kept at the
-- top of the file in case we come back to spell tweaks later.

-- The four Round 8 cheats (Always Sprint, Environmental Immunity, Melee Aim
-- Assist, Input Buffer) were removed after in-game testing showed no
-- observable effect despite component writes landing cleanly. Each one is
-- either gated by secondary systems (gameplay effects, root motion, stamina
-- regen) that override the raw component fields, or exposes an effect too
-- subtle to verify by feel. Going forward the same outcomes are reachable
-- through the Gameplay Effect system (UDominionGameplayEffectsComponent ->
-- ApplyGameplayEffect / RemoveGameplayEffect), which is the path the game
-- itself uses for every attribute mutation. See NOTES/cheats-to-revisit.md
-- section 11 for the per-cheat write-ups.

-- ===========================================================================
-- ROUND 11: new-capability cheats
-- ===========================================================================
-- After Round 10's GE experiment produced zero visible changes (see
-- cheats-to-revisit.md section 12), the strategy pivoted: skip GE, stay on
-- direct component-field writes, and only ship cheats that open a NEW
-- capability category (mounts, abilities, harvest, spectator) rather than
-- yet another way to express "I can't die". Every field / method / default
-- below was validated against its Dumps/ipc/components/*.json dump.

-- ---------- Mounts (01_BP_MountComponent.json) -----------------------------
-- UDominionMountComponent exposes per-mount unlocks via UnlockedFlags (uint32
-- bitmask) plus a convenience method SetAllMountsUnlocked(bool) that flips
-- all bits at once. Defaults on a clean save: UnlockedFlags=3 (first two
-- mounts unlocked), bDamageForcesDismount=true, bIgnoreSurvivalDamage=true.
-- Mount-invincible = set bDamageForcesDismount=false; bIgnoreSurvivalDamage
-- is already true by default so writing it is a defensive no-op that keeps
-- the cheat idempotent if the game patch ever flips it.

local MOUNT_ALIASES = { "BP_MountComponent", "DominionMountComponent" }

-- Baseline UnlockedFlags from a fresh character -- we restore this on "off".
-- If the user's actual save has a different value (they've already unlocked
-- more mounts through normal play), their real progress is still remembered
-- by the save system on next load; we only overwrite the live runtime field.
local MOUNT_UNLOCKED_BASELINE = 3

function M.unlock_all_mounts(value_str)
    -- One-shot action when called with no arg; toggle semantics when "on"/"off"
    -- is supplied (matches the rest of the module so the UI can treat it as
    -- a checkbox if we ever want to).
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, MOUNT_ALIASES)
    if not comp then return false, alias end
    local b = parse_bool(value_str)
    if b == nil then b = true end -- default: unlock
    local ok, err = call_comp_method(comp, alias, "SetAllMountsUnlocked", b and true or false)
    if not ok then return false, err end
    return true, b and "on" or "off"
end

function M.get_mounts_unlocked()
    -- "true" when every bit we expect the full catalog to occupy is set.
    -- We don't know the real bit count, so we use "UnlockedFlags != baseline"
    -- as a rough indicator. Good enough for a UI checkbox state probe.
    local ok, val = read_comp_field(MOUNT_ALIASES, "UnlockedFlags")
    if not ok then return false, val end
    local n = tonumber(val); if n == nil then return false, "not numeric" end
    return true, (n > MOUNT_UNLOCKED_BASELINE) and "true" or "false"
end

-- Mount-invincible: stay on the mount through hits + survival tick damage.
local MOUNT_INVINCIBLE_DEFAULTS = {
    bDamageForcesDismount = true,  -- default true  -> flip to false when on
    bIgnoreSurvivalDamage = true,  -- default true  -> redundant but safe
}

function M.set_mount_invincible(value_str)
    local b = parse_bool(value_str)
    if b == nil then return false, "expected on|off" end
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, MOUNT_ALIASES)
    if not comp then return false, alias end
    -- When on: force both flags into "no dismount / no survival tick" state.
    -- When off: restore dump-captured defaults.
    local target = {
        bDamageForcesDismount = b and false or MOUNT_INVINCIBLE_DEFAULTS.bDamageForcesDismount,
        bIgnoreSurvivalDamage = b and true  or MOUNT_INVINCIBLE_DEFAULTS.bIgnoreSurvivalDamage,
    }
    for field, v in pairs(target) do
        local ok, err = write_comp_field(comp, alias, field, v)
        if not ok then return false, err end
    end
    return true, b and "on" or "off"
end

function M.get_mount_invincible()
    local ok, val = read_comp_field(MOUNT_ALIASES, "bDamageForcesDismount")
    if not ok then return false, val end
    -- Cheat is "on" when we've *disabled* damage-forces-dismount.
    local is_on = (val == "false" or val == false)
    return true, is_on and "true" or "false"
end

-- ---------- Critical hit chance removed in round 11.5 --------------------
-- Direct write to UCriticalHitComponent.HeldEquipmentCriticalHitChance had
-- no observable in-game effect (slider at 1.0 = "always crit" still produced
-- vanilla-rate crits). The Round 10 GE attempt (UGE_CriticalHitChance*)
-- couldn't drive it either, so the crit system is gated behind a path we
-- haven't found yet. See cheats-to-revisit.md section 13.

-- ---------- Aim pitch unlock (41_BP_Components_PlayerRangedAttack.json) ----
-- The four pitch fields on UPlayerRangedAttackComponent:
--   MaxPitchAngleWhenAiming    =  90  (default already max-up; untouched)
--   MinPitchAngleWhenAiming    = -65  (game clamps aim-down to 65 deg; lift to -90)
--   TargetMaxPitchAngle        =  90
--   TargetMinPitchAngle        = -90
-- Only the *aiming* min is restricted by default. The "target" fields are
-- already full range. We widen the aiming min and assert the others so a
-- mid-session patch tweak doesn't silently re-clamp us.

local AIMPITCH_DEFAULTS = {
    MaxPitchAngleWhenAiming = 90,
    MinPitchAngleWhenAiming = -65,
    TargetMaxPitchAngle     = 90,
    TargetMinPitchAngle     = -90,
}
local AIMPITCH_UNLOCKED = {
    MaxPitchAngleWhenAiming = 90,
    MinPitchAngleWhenAiming = -90,
    TargetMaxPitchAngle     = 90,
    TargetMinPitchAngle     = -90,
}

function M.set_aim_pitch_unlock(value_str)
    local b = parse_bool(value_str)
    if b == nil then return false, "expected on|off" end
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, RANGED_ALIASES)
    if not comp then return false, alias end
    local table_to_use = b and AIMPITCH_UNLOCKED or AIMPITCH_DEFAULTS
    for field, v in pairs(table_to_use) do
        local ok, err = write_comp_field(comp, alias, field, v)
        if not ok then return false, err end
    end
    return true, b and "on" or "off"
end

function M.get_aim_pitch_unlock()
    local ok, val = read_comp_field(RANGED_ALIASES, "MinPitchAngleWhenAiming")
    if not ok then return false, val end
    local n = tonumber(val); if n == nil then return false, "not numeric" end
    -- "on" when we've pushed below default -65. Tolerance for float round-trip.
    return true, (n <= -89.5) and "true" or "false"
end

-- ---------- Arrow trace distance (41_BP_Components_PlayerRangedAttack.json)-
-- MaxProjectileTraceDistance = 5000 (cm, so 50 m at default). This controls
-- how far the aim trace reaches when the game resolves which actor the
-- arrow is visually pointing at; boosting it extends reliable far-shot
-- targeting. Clamp to [1000, 100000] = 10m..1km.

function M.set_arrow_range(value_str)
    local n = parse_number(value_str)
    if not n then return false, "expected number" end
    if n < 1000   then n = 1000   end
    if n > 100000 then n = 100000 end
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, RANGED_ALIASES)
    if not comp then return false, alias end
    return write_comp_field(comp, alias, "MaxProjectileTraceDistance", n)
end

function M.get_arrow_range() return read_comp_field(RANGED_ALIASES, "MaxProjectileTraceDistance") end

-- ---------- Self-revive delay (43_BP_Components_PlayerRespawn.json) --------
-- UPlayerRespawnComponent.SelfReviveDelay = 6 (seconds; dumped default).
-- Setting to 0 makes self-revive instantaneous. Distinct from respawninvul
-- which is the post-revive immunity window.

local RESPAWN_CHEAT_ALIASES = { "BP_Components_PlayerRespawn", "PlayerRespawnComponent" }

function M.set_revive_delay(value_str)
    local n = parse_number(value_str)
    if not n then return false, "expected number" end
    -- Min clamped to 2: 0 = player never revives, 1 = character stays invisible
    -- after revive. 2s is the lowest value that actually works in-game. The UI
    -- slider enforces the same minimum but we clamp here too in case the verb
    -- is dispatched with a bad value from elsewhere.
    if n < 2  then n = 2  end
    if n > 60 then n = 60 end
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    local comp, alias = get_component(pawn, RESPAWN_CHEAT_ALIASES)
    if not comp then return false, alias end
    return write_comp_field(comp, alias, "SelfReviveDelay", n)
end

function M.get_revive_delay() return read_comp_field(RESPAWN_CHEAT_ALIASES, "SelfReviveDelay") end

-- ---------- Foliage range removed in round 11.5 --------------------------
-- UNearbyFoliageConverterComponent.Range writes took no observable effect
-- (tested 300 -> 3000 cm, no additional foliage became harvestable from a
-- standing position). Confirms this is the render-LOD aura we suspected,
-- not the gameplay harvest aura. See cheats-to-revisit.md section 14.

-- ---------- Cancel current spell (one-shot) --------------------------------
-- UPlayerMagicComponent exposes Server_CancelSpell() on both the combat
-- magic and utility magic components. We fire both so the button works
-- regardless of which subsystem is mid-cast. Failures are not fatal: if
-- the player isn't casting anything, the RPC just no-ops.

function M.cancel_spell()
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    local fired = 0
    for _, aliases in ipairs({ COMBAT_MAGIC_ALIASES, UTILITY_MAGIC_ALIASES }) do
        local comp, alias = get_component(pawn, aliases)
        if comp then
            local ok, _ = call_comp_method(comp, alias, "Server_CancelSpell")
            if ok then fired = fired + 1 end
        end
    end
    if fired == 0 then return false, "no magic component resolved" end
    return true, tostring(fired) .. " cancel(s) dispatched"
end

-- Round 12 rollback: the three UDominionCheatManager spell wrappers
-- (set_no_magic_cost / set_no_utility_cooldown / unlock_all_spells) and
-- the bCorruptionShotUnlockedSimProxy toggle were removed. Every dom*
-- cheat no-ops in the shipping build and the sim-proxy flag write got
-- stomped by server replication. See NOTES/cheats-to-revisit.md §16.
-- Round 13 rebuilds spell cheats one at a time, starting from the
-- concrete UUtilitySpellData / AUtilitySpell fields instead.

-- ---------- Round 13: global UUtilitySpellData field writes ----------------
-- Access path (confirmed by player.dump.spells probe):
--   pawn.PlayerController  ->  ADominionPlayerController
--   pc.SpellcastingComponent (alias "SpellcastingComponent")
--                          ->  UBP_Components_Spellcasting_C
--   sc.SelectedSpells      ->  TArray<UUtilitySpellData*> (47 slots, some empty)
--
-- Every real spell has bNeedsUnlocking=true and a CooldownDuration > 0.
-- Empty/null slots have bNeedsUnlocking=false and CooldownDuration=0 --
-- we cache-and-restore per slot so they are round-tripped harmlessly.
--
-- Thread note: these run on the game thread (router's responsibility).
-- Direct field writes on UDataAsset instances are safe from Lua.

local SPELLCASTING_COMP_ALIASES = {
    "SpellcastingComponent",
    "BP_Components_SpellcastingComponent",
    "BP_Components_Spellcasting",
}

-- Per-toggle caches: slot_index -> original value before we wrote.
-- Reset to {} when the toggle is turned off.
--
-- Round 13.5 fixes (validated by player.dump.spellmodules probe):
--   * the entry validity guard MUST NOT call feature_actor.is_valid_object()
--     -- that wraps obj:IsValid() which is true only for AActor-derived
--     instances. UUtilitySpellData inherits from UDataAsset, so IsValid()
--     returns false on every entry and we wrote 0/48 slots last round.
--     The probe's `type(entry) == "userdata"` guard worked for all 30 live
--     slots; we mirror that here.
--   * bNeedsUnlocking on the data asset is a design-time hint, not the
--     runtime gate. The real gate is ProgressComponent.SpellsUnlocked
--     (TSet<UUtilitySpellData*>). On unlock we now ALSO insert each spell
--     data into that TSet via :Add(), and remember which entries we added
--     so off can :Remove() exactly what we put in.
local _spell_unlock_cache = {}    -- bNeedsUnlocking originals (per slot)
local _spell_cd_cache     = {}    -- CooldownDuration originals (per slot)
local _spell_cont_cache   = {}    -- bContinuouslyCast originals (per slot)
local _spell_unlock_added = {}    -- list of UUtilitySpellData userdatas we
                                  -- inserted into SpellsUnlocked TSet, so we
                                  -- can :Remove() them on toggle-off.

-- Reach through pawn -> PlayerController -> SpellcastingComponent.
-- Returns (component, alias_name, player_controller). PC is returned so the
-- spell-unlock path can also reach pc.ProgressComponent.SpellsUnlocked.
local function get_spellcasting_component(pawn)
    local pc = nil
    -- ADominionPlayerCharacter exposes PlayerController as a named field.
    local ok, p = pcall(function() return pawn.PlayerController end)
    if ok and type(p) == "userdata" and feature_actor.is_valid_object(p) then
        pc = p
    end
    if not pc then
        -- Fallback: stock ACharacter::Controller.
        local ok2, p2 = pcall(function() return pawn.Controller end)
        if ok2 and type(p2) == "userdata" and feature_actor.is_valid_object(p2) then
            pc = p2
        end
    end
    if not pc then return nil, "no PlayerController on pawn" end
    for _, alias in ipairs(SPELLCASTING_COMP_ALIASES) do
        local ok_c, comp = pcall(function() return pc[alias] end)
        if ok_c and type(comp) == "userdata" and feature_actor.is_valid_object(comp) then
            return comp, alias, pc
        end
    end
    return nil, "no SpellcastingComponent on PlayerController"
end

-- player.spells.unlock <on|off>
-- on:  for every live UUtilitySpellData in SelectedSpells:
--        (a) write bNeedsUnlocking=false on the data asset (cosmetic / UI hint),
--        (b) insert it into pc.ProgressComponent.SpellsUnlocked TSet (the
--            real runtime gate the cast code checks against).
-- off: restores cached bNeedsUnlocking originals AND removes from the TSet
--      every entry we added (we don't touch entries that were already in the
--      set when we toggled on -- those were unlocked legitimately).
function M.set_spells_unlock(value_str)
    local b = parse_bool(value_str)
    if b == nil then return false, "expected on|off" end
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    local sc, sc_err, pc = get_spellcasting_component(pawn)
    if not sc then return false, sc_err end

    local ok_sel, selected = pcall(function() return sc.SelectedSpells end)
    if not ok_sel or not selected then return false, "SelectedSpells unreadable" end
    local ok_n, n = pcall(function() return #selected end)
    if not ok_n or type(n) ~= "number" then return false, "SelectedSpells len unreadable" end

    -- ProgressComponent.SpellsUnlocked TSet -- best-effort, not required for
    -- the bNeedsUnlocking write to succeed.
    local sunlocked = nil
    if pc then
        local prok, prog = pcall(function() return pc.ProgressComponent end)
        if prok and type(prog) == "userdata" then
            local sok, su = pcall(function() return prog.SpellsUnlocked end)
            if sok and type(su) == "userdata" then sunlocked = su end
        end
    end

    local written, errs, set_added, set_removed = 0, 0, 0, 0
    if b then
        _spell_unlock_cache = {}
        _spell_unlock_added = {}
        for i = 1, n do
            local eok, entry = pcall(function() return selected[i] end)
            -- Loose guard: UUtilitySpellData is a UDataAsset, not an AActor,
            -- so feature_actor.is_valid_object() (which calls IsValid())
            -- returns false on every entry. Userdata + non-nil is enough --
            -- the dump_spellmodules probe uses the same guard and reads all
            -- 30 live slots cleanly.
            if eok and entry ~= nil and type(entry) == "userdata" then
                local rok, orig = pcall(function() return entry.bNeedsUnlocking end)
                _spell_unlock_cache[i] = (rok and orig) or true
                local wok = pcall(function() entry.bNeedsUnlocking = false end)
                if wok then written = written + 1 else errs = errs + 1 end

                -- TSet:Add() is idempotent -- inserting a userdata that's
                -- already in the set is a no-op. We only record an "added"
                -- entry if it wasn't already there, so toggle-off stays clean.
                if sunlocked then
                    local already = false
                    local cok, hit = pcall(function()
                        if sunlocked.Contains then return sunlocked:Contains(entry) end
                        return false
                    end)
                    if cok and hit == true then already = true end
                    if not already then
                        local aok = pcall(function() sunlocked:Add(entry) end)
                        if aok then
                            set_added = set_added + 1
                            _spell_unlock_added[#_spell_unlock_added + 1] = entry
                        end
                    end
                end
            end
        end
    else
        for i = 1, n do
            local eok, entry = pcall(function() return selected[i] end)
            if eok and entry ~= nil and type(entry) == "userdata" then
                local orig = _spell_unlock_cache[i]
                if orig ~= nil then
                    local wok = pcall(function() entry.bNeedsUnlocking = orig end)
                    if wok then written = written + 1 else errs = errs + 1 end
                end
            end
        end
        if sunlocked then
            for _, entry in ipairs(_spell_unlock_added) do
                if type(entry) == "userdata" then
                    local rok = pcall(function()
                        if sunlocked.Remove then sunlocked:Remove(entry) end
                    end)
                    if rok then set_removed = set_removed + 1 end
                end
            end
        end
        _spell_unlock_cache = {}
        _spell_unlock_added = {}
    end
    return true, string.format("%s %d/%d (TSet %s %d)",
        b and "unlocked" or "relocked", written, n,
        b and "added" or "removed",
        b and set_added or set_removed)
end

-- player.spells.zerocooldown <on|off>
-- on:  caches original CooldownDuration per slot, writes 0 on every entry.
-- off: restores cached originals.
function M.set_spells_zerocooldown(value_str)
    local b = parse_bool(value_str)
    if b == nil then return false, "expected on|off" end
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    local sc, sc_err = get_spellcasting_component(pawn)
    if not sc then return false, sc_err end

    local ok_sel, selected = pcall(function() return sc.SelectedSpells end)
    if not ok_sel or not selected then return false, "SelectedSpells unreadable" end
    local ok_n, n = pcall(function() return #selected end)
    if not ok_n or type(n) ~= "number" then return false, "SelectedSpells len unreadable" end

    local written, errs = 0, 0
    if b then
        _spell_cd_cache = {}
        for i = 1, n do
            local eok, entry = pcall(function() return selected[i] end)
            -- Loose guard (see set_spells_unlock for rationale).
            if eok and entry ~= nil and type(entry) == "userdata" then
                local rok, orig = pcall(function() return entry.CooldownDuration end)
                _spell_cd_cache[i] = (rok and type(orig) == "number") and orig or 0
                local wok = pcall(function() entry.CooldownDuration = 0 end)
                if wok then written = written + 1 else errs = errs + 1 end
            end
        end
    else
        for i = 1, n do
            local eok, entry = pcall(function() return selected[i] end)
            if eok and entry ~= nil and type(entry) == "userdata" then
                local orig = _spell_cd_cache[i]
                if orig ~= nil then
                    local wok = pcall(function() entry.CooldownDuration = orig end)
                    if wok then written = written + 1 else errs = errs + 1 end
                end
            end
        end
        _spell_cd_cache = {}
    end
    return true, string.format("%s %d/%d spells (%d errs)",
        b and "zeroed" or "restored", written, n, errs)
end

-- player.spells.continuouscast <on|off>  (EXPERIMENTAL)
-- bContinuouslyCast is a parent-class boolean that ships false on every
-- spell. The hypothesis is that flipping it makes a spell auto-recast as
-- soon as its cooldown elapses (or even tick-rate, for buff-style spells)
-- -- think permanent Tempest Shield / Enchant Weapon. Behaviour on
-- placement spells (Rocksplosion, Splinter, Summon Shelter) is unknown and
-- could spam the world. Toggle-off restores per-slot originals.
function M.set_spells_continuouscast(value_str)
    local b = parse_bool(value_str)
    if b == nil then return false, "expected on|off" end
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    local sc, sc_err = get_spellcasting_component(pawn)
    if not sc then return false, sc_err end

    local ok_sel, selected = pcall(function() return sc.SelectedSpells end)
    if not ok_sel or not selected then return false, "SelectedSpells unreadable" end
    local ok_n, n = pcall(function() return #selected end)
    if not ok_n or type(n) ~= "number" then return false, "SelectedSpells len unreadable" end

    local written, errs = 0, 0
    if b then
        _spell_cont_cache = {}
        for i = 1, n do
            local eok, entry = pcall(function() return selected[i] end)
            if eok and entry ~= nil and type(entry) == "userdata" then
                local rok, orig = pcall(function() return entry.bContinuouslyCast end)
                _spell_cont_cache[i] = (rok and type(orig) == "boolean") and orig or false
                local wok = pcall(function() entry.bContinuouslyCast = true end)
                if wok then written = written + 1 else errs = errs + 1 end
            end
        end
    else
        for i = 1, n do
            local eok, entry = pcall(function() return selected[i] end)
            if eok and entry ~= nil and type(entry) == "userdata" then
                local orig = _spell_cont_cache[i]
                if orig ~= nil then
                    local wok = pcall(function() entry.bContinuouslyCast = orig end)
                    if wok then written = written + 1 else errs = errs + 1 end
                end
            end
        end
        _spell_cont_cache = {}
    end
    return true, string.format("%s %d/%d spells (%d errs)",
        b and "continuous" or "restored", written, n, errs)
end

-- ============================================================
-- Phase 2: Camera + UI tooling.
--
-- Generic component-field cheat. The WPF sends:
--   player.comp.set <Alias> <Field> <value>
-- and we resolve <Alias> via this lookup chain:
--   1. COMP_ALIAS_MAP (short tokens -> get_component(pawn, ...))
--   2. ROOT_ALIAS_MAP (special tokens for objects that aren't pawn
--      attributes: PC -> player controller, HUD -> pc.MyHUD,
--      CameraManager -> pc.PlayerCameraManager).
--   3. pawn[<Alias>]   (covers FollowCamera, CameraBoom, etc.)
--   4. pc[<Alias>]     (covers any PC sub-component)
--   5. get_component(pawn, { <Alias> }) as a last resort.
--
-- value is auto-parsed: bool first (on/off/true/false), then number.
-- ============================================================

local COMP_ALIAS_MAP = {
    boom        = { "CameraBoom" },
    springarm   = { "CameraBoom" },
    camera      = { "FollowCamera" },
    followcamera= { "FollowCamera" },
}

-- Special root resolvers. Return the actual UObject to write fields on.
local function _root_pc(pawn)         return get_player_controller(pawn) end
local function _root_hud(pawn)
    local pc = get_player_controller(pawn); if not pc then return nil end
    local ok, hud = pcall(function() return pc.MyHUD end)
    if ok then return hud end
    return nil
end
local function _root_camera_manager(pawn)
    local pc = get_player_controller(pawn); if not pc then return nil end
    local ok, cm = pcall(function() return pc.PlayerCameraManager end)
    if ok then return cm end
    return nil
end

local ROOT_ALIAS_MAP = {
    pc                = _root_pc,
    playercontroller  = _root_pc,
    hud               = _root_hud,
    myhud             = _root_hud,
    cameramanager     = _root_camera_manager,
    playercameramanager = _root_camera_manager,
}

local function resolve_component(pawn, alias_token)
    local key = alias_token:lower()
    local root_fn = ROOT_ALIAS_MAP[key]
    if root_fn then
        local r = root_fn(pawn)
        if r ~= nil then return r end
    end
    local mapped = COMP_ALIAS_MAP[key]
    if mapped then
        local comp = get_component(pawn, mapped)
        if comp then return comp end
    end
    -- Direct attribute on the pawn.
    local ok, c = pcall(function() return pawn[alias_token] end)
    if ok and c ~= nil then return c end
    -- Try the player controller.
    local pc = get_player_controller(pawn)
    if pc then
        local ok2, c2 = pcall(function() return pc[alias_token] end)
        if ok2 and c2 ~= nil then return c2 end
    end
    -- Last resort: get_component on the raw token.
    return get_component(pawn, { alias_token })
end

-- player.comp.set <Alias> <Field> <value>
function M.comp_set(args_str)
    if not args_str or args_str == "" then
        return false, "usage: player.comp.set <Alias> <Field> <value>"
    end
    local alias, field, value = args_str:match("^(%S+)%s+(%S+)%s+(.+)$")
    if not (alias and field and value) then
        return false, "usage: player.comp.set <Alias> <Field> <value>"
    end
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    local comp = resolve_component(pawn, alias)
    if not comp then return false, "target not found: " .. alias end

    local b = parse_bool(value)
    if b ~= nil then
        local wok, werr = pcall(function() comp[field] = b end)
        if not wok then return false, field .. " bool write failed: " .. tostring(werr) end
        return true, alias .. "." .. field .. " = " .. tostring(b)
    end
    local n = parse_number(value)
    if n then
        local wok, werr = pcall(function() comp[field] = n end)
        if not wok then return false, field .. " float write failed: " .. tostring(werr) end
        return true, string.format("%s.%s = %.6g", alias, field, n)
    end
    return false, "value must be number or on|off"
end

-- player.comp.get <Alias> <Field>
function M.comp_get(args_str)
    if not args_str or args_str == "" then
        return false, "usage: player.comp.get <Alias> <Field>"
    end
    local alias, field = args_str:match("^(%S+)%s+(%S+)%s*$")
    if not (alias and field) then
        return false, "usage: player.comp.get <Alias> <Field>"
    end
    local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
    local comp = resolve_component(pawn, alias)
    if not comp then return false, "target not found: " .. alias end
    local ok, v = pcall(function() return comp[field] end)
    if not ok then return false, field .. " read failed" end
    if v == nil then return false, field .. " is nil" end
    if type(v) == "boolean" then return true, v and "true" or "false" end
    if type(v) == "number" then return true, string.format("%.6g", v) end
    return true, tostring(v)
end

-- Round 53 fix: Summon via the engine console exec instead of a direct
-- reflection call to UCheatManager::Summon. The reflection path takes the
-- short or long class path string and ultimately calls LoadObject<UClass>,
-- which fails ("Failed to find class.") on long object paths whose package
-- has not yet been loaded into memory. PlayerController:ConsoleCommand
-- routes through the same exec pipeline that the in-game `~` console uses
-- (UPlayer::Exec -> CallFunctionByNameWithArguments) which loads the
-- package on demand and resolves the trailing _C suffix correctly.
function M.summon(value_str)
    local s = value_str and value_str:match("^%s*(.-)%s*$") or ""
    if s == "" then return false, "usage: world.summon <ShortName_C | /Game/.../BP.BP_C>" end

    -- Resolve the local PlayerController via the canonical
    -- IsLocalController()-based resolver in feature_net. Was previously
    -- a UEHelpers-then-FindFirstOf walk, which on a multiplayer client
    -- could pick up the host PC and route the summon there.
    local feature_net = require("feature_net")
    local pc = feature_net.local_controller()
    if not pc then return false, "no player controller" end

    -- APlayerController::ConsoleCommand is a plain C++ method (not a
    -- UFunction), so UE4SS reflection can't bind a real `this` and the
    -- call traps with "UObject instance is nullptr". The reliable route
    -- is the BlueprintCallable UFunction
    -- UKismetSystemLibrary::ExecuteConsoleCommand(WorldContext, Cmd, SpecificPlayer).
    local ksl = StaticFindObject and StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") or nil
    if not (ksl and ksl:IsValid()) then
        return false, "KismetSystemLibrary CDO not found"
    end
    local cmd = "summon " .. s
    local ok, err = pcall(function() ksl:ExecuteConsoleCommand(pc, cmd, pc) end)
    if not ok then return false, "ExecuteConsoleCommand failed: " .. tostring(err) end
    print(string.format("[RSDWTools] world.summon %s", s))
    return true, s
end

return M

