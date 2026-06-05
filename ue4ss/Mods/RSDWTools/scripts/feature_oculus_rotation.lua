-- Oculus Rotation Mode.
--
-- Targets the actor/item under the Oculus repair reticle, freezes Oculus
-- translation, and lets mouse motion rotate the target in-place.

local M = {}

local feature_actor = require("feature_actor")
local feature_field = require("feature_field")
local feature_grab = require("feature_grab")
local feature_net = require("feature_net")
local feature_oculus = require("feature_oculus")
local feature_oculus_transform = require("feature_oculus_transform")
local feature_umg = require("feature_umg")

local TICK_MS = 33
local MODE_HOTKEY_DEBOUNCE_SECONDS = 0.08
local settings = {
    yaw_sensitivity = 0.12,
    pitch_sensitivity = 0.08,
    roll_sensitivity = 0.12,
    freeze_speed = 0.01,
    look_locked = true,
    look_scale = 0.001,
}

local state = {
    active = false,
    actor = nil,
    name = nil,
    source = nil,
    mode = "free",
    original_rot = nil,
    current_rot = nil,
    saved_motion = nil,
    saved_look = nil,
    loop_armed = false,
    token = 0,
    mouse_last_x = nil,
    mouse_last_y = nil,
    mouse_source = "none",
    camera_last_pitch = nil,
    camera_last_yaw = nil,
    last_help_refresh_clock = 0,
    writes = 0,
    actor_write_failures = 0,
    root_writes = 0,
    last_dx = 0.0,
    last_dy = 0.0,
    last_write_path = "none",
    last_mode_hotkey_clock = 0,
    loop_driver = nil,
    tick_fn = nil,
    engine_tick_started = false,
}

local function is_valid(obj)
    return feature_actor.is_valid_object(obj)
end

local function trim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

local function short_label(actor)
    local name = feature_actor.short_name_of(actor) or ""
    name = name:gsub("_UAID_[%x_]+$", "")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name ~= "" then return name end
    return "<unnamed>"
end

local function num(v, fallback)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then
        return fallback or 0.0
    end
    return n
end

local function copy_rot(rot)
    rot = rot or {}
    return {
        Pitch = num(rot.Pitch or rot.pitch, 0.0),
        Yaw = num(rot.Yaw or rot.yaw, 0.0),
        Roll = num(rot.Roll or rot.roll, 0.0),
    }
end

local function read_field(obj, field_name)
    if not is_valid(obj) then return nil end
    local ok, value = pcall(function() return obj[field_name] end)
    if ok then return value end
    return nil
end

local function write_field(obj, field_name, value)
    if not is_valid(obj) then return false, "invalid target" end
    local ok, err = pcall(function() obj[field_name] = value end)
    if ok then return true end
    return false, tostring(err)
end

local function movement_component()
    local opawn, err = feature_field.resolve_root("pawn.OculusComponent.OculusPawn")
    if not is_valid(opawn) then return nil, "no OculusPawn: " .. tostring(err) end
    local movement = read_field(opawn, "MovementComponent")
    if is_valid(movement) then return movement, nil end
    return nil, "no Oculus MovementComponent"
end

local function freeze_camera_motion()
    local movement, err = movement_component()
    if not movement then return false, err end
    local saved = {
        movement = movement,
        MaxSpeed = read_field(movement, "MaxSpeed"),
        Acceleration = read_field(movement, "Acceleration"),
        Deceleration = read_field(movement, "Deceleration"),
    }
    local freeze_value = math.max(0.001, num(settings.freeze_speed, 0.01))
    local ok_speed, speed_err = write_field(movement, "MaxSpeed", freeze_value)
    local ok_accel, accel_err = write_field(movement, "Acceleration", freeze_value)
    local ok_decel, decel_err = write_field(movement, "Deceleration", freeze_value)
    if not (ok_speed and ok_accel and ok_decel) then
        if saved.MaxSpeed ~= nil then write_field(movement, "MaxSpeed", saved.MaxSpeed) end
        if saved.Acceleration ~= nil then write_field(movement, "Acceleration", saved.Acceleration) end
        if saved.Deceleration ~= nil then write_field(movement, "Deceleration", saved.Deceleration) end
        return false, string.format("freeze failed speed=%s accel=%s decel=%s",
            tostring(speed_err or ok_speed),
            tostring(accel_err or ok_accel),
            tostring(decel_err or ok_decel))
    end
    state.saved_motion = saved
    return true, "camera movement frozen"
end

local function restore_camera_motion()
    local saved = state.saved_motion
    state.saved_motion = nil
    if type(saved) ~= "table" or not is_valid(saved.movement) then return end
    if saved.MaxSpeed ~= nil then write_field(saved.movement, "MaxSpeed", saved.MaxSpeed) end
    if saved.Acceleration ~= nil then write_field(saved.movement, "Acceleration", saved.Acceleration) end
    if saved.Deceleration ~= nil then write_field(saved.movement, "Deceleration", saved.Deceleration) end
end

local function signed_scale(original, magnitude)
    magnitude = math.max(0.0, num(magnitude, 0.001))
    local source = tonumber(original)
    if source and source < 0 then return -magnitude end
    return magnitude
end

local function damp_camera_look()
    local controller = feature_net.local_controller()
    if not is_valid(controller) then return false, "no local controller" end

    local saved = {
        controller = controller,
        look_locked = settings.look_locked == true,
        look_scale = num(settings.look_scale, 0.001),
    }
    if controller.IsLookInputIgnored then
        pcall(function() saved.ignore_look = controller:IsLookInputIgnored() end)
    end
    if controller.GetDeprecatedInputPitchScale then
        pcall(function() saved.pitch_scale = controller:GetDeprecatedInputPitchScale() end)
    else
        saved.pitch_scale = read_field(controller, "InputPitchScale")
    end
    if controller.GetDeprecatedInputYawScale then
        pcall(function() saved.yaw_scale = controller:GetDeprecatedInputYawScale() end)
    else
        saved.yaw_scale = read_field(controller, "InputYawScale")
    end

    local applied = false
    if settings.look_locked == true and saved.ignore_look ~= true and controller.SetIgnoreLookInput then
        local ok = pcall(function() controller:SetIgnoreLookInput(true) end)
        saved.ignore_look_applied = ok == true
        applied = applied or ok
    end

    local scale = math.max(0.0, num(settings.look_scale, 0.001))
    if controller.SetDeprecatedInputPitchScale then
        local ok = pcall(function() controller:SetDeprecatedInputPitchScale(signed_scale(saved.pitch_scale, scale)) end)
        applied = applied or ok
    else
        local ok = write_field(controller, "InputPitchScale", signed_scale(saved.pitch_scale, scale))
        applied = applied or ok
    end
    if controller.SetDeprecatedInputYawScale then
        local ok = pcall(function() controller:SetDeprecatedInputYawScale(signed_scale(saved.yaw_scale, scale)) end)
        applied = applied or ok
    else
        local ok = write_field(controller, "InputYawScale", signed_scale(saved.yaw_scale, scale))
        applied = applied or ok
    end

    state.saved_look = saved
    return applied, string.format("camera look %s scale=%.4f",
        settings.look_locked and "locked" or "damped",
        scale)
end

local function restore_camera_look()
    local saved = state.saved_look
    state.saved_look = nil
    if type(saved) ~= "table" or not is_valid(saved.controller) then return end
    local controller = saved.controller
    if saved.pitch_scale ~= nil then
        if controller.SetDeprecatedInputPitchScale then
            pcall(function() controller:SetDeprecatedInputPitchScale(saved.pitch_scale) end)
        else
            write_field(controller, "InputPitchScale", saved.pitch_scale)
        end
    end
    if saved.yaw_scale ~= nil then
        if controller.SetDeprecatedInputYawScale then
            pcall(function() controller:SetDeprecatedInputYawScale(saved.yaw_scale) end)
        else
            write_field(controller, "InputYawScale", saved.yaw_scale)
        end
    end
    if saved.ignore_look_applied == true and controller.SetIgnoreLookInput then
        pcall(function() controller:SetIgnoreLookInput(false) end)
    elseif saved.ignore_look == nil and saved.look_locked == true and controller.ResetIgnoreLookInput then
        pcall(function() controller:ResetIgnoreLookInput() end)
    end
end

local function set_live_rotation(actor, rot)
    if not is_valid(actor) or not rot then return false end
    state.writes = (state.writes or 0) + 1
    local actor_ok = feature_actor.set_actor_rotation(actor, rot)
    if actor_ok then
        state.last_write_path = "actor"
        return true
    end

    state.actor_write_failures = (state.actor_write_failures or 0) + 1
    feature_actor.force_actor_movable(actor)
    actor_ok = feature_actor.set_actor_rotation(actor, rot)
    if actor_ok then
        state.last_write_path = "actor_after_movable"
        return true
    end

    local root_ok = false
    local root = read_field(actor, "RootComponent")
    if is_valid(root) then
        if root.K2_SetWorldRotation then
            local ok_call, result = pcall(function()
                local hit = {}
                return root:K2_SetWorldRotation(rot, false, hit, true)
            end)
            if ok_call then root_ok = result ~= false end
        end
        if not root_ok and root.SetWorldRotation then
            local ok_call, result = pcall(function() return root:SetWorldRotation(rot) end)
            if ok_call then root_ok = result ~= false end
        end
    end
    if root_ok then
        state.root_writes = (state.root_writes or 0) + 1
        state.last_write_path = "root"
    else
        state.last_write_path = "failed"
    end
    return root_ok
end

local function normalize_angle_delta(delta)
    delta = num(delta, 0.0)
    while delta > 180.0 do delta = delta - 360.0 end
    while delta < -180.0 do delta = delta + 360.0 end
    return delta
end

local function read_camera_rotation()
    local opawn = feature_field.resolve_root("pawn.OculusComponent.OculusPawn")
    if is_valid(opawn) then
        local cam = read_field(opawn, "Camera")
        if is_valid(cam) and cam.K2_GetComponentRotation then
            local ok, rot = pcall(function() return cam:K2_GetComponentRotation() end)
            if ok and rot then return rot, "oculus.camera" end
        end
        if opawn.K2_GetActorRotation then
            local ok, rot = pcall(function() return opawn:K2_GetActorRotation() end)
            if ok and rot then return rot, "oculus.pawn" end
        end
    end
    local controller = feature_net.local_controller()
    if is_valid(controller) and controller.GetPlayerViewPoint then
        local ok, _loc, rot = pcall(function()
            local loc = { X = 0, Y = 0, Z = 0 }
            local out_rot = { Pitch = 0, Yaw = 0, Roll = 0 }
            controller:GetPlayerViewPoint(loc, out_rot)
            return loc, out_rot
        end)
        if ok and rot then return rot, "controller" end
    end
    return nil, "camera unavailable"
end

local function read_camera_look_delta()
    local rot, source = read_camera_rotation()
    if not rot then return nil, nil, source end
    local pitch = num(rot.Pitch or rot.pitch, 0.0)
    local yaw = num(rot.Yaw or rot.yaw, 0.0)
    if state.camera_last_pitch == nil or state.camera_last_yaw == nil then
        state.camera_last_pitch = pitch
        state.camera_last_yaw = yaw
        return 0.0, 0.0, source .. ":seed"
    end
    local dyaw = normalize_angle_delta(yaw - state.camera_last_yaw)
    local dpitch = normalize_angle_delta(pitch - state.camera_last_pitch)
    state.camera_last_pitch = pitch
    state.camera_last_yaw = yaw
    if math.abs(dyaw) < 0.001 and math.abs(dpitch) < 0.001 then
        return 0.0, 0.0, source
    end
    local dx = -dyaw / math.max(0.001, settings.yaw_sensitivity)
    local dy = dpitch / math.max(0.001, settings.pitch_sensitivity)
    return dx, dy, source .. ":look"
end

local input_fkey_cache = {}
local function input_fkey(name)
    if input_fkey_cache[name] then return input_fkey_cache[name] end
    if not FName then return nil end
    local ok_name, fname = pcall(function() return FName(name) end)
    if not ok_name or not fname then return nil end
    local key = { KeyName = fname }
    input_fkey_cache[name] = key
    return key
end

local function input_axis_name(name)
    if not FName then return nil end
    local ok_name, fname = pcall(function() return FName(name) end)
    if ok_name then return fname end
    return nil
end

local function number_from_out(value)
    if type(value) == "number" then return value end
    if type(value) == "table" then
        return tonumber(value.Value or value.value or value[1] or value.X or value.Y or 0.0) or 0.0
    end
    return tonumber(value) or 0.0
end

local function read_mouse_axis_delta(controller)
    if not is_valid(controller) then return nil, nil, "no local controller" end
    local mouse_x = input_fkey("MouseX")
    local mouse_y = input_fkey("MouseY")
    if mouse_x and mouse_y and controller.GetInputAnalogKeyState then
        local ok_x, dx = pcall(function() return controller:GetInputAnalogKeyState(mouse_x) end)
        local ok_y, dy = pcall(function() return controller:GetInputAnalogKeyState(mouse_y) end)
        if ok_x and ok_y then return tonumber(dx) or 0.0, tonumber(dy) or 0.0, "analog" end
    end
    if mouse_x and mouse_y and controller.GetInputAxisKeyValue then
        local ok_x, dx = pcall(function() return controller:GetInputAxisKeyValue(mouse_x) end)
        local ok_y, dy = pcall(function() return controller:GetInputAxisKeyValue(mouse_y) end)
        if ok_x and ok_y then return tonumber(dx) or 0.0, tonumber(dy) or 0.0, "axiskey" end
    end
    if controller.GetInputAxisValue then
        local axis_x = input_axis_name("MouseX")
        local axis_y = input_axis_name("MouseY")
        if axis_x and axis_y then
            local ok_x, dx = pcall(function() return controller:GetInputAxisValue(axis_x) end)
            local ok_y, dy = pcall(function() return controller:GetInputAxisValue(axis_y) end)
            if ok_x and ok_y then return tonumber(dx) or 0.0, tonumber(dy) or 0.0, "axis" end
        end
    end
    return nil, nil, "axis unavailable"
end

local function read_mouse_position_delta(controller)
    if not is_valid(controller) or not controller.GetMousePosition then return nil, nil, "no mouse position" end
    local out_x, out_y = { Value = 0.0 }, { Value = 0.0 }
    local ok_pos, success = pcall(function() return controller:GetMousePosition(out_x, out_y) end)
    if not ok_pos or success == false then return nil, nil, "mouse position unavailable" end
    local x, y = number_from_out(out_x), number_from_out(out_y)
    if state.mouse_last_x == nil or state.mouse_last_y == nil then
        state.mouse_last_x, state.mouse_last_y = x, y
        return 0.0, 0.0, "position"
    end
    local dx, dy = x - state.mouse_last_x, y - state.mouse_last_y
    state.mouse_last_x, state.mouse_last_y = x, y
    return dx, dy, "position"
end

local function read_mouse_delta()
    local controller = feature_net.local_controller()
    if not is_valid(controller) then return nil, nil, "no local controller" end
    local ax, ay, asource = read_mouse_axis_delta(controller)
    if ax ~= nil and ay ~= nil and (math.abs(ax) >= 0.01 or math.abs(ay) >= 0.01) then return ax, ay, asource end
    if controller.GetInputMouseDelta then
        local out_x, out_y = { Value = 0.0 }, { Value = 0.0 }
        local ok_delta, result_x, result_y = pcall(function() return controller:GetInputMouseDelta(out_x, out_y) end)
        if ok_delta then
            local dx = tonumber(result_x) or number_from_out(out_x)
            local dy = tonumber(result_y) or number_from_out(out_y)
            if math.abs(dx) >= 0.01 or math.abs(dy) >= 0.01 then return dx, dy, "delta" end
            local px, py, psource = read_mouse_position_delta(controller)
            if px ~= nil and py ~= nil and (math.abs(px) >= 0.01 or math.abs(py) >= 0.01) then return px, py, psource end
            if ax ~= nil and ay ~= nil and (math.abs(ax) >= 0.01 or math.abs(ay) >= 0.01) then return ax, ay, asource end
            if math.abs(dx) >= 0.01 or math.abs(dy) >= 0.01 then return dx, dy, "delta" end
        end
        local ok_return, dx_return, dy_return = pcall(function() return controller:GetInputMouseDelta(0.0, 0.0) end)
        if ok_return and (tonumber(dx_return) or tonumber(dy_return)) then
            local dx, dy = tonumber(dx_return) or 0.0, tonumber(dy_return) or 0.0
            if math.abs(dx) >= 0.01 or math.abs(dy) >= 0.01 then return dx, dy, "delta:return" end
        end
    end
    if ax ~= nil and ay ~= nil and (math.abs(ax) >= 0.01 or math.abs(ay) >= 0.01) then return ax, ay, asource end
    local px, py, psource = read_mouse_position_delta(controller)
    if px ~= nil and py ~= nil and (math.abs(px) >= 0.01 or math.abs(py) >= 0.01) then return px, py, psource end
    return read_camera_look_delta()
end

local function mode_label(mode)
    mode = mode or state.mode or "free"
    if mode == "x" then return "X axis (Roll)" end
    if mode == "y" then return "Y axis (Pitch)" end
    if mode == "z" then return "Z axis (Yaw)" end
    return "Free (Yaw + Pitch)"
end

local function short_mode_label(mode)
    mode = mode or state.mode or "free"
    if mode == "x" then return "Roll" end
    if mode == "y" then return "Pitch" end
    if mode == "z" then return "Yaw" end
    return "Free"
end

local function refresh_hotkey_help()
    local config = package.loaded["feature_oculus_config"]
    if type(config) == "table" and type(config.refresh_hotkey_help) == "function" then
        pcall(function() config.refresh_hotkey_help() end)
    end
end

function M.help_status()
    return M.help_details()
end

function M.top_status()
    local rot = state.current_rot or {}
    return string.format(
        "Rotation Mode: %s\nActor: %s\nYaw: %.1f   Pitch: %.1f   Roll: %.1f",
        short_mode_label(state.mode),
        tostring(state.name or "<target>"),
        num(rot.Yaw, 0.0),
        num(rot.Pitch, 0.0),
        num(rot.Roll, 0.0)
    )
end

function M.help_details()
    return string.format(
        "Transforms Mode\nMode: %s\nR/Left Click: Confirm Changes",
        mode_label(state.mode)
    )
end

local function update_overlay(force)
    local now = os.clock()
    if not force and (now - (state.last_help_refresh_clock or 0)) < 0.50 then return end
    state.last_help_refresh_clock = now
    if state.active then
        pcall(function() feature_umg.oculus_rotation_overlay(true, M.top_status(), "") end)
    else
        pcall(function() feature_umg.oculus_rotation_overlay(false) end)
    end
    refresh_hotkey_help()
end

local function mode_hotkey_allows_force_refresh()
    local now = os.clock()
    local last = tonumber(state.last_mode_hotkey_clock) or 0.0
    state.last_mode_hotkey_clock = now
    return (now - last) >= MODE_HOTKEY_DEBOUNCE_SECONDS
end

local function cleanup()
    state.active = false
    state.actor = nil
    state.name = nil
    state.source = nil
    state.mode = "free"
    state.original_rot = nil
    state.current_rot = nil
    state.mouse_last_x = nil
    state.mouse_last_y = nil
    state.mouse_source = "none"
    state.camera_last_pitch = nil
    state.camera_last_yaw = nil
    state.last_help_refresh_clock = 0
    state.writes = 0
    state.actor_write_failures = 0
    state.root_writes = 0
    state.last_dx = 0.0
    state.last_dy = 0.0
    state.last_write_path = "none"
    state.last_mode_hotkey_clock = 0
    state.loop_armed = false
    state.tick_fn = nil
    state.loop_driver = nil
    restore_camera_look()
    restore_camera_motion()
    update_overlay(true)
end

local function capture_current(reason)
    if is_valid(state.actor) then
        pcall(function() feature_oculus_transform.capture_actor(state.actor, reason or "rotation") end)
    end
end

local function stop_for_invalid_target()
    local label = tostring(state.name or "<target>")
    cleanup()
    pcall(function() feature_umg.toast("Rotation Mode stopped: target lost (" .. label .. ")", 2.0) end)
end

local function apply_rotation_delta(dx, dy)
    if not state.active then return false end
    local rot = state.current_rot
    if not rot then return false end
    dx = tonumber(dx) or 0.0
    dy = tonumber(dy) or 0.0
    state.last_dx = dx
    state.last_dy = dy
    if math.abs(dx) < 0.01 and math.abs(dy) < 0.01 then return false end
    if state.mode == "x" then
        rot.Roll = num(rot.Roll, 0.0) + dx * settings.roll_sensitivity
    elseif state.mode == "y" then
        rot.Pitch = num(rot.Pitch, 0.0) + dy * settings.pitch_sensitivity
    elseif state.mode == "z" then
        rot.Yaw = num(rot.Yaw, 0.0) + dx * settings.yaw_sensitivity
    else
        rot.Yaw = num(rot.Yaw, 0.0) + dx * settings.yaw_sensitivity
        rot.Pitch = num(rot.Pitch, 0.0) + dy * settings.pitch_sensitivity
    end
    return set_live_rotation(state.actor, rot)
end

local function tick_rotation()
    if not state.active then return true end
    if not is_valid(state.actor) then
        stop_for_invalid_target()
        return true
    end
    local dx, dy, source = read_mouse_delta()
    state.mouse_source = source or state.mouse_source or "unknown"
    if dx ~= nil and dy ~= nil then
        local changed = apply_rotation_delta(dx, dy)
        if changed then update_overlay() end
    end
    return false
end

local function start_loop()
    if state.loop_armed and state.tick_fn ~= nil then return end
    state.loop_armed = true
    local token = state.token
    local function run_step()
        if token ~= state.token then
            state.loop_armed = false
            return true
        end
        if not state.active then
            state.loop_armed = false
            return true
        end
        local ok_step, done = pcall(tick_rotation)
        if not ok_step then
            print("[RSDWTools] rotation mode tick failed: " .. tostring(done))
            cleanup()
            state.loop_armed = false
            return true
        end
        if done then
            state.loop_armed = false
            return true
        end
        return false
    end

    if EngineTickAvailable == true and type(LoopInGameThreadAfterFrames) == "function" then
        state.tick_fn = run_step
        state.loop_driver = "engine_tick"
        if not state.engine_tick_started then
            local ok, handle_or_err = pcall(function()
                return LoopInGameThreadAfterFrames(1, function()
                    local tick = state.tick_fn
                    if not tick then
                        if not state.active then state.loop_armed = false end
                        return
                    end
                    if tick() then
                        state.tick_fn = nil
                        state.loop_armed = false
                        if state.loop_driver == "engine_tick" then state.loop_driver = nil end
                    end
                end)
            end)
            if ok and handle_or_err then
                state.engine_tick_started = true
                return
            end
            print("[RSDWTools] rotation mode engine tick unavailable: " .. tostring(handle_or_err))
            state.tick_fn = nil
            state.loop_driver = nil
        else
            return
        end
    end

    if not LoopAsync then return end
    state.loop_driver = "loop_async"
    LoopAsync(TICK_MS, run_step)
end

local function parse_mode(args)
    local value = trim(args):lower()
    if value == "" then return nil, "usage: camera.oculus.rotation.mode <free|x|y|z>" end
    if value == "free" or value == "x" or value == "y" or value == "z" then return value end
    return nil, "mode must be one of free, x, y, z"
end

function M.is_active()
    return state.active == true
end

function M.start()
    if state.active then
        return true, "already active target=" .. tostring(state.name) .. " mode=" .. tostring(state.mode)
    end
    local ok_repair, repair_detail = feature_oculus.require_state("repair")
    if not ok_repair then return false, "requires Oculus Repair mode: " .. tostring(repair_detail) end
    if feature_grab.is_active and feature_grab.is_active() then
        return false, "release the grabbed actor before entering Rotation Mode"
    end

    local actor, source = feature_grab.pick_actor_under_reticle()
    if not is_valid(actor) then
        return false, tostring(source or "no actor under reticle")
    end

    local rot = feature_actor.actor_rotation(actor)
    if not rot then return false, "target rotation unavailable" end
    feature_actor.force_actor_movable(actor)

    local frozen, freeze_detail = freeze_camera_motion()
    if not frozen then return false, tostring(freeze_detail) end
    damp_camera_look()

    state.token = state.token + 1
    state.active = true
    state.actor = actor
    state.name = short_label(actor)
    state.source = tostring(source or "reticle")
    state.mode = "free"
    state.original_rot = copy_rot(rot)
    state.current_rot = copy_rot(rot)
    state.mouse_last_x = nil
    state.mouse_last_y = nil
    state.mouse_source = "none"
    state.camera_last_pitch = nil
    state.camera_last_yaw = nil
    state.last_help_refresh_clock = 0
    state.writes = 0
    state.actor_write_failures = 0
    state.root_writes = 0
    state.last_dx = 0.0
    state.last_dy = 0.0
    state.last_write_path = "none"
    state.last_mode_hotkey_clock = 0
    update_overlay(true)
    start_loop()
    return true, "target=" .. tostring(state.name) .. " source=" .. tostring(state.source) .. " mode=free"
end

function M.stop()
    if not state.active then return true, "inactive" end
    local label = tostring(state.name or "<target>")
    local actor = state.actor
    cleanup()
    if is_valid(actor) then
        pcall(function() feature_oculus_transform.capture_actor(actor, "rotation.stop") end)
    end
    return true, "applied " .. label
end

function M.toggle()
    if state.active then return M.stop() end
    return M.start()
end

function M.mode(args)
    if not state.active then return false, "rotation mode inactive" end
    local value, err = parse_mode(args)
    if not value then return false, err end
    state.mode = value
    mode_hotkey_allows_force_refresh()
    update_overlay(false)
    return true, "mode=" .. value .. " " .. mode_label(value)
end

function M.reset()
    if not state.active then return false, "rotation mode inactive" end
    if not is_valid(state.actor) then
        stop_for_invalid_target()
        return false, "target lost"
    end
    state.current_rot = copy_rot(state.original_rot)
    local ok = set_live_rotation(state.actor, state.current_rot)
    capture_current("rotation.reset")
    update_overlay(true)
    if ok then return true, "reset " .. tostring(state.name) end
    return false, "reset rotation write failed"
end

function M.status()
    if not state.active then return true, "inactive" end
    local rot = state.current_rot or {}
    return true, string.format("active target=%s mode=%s source=%s mouse=%s driver=%s writes=%d actor_fail=%d root=%d path=%s dx=%.3f dy=%.3f pitch=%.3f yaw=%.3f roll=%.3f",
        tostring(state.name),
        tostring(state.mode),
        tostring(state.source),
        tostring(state.mouse_source),
        tostring(state.loop_driver or "none"),
        tonumber(state.writes) or 0,
        tonumber(state.actor_write_failures) or 0,
        tonumber(state.root_writes) or 0,
        tostring(state.last_write_path),
        num(state.last_dx, 0.0),
        num(state.last_dy, 0.0),
        num(rot.Pitch, 0.0),
        num(rot.Yaw, 0.0),
        num(rot.Roll, 0.0))
end

function M.sensitivity(args)
    local parts = {}
    for part in tostring(args or ""):gmatch("%S+") do parts[#parts + 1] = part end
    if #parts == 0 then
        return true, string.format("yaw=%.4f pitch=%.4f roll=%.4f",
            settings.yaw_sensitivity,
            settings.pitch_sensitivity,
            settings.roll_sensitivity)
    end
    local yaw = tonumber(parts[1])
    local pitch = tonumber(parts[2]) or yaw
    local roll = tonumber(parts[3]) or yaw
    if not yaw or yaw <= 0 or not pitch or pitch <= 0 or not roll or roll <= 0 then
        return false, "usage: camera.oculus.rotation.sensitivity <yaw> [pitch] [roll]"
    end
    settings.yaw_sensitivity = yaw
    settings.pitch_sensitivity = pitch
    settings.roll_sensitivity = roll
    return M.sensitivity("")
end

function M.freeze(args)
    local value = trim(args)
    if value == "" then
        return true, string.format("freeze_speed=%.4f", settings.freeze_speed)
    end
    local parsed = tonumber(value)
    if not parsed or parsed <= 0 then
        return false, "usage: camera.oculus.rotation.freeze <positive-speed>"
    end
    settings.freeze_speed = parsed
    return true, string.format("freeze_speed=%.4f", settings.freeze_speed)
end

function M.look(args)
    local parts = {}
    for part in tostring(args or ""):gmatch("%S+") do parts[#parts + 1] = part end
    if #parts == 0 then
        return true, string.format("mode=%s scale=%.4f",
            settings.look_locked and "locked" or "damped",
            settings.look_scale)
    end

    local mode = trim(parts[1]):lower()
    local scale_index = 2
    if tonumber(parts[1]) ~= nil then
        scale_index = 1
    elseif mode == "locked" or mode == "lock" or mode == "on" or mode == "true" or mode == "1" then
        settings.look_locked = true
    elseif mode == "damped" or mode == "damp" or mode == "soft" or mode == "off" or mode == "false" or mode == "0" then
        settings.look_locked = false
    else
        return false, "usage: camera.oculus.rotation.look <locked|damped> [scale]"
    end

    local scale = tonumber(parts[scale_index])
    if scale ~= nil then
        if scale < 0 then return false, "look scale must be >= 0" end
        settings.look_scale = scale
    end
    return M.look("")
end

function M.handle_modal_hotkey(key)
    if not state.active then return false end
    local k = trim(key):upper()
    if k == "R" or k == "LEFT_MOUSE_BUTTON" or k == "LEFT_MOUSE" then
        M.stop()
        return true
    elseif k == "F" then
        M.mode("free")
        return true
    elseif k == "X" or k == "Y" or k == "Z" then
        M.mode(k:lower())
        return true
    elseif k == "MIDDLE_MOUSE_BUTTON" or k == "MIDDLE" or k == "MIDDLE_MOUSE" then
        M.reset()
        return true
    end
    return false
end

return M
