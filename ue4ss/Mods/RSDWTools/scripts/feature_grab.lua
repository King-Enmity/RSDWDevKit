-- Feature: actor "grab" tool. Latches a named actor onto the player's
-- current camera viewpoint and updates its transform every tick so the
-- actor follows the camera until released.
--
-- Design choices vs. the OLD/RSDTools implementation:
--   * One LoopAsync loop, started only when something is grabbed and
--     self-terminating on release. Zero per-frame cost when idle.
--   * Camera viewpoint comes from APlayerController:GetPlayerViewPoint,
--     which already routes through the active view target. While the
--     player is in Oculus mode the view target is AOculusPawn ; while
--     they're in normal play it's the player character. Same code path,
--     no special-case for "is oculus on".
--   * No per-tick reflection method-fallbacks. We resolve the actor +
--     its transform setters once at grab-start (via feature_actor's
--     M.move_actor / M.set_actor_rotation), and on the loop body we
--     just call them. If they fail we abort loudly instead of silently
--     trying alternates ; the old triple-fallback chain hid real bugs.
--   * Pre-allocated dest/rot tables mutated in place to keep GC out of
--     the hot path.
--   * Modes (move | rot | z | scale) are explicit verbs from the
--     router, not inferred from key state. The WPF or hotkey layer
--     decides how to map keys to verbs ; this module just executes.
--
-- Public verbs (called via command_line_router.lua):
--   camera.grab.start <name>            latch named actor to camera
--   camera.grab.release                 drop in place
--   camera.grab.cancel                  drop and restore start transform
--   camera.grab.mode <move|rot|z|scale> set what scroll-delta affects
--   camera.grab.delta <signed_number>   one wheel-tick worth (signed)
--   camera.grab.status                  print current state to ack
--
-- All verbs run on the game thread (the bridge dispatcher already
-- wraps router calls in ExecuteInGameThread). The LoopAsync tick body
-- also runs on the game thread under UE4SS, so direct UE calls from
-- inside it are safe.

local M = {}

local feature_actor = require("feature_actor")
local feature_field = require("feature_field")
local feature_umg   = require("feature_umg")

-- Trim the engine-assigned `_UAID_<hex>_<num>` runtime suffix off an
-- actor's instance name so the UI label reads as the editor name
-- (e.g. `BP_NPC_Doric_FTUE_C_UAID_AC1A...` -> `BP_NPC_Doric_FTUE_C`).
-- We strip the FIRST occurrence ; some actors get nested suffixes when
-- spawned via subobject construction.
local function _label_for(actor)
    local s = feature_actor.short_name_of(actor)
    if not s then return "<unnamed>" end
    local trimmed = s:match("^(.-)_UAID_") or s
    return trimmed
end

-- Brief on-screen toast. Wrapped in pcall so the UMG layer being
-- absent (e.g. before player_ready) never crashes the verb.
local function _toast(msg, secs)
    pcall(function() feature_umg.toast(msg, secs or 1.5) end)
end

local function _destroy_actor(actor)
    if not feature_actor.is_valid_object(actor) then return false end
    if actor.K2_DestroyActor then
        local ok = pcall(function() actor:K2_DestroyActor() end)
        if ok then return true end
    end
    if actor.DestroyActor then
        local ok = pcall(function() actor:DestroyActor() end)
        if ok then return true end
    end
    return false
end

-- ---------- tunables ----------

-- Tick rate for the follow loop. 30 Hz is plenty: the camera updates
-- at 60 Hz natively, the grabbed actor follows on alternate frames.
-- Halving the tick rate vs. 60 Hz halves our reflection cost for an
-- imperceptible loss in smoothness because the camera (which the eye
-- tracks) is still buttery.
local GRAB_TICK_MS = 33

-- Distance + Z deltas (per wheel notch).
local STEP_DISTANCE = 50.0    -- cm
local STEP_Z = 25.0           -- cm
local STEP_ROT_DEG = 15.0     -- yaw degrees
local STEP_SCALE = 0.10       -- uniform multiplier delta
local SCALE_MIN = 0.05
local SCALE_MAX = 50.0

-- Default placement distance from the camera if we can't measure where
-- the actor was when grabbed (e.g. its location read failed).
local DEFAULT_DISTANCE = 300.0

-- Maximum trace distance for "grab what I'm looking at". 100m covers
-- any reasonable in-game pick distance ; we don't want to trace to
-- infinity and grab terrain on the horizon by accident.
local LOOKAT_MAX_DISTANCE = 10000.0

-- ---------- state ----------

-- Single in-flight grab. We deliberately don't support stacking grabs:
-- the user can only steer one actor at a time and the UX is clearer.
local grab = nil
-- Shape:
--   {
--     actor       = userdata,
--     name        = "<short name>",
--     orig_loc    = { X, Y, Z },          -- for cancel()
--     orig_rot    = { Pitch, Yaw, Roll }, -- for cancel()
--     distance    = number,               -- cm in front of camera
--     z_offset    = number,               -- cm above camera plane
--     yaw_offset  = number,               -- deg added to camera yaw
--     scale       = number,               -- uniform scalar
--     mode        = "move" | "rot" | "z" | "scale",
--     dest        = { X, Y, Z },          -- pre-allocated, mutated in place
--     rot         = { Pitch, Yaw, Roll }, -- pre-allocated, mutated in place
--     loop_armed  = bool,                 -- LoopAsync handle is live
--   }

-- ---------- camera viewpoint ----------

-- Pulls the active player camera location + rotation. Routes through
-- GetPlayerViewPoint so we automatically follow whatever pawn is the
-- current view target for normal play.
--
-- Special case: when the oculus freecam is active the game does NOT
-- swap the view target on the player controller. The oculus pawn
-- renders its own camera independently, so GetPlayerViewPoint keeps
-- returning the player character's eyes (and the InteractableDetector
-- that traces from there sees nothing useful while the player is far
-- away). Detect that and read straight from the oculus pawn's
-- UCameraComponent instead. Reach path matches the working camera.json
-- kits: pawn.OculusComponent.OculusPawn.Camera + .TargetRotation.
local function get_camera_viewpoint()
    -- 1. Oculus override (only when actually active).
    local opawn = (function()
        local p, _ = feature_field.resolve_root("pawn.OculusComponent.OculusPawn")
        return p
    end)()
    if feature_actor.is_valid_object(opawn) then
        local active = false
        local ok_a, v = pcall(function() return opawn.bOculusActive end)
        if ok_a then active = (v == true) end
        if active then
            -- Prefer the camera component's world transform so we match
            -- exactly what's being rendered (TargetPosition/Rotation are
            -- the network-replicated targets, not the interpolated frame
            -- values, so they can lag a tick behind the visible camera).
            local cam_loc, cam_rot
            local ok_c, cam = pcall(function() return opawn.Camera end)
            if ok_c and feature_actor.is_valid_object(cam) then
                local ok_l, l = pcall(function() return cam:K2_GetComponentLocation() end)
                if ok_l and l then cam_loc = l end
                local ok_r, r = pcall(function() return cam:K2_GetComponentRotation() end)
                if ok_r and r then cam_rot = r end
            end
            -- Fall back to the pawn's own actor transform if the camera
            -- component reflection failed (rare, but keep the path live).
            if not cam_loc then
                local ok_l, l = pcall(function() return opawn:K2_GetActorLocation() end)
                if ok_l and l then cam_loc = l end
            end
            if not cam_rot then
                local ok_r, r = pcall(function() return opawn:K2_GetActorRotation() end)
                if ok_r and r then cam_rot = r end
            end
            if cam_loc and cam_rot then
                return cam_loc, cam_rot, nil
            end
            -- If we got here oculus is "active" but reflection failed.
            -- Fall through to the controller path below.
        end
    end

    -- 2. Standard path (player char, spectator, set-view-target).
    local pc, err = feature_field.resolve_root("controller")
    if not pc then return nil, nil, "no controller: " .. tostring(err) end
    if not pc.GetPlayerViewPoint then
        return nil, nil, "controller missing GetPlayerViewPoint"
    end
    -- UE outputs are passed in as a struct ; UE4SS auto-allocates them.
    local ok, loc, rot = pcall(function()
        local l = { X = 0, Y = 0, Z = 0 }
        local r = { Pitch = 0, Yaw = 0, Roll = 0 }
        pc:GetPlayerViewPoint(l, r)
        return l, r
    end)
    if not ok then return nil, nil, "GetPlayerViewPoint raised: " .. tostring(loc) end
    return loc, rot, nil
end

-- ---------- camera trace ----------
--
-- Casts a line from the active camera straight forward and returns the
-- first hit actor (+ hit location, + impact normal). Used by lookat
-- and by the no-arg form of camera.grab.start.
--
-- Implementation notes:
--   * KismetSystemLibrary::LineTraceSingle is the only trace API that has
--     proven stable across UE4SS reflection on this build. The OLD
--     RSDTools mod tried World:LineTraceSingleByChannel directly and
--     it null-deref'd ; the kismet wrapper resolves the hidden world
--     context arg internally, sidestepping that.
--   * We pass an actor-ignore list containing the local pawn AND the
--     oculus pawn. Without this, every grab attempt while in oculus
--     mode would just hit your own collision sphere first.
--   * "TraceTypeQuery1" is ECC_Visibility on a stock UE 5.x project.
--     Game-specific channels (e.g. ECC_Pawn) might miss world geometry,
--     but visibility hits everything renderable, which is what the
--     "grab what's under the reticle" intent wants.
local _ksl = nil  -- cached UKismetSystemLibrary CDO
local function get_kismet_lib()
    if _ksl and _ksl.IsValid and _ksl:IsValid() then return _ksl end
    if not StaticFindObject then return nil end
    local ok, obj = pcall(StaticFindObject, "/Script/Engine.Default__KismetSystemLibrary")
    if ok and obj and obj.IsValid and obj:IsValid() then
        _ksl = obj
        return _ksl
    end
    return nil
end

local function get_oculus_pawn_safe()
    local pawn, _ = feature_field.resolve_root("pawn.OculusComponent.OculusPawn")
    return pawn  -- may be nil ; that's fine, just means oculus isn't active
end

local function build_camera_ray(distance)
    distance = tonumber(distance) or LOOKAT_MAX_DISTANCE
    if distance < 100.0 then distance = LOOKAT_MAX_DISTANCE end

    local cam_loc, cam_rot, err = get_camera_viewpoint()
    if not cam_loc then return nil, nil, nil, nil, "camera unavailable: " .. tostring(err) end

    local pitch = (cam_rot.Pitch or 0) * math.pi / 180.0
    local yaw   = (cam_rot.Yaw   or 0) * math.pi / 180.0
    local cp = math.cos(pitch)
    local fx = cp * math.cos(yaw)
    local fy = cp * math.sin(yaw)
    local fz = math.sin(pitch)

    local start_v = { X = cam_loc.X, Y = cam_loc.Y, Z = cam_loc.Z }
    local end_v = {
        X = cam_loc.X + fx * distance,
        Y = cam_loc.Y + fy * distance,
        Z = cam_loc.Z + fz * distance,
    }
    return start_v, end_v, { X = fx, Y = fy, Z = fz }, cam_rot, nil
end

local function _trace_from_camera(distance)
    local start_v, end_v, _forward, _cam_rot, ray_err = build_camera_ray(distance)
    if not start_v then return nil, nil, tostring(ray_err) end

    local ksl = get_kismet_lib()
    if not ksl then return nil, nil, "KismetSystemLibrary CDO unavailable" end

    local world = (function()
        local w, _ = feature_field.resolve_root("world")
        return w
    end)()
    if not world then return nil, nil, "no world" end

    -- Build the ignore list. Pawn is the player character ; oculus pawn
    -- is the freecam pawn we're flying. Either may be nil depending on
    -- mode ; we just leave the slot empty when so.
    local ignore = {}
    local pawn = feature_actor.get_local_pawn()
    if feature_actor.is_valid_object(pawn) then ignore[#ignore + 1] = pawn end
    local opawn = get_oculus_pawn_safe()
    if feature_actor.is_valid_object(opawn) then ignore[#ignore + 1] = opawn end

    local hit = {}
    local trace_color = { R = 0, G = 0, B = 0, A = 0 }
    local hit_color   = { R = 0, G = 0, B = 0, A = 0 }

    -- Try a tight line trace first (cheapest, gives the exact reticle hit
    -- when the target is solid + well-aligned). If that returns no hit OR
    -- a hit with no resolvable actor (e.g. instanced static mesh foliage,
    -- raw landscape components), retry with a sphere sweep so distant
    -- pawns / thin geometry get caught. Two-pass keeps the common case
    -- fast while making the freecam pick "feel" forgiving like the OLD
    -- selection code's wider tolerance.
    local function _do_line_trace()
        return pcall(function()
            return ksl:LineTraceSingle(
                world, start_v, end_v,
                "TraceTypeQuery1",        -- ECC_Visibility
                false,                     -- bTraceComplex
                ignore,
                "EDrawDebugTrace::None",
                hit,
                true,                      -- bIgnoreSelf
                trace_color, hit_color,
                0.0                        -- DrawTime
            )
        end)
    end
    local function _do_sphere_trace(radius)
        -- Fresh table so the first-pass output doesn't leak into the
        -- second when the line trace half-failed.
        hit = {}
        return pcall(function()
            return ksl:SphereTraceSingle(
                world, start_v, end_v, radius,
                "TraceTypeQuery1",
                false,
                ignore,
                "EDrawDebugTrace::None",
                hit,
                true,
                trace_color, hit_color,
                0.0
            )
        end)
    end

    -- Resolves the first usable actor handle out of an FHitResult.
    -- IMPORTANT: do NOT pre-filter Component / HitObjectHandle through
    -- is_valid_object. UE4SS marshals Component as a userdata wrapper
    -- (not a plain UObject*) and HitObjectHandle as a Lua TABLE (the
    -- FActorInstanceHandle struct), neither of which IsValid accepts.
    -- We just pcall the accessors and trust the result if it comes
    -- back as a live UObject.
    local function _unpack_actor(hr)
        local a = nil
        local h = hr.HitObjectHandle
        if h then
            -- Struct form: try a method first (some UE4SS builds expose
            -- it on the table) ; fall back to the raw Actor field.
            if type(h) == "table" or type(h) == "userdata" then
                if h.GetActor then
                    local okh, v = pcall(function() return h:GetActor() end)
                    if okh and feature_actor.is_valid_object(v) then a = v end
                end
                if (not a) and h.Actor and feature_actor.is_valid_object(h.Actor) then
                    a = h.Actor
                end
                if (not a) and h.ReferenceObject and feature_actor.is_valid_object(h.ReferenceObject) then
                    a = h.ReferenceObject
                end
            end
        end
        if (not a) and hr.Actor and feature_actor.is_valid_object(hr.Actor) then
            a = hr.Actor
        end
        local comp = hr.Component
        local comp_obj = comp
        if comp then
            if feature_actor.is_valid_object(comp) then
                comp_obj = comp
            else
                local okg, real = pcall(function()
                    if comp.get then return comp:get() end
                    if comp.ToObject then return comp:ToObject() end
                    return nil
                end)
                if okg and feature_actor.is_valid_object(real) then
                    comp_obj = real
                end
            end
        end
        if (not a) and comp_obj then
            -- Component is userdata. GetOwner may exist directly, or we
            -- may need to go through the wrapper's :get() / :ToObject()
            -- (UE4SS's RemoteUnrealParam pattern). Try both.
            if comp_obj and comp_obj.GetOwner then
                local oko, v = pcall(function() return comp_obj:GetOwner() end)
                if oko and feature_actor.is_valid_object(v) then a = v end
            end
            if not a then
                local okg, real = pcall(function() return comp_obj end)
                if okg and real and real.GetOwner then
                    local oko, v = pcall(function() return real:GetOwner() end)
                    if oko and feature_actor.is_valid_object(v) then a = v end
                end
            end
        end
        return a, comp_obj or comp
    end

    local ok, did_hit = _do_line_trace()
    if not ok then return nil, nil, "trace raised: " .. tostring(did_hit) end

    local actor, comp = nil, nil
    if did_hit then actor, comp = _unpack_actor(hit) end

    if not feature_actor.is_valid_object(actor) then
        -- Sphere fallback. 50cm radius matches the OLD selection code's
        -- "what you're roughly aiming at" tolerance and reliably picks up
        -- NPCs at range without grabbing terrain right under the reticle.
        local ok2, did_hit2 = _do_sphere_trace(50.0)
        if ok2 and did_hit2 then
            actor, comp = _unpack_actor(hit)
        end
    end

    if not feature_actor.is_valid_object(actor) then
        -- Still nothing. Dump every top-level key of the hit struct
        -- so we can see how UE4SS is marshalling FHitResult in this
        -- build (the field name for the component varies between UE
        -- versions: Component / HitComponent / PhysMaterial owner).
        -- We log to UE4SS console AND return a compact summary so it
        -- shows up in the bridge ack too.
        local keys = {}
        for k, v in pairs(hit) do
            local tv = type(v)
            local extra = ""
            if tv == "userdata" and v.GetFullName then
                local okn, n = pcall(function() return v:GetFullName() end)
                if okn then extra = "=" .. tostring(n) end
            elseif tv == "table" then
                extra = "={...}"
            elseif tv ~= "function" then
                extra = "=" .. tostring(v)
            end
            keys[#keys + 1] = k .. "(" .. tv .. ")" .. extra
        end
        table.sort(keys)
        local dump = table.concat(keys, ", ")
        if print then print("[grab.trace] FHitResult fields: " .. dump .. "\n") end

        -- Also dump the HitObjectHandle struct's inner keys ; UE 5.x
        -- buries the actor pointer inside it (e.g. Manager + InstanceUID
        -- + ReferenceObject) and we want to see what shape this build
        -- ships before guessing.
        if hit.HitObjectHandle and type(hit.HitObjectHandle) == "table" then
            local hkeys = {}
            for k, v in pairs(hit.HitObjectHandle) do
                hkeys[#hkeys + 1] = k .. "(" .. type(v) .. ")"
            end
            table.sort(hkeys)
            if print then print("[grab.trace] HitObjectHandle: " .. table.concat(hkeys, ", ") .. "\n") end
        end

        local cclass = "<no component>"
        local comp_raw = hit.Component
        if comp_raw then
            -- Try class name without going through is_valid_object,
            -- which rejects non-UObject userdata wrappers.
            local okc, cn = pcall(function()
                if comp_raw.GetClass then
                    local c = comp_raw:GetClass()
                    if c and c.GetFName then return c:GetFName():ToString() end
                    if c and c.GetName then return c:GetName() end
                end
                if comp_raw.GetFullName then return comp_raw:GetFullName() end
                return nil
            end)
            if okc and cn then cclass = tostring(cn) end
        end
        local impact = hit.Location or hit.ImpactPoint
        local where = ""
        if impact then
            where = string.format(" @ (%.0f, %.0f, %.0f)", impact.X or 0, impact.Y or 0, impact.Z or 0)
        end
        local short = dump
        if #short > 240 then short = short:sub(1, 240) .. "..." end
        return nil, impact, "hit non-actor geometry [comp=" .. cclass .. "]" .. where .. " fields=" .. short
    end
    local impact = hit.Location or hit.ImpactPoint
    return actor, impact, nil, {
        component = comp,
        item = hit.Item,
        my_item = hit.MyItem,
        element_index = hit.ElementIndex,
        face_index = hit.FaceIndex,
        hit = hit,
    }
end

-- ---------- math ----------

local function deg2rad(d) return d * math.pi / 180.0 end

local function camera_forward(rot)
    -- Flat XY forward (yaw only). Used for the legacy "distance on
    -- floor plane" model ; kept for the seed-distance computation in
    -- M.start so a horizontal grab still feels stable when the player
    -- is looking nearly straight down.
    local yaw = deg2rad(rot and rot.Yaw or 0)
    return math.cos(yaw), math.sin(yaw)
end

-- Full 3D forward unit vector (pitch + yaw). UE rotators: pitch up is
-- +ve, so positive pitch yields +Z. This is what makes the grab feel
-- oculus-y: looking up raises the held actor along the sight line.
local function camera_forward_3d(rot)
    local pitch = deg2rad(rot and rot.Pitch or 0)
    local yaw   = deg2rad(rot and rot.Yaw or 0)
    local cp = math.cos(pitch)
    return cp * math.cos(yaw), cp * math.sin(yaw), math.sin(pitch)
end

local function vec_len_xy(dx, dy, dz)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- ---------- tick body ----------

-- Compute the desired world transform from the camera viewpoint + the
-- per-grab offsets, then push it onto the actor. Returns false on a
-- terminal failure (auto-release on next tick).
local function tick_grab()
    -- Snapshot the upvalue to a local. M.release()/M.cancel() can null
    -- `grab` between the get_camera_viewpoint() call (which marshals
    -- through ExecuteInGameThread) and the subsequent field writes.
    -- Observed in user log 2026-05-15: line "grab.dest.X = ..." crashed
    -- with "attempt to index a nil value (upvalue 'grab')". The local
    -- snapshot keeps this tick consistent even if the upvalue clears
    -- mid-flight ; the loop callback in start_loop() will see the nil
    -- on the next iteration and exit cleanly.
    local g = grab
    if not g then return false end
    local actor = g.actor
    if not feature_actor.is_valid_object(actor) then
        print("[RSDWTools] grab: target invalid, releasing.")
        return false
    end
    local cam_loc, cam_rot, err = get_camera_viewpoint()
    if not cam_loc then
        -- Don't release on a single failed read ; the controller can
        -- transiently disappear during view target swaps. Just skip.
        return true
    end
    -- Re-check after the cross-thread call.
    if not grab or grab ~= g then return false end

    -- Full 3D forward so pitching the camera moves the held actor up
    -- and down along the sight line (oculus feel). z_offset is an
    -- additional vertical nudge applied on top, driven by `z` mode.
    local fx, fy, fz = camera_forward_3d(cam_rot)
    g.dest.X = (cam_loc.X or 0) + fx * g.distance
    g.dest.Y = (cam_loc.Y or 0) + fy * g.distance
    g.dest.Z = (cam_loc.Z or 0) + fz * g.distance + g.z_offset

    g.rot.Pitch = 0
    g.rot.Yaw = (cam_rot and cam_rot.Yaw or 0) + g.yaw_offset
    g.rot.Roll = 0

    local moved = feature_actor.move_actor(actor, g.dest)
    if moved == false then
        -- One failed write isn't fatal -- the engine occasionally
        -- rejects a sweep when the destination collides. Keep going ;
        -- next tick the camera has moved a bit and may succeed.
        return true
    end
    feature_actor.set_actor_rotation(actor, g.rot)
    return true
end

local function start_loop()
    if grab and grab.loop_armed then return end
    if not LoopAsync then
        print("[RSDWTools] grab: LoopAsync unavailable, cannot tick.")
        return
    end
    grab.loop_armed = true
    LoopAsync(GRAB_TICK_MS, function()
        if not grab then return true end          -- released externally
        local keep = tick_grab()
        if not keep then
            grab = nil
            return true                            -- exit loop
        end
        return false
    end)
end

-- ---------- public verbs ----------

-- The game's own interaction system already answers "what is the
-- player looking at right now?" via UInteractableDetectorComponent on
-- the player character. It traces every tick to drive nameplates +
-- the press-to-interact prompt, so we just read its result instead of
-- racing it with our own trace. The detector lives on the live pawn
-- and updates from the active camera viewpoint, so it works in oculus
-- mode too as long as the player character itself is loaded.
--
--   pawn.InteractableDetector.CurrentWorldActor      AActor* (any actor)
--   pawn.InteractableDetector.CurrentInteractable    UInteractionComponent*
--
-- We prefer CurrentWorldActor because nameplates use it (NPCs, animals,
-- buildings, dropped items) ; CurrentInteractable is only set when the
-- thing is also currently interactable, which is a stricter set.
local function _detector_pick()
    local pawn = feature_actor.get_local_pawn()
    if not feature_actor.is_valid_object(pawn) then return nil end
    local det = nil
    local ok, getter = pcall(function() return pawn.GetInteractableDetector end)
    if ok and getter then
        local ok2, d = pcall(function() return pawn:GetInteractableDetector() end)
        if ok2 then det = d end
    end
    if not feature_actor.is_valid_object(det) then
        local ok3, d = pcall(function() return pawn.InteractableDetector end)
        if ok3 then det = d end
    end
    if not feature_actor.is_valid_object(det) then return nil end
    local ok4, a = pcall(function() return det.CurrentWorldActor end)
    if ok4 and feature_actor.is_valid_object(a) then return a end
    -- Fall back to CurrentInteractable's owner (UInteractionComponent
    -- is a UActorComponent, so its owner is the world actor).
    local ok5, ic = pcall(function() return det.CurrentInteractable end)
    if ok5 and feature_actor.is_valid_object(ic) and ic.GetOwner then
        local ok6, owner = pcall(function() return ic:GetOwner() end)
        if ok6 and feature_actor.is_valid_object(owner) then return owner end
    end
    return nil
end

-- True if the player is currently flying around in the oculus freecam.
-- Detector reads should be SKIPPED in that case: the detector runs on
-- the (hidden) player character, so its CurrentWorldActor reflects
-- "what the player char is looking at", not the freecam reticle.
local function _oculus_is_active()
    local opawn = (function()
        local p, _ = feature_field.resolve_root("pawn.OculusComponent.OculusPawn")
        return p
    end)()
    if not feature_actor.is_valid_object(opawn) then return false end
    local ok, v = pcall(function() return opawn.bOculusActive end)
    return ok and v == true
end

-- camera.grab.start [<name>]
--
-- With <name>: resolve via feature_actor by exact short name (same path
-- used by every other actor.* verb).
-- Without <name>: ask the game's interaction detector first, then fall
-- back to a forward line trace. The local pawn and the oculus pawn
-- are always excluded from the trace so we never grab ourselves.
-- Internal : begin a grab session given a fully-resolved (actor, name)
-- pair. All public M.start* entries funnel through here so the static-
-- class block, transform seeding and grab-state allocation only live
-- in one place. Returns the same (ok, detail) tuple as M.start.
local function _begin_grab(actor, picked_name)
    -- Round 62+: forbid grabbing world-static / foliage / building-piece
    -- actors. These are engine-owned placement/world objects; moving them
    -- outside their native systems can desync collision, nav, placement or
    -- persistence state. Match on cheap actor properties and names rather
    -- than walking class ancestry, which has been unsafe in this UE4SS build.
    local function _grab_block_reason(a)
        local cls_name, full_name
        pcall(function()
            local c = a:GetClass()
            if c then cls_name = c:GetName() end
        end)
        pcall(function() full_name = a:GetFullName() end)
        local hay = ((cls_name or "") .. " " .. (full_name or "")):lower()

        local building_piece_data_index
        pcall(function() building_piece_data_index = a.BuildingPieceDataIndex end)
        if type(building_piece_data_index) == "number" then
            return "building piece", "BuildingPieceDataIndex=" .. tostring(building_piece_data_index)
        end

        if hay:find("staticmeshactor", 1, true)
            or hay:find("instancedfoliageactor", 1, true)
            or hay:find("landscapestreamingproxy", 1, true)
            or hay:find("bpp_", 1, true) then
            return "world-static/environment", cls_name or full_name or "<unknown>"
        end
        return nil
    end
    local blocked_kind, blocked_detail = _grab_block_reason(actor)
    if blocked_kind then
        return false, string.format(
            "refusing to grab '%s' : target is %s (%s) and is unsafe to move with camera.grab",
            tostring(picked_name), tostring(blocked_kind), tostring(blocked_detail))
    end

    local cam_loc, cam_rot, cerr = get_camera_viewpoint()
    if not cam_loc then return false, "camera unavailable: " .. tostring(cerr) end

    local orig_loc = feature_actor.actor_location(actor) or
                     { X = cam_loc.X, Y = cam_loc.Y, Z = cam_loc.Z }
    local orig_rot = feature_actor.actor_rotation(actor) or
                     { Pitch = 0, Yaw = 0, Roll = 0 }

    -- Seed distance/z so the actor doesn't snap on the first tick.
    -- New (3D-forward) model: distance is the projection of the
    -- camera->actor vector onto the camera's forward unit vector, and
    -- z_offset captures whatever residual vertical remains after that
    -- projection (so actors slightly off the sight line don't pop to
    -- the centre when grabbed). Yaw offset starts at zero.
    local dx = (orig_loc.X or 0) - (cam_loc.X or 0)
    local dy = (orig_loc.Y or 0) - (cam_loc.Y or 0)
    local dz = (orig_loc.Z or 0) - (cam_loc.Z or 0)
    local fx, fy, fz = camera_forward_3d(cam_rot)
    local proj = dx * fx + dy * fy + dz * fz
    if proj < 50.0 then proj = DEFAULT_DISTANCE end
    local z_residual = dz - fz * proj
    local horiz = proj

    feature_actor.force_actor_movable(actor)

    local cur_scale = feature_actor.get_actor_scale3d(actor) or { X = 1, Y = 1, Z = 1 }
    local uniform = ((cur_scale.X or 1) + (cur_scale.Y or 1) + (cur_scale.Z or 1)) / 3.0

    grab = {
        actor      = actor,
        name       = picked_name,
        orig_loc   = { X = orig_loc.X or 0, Y = orig_loc.Y or 0, Z = orig_loc.Z or 0 },
        orig_rot   = {
            Pitch = orig_rot.Pitch or 0,
            Yaw   = orig_rot.Yaw or 0,
            Roll  = orig_rot.Roll or 0,
        },
        distance   = horiz,
        z_offset   = z_residual,
        yaw_offset = 0.0,
        scale      = uniform,
        mode       = "move",
        dest       = { X = 0, Y = 0, Z = 0 },
        rot        = { Pitch = 0, Yaw = 0, Roll = 0 },
        loop_armed = false,
    }
    start_loop()
    _toast("Grabbed: " .. _label_for(actor), 1.5)
    return true, string.format("grabbed %s @ dist=%.0f z=%.0f", picked_name, horiz, z_residual)
end

-- camera.grab.start [<name>]
--
-- With <name>: resolve via feature_actor by exact short name (same path
-- used by every other actor.* verb).
-- Without <name>: ask the game's interaction detector first, then fall
-- back to a forward line trace. The local pawn and the oculus pawn
-- are always excluded from the trace so we never grab ourselves.
function M.start(name)
    if grab then
        return false, "already grabbing " .. tostring(grab.name) .. " ; release first"
    end
    -- Round 62: require oculus freecam to be active before allowing
    -- a grab to start. The grab pipeline anchors the actor to the
    -- camera viewpoint each tick ; outside oculus mode that viewpoint
    -- is the player char's own camera, which means the grabbed actor
    -- floats in front of the player and rides their head movement.
    -- Forcing oculus-only avoids that footgun and keeps grab semantics
    -- aligned with the freecam workflow it was designed for.
    if not _oculus_is_active() then
        return false, "camera.grab.start requires oculus freecam to be active"
    end

    local actor, picked_name
    if name and name ~= "" then
        actor = feature_actor.resolve_actor_by_name(name)
        if not actor then return false, "actor not found: " .. tostring(name) end
        picked_name = name
    else
        -- Prefer the game's interaction detector when the player char
        -- is in control ; in oculus mode the detector is irrelevant
        -- (it's tied to the hidden player char), so trace directly.
        local picked = nil
        if not _oculus_is_active() then
            picked = _detector_pick()
        end
        if not picked then
            local hit_actor, _impact, terr = _trace_from_camera(LOOKAT_MAX_DISTANCE)
            if not hit_actor then
                return false, "lookat: " .. tostring(terr)
            end
            picked = hit_actor
        end
        actor = picked
        picked_name = feature_actor.short_name_of(actor) or "<unnamed>"
    end

    return _begin_grab(actor, picked_name)
end

-- camera.grab.lastspawned
--
-- Grab whichever actor world.spawn / world.spawn.item most recently
-- produced. Resolves through the `lastspawned` reach root in
-- feature_field, so it auto-clears if the actor has been destroyed
-- since the spawn. Same oculus-required guard as M.start ; the
-- intended workflow is "fly around in oculus, spawn at reticle, then
-- nudge the new actor into precise position before releasing".
function M.start_lastspawned()
    if grab then
        return false, "already grabbing " .. tostring(grab.name) .. " ; release first"
    end
    if not _oculus_is_active() then
        return false, "camera.grab.lastspawned requires oculus freecam to be active"
    end
    local actor, rerr = feature_field.resolve_root("lastspawned")
    if not actor then
        return false, "no lastspawned actor (or it has been destroyed): " .. tostring(rerr)
    end
    local picked_name = feature_actor.short_name_of(actor) or "lastspawned"
    return _begin_grab(actor, picked_name)
end

local function pick_target_under_reticle()
    local actor, source, impact = nil, nil, nil
    if not _oculus_is_active() then
        actor = _detector_pick()
        if actor then source = "detector" end
    end
    if not actor then
        local hit_actor, hit_impact, err = _trace_from_camera(LOOKAT_MAX_DISTANCE)
        if not hit_actor then
            return nil, nil, nil, "no actor under reticle (trace: " .. tostring(err) .. ")"
        end
        actor = hit_actor
        impact = hit_impact
        source = "trace"
    end
    local loc = impact or feature_actor.actor_location(actor) or { X = 0, Y = 0, Z = 0 }
    return actor, loc, source, nil
end

local function pick_location_under_reticle()
    if not _oculus_is_active() then
        local actor = _detector_pick()
        if feature_actor.is_valid_object(actor) then
            return actor, feature_actor.actor_location(actor) or { X = 0, Y = 0, Z = 0 }, "detector", nil
        end
    end
    local hit_actor, hit_impact, err = _trace_from_camera(LOOKAT_MAX_DISTANCE)
    if feature_actor.is_valid_object(hit_actor) then
        return hit_actor, hit_impact or feature_actor.actor_location(hit_actor) or { X = 0, Y = 0, Z = 0 }, "trace", nil
    end
    if hit_impact then
        return nil, hit_impact, "trace.geometry", err
    end
    return nil, nil, nil, "no location under reticle (trace: " .. tostring(err) .. ")"
end

-- camera.lookat -- pure read-only "what's the camera pointed at?".
-- Source priority:
--   1. Detector (player-char path) -- only when NOT in oculus mode,
--      because the detector traces from the player character itself.
--   2. KismetSystemLibrary line trace from the active camera viewpoint
--      (which becomes the oculus pawn's camera while flying around).
function M.lookat()
    local actor, loc, source, err = pick_target_under_reticle()
    if not actor then return false, err end
    local short = feature_actor.short_name_of(actor) or "<unnamed>"
    local class = feature_field.class_name_of(actor) or "<unknown>"
    -- Toast a tidy label (engine `_UAID_*` suffix stripped) so the
    -- player can glance at the screen and know what their reticle is
    -- on without alt-tabbing to the bridge log.
    _toast(_label_for(actor), 1.5)
    return true, string.format(
        "%s [class=%s, src=%s] @ (%.0f, %.0f, %.0f)",
        short, class, source, loc.X or 0, loc.Y or 0, loc.Z or 0
    )
end

function M.destroy_lookat()
    local actor, loc, source, err = pick_target_under_reticle()
    if not feature_actor.is_valid_object(actor) then return false, tostring(err or "no actor under reticle") end

    local pawn = feature_actor.get_local_pawn()
    if feature_actor.is_valid_object(pawn) and actor == pawn then
        return false, "refusing to destroy local player pawn"
    end
    local opawn = get_oculus_pawn_safe()
    if feature_actor.is_valid_object(opawn) and actor == opawn then
        return false, "refusing to destroy oculus pawn"
    end

    local label = _label_for(actor)
    local short = feature_actor.short_name_of(actor) or "<unnamed>"
    local class = feature_field.class_name_of(actor) or "<unknown>"
    if grab and grab.actor == actor then grab = nil end
    if not _destroy_actor(actor) then return false, "destroy failed: " .. tostring(short) end
    _toast("Destroyed: " .. label, 1.5)
    return true, string.format("%s [class=%s, src=%s] @ (%.0f, %.0f, %.0f)",
        short, class, tostring(source), loc.X or 0, loc.Y or 0, loc.Z or 0)
end

-- camera.grab.release   -- drop in place
function M.release()
    if not grab then return false, "not grabbing anything" end
    local name = grab.name
    local label = (feature_actor.is_valid_object(grab.actor) and _label_for(grab.actor)) or name
    _toast("Released: " .. label, 1.5)
    grab = nil
    return true, "released " .. name
end

-- camera.grab.toggle [<name>] -- one verb, two behaviors. If something
-- is currently grabbed, drop it (release). Otherwise start a new grab
-- using the same name-resolution / detector path as camera.grab.start.
-- Lets a single hotkey serve as "pick up / put down".
function M.toggle(name)
    if grab then
        return M.release()
    end
    return M.start(name)
end

-- camera.grab.cancel    -- drop and restore start transform
function M.cancel()
    if not grab then return false, "not grabbing anything" end
    local actor = grab.actor
    local name = grab.name
    if feature_actor.is_valid_object(actor) then
        feature_actor.move_actor(actor, grab.orig_loc)
        feature_actor.set_actor_rotation(actor, grab.orig_rot)
    end
    grab = nil
    return true, "cancelled " .. name .. " (restored)"
end

-- camera.grab.mode <move|rot|z|scale>
local VALID_MODES = { move = true, rot = true, z = true, scale = true }
function M.mode(mode_str)
    if not grab then return false, "not grabbing" end
    local m = tostring(mode_str or ""):lower()
    if not VALID_MODES[m] then
        return false, "mode must be one of: move, rot, z, scale"
    end
    grab.mode = m
    return true, "mode=" .. m
end

-- camera.grab.delta <signed_number>
-- Applies one wheel-tick of input to the active mode.
function M.delta(delta_str)
    if not grab then return false, "not grabbing" end
    local d = tonumber(delta_str)
    if not d or d == 0 then return false, "delta must be a non-zero number" end

    if grab.mode == "move" then
        grab.distance = math.max(50.0, grab.distance + d * STEP_DISTANCE)
        return true, string.format("distance=%.0f", grab.distance)
    elseif grab.mode == "z" then
        grab.z_offset = grab.z_offset + d * STEP_Z
        return true, string.format("z_offset=%.0f", grab.z_offset)
    elseif grab.mode == "rot" then
        grab.yaw_offset = (grab.yaw_offset + d * STEP_ROT_DEG) % 360.0
        return true, string.format("yaw_offset=%.1f", grab.yaw_offset)
    elseif grab.mode == "scale" then
        local s = grab.scale + d * STEP_SCALE
        if s < SCALE_MIN then s = SCALE_MIN end
        if s > SCALE_MAX then s = SCALE_MAX end
        grab.scale = s
        if feature_actor.is_valid_object(grab.actor) then
            feature_actor.set_actor_scale3d(grab.actor, { X = s, Y = s, Z = s })
        end
        return true, string.format("scale=%.3f", s)
    end
    return false, "unknown mode " .. tostring(grab.mode)
end

-- camera.grab.rotate <signed> -- dedicated yaw nudge that ignores the
-- active mode. Lets the user bind a separate hotkey/wheel axis to
-- spinning the held actor without having to switch into `rot` mode
-- first (mimics oculus's scroll-to-rotate-while-holding behaviour).
function M.rotate(delta_str)
    if not grab then return false, "not grabbing" end
    local d = tonumber(delta_str) or 1
    if d == 0 then d = 1 end
    grab.yaw_offset = (grab.yaw_offset + d * STEP_ROT_DEG) % 360.0
    return true, string.format("yaw_offset=%.1f", grab.yaw_offset)
end

-- camera.grab.lift <signed> -- dedicated Z-axis nudge that ignores the
-- active mode. Mirrors `camera.grab.rotate` ; lets a hotkey lift/lower
-- the held actor without flipping `mode` to `z` first.
function M.lift(delta_str)
    if not grab then return false, "not grabbing" end
    local d = tonumber(delta_str) or 1
    if d == 0 then d = 1 end
    grab.z_offset = grab.z_offset + d * STEP_Z
    return true, string.format("z_offset=%.0f", grab.z_offset)
end

-- camera.grab.scale <signed> -- dedicated uniform-scale nudge that
-- ignores the active mode. Mirrors `camera.grab.rotate` ; lets a
-- hotkey grow/shrink the held actor without flipping `mode` to
-- `scale` first.
function M.scale_delta(delta_str)
    if not grab then return false, "not grabbing" end
    local d = tonumber(delta_str) or 1
    if d == 0 then d = 1 end
    local s = grab.scale + d * STEP_SCALE
    if s < SCALE_MIN then s = SCALE_MIN end
    if s > SCALE_MAX then s = SCALE_MAX end
    grab.scale = s
    if feature_actor.is_valid_object(grab.actor) then
        feature_actor.set_actor_scale3d(grab.actor, { X = s, Y = s, Z = s })
    end
    return true, string.format("scale=%.3f", s)
end

-- camera.grab.status -- pure introspection ; no state change.
function M.status()
    if not grab then return true, "idle" end
    return true, string.format(
        "name=%s mode=%s dist=%.0f z=%.0f yaw=%.1f scale=%.3f",
        grab.name, grab.mode, grab.distance, grab.z_offset,
        grab.yaw_offset, grab.scale
    )
end

-- Externally observable: are we currently grabbing? Used by feature_hotkeys
-- to decide whether to dispatch wheel-delta verbs.
function M.is_active() return grab ~= nil end

-- pick_actor_under_reticle()  --  shared "what's under the crosshair?"
-- helper for OTHER features that want to target without going through
-- the Scan tab. Same source priority as M.lookat() (detector first when
-- not in oculus, camera trace as fallback) but with no toast/ack side
-- effects, and returns the raw UObject + a source tag for callers to
-- log themselves. Returns (actor_or_nil, source_string_or_err).
function M.pick_actor_under_reticle()
    if not _oculus_is_active() then
        local a = _detector_pick()
        if feature_actor.is_valid_object(a) then return a, "detector" end
    end
    local hit_actor, _impact, err = _trace_from_camera(LOOKAT_MAX_DISTANCE)
    if feature_actor.is_valid_object(hit_actor) then return hit_actor, "trace" end
    return nil, "no actor under reticle (trace: " .. tostring(err) .. ")"
end

function M.pick_target_under_reticle()
    return pick_target_under_reticle()
end

function M.pick_location_under_reticle()
    return pick_location_under_reticle()
end

function M.pick_hit_under_reticle()
    if not _oculus_is_active() then
        local actor = _detector_pick()
        if feature_actor.is_valid_object(actor) then
            return actor, feature_actor.actor_location(actor) or { X = 0, Y = 0, Z = 0 }, "detector", nil, nil
        end
    end
    local actor, loc, err, details = _trace_from_camera(LOOKAT_MAX_DISTANCE)
    if feature_actor.is_valid_object(actor) then
        return actor, loc or feature_actor.actor_location(actor) or { X = 0, Y = 0, Z = 0 }, "trace", nil, details
    end
    if loc then
        return nil, loc, "trace.geometry", err, details
    end
    return nil, nil, nil, "no hit under reticle (trace: " .. tostring(err) .. ")", details
end

function M.reticle_ray(distance)
    return build_camera_ray(distance or LOOKAT_MAX_DISTANCE)
end

return M
