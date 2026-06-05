-- Smart Oculus duplicate/copy helper.
--
-- One repair-mode reticle action:
--   * building pieces arm the normal build preview copy path
--   * actors/items use the existing Oculus class/item clone path

local M = {}

local feature_actor = require("feature_actor")
local feature_build_preview = require("feature_build_preview")
local feature_grab = require("feature_grab")
local feature_oculus_clone = require("feature_oculus_clone")

local function is_valid(obj)
    return feature_actor.is_valid_object(obj)
end

local function building_piece_index(actor)
    if not is_valid(actor) then return nil end
    local idx
    pcall(function() idx = actor.BuildingPieceDataIndex end)
    if type(idx) == "number" then return idx end
    return nil
end

function M.duplicate()
    local actor, source = feature_grab.pick_actor_under_reticle()
    if not is_valid(actor) then
        return false, tostring(source or "no actor under reticle")
    end

    local idx = building_piece_index(actor)
    if idx ~= nil then
        local ok, detail = feature_build_preview.lookat()
        if ok then
            return true, "building piece idx=" .. tostring(idx) .. "; " .. tostring(detail)
        end
        return false, "building piece copy failed: " .. tostring(detail)
    end

    return feature_oculus_clone.clone()
end

return M
