-- Oculus "clone" helper.
--
-- This is intentionally a class-level duplicate: pick the actor under the
-- freecam reticle, spawn another actor of that same class at the source
-- actor's current transform, then grab the freshly spawned actor for placement.

local M = {}

local feature_actor = require("feature_actor")
local feature_field = require("feature_field")
local feature_grab = require("feature_grab")
local feature_inventory = require("feature_inventory")
local feature_player_core = require("feature_player_core")
local feature_player_spawn = require("feature_player_spawn")

local function is_valid(obj)
    return feature_actor.is_valid_object(obj)
end

local function full_name(obj)
    if not is_valid(obj) or not obj.GetFullName then return nil end
    local ok, value = pcall(function() return obj:GetFullName() end)
    if ok and type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

local function actor_class_path(actor)
    if not is_valid(actor) then return nil, "invalid actor" end

    local cls = nil
    local ok_cls = pcall(function() cls = actor:GetClass() end)
    if not ok_cls or not is_valid(cls) then
        return nil, "actor class unavailable"
    end

    local full = full_name(cls)
    if not full then
        return nil, "actor class full name unavailable"
    end

    local path = full:match("^%S+%s+(.+)$") or full
    path = tostring(path or ""):match("^%s*(.-)%s*$") or ""
    path = path:gsub("^'", ""):gsub("'$", "")
    if path == "" then
        return nil, "actor class path empty"
    end

    return feature_player_core.normalize_uclass_path(path), full
end

local function object_short_name(obj)
    if not is_valid(obj) then return nil end
    local name = feature_actor.short_name_of(obj)
    if name and name ~= "" then return name end
    if obj.GetName then
        local ok, value = pcall(function() return obj:GetName() end)
        if ok and type(value) == "string" and value ~= "" then return value end
    end
    return nil
end

local function object_path(obj)
    local full = full_name(obj)
    if not full then return nil end
    local path = full:match("^%S+%s+(.+)$") or full
    path = tostring(path or ""):match("^%s*(.-)%s*$") or ""
    path = path:gsub("^'", ""):gsub("'$", "")
    if path == "" then return nil end
    return path
end

local function is_runtime_world_item(actor)
    if not is_valid(actor) then return false end
    local cls_name, obj_full
    pcall(function()
        local cls = actor:GetClass()
        if cls then
            if cls.GetFName then
                local fn = cls:GetFName()
                if fn and fn.ToString then cls_name = fn:ToString() end
            end
            if not cls_name and cls.GetName then cls_name = cls:GetName() end
        end
    end)
    pcall(function() obj_full = actor:GetFullName() end)
    local hay = ((cls_name or "") .. " " .. (obj_full or "")):lower()
    return hay:find("runtimespawnedworlditem", 1, true) ~= nil
        or hay:find("bp_runtimespawnedworlditem", 1, true) ~= nil
end

local function read_world_item_data(actor)
    if not is_valid(actor) then return nil end
    for _, method_name in ipairs({ "BP_GetItemData", "GetSpawnedItemData", "GetPrimaryAssociatedItemData" }) do
        local fn = actor[method_name]
        if fn then
            local ok, value = pcall(function() return fn(actor) end)
            if ok and is_valid(value) then return value, method_name end
        end
    end
    for _, field_name in ipairs({ "ItemData", "SpawnedItemData", "PrimaryAssociatedItemData" }) do
        local ok, value = pcall(function() return actor[field_name] end)
        if ok and is_valid(value) then return value, field_name end
    end
    return nil
end

local function actor_transform(actor)
    return {
        loc = feature_actor.actor_location(actor) or { X = 0, Y = 0, Z = 0 },
        rot = feature_actor.actor_rotation(actor) or { Pitch = 0, Yaw = 0, Roll = 0 },
        scale = feature_actor.get_actor_scale3d(actor) or { X = 1, Y = 1, Z = 1 },
    }
end

local function num(v, fallback)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then
        return fallback or 0
    end
    return n
end

local function json_num(v, fallback)
    return string.format("%.9g", num(v, fallback))
end

local function spawn_transform_args(class_path, xform)
    local loc = xform.loc or {}
    local rot = xform.rot or {}
    local scale = xform.scale or {}
    return string.format(
        '%s {"loc":[%s,%s,%s],"rot":[%s,%s,%s],"scale":[%s,%s,%s]}',
        tostring(class_path),
        json_num(loc.X or loc.x, 0),
        json_num(loc.Y or loc.y, 0),
        json_num(loc.Z or loc.z, 0),
        json_num(rot.Pitch or rot.pitch, 0),
        json_num(rot.Yaw or rot.yaw, 0),
        json_num(rot.Roll or rot.roll, 0),
        json_num(scale.X or scale.x, 1),
        json_num(scale.Y or scale.y, 1),
        json_num(scale.Z or scale.z, 1))
end

local function oculus_pawn()
    local ok, obj = pcall(function()
        return feature_field.resolve_root("pawn.OculusComponent.OculusPawn")
    end)
    if ok and is_valid(obj) then return obj end
    return nil
end

local function refused_self(actor)
    local pawn = feature_actor.get_local_pawn()
    if is_valid(pawn) and actor == pawn then
        return "refusing to clone local player pawn"
    end
    local opawn = oculus_pawn()
    if is_valid(opawn) and actor == opawn then
        return "refusing to clone oculus pawn"
    end
    return nil
end

local function clone_runtime_world_item(actor, source)
    local item_data, item_source = read_world_item_data(actor)
    if not is_valid(item_data) then
        return false, "runtime world item has no readable ItemData"
    end

    local item_name = object_short_name(item_data)
    local item_path = object_path(item_data)
    if not item_name or item_name == "" then
        return false, "runtime world item ItemData has no readable asset name"
    end

    local ok_give, give_detail = feature_inventory.give(item_name .. " 1")
    if not ok_give and item_path and item_path ~= "" then
        ok_give, give_detail = feature_player_spawn.spawn_item(item_path .. " 1")
    end
    if not ok_give then
        return false, string.format("item duplicate failed for %s: %s", tostring(item_name), tostring(give_detail))
    end

    local ok_grab, grab_detail = feature_grab.start_lastspawned()
    if not ok_grab then
        return false, string.format("duplicated item %s, but grab failed: %s", tostring(item_name), tostring(grab_detail))
    end

    local short = feature_actor.short_name_of(actor) or "<unnamed item>"
    return true, string.format(
        "duplicated item %s from %s [%s via %s]; %s; %s",
        tostring(item_name),
        tostring(short),
        tostring(source or "trace"),
        tostring(item_source or "ItemData"),
        tostring(give_detail),
        tostring(grab_detail))
end

function M.clone()
    if feature_grab.is_active and feature_grab.is_active() then
        return false, "release the current grabbed actor first"
    end

    local actor, source = feature_grab.pick_actor_under_reticle()
    if not is_valid(actor) then
        return false, "no actor under reticle"
    end

    local self_err = refused_self(actor)
    if self_err then return false, self_err end

    if is_runtime_world_item(actor) then
        return clone_runtime_world_item(actor, source)
    end

    local class_path, class_full = actor_class_path(actor)
    if not class_path then return false, tostring(class_full) end

    local source_transform = actor_transform(actor)
    local short = feature_actor.short_name_of(actor) or "<unnamed>"
    local spawn_args = spawn_transform_args(class_path, source_transform)
    local ok_spawn, spawn_detail = feature_player_spawn.spawn_transform(spawn_args)
    if not ok_spawn then
        return false, string.format("spawn.transform failed for %s (%s): %s",
            tostring(short), tostring(class_path), tostring(spawn_detail))
    end

    local ok_grab, grab_detail = feature_grab.start_lastspawned_preserving_transform(
        source_transform.rot,
        source_transform.scale)
    if not ok_grab then
        return false, string.format("spawned %s from %s, but grab failed: %s",
            tostring(class_path), tostring(short), tostring(grab_detail))
    end

    return true, string.format(
        "cloned %s via %s [%s]; copied loc=(%.1f,%.1f,%.1f) rot=(%.1f,%.1f,%.1f) scale=(%.3f,%.3f,%.3f); %s",
        tostring(short), tostring(class_path), tostring(source or "trace"),
        source_transform.loc.X or 0,
        source_transform.loc.Y or 0,
        source_transform.loc.Z or 0,
        source_transform.rot.Pitch or 0,
        source_transform.rot.Yaw or 0,
        source_transform.rot.Roll or 0,
        source_transform.scale.X or 1,
        source_transform.scale.Y or 1,
        source_transform.scale.Z or 1,
        tostring(grab_detail))
end

return M
