-- feature_buildings.lua
--
-- Player-placed building inspection / serialization.
--
-- Goal arc:
--   v1 (this file)  : describe / count / nearest
--                     read-only; dumps to stdout so we can verify the
--                     schema before committing to JSON.
--   v2 (next round) : world.buildings.export <name>
--                     full enumeration -> JSON file under ipc/.
--   v3 (after that) : world.buildings.import <name>
--                     replay via UBuildModeComponent::Server_SpawnBuilding
--                     ; assumes the existing free-build mod has zeroed
--                     piece requirements (world.foreach BuildingPieceData
--                     clear Requirements).
--
-- Discovery strategy:
--   FindAllOf("BaseBuildingActor") is used as the primary enumerator.
--   The dumps show two manager sources that also know about pieces
--   (AGlobalBuildingManager.BuildingPieces TMap and
--    UBuildingSubsystem.PieceIDToBuildingPieceActor TMap), but TMap
--   iteration from Lua is fiddly and FindAllOf gives us live actors
--   directly. We sanity-check the subsystem count alongside the
--   FindAllOf count in describe so any divergence is visible.
--
-- Per-piece schema we currently capture (subject to validation in v1):
--   piece_id          : uint32  (BuildingPieceID, the registry key)
--   piece_data_index  : int32   (BuildingPieceDataIndex, catalogue idx)
--   piece_data_name   : string  (BuildingPieceData full name)
--   spud_guid         : string  (FGuid as printable string)
--   class_name        : string  (GetClass():GetFullName())
--   short_name        : string  (GetName())
--   x,y,z             : floats  (GetActorLocation)
--   yaw               : float   (GetActorRotation().Yaw -- per FClientVisibleBuildingPieceState)
--   actual_rot        : {pitch,roll,yaw}  -- safety-net; expected pitch=roll=0
--   actual_scale      : {x,y,z}            -- safety-net; expected (1,1,1)
--   stability         : float   (StabilityValue)
--   is_ghosted        : bool
--   is_preview        : bool
--   distance_to_player: float   (only in describe / nearest output)

local M = {}

local feature_actor = require("feature_actor")
local feature_field = require("feature_field")
local feature_inventory = require("feature_inventory")
local feature_player_spawn = require("feature_player_spawn")
local mod_paths = require("mod_paths")

local function is_valid(obj)
    return feature_actor.is_valid_object(obj)
end

-- ---------------------------------------------------------------------------
-- FindAllOf wrapper -- mirrors feature_world.find_first_valid but returns
-- an array of every live (non-stale, non-CDO) instance. Filters out the
-- class default object since it shows up alongside real instances and has
-- no transform / placement state.
-- ---------------------------------------------------------------------------
local function find_all_live(class_name)
    local out = {}
    if not FindAllOf then return out end
    local ok, list = pcall(FindAllOf, class_name)
    if not ok or not list then return out end
    local n = 0
    pcall(function() n = #list end)
    if n == 0 then
        local ok_num, num_val = pcall(function() return list:Num() end)
        if ok_num and type(num_val) == "number" then n = num_val end
    end
    for i = 1, n do
        local eok, entry = pcall(function() return list[i] end)
        if eok and type(entry) == "userdata" and is_valid(entry) then
            local fn
            pcall(function() fn = entry:GetFullName() end)
            if type(fn) == "string" and not fn:find("Default__", 1, true) then
                out[#out + 1] = entry
            end
        end
    end
    return out
end

local function find_first_live(class_name)
    local arr = find_all_live(class_name)
    return arr[1]
end

-- ---------------------------------------------------------------------------
-- Local pawn location, used as the "player position" reference for
-- distance ordering in describe / nearest. nil if the player isn't in
-- a world yet.
-- ---------------------------------------------------------------------------
local function pawn_location()
    local pawn = feature_actor.get_local_pawn()
    if not is_valid(pawn) then return nil end
    if pawn.K2_GetActorLocation then
        local ok, loc = pcall(function() return pawn:K2_GetActorLocation() end)
        if ok and loc then return loc end
    end
    if pawn.GetActorLocation then
        local ok, loc = pcall(function() return pawn:GetActorLocation() end)
        if ok and loc then return loc end
    end
    return nil
end

local function dist_sq(a, b)
    if not a or not b then return math.huge end
    local dx = (a.X or 0) - (b.X or 0)
    local dy = (a.Y or 0) - (b.Y or 0)
    local dz = (a.Z or 0) - (b.Z or 0)
    return dx * dx + dy * dy + dz * dz
end

-- ---------------------------------------------------------------------------
-- Capture a structured snapshot of a single building actor. Best-effort
-- on every field ; missing values come back as nil rather than aborting,
-- so a malformed actor just yields a sparse record instead of failing
-- the whole walk.
-- ---------------------------------------------------------------------------
local function snapshot_piece(actor)
    if not is_valid(actor) then return nil end
    local rec = {}

    pcall(function() rec.short_name = actor:GetName() end)
    pcall(function() rec.full_name = actor:GetFullName() end)
    pcall(function()
        local cls = actor:GetClass()
        if cls then rec.class_name = cls:GetFullName() end
    end)

    pcall(function() rec.piece_id = actor.BuildingPieceID end)
    pcall(function() rec.piece_data_index = actor.BuildingPieceDataIndex end)
    pcall(function()
        local pd = actor.BuildingPieceData
        if pd and pd.IsValid and pd:IsValid() then
            pcall(function() rec.piece_data_name = pd:GetFullName() end)
        end
    end)
    pcall(function()
        local g = actor.SpudGuid
        if g then
            -- FGuid often prints via tostring or :ToString() ; try both.
            local ok_ts, s = pcall(function() return tostring(g) end)
            if ok_ts and type(s) == "string" then rec.spud_guid = s end
            if not rec.spud_guid and g.ToString then
                local ok2, s2 = pcall(function() return g:ToString() end)
                if ok2 and type(s2) == "string" then rec.spud_guid = s2 end
            end
        end
    end)

    pcall(function() rec.stability = actor.StabilityValue end)
    pcall(function() rec.is_ghosted = actor.bIsGhosted end)
    pcall(function() rec.is_preview = actor.bIsPreview end)

    -- Location (preferred on the schema)
    local loc
    if actor.K2_GetActorLocation then
        pcall(function() loc = actor:K2_GetActorLocation() end)
    end
    if not loc and actor.GetActorLocation then
        pcall(function() loc = actor:GetActorLocation() end)
    end
    if loc then
        rec.x = loc.X; rec.y = loc.Y; rec.z = loc.Z
    end

    -- Full rotation. yaw remains the compatibility field used by old
    -- captures; pitch/roll allow SPUD-backed/interactable actors to
    -- replay with their live transform when the game supports it.
    local rot
    if actor.K2_GetActorRotation then
        pcall(function() rot = actor:K2_GetActorRotation() end)
    end
    if not rot and actor.GetActorRotation then
        pcall(function() rot = actor:GetActorRotation() end)
    end
    if rot then
        rec.pitch = rot.Pitch
        rec.yaw = rot.Yaw
        rec.roll = rot.Roll
        rec.actual_rot = { pitch = rot.Pitch, roll = rot.Roll, yaw = rot.Yaw }
    end

    -- Scale. Structural pieces usually persist unit scale only, but
    -- interactable/SPUD-backed building actors can carry full scale.
    local scale
    if actor.K2_GetActorScale3D then
        pcall(function() scale = actor:K2_GetActorScale3D() end)
    end
    if not scale and actor.GetActorScale3D then
        pcall(function() scale = actor:GetActorScale3D() end)
    end
    if scale then
        rec.scale_x = scale.X
        rec.scale_y = scale.Y
        rec.scale_z = scale.Z
        rec.actual_scale = { x = scale.X, y = scale.Y, z = scale.Z }
    end

    return rec
end

-- ---------------------------------------------------------------------------
-- Manager / subsystem cross-check counts, so we can see at a glance
-- whether FindAllOf agrees with the registry.
-- ---------------------------------------------------------------------------
local function manager_counts()
    local counts = { findall = nil, manager = nil, subsystem = nil }

    local actors = find_all_live("BaseBuildingActor")
    counts.findall = #actors

    local mgr = find_first_live("GlobalBuildingManager")
    if is_valid(mgr) then
        pcall(function()
            local m = mgr.BuildingPieces
            if m then
                local n
                pcall(function() n = m:Num() end)
                if type(n) ~= "number" then pcall(function() n = #m end) end
                counts.manager = n
            end
        end)
    end

    local sub = find_first_live("BuildingSubsystem")
    if is_valid(sub) then
        pcall(function()
            local m = sub.PieceIDToBuildingPieceActor
            if m then
                local n
                pcall(function() n = m:Num() end)
                if type(n) ~= "number" then pcall(function() n = #m end) end
                counts.subsystem = n
            end
        end)
    end

    return counts
end

-- ---------------------------------------------------------------------------
-- Authoritative enumeration: walk UBuildingSubsystem.PieceIDToBuildingPieceActor
-- (TMap<uint32, ABaseBuildingActor*>). This is the registry the placement
-- pipeline maintains, so a piece is in this map iff it has been
-- successfully registered as a player-placed structure. FindAllOf is
-- noisier (preview/ghost residue, CDOs) ; we keep it as a fallback only.
--
-- Returns: array of ABaseBuildingActor* userdata, in undefined order.
-- ---------------------------------------------------------------------------
local function enumerate_registered_pieces()
    local out = {}
    local sub = find_first_live("BuildingSubsystem")
    if is_valid(sub) then
        local map
        pcall(function() map = sub.PieceIDToBuildingPieceActor end)
        if map and map.ForEach then
            local ok = pcall(function()
                map:ForEach(function(_k, v)
                    -- TMap<uint32, ABaseBuildingActor*> ; v is the actor handle
                    local actor = v
                    -- UE4SS sometimes wraps the value in a property accessor ;
                    -- try :get() if direct use isn't a userdata.
                    if type(actor) ~= "userdata" then
                        local got
                        pcall(function() got = v:get() end)
                        if type(got) == "userdata" then actor = got end
                    end
                    if type(actor) == "userdata" and is_valid(actor) then
                        out[#out + 1] = actor
                    end
                end)
            end)
            if ok and #out > 0 then return out end
        end
    end

    -- Fallback: filter FindAllOf by manager.BuildingPieces membership
    -- (or just take everything FindAllOf returns if even that's missing).
    -- This branch should only fire if the subsystem map walk failed.
    print("[RSDWTools] buildings: subsystem map walk failed, falling back to FindAllOf")
    return find_all_live("BaseBuildingActor")
end

-- ---------------------------------------------------------------------------
-- Public: print a record to stdout in a single readable block. Used by
-- describe / nearest. Keeps numerics terse.
-- ---------------------------------------------------------------------------
local function fmt_num(v)
    if type(v) ~= "number" then return tostring(v) end
    return string.format("%.2f", v)
end

local function print_record(rec, distance)
    print("[RSDWTools] -- building piece --")
    if distance then
        print(string.format("  distance        : %.1f", distance))
    end
    print(string.format("  short_name      : %s", tostring(rec.short_name)))
    print(string.format("  class_name      : %s", tostring(rec.class_name)))
    print(string.format("  piece_id        : %s", tostring(rec.piece_id)))
    print(string.format("  piece_data_idx  : %s", tostring(rec.piece_data_index)))
    print(string.format("  piece_data_name : %s", tostring(rec.piece_data_name)))
    print(string.format("  spud_guid       : %s", tostring(rec.spud_guid)))
    print(string.format("  location        : (%s, %s, %s)",
        fmt_num(rec.x), fmt_num(rec.y), fmt_num(rec.z)))
    print(string.format("  yaw             : %s", fmt_num(rec.yaw)))
    if rec.actual_rot then
        print(string.format("  actual_rot      : pitch=%s roll=%s yaw=%s",
            fmt_num(rec.actual_rot.pitch), fmt_num(rec.actual_rot.roll), fmt_num(rec.actual_rot.yaw)))
    end
    if rec.actual_scale then
        print(string.format("  actual_scale    : (%s, %s, %s)",
            fmt_num(rec.actual_scale.x), fmt_num(rec.actual_scale.y), fmt_num(rec.actual_scale.z)))
    end
    print(string.format("  stability       : %s", fmt_num(rec.stability)))
    print(string.format("  is_ghosted      : %s  is_preview: %s",
        tostring(rec.is_ghosted), tostring(rec.is_preview)))
end

-- ---------------------------------------------------------------------------
-- world.buildings.count
-- Quick "how many pieces are alive right now?" probe. Returns the
-- FindAllOf number to the caller for the router's ok detail line ;
-- also logs the manager + subsystem cross-check.
-- ---------------------------------------------------------------------------
function M.count()
    local counts = manager_counts()
    print(string.format(
        "[RSDWTools] buildings.count: findall=%s manager.BuildingPieces=%s subsystem.PieceIDToBuildingPieceActor=%s",
        tostring(counts.findall), tostring(counts.manager), tostring(counts.subsystem)))
    if counts.findall == nil then
        return false, "FindAllOf unavailable"
    end
    return true, string.format("findall=%d", counts.findall)
end

-- ---------------------------------------------------------------------------
-- world.buildings.nearest
-- Find and dump the single closest BaseBuildingActor to the player.
-- ---------------------------------------------------------------------------
function M.nearest()
    local origin = pawn_location()
    if not origin then
        return false, "could not locate player pawn"
    end
    local actors = enumerate_registered_pieces()
    if #actors == 0 then return false, "no registered building pieces live" end

    local best, best_d2
    for i = 1, #actors do
        local a = actors[i]
        local loc
        if a.K2_GetActorLocation then
            pcall(function() loc = a:K2_GetActorLocation() end)
        end
        if not loc and a.GetActorLocation then
            pcall(function() loc = a:GetActorLocation() end)
        end
        if loc then
            local d2 = dist_sq(origin, loc)
            if not best_d2 or d2 < best_d2 then
                best, best_d2 = a, d2
            end
        end
    end

    if not best then return false, "no piece had a readable location" end
    local rec = snapshot_piece(best)
    print_record(rec, math.sqrt(best_d2))
    return true, string.format("piece_id=%s dist=%.1f",
        tostring(rec.piece_id), math.sqrt(best_d2))
end

-- ---------------------------------------------------------------------------
-- world.buildings.describe [N]
-- Logs cross-check counts and dumps the N closest pieces (default 3).
-- This is the schema-validation pass: with this output we can verify
-- whether every field we plan to serialize is actually populated, and
-- whether actual_rot/actual_scale ever deviate from the assumed
-- yaw-only / unit-scale invariants.
-- ---------------------------------------------------------------------------
function M.describe(args_str)
    local n_want = 3
    if type(args_str) == "string" then
        local s = args_str:match("^%s*(%S+)") or ""
        if s:lower() == "all" then
            n_want = math.huge
        else
            local v = tonumber(s)
            if v and v > 0 then n_want = math.floor(v) end
        end
    end

    local counts, _ = manager_counts()
    local actors = enumerate_registered_pieces()
    print(string.format(
        "[RSDWTools] buildings.describe: registered=%d (findall=%s manager=%s subsystem=%s)",
        #actors, tostring(counts.findall), tostring(counts.manager), tostring(counts.subsystem)))
    if #actors == 0 then
        return true, "0 pieces live"
    end

    local origin = pawn_location()
    if not origin then
        -- No pawn -> just dump the first n_want we found, no distance sort.
        local n = math.min(n_want, #actors)
        for i = 1, n do
            local rec = snapshot_piece(actors[i])
            if rec then print_record(rec, nil) end
        end
        return true, string.format("dumped %d (no pawn for distance sort)", n)
    end

    -- Build (actor, dist) list, sort, dump top-N.
    local ranked = {}
    for i = 1, #actors do
        local a = actors[i]
        local loc
        if a.K2_GetActorLocation then
            pcall(function() loc = a:K2_GetActorLocation() end)
        end
        if not loc and a.GetActorLocation then
            pcall(function() loc = a:GetActorLocation() end)
        end
        if loc then
            ranked[#ranked + 1] = { a = a, d2 = dist_sq(origin, loc) }
        end
    end
    table.sort(ranked, function(x, y) return x.d2 < y.d2 end)

    local n = math.min(n_want, #ranked)
    for i = 1, n do
        local rec = snapshot_piece(ranked[i].a)
        if rec then print_record(rec, math.sqrt(ranked[i].d2)) end
    end
    return true, string.format("dumped %d of %d (origin=pawn)", n, #ranked)
end

-- ---------------------------------------------------------------------------
-- JSON encoding (minimal, hand-rolled to match the rest of the mod ;
-- no cjson dependency). Numbers are emitted with %.6g so floats round-trip
-- safely. Strings escape the same way feature_scan / feature_ui do.
-- ---------------------------------------------------------------------------
local function json_escape_str(s)
    local escaped = tostring(s or "")
        :gsub("\\", "\\\\")
        :gsub('"', '\\"')
        :gsub("\n", "\\n")
        :gsub("\r", "\\r")
        :gsub("\t", "\\t")
    return '"' .. escaped .. '"'
end

local function json_num(v)
    if type(v) ~= "number" then return "null" end
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if v == math.floor(v) and math.abs(v) < 1e15 then
        return string.format("%d", v)
    end
    return string.format("%.6g", v)
end

local function json_bool(v)
    if v == nil then return "null" end
    return v and "true" or "false"
end

local function json_str_or_null(v)
    if v == nil then return "null" end
    return json_escape_str(v)
end

-- Encodes one piece record as a flat JSON object. We deliberately keep
-- the schema small + flat so a human can hand-edit a JSON if needed.
-- Fields the import path needs are required ; cosmetic / debug fields
-- (class_name, piece_data_name, stability) are kept for traceability
-- across a save move but ignored by replay.
local function encode_piece(rec)
    local parts = {
        '"piece_id":' .. json_num(rec.piece_id),
        '"piece_data_index":' .. json_num(rec.piece_data_index),
        '"piece_data_name":' .. json_str_or_null(rec.piece_data_name),
        '"class_name":' .. json_str_or_null(rec.class_name),
        '"x":' .. json_num(rec.x),
        '"y":' .. json_num(rec.y),
        '"z":' .. json_num(rec.z),
        '"pitch":' .. json_num(rec.pitch),
        '"yaw":' .. json_num(rec.yaw),
        '"roll":' .. json_num(rec.roll),
        '"scale_x":' .. json_num(rec.scale_x),
        '"scale_y":' .. json_num(rec.scale_y),
        '"scale_z":' .. json_num(rec.scale_z),
        '"spud_guid":' .. json_str_or_null(rec.spud_guid),
        '"stability":' .. json_num(rec.stability),
        '"is_ghosted":' .. json_bool(rec.is_ghosted),
    }
    return "{" .. table.concat(parts, ",") .. "}"
end

local function full_name(obj)
    if not is_valid(obj) or not obj.GetFullName then return nil end
    local ok, value = pcall(function() return obj:GetFullName() end)
    if ok and type(value) == "string" and value ~= "" then return value end
    return nil
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

local function read_item_count(actor)
    if not is_valid(actor) then return 1 end
    for _, field_name in ipairs({ "Count", "ItemCount", "StackCount", "Quantity", "Amount" }) do
        local ok, value = pcall(function() return actor[field_name] end)
        local n = ok and tonumber(value) or nil
        if n and n >= 1 then return math.floor(n) end
    end
    return 1
end

local function actor_class_full_name(actor)
    if not is_valid(actor) then return nil end
    local cls
    pcall(function() cls = actor:GetClass() end)
    return full_name(cls)
end

local function snapshot_runtime_item(actor)
    if not is_valid(actor) then return nil, "invalid actor" end
    if feature_inventory._is_runtime_world_item
       and not feature_inventory._is_runtime_world_item(actor) then
        return nil, "not runtime item"
    end

    local item_data, item_source = read_world_item_data(actor)
    if not is_valid(item_data) then
        return nil, "no readable ItemData"
    end

    local loc = feature_actor.actor_location(actor)
    if not loc then return nil, "no actor location" end
    local rot = feature_actor.actor_rotation(actor) or { Pitch = 0, Yaw = 0, Roll = 0 }
    local scale = feature_actor.get_actor_scale3d(actor) or { X = 1, Y = 1, Z = 1 }

    return {
        actor_name      = object_short_name(actor),
        actor_class     = actor_class_full_name(actor),
        item_asset_name = object_short_name(item_data),
        item_asset_path = object_path(item_data),
        item_source     = item_source,
        count           = read_item_count(actor),
        x               = loc.X,
        y               = loc.Y,
        z               = loc.Z,
        pitch           = rot.Pitch,
        yaw             = rot.Yaw,
        roll            = rot.Roll,
        scale_x         = scale.X,
        scale_y         = scale.Y,
        scale_z         = scale.Z,
    }
end

local function encode_item(rec)
    local parts = {
        '"actor_name":' .. json_str_or_null(rec.actor_name),
        '"actor_class":' .. json_str_or_null(rec.actor_class),
        '"item_asset_name":' .. json_str_or_null(rec.item_asset_name),
        '"item_asset_path":' .. json_str_or_null(rec.item_asset_path),
        '"item_source":' .. json_str_or_null(rec.item_source),
        '"count":' .. json_num(rec.count),
        '"x":' .. json_num(rec.x),
        '"y":' .. json_num(rec.y),
        '"z":' .. json_num(rec.z),
        '"pitch":' .. json_num(rec.pitch),
        '"yaw":' .. json_num(rec.yaw),
        '"roll":' .. json_num(rec.roll),
        '"scale_x":' .. json_num(rec.scale_x),
        '"scale_y":' .. json_num(rec.scale_y),
        '"scale_z":' .. json_num(rec.scale_z),
    }
    return "{" .. table.concat(parts, ",") .. "}"
end

-- ---------------------------------------------------------------------------
-- Output path: <mod_root>\ipc\building\<name>.json
-- One file per export, no fixed prefix ; the WPF "Building Service" tab
-- enumerates everything in this folder regardless of filename so users
-- can drop shared .json files in directly.
-- ---------------------------------------------------------------------------
local function sanitize_name(name)
    -- Allow letters, digits, dash, underscore. Anything else becomes _.
    -- Empty / weird input falls back to "default".
    local s = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    -- Strip a trailing .json so users can paste full filenames.
    s = s:gsub("%.[Jj][Ss][Oo][Nn]$", "")
    if s == "" then return "default" end
    return (s:gsub("[^%w%-_]", "_"))
end

local function export_path_for(name)
    local dir = mod_paths.buildings_dir()
    if not dir then return nil end
    return dir .. "\\" .. sanitize_name(name) .. ".json"
end

-- ---------------------------------------------------------------------------
-- world.buildings.export <name>
-- ---------------------------------------------------------------------------
-- world.buildings.export <name> [ghosts_only]
-- Walks the registered pieces, snapshots each, writes JSON. Skips the
-- distance / actual_rot / actual_scale / spud_guid fields entirely ;;
-- describe verified the schema invariants so we don't carry the noise.
-- Pieces with missing required fields (no location, no piece_data_index)
-- are skipped with a log line instead of aborting.
--
-- The optional `ghosts_only` flag filters to pieces with is_ghosted=true.
-- Used by the WPF "Commit All Ghosts" workaround : capture ghosts to a
-- temp build, delete them, redeliver as real pieces (the engine's
-- Donation path doesn't seem to actually flip persistent ghosts to real
-- regardless of pre-filled CompletionStatus, so capture+rebuild is the
-- only reliable way).
-- ---------------------------------------------------------------------------
function M.export(args_str)
    local raw = tostring(args_str or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local ghosts_only = false
    local include_items = false
    -- Strip a trailing "include_items" / "items" token before anchor
    -- parsing so WPF can append it after anchor metadata.
    local stripped_i, n_i = raw:gsub("%s+[iI][nN][cC][lL][uU][dD][eE]_[iI][tT][eE][mM][sS]%s*$", "")
    if n_i > 0 then
        include_items = true
        raw = stripped_i
    else
        local stripped_items, n_items = raw:gsub("%s+[iI][tT][eE][mM][sS]%s*$", "")
        if n_items > 0 then
            include_items = true
            raw = stripped_items
        end
    end
    -- Strip a trailing "ghosts_only" token (case-insensitive) so the
    -- name parser doesn't fold it into the filename.
    local stripped, n_replaced = raw:gsub("%s+[gG][hH][oO][sS][tT][sS]_[oO][nN][lL][yY]%s*$", "")
    if n_replaced > 0 then
        ghosts_only = true
        raw = stripped
    end

    -- Optional anchor=<int> token : when present we record the chosen
    -- piece_data_index in the JSON top level so build.preview.preview
    -- can promote that piece to the reticle on delivery. Stripped from
    -- the name parser the same way ghosts_only is.
    local anchor_idx = nil
    local stripped_a, n_a = raw:gsub("%s+[aA][nN][cC][hH][oO][rR]=(%-?%d+)%s*$", function(num)
        anchor_idx = tonumber(num)
        return ""
    end)
    if n_a > 0 then raw = stripped_a end

    -- Optional anchor_pid=<int> token : the per-instance BuildingPieceID
    -- of the actor the user actually pointed at. piece_data_index alone
    -- is ambiguous when the build contains multiple copies of the same
    -- archetype (e.g. four foundations). With this we can pick the
    -- exact instance and physically swap it to position 1 so the
    -- preview path (which always uses pieces[1] as the anchor) lands
    -- on the right spot. Tokens can appear in either order.
    local anchor_pid = nil
    for _ = 1, 2 do
        local stripped_p, n_p = raw:gsub("%s+[aA][nN][cC][hH][oO][rR]_[pP][iI][dD]=(%-?%d+)%s*$",
            function(num)
                anchor_pid = tonumber(num)
                return ""
            end)
        if n_p > 0 then raw = stripped_p end
        local stripped_a2, n_a2 = raw:gsub("%s+[aA][nN][cC][hH][oO][rR]=(%-?%d+)%s*$", function(num)
            anchor_idx = tonumber(num)
            return ""
        end)
        if n_a2 > 0 then raw = stripped_a2 end
        if n_p == 0 and n_a2 == 0 then break end
    end

    local name = sanitize_name(raw)
    local out_path = export_path_for(name)
    if not out_path then
        return false, "could not resolve mod ipc directory (game not loaded?)"
    end

    local actors = enumerate_registered_pieces()
    if #actors == 0 then
        return false, "no registered building pieces ; nothing to export"
    end

    local kept = {}
    local skipped = 0
    local filtered_out = 0
    for i = 1, #actors do
        local rec = snapshot_piece(actors[i])
        if rec
            and type(rec.piece_data_index) == "number"
            and type(rec.x) == "number"
            and type(rec.y) == "number"
            and type(rec.z) == "number" then
            if ghosts_only and rec.is_ghosted ~= true then
                filtered_out = filtered_out + 1
            else
                kept[#kept + 1] = rec
            end
        else
            skipped = skipped + 1
        end
    end

    -- Sort by Z ascending so the import path naturally rebuilds
    -- foundations before walls before roofs (stability dependencies).
    table.sort(kept, function(a, b) return (a.z or 0) < (b.z or 0) end)

    -- If an anchor was specified, physically promote that piece to
    -- position 1. Preview/import always treats pieces[1] as the anchor,
    -- so making it the actual anchor at capture time means we don't
    -- need any anchor-lookup logic at delivery time. Match priority:
    --   1. piece_id == anchor_pid   (per-instance ; unique)
    --   2. piece_data_index == anchor_idx (archetype ; first match wins)
    -- If neither hits, leave order alone and just record the metadata.
    local anchor_resolved_pid = nil
    if anchor_pid then
        for i = 1, #kept do
            if kept[i].piece_id == anchor_pid then
                if i > 1 then
                    local row = table.remove(kept, i)
                    table.insert(kept, 1, row)
                end
                anchor_resolved_pid = anchor_pid
                break
            end
        end
    end
    if not anchor_resolved_pid and anchor_idx then
        for i = 1, #kept do
            if kept[i].piece_data_index == anchor_idx then
                if i > 1 then
                    local row = table.remove(kept, i)
                    table.insert(kept, 1, row)
                end
                break
            end
        end
    end

    local items = {}
    local item_skipped = 0
    if include_items then
        local enumerator = feature_inventory._enumerate_runtime_world_items
        if type(enumerator) == "function" then
            local runtime_items = enumerator()
            for i = 1, #runtime_items do
                local rec, why = snapshot_runtime_item(runtime_items[i])
                if rec
                   and (type(rec.item_asset_name) == "string" or type(rec.item_asset_path) == "string")
                   and type(rec.x) == "number"
                   and type(rec.y) == "number"
                   and type(rec.z) == "number" then
                    items[#items + 1] = rec
                else
                    item_skipped = item_skipped + 1
                    print(string.format("[RSDWTools] buildings.export: skipped runtime item %d (%s)",
                        i, tostring(why or "missing required fields")))
                end
            end
        else
            item_skipped = item_skipped + 1
            print("[RSDWTools] buildings.export: runtime item enumerator unavailable")
        end
    end

    local body_parts = {}
    body_parts[#body_parts + 1] = '{"schema":"rsdwtools.buildings.v1"'
    body_parts[#body_parts + 1] = ',"name":' .. json_escape_str(name)
    body_parts[#body_parts + 1] = ',"generated_unix":' .. tostring(os.time())
    body_parts[#body_parts + 1] = ',"count":' .. tostring(#kept)
    body_parts[#body_parts + 1] = ',"skipped":' .. tostring(skipped)
    if include_items then
        body_parts[#body_parts + 1] = ',"item_count":' .. tostring(#items)
        body_parts[#body_parts + 1] = ',"item_skipped":' .. tostring(item_skipped)
    end
    if anchor_idx then
        body_parts[#body_parts + 1] = ',"anchor_piece_data_index":' .. tostring(anchor_idx)
    end
    if anchor_pid then
        body_parts[#body_parts + 1] = ',"anchor_piece_id":' .. tostring(anchor_pid)
    end
    body_parts[#body_parts + 1] = ',"pieces":['
    for i = 1, #kept do
        if i > 1 then body_parts[#body_parts + 1] = "," end
        body_parts[#body_parts + 1] = encode_piece(kept[i])
    end
    if include_items then
        body_parts[#body_parts + 1] = '],"items":['
        for i = 1, #items do
            if i > 1 then body_parts[#body_parts + 1] = "," end
            body_parts[#body_parts + 1] = encode_item(items[i])
        end
    end
    body_parts[#body_parts + 1] = ']}'
    local body = table.concat(body_parts)

    local ok, detail = mod_paths.write_atomic(out_path, body)
    if not ok then
        return false, "write failed: " .. tostring(detail)
    end
    if ghosts_only then
        print(string.format("[RSDWTools] buildings.export: wrote %d ghost pieces (filtered_out=%d skipped=%d items=%d item_skipped=%d) -> %s",
            #kept, filtered_out, skipped, #items, item_skipped, out_path))
        return true, string.format("count=%d filtered_out=%d skipped=%d%s path=%s",
            #kept, filtered_out, skipped,
            include_items and string.format(" items=%d item_skipped=%d", #items, item_skipped) or "",
            out_path)
    end
    print(string.format("[RSDWTools] buildings.export: wrote %d pieces (skipped %d items=%d item_skipped=%d) -> %s",
        #kept, skipped, #items, item_skipped, out_path))
    return true, string.format("count=%d skipped=%d%s path=%s",
        #kept, skipped,
        include_items and string.format(" items=%d item_skipped=%d", #items, item_skipped) or "",
        out_path)
end

-- ===========================================================================
-- IMPORT (v3): rebuild pieces from a previously exported JSON file.
--
-- Strategy:
--   1. Resolve player controller -> BuildModeComponent (the dump shows
--      ADominionPlayerController.BuildModeComponent at offset 0x0C60).
--   2. For each piece in the JSON, build an FTransform from
--      (x,y,z) + yaw and call Server_SpawnBuilding(piece_data_index,
--      transform, false, AvailableInventories).
--   3. AvailableInventories is passed empty -- the existing free-build
--      mod (world.foreach BuildingPieceData clear Requirements) zeros
--      cost, so the function should not need to consume from any
--      inventory.
--
-- Caveats called out up-front:
--   * No "creative-mode" placement bypass on this build that we know
--     of -- if Server_SpawnBuilding still validates collision/stability
--     against the live world, pieces in clipped/unsupported spots will
--     silently no-op.
--   * Yaw-only rebuild matches FClientVisibleBuildingPieceState ; pitch
--     and roll were always 0 in describe output. Quat is built from yaw.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Tiny ad-hoc JSON reader. Our exports are simple: one flat object with
-- "pieces" : [ { ...flat... }, ... ]. We don't need a full parser.
-- We pull the pieces array and split into individual {...} substrings,
-- then for each known field do a regex extract. This keeps us free of
-- third-party JSON deps.
-- ---------------------------------------------------------------------------
local function json_unescape(s)
    return (s:gsub("\\n", "\n"):gsub("\\r", "\r"):gsub("\\t", "\t")
             :gsub('\\"', '"'):gsub("\\\\", "\\"))
end

local function extract_named_array(body, key, required)
    -- Find "<key>":[ ... ] by paren-matching square brackets.
    local start_i = body:find('"' .. key .. '"%s*:%s*%[')
    if not start_i then
        if required == false then return nil, nil end
        return nil, "no " .. tostring(key) .. " array in JSON"
    end
    local arr_open = body:find("%[", start_i)
    if not arr_open then return nil, "malformed " .. tostring(key) .. " array" end

    local depth = 0
    local i = arr_open
    local n = #body
    local arr_close
    while i <= n do
        local c = body:sub(i, i)
        if c == "[" then depth = depth + 1
        elseif c == "]" then
            depth = depth - 1
            if depth == 0 then arr_close = i; break end
        elseif c == '"' then
            -- skip string
            i = i + 1
            while i <= n do
                local cc = body:sub(i, i)
                if cc == "\\" then i = i + 2
                elseif cc == '"' then break
                else i = i + 1 end
            end
        end
        i = i + 1
    end
    if not arr_close then return nil, "unterminated " .. tostring(key) .. " array" end
    return body:sub(arr_open + 1, arr_close - 1)
end

local function split_objects(arr_body)
    -- Walk arr_body and split into top-level {...} objects, ignoring
    -- braces inside strings. arr_body is the inside of [ ... ].
    local out = {}
    local i, n = 1, #arr_body
    while i <= n do
        -- skip whitespace + commas
        while i <= n and (arr_body:sub(i, i):match("[%s,]")) do i = i + 1 end
        if i > n then break end
        if arr_body:sub(i, i) ~= "{" then
            -- bail ; malformed
            return out
        end
        local depth = 0
        local start = i
        while i <= n do
            local c = arr_body:sub(i, i)
            if c == "{" then depth = depth + 1
            elseif c == "}" then
                depth = depth - 1
                if depth == 0 then
                    out[#out + 1] = arr_body:sub(start, i)
                    i = i + 1
                    break
                end
            elseif c == '"' then
                i = i + 1
                while i <= n do
                    local cc = arr_body:sub(i, i)
                    if cc == "\\" then i = i + 2
                    elseif cc == '"' then break
                    else i = i + 1 end
                end
            end
            i = i + 1
        end
    end
    return out
end

local function field_num(obj_body, key)
    local v = obj_body:match('"' .. key .. '"%s*:%s*(-?[%d%.eE%+%-]+)')
    return v and tonumber(v) or nil
end

local function field_str(obj_body, key)
    local v = obj_body:match('"' .. key .. '"%s*:%s*"((\\.?[^"\\]*)*)"')
    -- The pattern above is fragile under nested escapes ; fall back to
    -- a permissive grab if needed.
    if v then return json_unescape(v) end
    local raw = obj_body:match('"' .. key .. '"%s*:%s*"([^"]*)"')
    return raw and json_unescape(raw) or nil
end

local function field_bool(obj_body, key)
    local v = obj_body:match('"' .. key .. '"%s*:%s*(%a+)')
    if v == "true" then return true end
    if v == "false" then return false end
    return nil
end

local class_path_from_full

local function parse_pieces(body)
    local arr, err = extract_named_array(body, "pieces", true)
    if not arr then return nil, err end
    local objs = split_objects(arr)
    local out = {}
    for i = 1, #objs do
        local o = objs[i]
        out[#out + 1] = {
            piece_id         = field_num(o, "piece_id"),
            piece_data_index = field_num(o, "piece_data_index"),
            piece_data_name  = field_str(o, "piece_data_name"),
            class_name       = field_str(o, "class_name"),
            x                = field_num(o, "x"),
            y                = field_num(o, "y"),
            z                = field_num(o, "z"),
            pitch            = field_num(o, "pitch"),
            yaw              = field_num(o, "yaw"),
            roll             = field_num(o, "roll"),
            scale_x          = field_num(o, "scale_x"),
            scale_y          = field_num(o, "scale_y"),
            scale_z          = field_num(o, "scale_z"),
            spud_guid        = field_str(o, "spud_guid"),
            stability        = field_num(o, "stability"),
            is_ghosted       = field_bool(o, "is_ghosted"),
        }
    end
    return out
end

local function parse_items(body)
    local arr, err = extract_named_array(body, "items", false)
    if not arr then
        if err then return nil, err end
        return {}
    end
    local objs = split_objects(arr)
    local out = {}
    for i = 1, #objs do
        local o = objs[i]
        out[#out + 1] = {
            actor_name      = field_str(o, "actor_name"),
            actor_class     = field_str(o, "actor_class"),
            item_asset_name = field_str(o, "item_asset_name"),
            item_asset_path = field_str(o, "item_asset_path"),
            item_source     = field_str(o, "item_source"),
            count           = field_num(o, "count"),
            x               = field_num(o, "x"),
            y               = field_num(o, "y"),
            z               = field_num(o, "z"),
            pitch           = field_num(o, "pitch"),
            yaw             = field_num(o, "yaw"),
            roll            = field_num(o, "roll"),
            scale_x         = field_num(o, "scale_x"),
            scale_y         = field_num(o, "scale_y"),
            scale_z         = field_num(o, "scale_z"),
        }
    end
    return out
end

local function parse_actors(body)
    local arr, err = extract_named_array(body, "actors", false)
    if not arr then
        if err then return nil, err end
        return {}
    end
    local objs = split_objects(arr)
    local out = {}
    for i = 1, #objs do
        local o = objs[i]
        local class_path = field_str(o, "class_path")
            or field_str(o, "path")
            or field_str(o, "bp")
            or field_str(o, "class")
        if not class_path then
            class_path = class_path_from_full(field_str(o, "actor_class"))
        end
        out[#out + 1] = {
            actor_name  = field_str(o, "actor_name"),
            actor_class = field_str(o, "actor_class"),
            class_path  = class_path,
            x           = field_num(o, "x"),
            y           = field_num(o, "y"),
            z           = field_num(o, "z"),
            pitch       = field_num(o, "pitch"),
            yaw         = field_num(o, "yaw"),
            roll        = field_num(o, "roll"),
            scale_x     = field_num(o, "scale_x"),
            scale_y     = field_num(o, "scale_y"),
            scale_z     = field_num(o, "scale_z"),
        }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Player / build-mode resolution. We need the live ADominionPlayerController
-- and its UBuildModeComponent (offset 0x0C60 in dumps).
-- ---------------------------------------------------------------------------
local function get_local_pc_and_bmc()
    -- Use feature_net for the canonical local-PC lookup so this
    -- always agrees with the rest of the mod in multiplayer.
    local feature_net = require("feature_net")
    local pc = feature_net.local_controller()
    if not is_valid(pc) then return nil, nil, "no player controller" end

    local bmc
    pcall(function() bmc = pc.BuildModeComponent end)
    if not is_valid(bmc) and pc.GetBuildModeComponent then
        pcall(function() bmc = pc:GetBuildModeComponent() end)
    end
    if not is_valid(bmc) then return pc, nil, "no BuildModeComponent on player controller" end
    return pc, bmc, nil
end

-- ---------------------------------------------------------------------------
-- Build an FTransform-shaped Lua table from x/y/z + full rotator +
-- scale. UE4SS will coerce a table with the same field names as the
-- struct layout into the parameter. Old JSON that only has yaw falls
-- back to pitch=0, roll=0, scale=1.
-- ---------------------------------------------------------------------------
local function rotator_to_quat(pitch_deg, yaw_deg, roll_deg)
    local pitch = (pitch_deg or 0) * math.pi / 180.0
    local yaw = (yaw_deg or 0) * math.pi / 180.0
    local roll = (roll_deg or 0) * math.pi / 180.0
    local cy, sy = math.cos(yaw * 0.5), math.sin(yaw * 0.5)
    local cp, sp = math.cos(pitch * 0.5), math.sin(pitch * 0.5)
    local cr, sr = math.cos(roll * 0.5), math.sin(roll * 0.5)
    return {
        -- Match Unreal's FRotator::Quaternion sign convention. Using
        -- the usual math-library XYZ convention flips Pitch/Roll while
        -- leaving Yaw looking correct.
        X = cr * sp * sy - sr * cp * cy,
        Y = -cr * sp * cy - sr * cp * sy,
        Z = cr * cp * sy - sr * sp * cy,
        W = cr * cp * cy + sr * sp * sy,
    }
end

local function make_transform(x, y, z, pitch_deg, yaw_deg, roll_deg, sx, sy, sz)
    return {
        Rotation    = rotator_to_quat(pitch_deg, yaw_deg, roll_deg),
        Translation = { X = x or 0, Y = y or 0, Z = z or 0 },
        Scale3D     = { X = sx or 1, Y = sy or 1, Z = sz or 1 },
    }
end

local function normalize_count(v)
    local n = tonumber(v) or 1
    if n < 1 then n = 1 end
    if n > 9999 then n = 9999 end
    return math.floor(n)
end

function class_path_from_full(full)
    if type(full) ~= "string" or full == "" then return nil end
    local path = full:match("^%S+%s+(.+)$") or full
    path = tostring(path or ""):match("^%s*(.-)%s*$") or ""
    path = path:gsub("^'", ""):gsub("'$", "")
    if path == "" then return nil end
    return path
end

local function apply_actor_transform(actor, rec)
    if not is_valid(actor) or type(rec) ~= "table" then
        return false, "invalid actor/record"
    end
    feature_actor.force_actor_movable(actor)
    pcall(function() actor.bRegisterAsRuntimeSpawned = true end)

    local loc = { X = rec.x or 0, Y = rec.y or 0, Z = rec.z or 0 }
    local rot = { Pitch = rec.pitch or 0, Yaw = rec.yaw or 0, Roll = rec.roll or 0 }
    local scale = {
        X = rec.scale_x or 1,
        Y = rec.scale_y or 1,
        Z = rec.scale_z or 1,
    }

    local ok_loc, loc_err = feature_actor.move_actor(actor, loc)
    if not ok_loc then return false, "move failed: " .. tostring(loc_err) end
    feature_actor.set_actor_rotation(actor, rot)
    feature_actor.set_actor_scale3d(actor, scale)
    return true
end

local function spawn_item_record(rec)
    if type(rec) ~= "table" then return false, "bad item record" end
    if type(rec.x) ~= "number" or type(rec.y) ~= "number" or type(rec.z) ~= "number" then
        return false, "item missing x/y/z"
    end
    local count = normalize_count(rec.count)
    local item_name = rec.item_asset_name
    local item_path = rec.item_asset_path
    local ok_spawn, spawn_detail = false, nil

    if type(item_name) == "string" and item_name ~= "" then
        ok_spawn, spawn_detail = feature_inventory.give(item_name .. " " .. tostring(count))
    end
    if not ok_spawn and type(item_path) == "string" and item_path ~= "" then
        local actor_class_path = class_path_from_full(rec.actor_class)
        local spawn_args = item_path .. " " .. tostring(count)
        if actor_class_path then spawn_args = spawn_args .. " " .. actor_class_path end
        ok_spawn, spawn_detail = feature_player_spawn.spawn_item(spawn_args)
    end
    if not ok_spawn then
        return false, "spawn failed: " .. tostring(spawn_detail or "no item identity")
    end

    local actor
    pcall(function() actor = feature_field.resolve_root("lastspawned") end)
    if not is_valid(actor) then
        return false, "spawned item but lastspawned was not resolvable"
    end

    local ok_xform, xform_detail = apply_actor_transform(actor, rec)
    if not ok_xform then
        return false, xform_detail
    end

    local ok_stable, stable_result = feature_inventory.stabilize_runtime_world_item(actor)
    if not ok_stable then
        local err = stable_result
        if type(stable_result) == "table" then
            err = stable_result.error or stable_result.detail or stable_result.message
        end
        return false, "stabilize failed after spawn: " .. tostring(err)
    end

    local actions = 0
    local failures = 0
    if type(stable_result) == "table" then
        if type(stable_result.actions) == "table" then actions = #stable_result.actions end
        if type(stable_result.failures) == "table" then failures = #stable_result.failures end
    end
    return true, tostring(spawn_detail or "spawned")
        .. string.format(" ; stabilized actions=%d failures=%d", actions, failures)
end

local function replay_items_absolute(items)
    if type(items) ~= "table" or #items == 0 then
        return { sent = 0, failed = 0, skipped = 0 }
    end
    local counts = { sent = 0, failed = 0, skipped = 0 }
    for i = 1, #items do
        local rec = items[i]
        local ok, detail = spawn_item_record(rec)
        if ok then
            counts.sent = counts.sent + 1
            print(string.format("[RSDWTools] buildings.import: item[%d] spawned %s x%d at (%.1f, %.1f, %.1f) ; %s",
                i, tostring(rec.item_asset_name or rec.item_asset_path), normalize_count(rec.count),
                rec.x or 0, rec.y or 0, rec.z or 0, tostring(detail or "")))
        else
            counts.failed = counts.failed + 1
            print(string.format("[RSDWTools] buildings.import: item[%d] failed (%s)",
                i, tostring(detail)))
        end
    end
    return counts
end

local function rotate_record_relative(rec, origin, anchor_loc, theta_deg)
    if type(rec) ~= "table" or type(origin) ~= "table" or not anchor_loc then return nil end
    if type(rec.x) ~= "number" or type(rec.y) ~= "number" or type(rec.z) ~= "number" then return nil end
    local theta_rad = (theta_deg or 0) * math.pi / 180.0
    local cos_t, sin_t = math.cos(theta_rad), math.sin(theta_rad)
    local dx = rec.x - (origin.x or 0)
    local dy = rec.y - (origin.y or 0)
    local dz = rec.z - (origin.z or 0)
    local rx = dx * cos_t - dy * sin_t
    local ry = dx * sin_t + dy * cos_t
    local out = {}
    for k, v in pairs(rec) do out[k] = v end
    out.x = (anchor_loc.X or 0) + rx
    out.y = (anchor_loc.Y or 0) + ry
    out.z = (anchor_loc.Z or 0) + dz
    out.yaw = (rec.yaw or 0) + (theta_deg or 0)
    return out
end

local function replay_items_relative(items, origin, anchor_loc, theta_deg)
    if type(items) ~= "table" or #items == 0 then
        return { sent = 0, failed = 0, skipped = 0 }
    end
    local transformed = {}
    local counts = { sent = 0, failed = 0, skipped = 0 }
    for i = 1, #items do
        local rec = rotate_record_relative(items[i], origin, anchor_loc, theta_deg)
        if rec then
            transformed[#transformed + 1] = rec
        else
            counts.skipped = counts.skipped + 1
            print(string.format("[RSDWTools] buildings.import: item[%d] skipped (bad relative transform)", i))
        end
    end
    local spawned = replay_items_absolute(transformed)
    counts.sent = counts.sent + spawned.sent
    counts.failed = counts.failed + spawned.failed
    counts.skipped = counts.skipped + spawned.skipped
    return counts
end

local function spawn_transform_args(class_path, rec)
    local cp = class_path_from_full(class_path)
    if not cp or cp == "" then return nil, "missing class_path" end
    if type(rec.x) ~= "number" or type(rec.y) ~= "number" or type(rec.z) ~= "number" then
        return nil, "actor missing x/y/z"
    end
    return string.format(
        '%s {"loc":[%s,%s,%s],"rot":[%s,%s,%s],"scale":[%s,%s,%s]}',
        cp,
        json_num(rec.x), json_num(rec.y), json_num(rec.z),
        json_num(rec.pitch or 0), json_num(rec.yaw or 0), json_num(rec.roll or 0),
        json_num(rec.scale_x or 1), json_num(rec.scale_y or 1), json_num(rec.scale_z or 1)
    ), nil
end

local function spawn_actor_record(rec)
    if type(rec) ~= "table" then return false, "bad actor record" end
    local class_path = rec.class_path or class_path_from_full(rec.actor_class)
    local args, arg_err = spawn_transform_args(class_path, rec)
    if not args then return false, arg_err end
    local ok, detail = feature_player_spawn.spawn_transform(args)
    if not ok then return false, detail end
    return true, detail
end

local function replay_actors_absolute(actors)
    if type(actors) ~= "table" or #actors == 0 then
        return { sent = 0, failed = 0, skipped = 0 }
    end
    local counts = { sent = 0, failed = 0, skipped = 0 }
    for i = 1, #actors do
        local rec = actors[i]
        local ok, detail = spawn_actor_record(rec)
        if ok then
            counts.sent = counts.sent + 1
            print(string.format("[RSDWTools] buildings.import: actor[%d] spawned %s at (%.1f, %.1f, %.1f) ; %s",
                i, tostring(rec.class_path or rec.actor_class), rec.x or 0, rec.y or 0, rec.z or 0,
                tostring(detail or "")))
        else
            counts.failed = counts.failed + 1
            print(string.format("[RSDWTools] buildings.import: actor[%d] failed (%s)",
                i, tostring(detail)))
        end
    end
    return counts
end

local function replay_actors_relative(actors, origin, anchor_loc, theta_deg)
    if type(actors) ~= "table" or #actors == 0 then
        return { sent = 0, failed = 0, skipped = 0 }
    end
    local transformed = {}
    local counts = { sent = 0, failed = 0, skipped = 0 }
    for i = 1, #actors do
        local rec = rotate_record_relative(actors[i], origin, anchor_loc, theta_deg)
        if rec then
            transformed[#transformed + 1] = rec
        else
            counts.skipped = counts.skipped + 1
            print(string.format("[RSDWTools] buildings.import: actor[%d] skipped (bad relative transform)", i))
        end
    end
    local spawned = replay_actors_absolute(transformed)
    counts.sent = counts.sent + spawned.sent
    counts.failed = counts.failed + spawned.failed
    counts.skipped = counts.skipped + spawned.skipped
    return counts
end

-- ---------------------------------------------------------------------------
-- world.buildings.import <name> [ghost]
-- Reads ipc/buildings_<name>.json and replays each piece via
-- Server_SpawnBuilding. Reports per-piece success in the log and a
-- one-liner summary in the router ack.
--
-- Optional second token "ghost" : after the spawn loop fires, schedule
-- a 3-second polling LoopAsync that watches for newly-appearing
-- BaseBuildingActor instances (diff against pre-spawn snapshot) and
-- sets bIsGhosted=true on each. Used by the WPF "Ghost Building Mode"
-- checkbox so deliveries land as undeletable-by-default ghost shells
-- the user can later commit or wipe in bulk.
-- ---------------------------------------------------------------------------
function M.import(args_str)
    args_str = args_str or ""
    local name_tok = args_str:match("^%s*(%S+)") or ""
    local rest = args_str:sub(#name_tok + 1):lower()
    local ghost_mode = rest:find("ghost", 1, true) ~= nil
    local name = sanitize_name(name_tok)
    local path = export_path_for(name)
    if not path then
        return false, "could not resolve mod ipc directory"
    end

    local body = mod_paths.read_file(path)
    if not body then
        return false, "could not read " .. path
    end
    local pieces, perr = parse_pieces(body)
    if not pieces then
        if tostring(perr or ""):find("no pieces array", 1, true) then
            pieces = {}
        else
            return false, "JSON parse: " .. tostring(perr)
        end
    end
    local items, ierr = parse_items(body)
    if not items then
        return false, "JSON parse items: " .. tostring(ierr)
    end
    local actors, aerr = parse_actors(body)
    if not actors then
        return false, "JSON parse actors: " .. tostring(aerr)
    end
    if #pieces == 0 and #items == 0 and #actors == 0 then
        return false, "no pieces/items/actors in JSON"
    end

    local bmc = nil
    local empty_inv = {}
    if #pieces > 0 then
        local _pc, resolved_bmc, err = get_local_pc_and_bmc()
        if not resolved_bmc then
            return false, "build mode unavailable: " .. tostring(err)
        end
        bmc = resolved_bmc
        if type(bmc.Server_SpawnBuilding) ~= "function" and not bmc.Server_SpawnBuilding then
            -- UE4SS exposes UFunctions as callable members -- the truthy
            -- check via direct index is the reliable test.
            return false, "BuildModeComponent has no Server_SpawnBuilding"
        end
    end

    -- Ghost-mode delivery: pass bSpawnGhost=true to Server_SpawnBuilding
    -- so the engine spawns each piece as a proper persistent ghost
    -- (server-side state, replicated, survives save+reload). The
    -- previous approach of post-spawn pinning bIsGhosted=true on the
    -- client only had no effect on the persisted state.
    local spawn_ghost = ghost_mode and true or false
    if ghost_mode and #pieces > 0 then
        print("[RSDWTools] buildings.import: ghost-mode armed (Server_SpawnBuilding bSpawnGhost=true)")
    end

    local ok_count, fail_count = 0, 0
    print(string.format("[RSDWTools] buildings.import: replaying %d pieces from %s",
        #pieces, path))
    for i = 1, #pieces do
        local p = pieces[i]
        if type(p.piece_data_index) ~= "number" or type(p.x) ~= "number"
            or type(p.y) ~= "number" or type(p.z) ~= "number" then
            print(string.format("  [%d] skipped (missing required fields)", i))
            fail_count = fail_count + 1
        else
            local xform = make_transform(p.x, p.y, p.z,
                p.pitch, p.yaw, p.roll,
                p.scale_x, p.scale_y, p.scale_z)
            local ok = pcall(function()
                bmc:Server_SpawnBuilding(p.piece_data_index, xform, spawn_ghost, empty_inv)
            end)
            if ok then
                ok_count = ok_count + 1
                print(string.format("  [%d] sent piece_data_index=%d at (%.1f, %.1f, %.1f) yaw=%.1f",
                    i, p.piece_data_index, p.x, p.y, p.z, p.yaw or 0))
            else
                fail_count = fail_count + 1
                print(string.format("  [%d] Server_SpawnBuilding errored on idx=%d",
                    i, p.piece_data_index))
            end
        end
    end

    local item_counts = replay_items_absolute(items)
    local actor_counts = replay_actors_absolute(actors)

    print(string.format("[RSDWTools] buildings.import: done  sent=%d failed=%d items_sent=%d items_failed=%d items_skipped=%d actors_sent=%d actors_failed=%d actors_skipped=%d",
        ok_count, fail_count,
        item_counts.sent, item_counts.failed, item_counts.skipped,
        actor_counts.sent, actor_counts.failed, actor_counts.skipped))

    local suffix = (ghost_mode and #pieces > 0) and " (spawned as persistent ghosts)" or ""
    local item_suffix = (#items > 0)
        and string.format(" items_sent=%d items_failed=%d items_skipped=%d",
            item_counts.sent, item_counts.failed, item_counts.skipped)
        or ""
    local actor_suffix = (#actors > 0)
        and string.format(" actors_sent=%d actors_failed=%d actors_skipped=%d",
            actor_counts.sent, actor_counts.failed, actor_counts.skipped)
        or ""
    return true, string.format("sent=%d failed=%d%s%s%s (server may still reject ; check world)",
        ok_count, fail_count, item_suffix, actor_suffix, suffix)
end

-- ---------------------------------------------------------------------------
-- world.buildings.list
-- Lists every *.json under ipc\building\ for discoverability. Best-effort
-- using io.popen("dir") since Lua stdlib has no dir-iter ; if popen is
-- restricted in this UE4SS build we just say so.
-- ---------------------------------------------------------------------------
function M.list()
    local dir = mod_paths.buildings_dir()
    if not dir then return false, "ipc dir unresolved" end
    local found = {}
    local ok, pipe = pcall(io.popen, ('dir /b "%s\\*.json" 2>NUL'):format(dir))
    if ok and pipe then
        for line in pipe:lines() do
            line = (line or ""):gsub("[\r\n]+$", "")
            if line ~= "" then
                local short = line:match("^(.+)%.[Jj][Ss][Oo][Nn]$") or line
                found[#found + 1] = short
            end
        end
        pipe:close()
    end
    if #found == 0 then
        print("[RSDWTools] buildings.list: no exports found in " .. dir)
        return true, "0 exports in " .. dir
    end
    print(string.format("[RSDWTools] buildings.list: %d export(s) in %s", #found, dir))
    for i = 1, #found do print("  - " .. found[i]) end
    return true, string.format("%d export(s)", #found)
end

-- ---------------------------------------------------------------------------
-- world.buildings.catalog [name]
--
-- Enumerate every loaded UBuildingPieceData asset and dump
--   { piece_data_index, piece_data_name, short_name }
-- for each. Writes ipc/building/_catalog[_<name>].json (leading
-- underscore keeps it from colliding with normal capture exports and
-- sorts it to the top of the WPF list).
--
-- BuildingPieceDataIndex is a property on UBuildingPieceData itself
-- (header offset 0x0180) so we read it directly off each asset rather
-- than walking UBuildingPieceSubsystem.BuildingPieceDataIndexToBuildingPieceData
-- (TMap iteration from Lua is fiddly and FindAllOf reaches the same
-- set). CDOs are filtered out via the existing find_all_live helper.
--
-- Returns ack body : "count=N skipped=K path=..."
-- ---------------------------------------------------------------------------
function M.catalog(args_str)
    local raw = (args_str or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local suffix = raw == "" and "" or ("_" .. sanitize_name(raw))
    local dir = mod_paths.buildings_dir()
    if not dir then
        return false, "could not resolve mod ipc directory (game not loaded?)"
    end
    local out_path = dir .. "\\_catalog" .. suffix .. ".json"

    local assets = find_all_live("BuildingPieceData")
    if #assets == 0 then
        return false, "FindAllOf BuildingPieceData returned 0 ; assets not loaded?"
    end

    local kept = {}
    local skipped = 0
    for i = 1, #assets do
        local a = assets[i]
        local rec = {}
        pcall(function() rec.short_name = a:GetName() end)
        pcall(function() rec.piece_data_name = a:GetFullName() end)
        pcall(function() rec.piece_data_index = a.BuildingPieceDataIndex end)
        if type(rec.piece_data_index) == "number"
            and rec.piece_data_name and rec.piece_data_name ~= "" then
            kept[#kept + 1] = rec
        else
            skipped = skipped + 1
        end
    end

    -- Stable sort by index so the file diffs cleanly across runs and
    -- a human can scan it for index gaps.
    table.sort(kept, function(a, b) return (a.piece_data_index or 0) < (b.piece_data_index or 0) end)

    local body_parts = {}
    body_parts[#body_parts + 1] = '{"schema":"rsdwtools.buildings.catalog.v1"'
    body_parts[#body_parts + 1] = ',"generated_unix":' .. tostring(os.time())
    body_parts[#body_parts + 1] = ',"count":' .. tostring(#kept)
    body_parts[#body_parts + 1] = ',"skipped":' .. tostring(skipped)
    body_parts[#body_parts + 1] = ',"pieces":['
    for i = 1, #kept do
        if i > 1 then body_parts[#body_parts + 1] = "," end
        local r = kept[i]
        body_parts[#body_parts + 1] = "{"
            .. '"piece_data_index":' .. json_num(r.piece_data_index)
            .. ',"short_name":'      .. json_str_or_null(r.short_name)
            .. ',"piece_data_name":' .. json_str_or_null(r.piece_data_name)
            .. "}"
    end
    body_parts[#body_parts + 1] = "]}"
    local body = table.concat(body_parts)

    local ok, detail = mod_paths.write_atomic(out_path, body)
    if not ok then
        return false, "write failed: " .. tostring(detail)
    end
    print(string.format("[RSDWTools] buildings.catalog: wrote %d entries (skipped %d) -> %s",
        #kept, skipped, out_path))
    return true, string.format("count=%d skipped=%d path=%s", #kept, skipped, out_path)
end

-- ---------------------------------------------------------------------------
-- world.buildings.catalog.disk [name]
--
-- AssetRegistry sweep of every UBuildingPieceData asset on disk
-- (loaded or not). Complements world.buildings.catalog, which only
-- sees pieces that have been paged into memory this session.
--
-- Why both:
--   FindAllOf("BuildingPieceData") only enumerates assets currently
--   live in the global UObject array. The dump-time count of
--   reflected BuildingPieceData lines is ~728 yet the loaded catalog
--   tops out at 648, so ~80 pieces are sitting in pak files we have
--   never touched. The AssetRegistry knows about every cooked asset
--   regardless of load state, so we can compare the two files to see
--   what is missing and (later) force-load the gaps to recover their
--   piece_data_index.
--
-- Strategy:
--   1. Resolve UAssetRegistryHelpers CDO -> IAssetRegistry (same
--      pattern BPModLoaderMod uses).
--   2. Walk the three known BuildingPieces roots with
--      GetAssetsByPath(PackagePath, OutAssetData, true, true).
--   3. For each FAssetData, capture { package_name, package_path,
--      asset_name, asset_class, object_path, loaded } and filter to
--      AssetClass == "BuildingPieceData" (in case other asset types
--      live alongside under the same path).
--
-- The on-disk roots match what the loaded catalog reports today:
--   /Game/Gameplay/BaseBuilding/Data/BuildingPieces
--   /Game/Gameplay/BaseBuilding_New/BuildingPieces
--   /Fishing/Gameplay/BaseBuilding/BuildingPieces
-- ---------------------------------------------------------------------------
local DISK_CATALOG_ROOTS = {
    "/Game/Gameplay/BaseBuilding/Data/BuildingPieces",
    "/Game/Gameplay/BaseBuilding_New/BuildingPieces",
    "/Fishing/Gameplay/BaseBuilding/BuildingPieces",
}

local function resolve_asset_registry()
    if not StaticFindObject then
        return nil, "StaticFindObject not available"
    end
    local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    if not is_valid(helpers) then
        return nil, "UAssetRegistryHelpers CDO not found"
    end
    local ok, registry = pcall(function() return helpers:GetAssetRegistry() end)
    if not ok or not registry then
        return nil, "GetAssetRegistry call failed: " .. tostring(registry)
    end
    if not is_valid(registry) then
        return nil, "GetAssetRegistry returned invalid registry"
    end
    return registry, helpers
end

-- Read a single FAssetData row into a plain Lua table. Each FName field
-- is coerced via :ToString() ; the call is wrapped in pcall because a
-- malformed entry should skip rather than abort the whole sweep.
--
-- Note: FAssetData.AssetClass (FName) is deprecated in UE5 and returns
-- None for cooked assets ; the real class lives on AssetClassPath
-- (FTopLevelAssetPath { PackageName, AssetName }). We read both, then
-- prefer AssetClassPath.AssetName for filtering. The legacy field is
-- kept in the JSON for diagnostics.
--
-- UE4SS Lua FName access: depending on UE4SS build, FName fields can be
-- read as either userdata-with-:ToString() OR as a plain Lua string. We
-- handle both. Errors from each access are captured into rec.errors so
-- a failed sweep self-documents instead of returning all-nil rows.
local function fname_to_string(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    if type(v) == "userdata" then
        -- UE4SS wraps reflected struct fields and TArray elements in
        -- LocalUnrealParam / RemoteUnrealParam. Both expose :get() to
        -- materialize the underlying value. We may need to unwrap one
        -- or two layers (param -> FName) before :ToString() works.
        for _ = 1, 2 do
            if type(v) == "userdata" then
                local has_get = false
                pcall(function() has_get = (type(v.get) == "function") end)
                if has_get then
                    local ok, inner = pcall(function() return v:get() end)
                    if ok and inner ~= nil then
                        v = inner
                    else
                        break
                    end
                else
                    break
                end
            else
                break
            end
        end
        if type(v) == "string" then return v end
        if type(v) == "userdata" then
            for _, m in ipairs({ "ToString", "GetName", "GetPlainNameString" }) do
                local ok, s = pcall(function() return v[m](v) end)
                if ok and type(s) == "string" and s ~= "" then return s end
            end
            local ok, s = pcall(tostring, v)
            if ok and type(s) == "string" and s ~= "" and s ~= "nil"
                and not s:find("LocalUnrealParam") and not s:find("RemoteUnrealParam") then
                return s
            end
        end
    end
    return nil
end

-- Unwrap a TArray element / struct-field LocalUnrealParam down to the
-- underlying userdata (e.g. FAssetData struct). One :get() call is
-- usually enough but we tolerate two.
local function unwrap_param(v)
    if type(v) ~= "userdata" then return v end
    for _ = 1, 2 do
        local has_get = false
        pcall(function() has_get = (type(v.get) == "function") end)
        if not has_get then return v end
        local ok, inner = pcall(function() return v:get() end)
        if not ok or inner == nil then return v end
        v = inner
        if type(v) ~= "userdata" then return v end
    end
    return v
end

local function asset_data_to_record(entry, helpers)
    local rec = { errors = {} }
    local function try(field, fn)
        local ok, err = pcall(fn)
        if not ok then rec.errors[#rec.errors + 1] = field .. ":" .. tostring(err) end
    end
    try("PackageName", function() rec.package_name = fname_to_string(entry.PackageName) end)
    try("PackagePath", function() rec.package_path = fname_to_string(entry.PackagePath) end)
    try("AssetName",   function() rec.asset_name   = fname_to_string(entry.AssetName) end)
    try("AssetClass",  function() rec.asset_class_legacy = fname_to_string(entry.AssetClass) end)
    try("AssetClassPath.PackageName", function()
        rec.asset_class_package = fname_to_string(entry.AssetClassPath.PackageName)
    end)
    try("AssetClassPath.AssetName", function()
        rec.asset_class = fname_to_string(entry.AssetClassPath.AssetName)
    end)
    -- Fallback: if AssetClassPath access failed but AssetClass legacy
    -- still has a value (some engine builds keep it populated), use it.
    if not rec.asset_class and rec.asset_class_legacy
        and rec.asset_class_legacy ~= "" and rec.asset_class_legacy ~= "None" then
        rec.asset_class = rec.asset_class_legacy
    end
    if rec.package_name and rec.asset_name then
        rec.object_path = rec.package_name .. "." .. rec.asset_name
    end
    if helpers and is_valid(helpers) then
        try("IsAssetLoaded", function() rec.loaded = helpers:IsAssetLoaded(entry) end)
    end
    return rec
end

function M.catalog_disk(args_str)
    local raw = (args_str or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local suffix = raw == "" and "" or ("_" .. sanitize_name(raw))
    local dir = mod_paths.buildings_dir()
    if not dir then
        return false, "could not resolve mod ipc directory (game not loaded?)"
    end
    local out_path = dir .. "\\_catalog_disk" .. suffix .. ".json"

    local registry, helpers_or_err = resolve_asset_registry()
    if not registry then
        return false, helpers_or_err
    end
    local helpers = helpers_or_err

    -- Per-root scan. We pass an empty Lua table as the OutAssetData
    -- TArray ; UE4SS marshals reflected USTRUCT array out-params back
    -- into it. Recursive=true, IncludeOnlyOnDiskAssets=true so we
    -- catch unloaded paks (the whole point of this verb).
    local kept = {}
    local total_seen = 0
    local skipped_class = 0
    local per_root_counts = {}
    local class_hist = {}
    local error_hist = {}
    local first_entry_dump = nil
    for _, root in ipairs(DISK_CATALOG_ROOTS) do
        local out = {}
        local ok, _ = pcall(function()
            registry:GetAssetsByPath(FName(root), out, true, true)
        end)
        local n = 0
        pcall(function() n = #out end)
        if not ok then
            print("[RSDWTools] buildings.catalog.disk: GetAssetsByPath failed for " .. root)
        end
        per_root_counts[root] = n
        for i = 1, n do
            local entry = unwrap_param(out[i])
            if entry then
                total_seen = total_seen + 1
                local rec = asset_data_to_record(entry, helpers)
                -- One-shot diagnostic on the very first entry: capture
                -- type info so we can see exactly how the struct is
                -- shaped at runtime.
                if first_entry_dump == nil then
                    first_entry_dump = {
                        entry_type = type(entry),
                        rec = rec,
                    }
                end
                for _, err in ipairs(rec.errors) do
                    local key = err:match("^([^:]+)") or err
                    error_hist[key] = (error_hist[key] or 0) + 1
                end
                local cls_key = rec.asset_class or "<nil>"
                class_hist[cls_key] = (class_hist[cls_key] or 0) + 1
                if rec.asset_class == "BuildingPieceData" then
                    kept[#kept + 1] = rec
                else
                    skipped_class = skipped_class + 1
                end
            end
        end
    end

    -- Echo the diagnostic to stdout for the log scrape.
    if first_entry_dump then
        print("[RSDWTools] buildings.catalog.disk diag: first rec object_path=" .. tostring(first_entry_dump.rec.object_path)
            .. " package_name=" .. tostring(first_entry_dump.rec.package_name)
            .. " asset_name=" .. tostring(first_entry_dump.rec.asset_name)
            .. " asset_class=" .. tostring(first_entry_dump.rec.asset_class)
            .. " asset_class_legacy=" .. tostring(first_entry_dump.rec.asset_class_legacy))
        for _, err in ipairs(first_entry_dump.rec.errors or {}) do
            print("[RSDWTools] buildings.catalog.disk diag err: " .. err)
        end
    end

    -- Stable sort by object_path so diffs are clean across runs.
    table.sort(kept, function(a, b)
        return (a.object_path or "") < (b.object_path or "")
    end)

    local body_parts = {}
    body_parts[#body_parts + 1] = '{"schema":"rsdwtools.buildings.catalog_disk.v1"'
    body_parts[#body_parts + 1] = ',"generated_unix":' .. tostring(os.time())
    body_parts[#body_parts + 1] = ',"total_scanned":' .. tostring(total_seen)
    body_parts[#body_parts + 1] = ',"skipped_wrong_class":' .. tostring(skipped_class)
    body_parts[#body_parts + 1] = ',"count":' .. tostring(#kept)
    body_parts[#body_parts + 1] = ',"roots":['
    for i, root in ipairs(DISK_CATALOG_ROOTS) do
        if i > 1 then body_parts[#body_parts + 1] = "," end
        body_parts[#body_parts + 1] = '{"path":' .. json_str_or_null(root)
            .. ',"hits":' .. tostring(per_root_counts[root] or 0) .. '}'
    end
    body_parts[#body_parts + 1] = '],"class_histogram":{'
    do
        local first = true
        for cls, n in pairs(class_hist) do
            if not first then body_parts[#body_parts + 1] = "," end
            first = false
            body_parts[#body_parts + 1] = json_str_or_null(cls) .. ":" .. tostring(n)
        end
    end
    body_parts[#body_parts + 1] = '},"error_histogram":{'
    do
        local first = true
        for field, n in pairs(error_hist) do
            if not first then body_parts[#body_parts + 1] = "," end
            first = false
            body_parts[#body_parts + 1] = json_str_or_null(field) .. ":" .. tostring(n)
        end
    end
    body_parts[#body_parts + 1] = '},"pieces":['
    for i = 1, #kept do
        if i > 1 then body_parts[#body_parts + 1] = "," end
        local r = kept[i]
        body_parts[#body_parts + 1] = "{"
            .. '"object_path":'  .. json_str_or_null(r.object_path)
            .. ',"package_name":' .. json_str_or_null(r.package_name)
            .. ',"package_path":' .. json_str_or_null(r.package_path)
            .. ',"asset_name":'   .. json_str_or_null(r.asset_name)
            .. ',"asset_class":'  .. json_str_or_null(r.asset_class)
            .. ',"asset_class_package":' .. json_str_or_null(r.asset_class_package)
            .. ',"loaded":'       .. (r.loaded == true and "true" or "false")
            .. "}"
    end
    body_parts[#body_parts + 1] = "]}"
    local body = table.concat(body_parts)

    local ok, detail = mod_paths.write_atomic(out_path, body)
    if not ok then
        return false, "write failed: " .. tostring(detail)
    end
    print(string.format("[RSDWTools] buildings.catalog.disk: wrote %d entries (scanned %d, %d non-BuildingPieceData skipped) -> %s",
        #kept, total_seen, skipped_class, out_path))
    return true, string.format("count=%d scanned=%d path=%s", #kept, total_seen, out_path)
end

-- ---------------------------------------------------------------------------
-- world.buildings.stability <on|off>
--
-- Toggle building stability simulation at runtime. We attack it from
-- three angles because we don't yet know which one actually shipped
-- working in this build:
--
--   1. UDominionCheatManager::domBuildingTickStability(bool)
--      and domUpdateStabilityValuesInCellManager(bool). The header
--      dump shows these as exec UFUNCTIONs targeted exactly at the
--      stability sim. They may no-op (the prior round-12 spell dom*
--      wrappers all silently ignored their args), but they may also
--      Just Work for buildings since that's a different subsystem.
--
--   2. AGlobalBuildingManager.StabilityComponent ->
--      SetComponentTickEnabled / SetActive. If the stability solver
--      lives on a UActorComponent that ticks, we can stop it from
--      ticking entirely. This is the most reliable hammer because it
--      bypasses any cheat-gating on the dom* path.
--
--   3. For "off", sweep every live ABaseBuildingActor and pin
--      StabilityValue=1.0 so anything already mid-decay snaps back
--      to full. Cheap, idempotent, immediately visible.
--
-- Required because Server_SpawnBuilding-replayed structures
-- (build.preview.commit, world.buildings.import) sometimes spawn
-- with low stability values and start collapsing seconds later.
-- ---------------------------------------------------------------------------
function M.set_stability(args_str)
    local raw = (args_str or ""):lower():gsub("%s+", "")
    if raw == "" then
        return false, "usage: world.buildings.stability on|off"
    end
    local enable
    if raw == "on" or raw == "true" or raw == "1" then enable = true
    elseif raw == "off" or raw == "false" or raw == "0" then enable = false
    else return false, "expected on|off, got " .. raw end

    local pc, _bmc, err = get_local_pc_and_bmc()
    if not pc then return false, "no player controller: " .. tostring(err) end

    -- Best-effort: ensure cheats are enabled so the dom* exec funcs
    -- aren't gated. EnableCheats() is the standard UCheatManager path
    -- and is safe to call multiple times. May no-op in shipping.
    pcall(function() pc:EnableCheats() end)

    local cm
    pcall(function() cm = pc:GetDominionCheatManager() end)
    if not is_valid(cm) then pcall(function() cm = pc.CheatManager end) end

    local cheats_called = {}
    if is_valid(cm) then
        if cm.domBuildingTickStability then
            local ok = pcall(function() cm:domBuildingTickStability(enable) end)
            if ok then cheats_called[#cheats_called + 1] = "tick=" .. tostring(enable) end
        end
        if cm.domUpdateStabilityValuesInCellManager then
            local ok = pcall(function() cm:domUpdateStabilityValuesInCellManager(enable) end)
            if ok then cheats_called[#cheats_called + 1] = "cell=" .. tostring(enable) end
        end
    end

    -- Direct hammer: stop the BuildingStabilityComponent from ticking.
    -- AGlobalBuildingManager owns it as a subobject ; in shipped builds
    -- there is exactly one instance per world. Walk all of them
    -- defensively just in case multi-server / dedicated configs end up
    -- with more than one.
    local comps_touched = 0
    for _, mgr in pairs(find_all_live("GlobalBuildingManager")) do
        local sc
        pcall(function() sc = mgr.StabilityComponent end)
        if is_valid(sc) then
            pcall(function() sc:SetComponentTickEnabled(enable) end)
            pcall(function() sc:SetActive(enable) end)
            comps_touched = comps_touched + 1
        end
    end

    -- For "off", pin every live piece to max stability so any actor
    -- that already started decaying snaps back. Setting StabilityValue
    -- directly is sufficient -- the OnRep / replication path will
    -- propagate to clients on the next net update.
    local pieces_pinned = 0
    if not enable then
        for _, a in pairs(find_all_live("BaseBuildingActor")) do
            pcall(function() a.StabilityValue = 1.0 end)
            pieces_pinned = pieces_pinned + 1
        end
    end

    local cheats_str = (#cheats_called > 0) and table.concat(cheats_called, ",") or "none"
    print(string.format(
        "[RSDWTools] world.buildings.stability: mode=%s cheats=[%s] mgr_components=%d pieces_pinned=%d",
        enable and "on" or "off", cheats_str, comps_touched, pieces_pinned))
    return true, string.format("mode=%s cheats=[%s] mgr_components=%d pieces_pinned=%d",
        enable and "on" or "off", cheats_str, comps_touched, pieces_pinned)
end

-- ---------------------------------------------------------------------------
-- world.buildings.protect <on|off>
--
-- Background watcher that defends every live ABaseBuildingActor against
-- the engine's post-spawn validity / completion / stability checks. This
-- is the answer to "force_place spawns the piece, then 200ms later the
-- engine destroys it because it's overlapping/floating/etc."
--
-- HOW THE DESTROY HAPPENS (from the dump):
--   * After Server_SpawnBuilding lands, the engine eventually fires
--     ABaseBuildingActor::OnValiditySpawnStateChanged(state) where state
--     is one of EValiditySpawnState::{Overlapping, Floating, Unstable,
--     ...}. This is a UFUNCTION BlueprintImplementableEvent ; the BP
--     graph implementation is what calls K2_DestroyActor.
--   * For finished pieces, FBuildingCompletionStatus.CurrentAmount may
--     drift back toward zero if no inventory was provided. Some BPs
--     destroy on incomplete state.
--   * StabilityValue<threshold also collapses pieces over time -- handled
--     separately by world.buildings.stability off.
--
-- WHAT THIS DOES (per LoopAsync tick, ~16ms):
--   * Look up the BMC's current PreviewPiece and SKIP it (otherwise
--     we'd hide the reticle ghost the user is aiming with).
--   * For every other live BaseBuildingActor whose bIsPreview is
--     already false:
--       - bIsGhosted = false      (treat as fully-built)
--       - StabilityValue = 1.0    (pin max stability)
--       - bIgnoreReplicationManager = false
--   * We deliberately do NOT touch bIsPreview ; if an actor is still
--     marked preview it's either the reticle ghost or a transient
--     mid-spawn we shouldn't race with.
--
-- This does NOT install a UFunction hook on K2_DestroyActor or on the
-- BIE itself ; UE4SS hooks on BIEs are unreliable in this build (we
-- crashed on LocalUnrealParam unwrapping last time). The pin-and-pray
-- approach is empirically what works.
--
-- LIMITATIONS:
--   * Pieces that are destroyed in a single frame BEFORE our next tick
--     (16ms window) won't be saved. If you see destruction after
--     enabling protect, tighten the loop interval or pre-arm before
--     spawning.
--   * Walking every BaseBuildingActor every frame is O(N). At 1000+
--     pieces this gets expensive ; consider toggling off after the
--     spawn flurry settles.
-- ---------------------------------------------------------------------------
M._protect_loop_armed = false

function M.set_protect(args_str)
    local raw = (args_str or ""):lower():gsub("%s+", "")
    if raw == "" then
        return false, "usage: world.buildings.protect on|off"
    end
    local enable
    if raw == "on" or raw == "true" or raw == "1" then enable = true
    elseif raw == "off" or raw == "false" or raw == "0" then enable = false
    else return false, "expected on|off, got " .. raw end

    if not enable then
        if not M._protect_loop_armed then
            return true, "already off"
        end
        M._protect_loop_armed = false
        print("[RSDWTools] world.buildings.protect: off (loop will exit on next tick)")
        return true, "off"
    end

    if M._protect_loop_armed then
        return true, "already on"
    end
    if not LoopAsync then
        return false, "LoopAsync unavailable"
    end

    M._protect_loop_armed = true
    LoopAsync(16, function()
        if not M._protect_loop_armed then return true end

        -- Identify the BMC's current PreviewPiece so we DON'T clobber
        -- it. Pinning bIsPreview=false / bIsGhosted=false on the live
        -- preview actor hides the reticle ghost (the BMC keys its
        -- ghost-material path off bIsPreview/bIsGhosted) and freezes
        -- placement. Skipping it costs us nothing — the preview
        -- actor isn't a real spawned piece yet.
        local preview_actor = nil
        local pc = find_first_live("DominionPlayerController")
        if is_valid(pc) and pc.BuildModeComponent then
            local bmc = pc.BuildModeComponent
            if is_valid(bmc) and bmc.PreviewPiece then
                local pp = bmc.PreviewPiece
                -- TWeakObjectPtr -- try Get(), fall back to direct deref
                local ok, resolved = pcall(function()
                    if type(pp) == "userdata" and pp.Get then return pp:Get() end
                    return pp
                end)
                if ok and is_valid(resolved) then preview_actor = resolved end
            end
        end

        local actors = find_all_live("BaseBuildingActor")
        for i = 1, #actors do
            local a = actors[i]
            if is_valid(a) and a ~= preview_actor then
                -- Only protect actors that are NOT flagged as a preview
                -- piece. Anything still marked preview is either the
                -- BMC's reticle ghost (handled above) or a half-spawned
                -- transient we shouldn't fight with.
                local is_preview = false
                pcall(function() is_preview = a.bIsPreview and true or false end)
                if not is_preview then
                    pcall(function() a.bIsGhosted = false end)
                    pcall(function() a.StabilityValue = 1.0 end)
                    pcall(function() a.bIgnoreReplicationManager = false end)
                end
            end
        end
        return false
    end)
    print("[RSDWTools] world.buildings.protect: on (16ms tick, all live BaseBuildingActor)")
    return true, "on"
end

-- ---------------------------------------------------------------------------
-- world.buildings.delete_ghosts
--
-- Persistently destroy every ghosted ABaseBuildingActor in the world by
-- routing through the canonical server RPC :
--   UBuildInteractionComponent::Server_InteractActor(
--       EBuildInteractionType::Destroy,
--       ABaseBuildingActor*,
--       const ADominionPlayerController*,
--       const TArray<UInventoryComponent*>&)
--
-- The previous implementation used K2_DestroyActor which only removes
-- the client-side proxy ; the server's GlobalBuildingManager.BuildingPieces
-- TMap still holds the entry so the piece reappears on save+reload.
-- Going through Server_InteractActor lets the engine remove from the
-- piece registry, despawn cleanly, and persist the deletion.
--
-- Returns "destroyed=N skipped=M".
-- ---------------------------------------------------------------------------
function M.delete_ghosts()
    local pc, _bmc, perr = get_local_pc_and_bmc()
    if not is_valid(pc) then
        return false, "no player controller: " .. tostring(perr)
    end
    local bic
    pcall(function() bic = pc.BuildInteractionComponent end)
    if not is_valid(bic) then
        return false, "PC has no BuildInteractionComponent"
    end
    if not bic.Server_InteractActor then
        return false, "BIC has no Server_InteractActor UFUNCTION"
    end

    local empty_inv = {}
    local actors = find_all_live("BaseBuildingActor")
    local destroyed, skipped = 0, 0
    for i = 1, #actors do
        local a = actors[i]
        if not is_valid(a) then
            skipped = skipped + 1
        else
            local is_ghost = false
            pcall(function() is_ghost = a.bIsGhosted and true or false end)
            if is_ghost then
                -- EBuildInteractionType::Destroy = 3
                local ok = pcall(function()
                    bic:Server_InteractActor(3, a, pc, empty_inv)
                end)
                if ok then destroyed = destroyed + 1 else skipped = skipped + 1 end
            end
        end
    end
    print(string.format(
        "[RSDWTools] world.buildings.delete_ghosts: destroyed=%d skipped=%d (via Server_InteractActor)",
        destroyed, skipped))
    return true, string.format("destroyed=%d skipped=%d", destroyed, skipped)
end

-- ---------------------------------------------------------------------------
-- world.buildings.commit_ghosts
--
-- Persistently commit every ghosted ABaseBuildingActor to the
-- "fully built" state by :
--   1. Pre-filling each piece's CompletionStatus.CurrentAmount[] to
--      match its AmountNeeded[] (so the engine sees zero items
--      outstanding).
--   2. Routing UBuildInteractionComponent::Server_InteractActor with
--      EBuildInteractionType::Donation. With nothing left to deposit
--      the engine takes the "completion" branch : flips bIsGhosted=false
--      server-side, replicates the OnRep, and updates the registry.
--
-- The previous implementation only flipped bIsGhosted client-side, so
-- the server's persisted state remained ghosted and the piece reverted
-- on save+reload.
--
-- Returns "committed=N scanned=M skipped=K".
-- ---------------------------------------------------------------------------
function M.commit_ghosts()
    local pc, _bmc, perr = get_local_pc_and_bmc()
    if not is_valid(pc) then
        return false, "no player controller: " .. tostring(perr)
    end
    local bic
    pcall(function() bic = pc.BuildInteractionComponent end)
    if not is_valid(bic) then
        return false, "PC has no BuildInteractionComponent"
    end
    if not bic.Server_InteractActor then
        return false, "BIC has no Server_InteractActor UFUNCTION"
    end

    local empty_inv = {}
    local actors = find_all_live("BaseBuildingActor")
    local committed, scanned, skipped = 0, 0, 0
    for i = 1, #actors do
        local a = actors[i]
        scanned = scanned + 1
        if is_valid(a) then
            local is_ghost = false
            pcall(function() is_ghost = a.bIsGhosted and true or false end)
            if is_ghost then
                -- Pre-fill CompletionStatus.CurrentAmount = AmountNeeded so
                -- the Donation RPC has nothing left to deposit and routes
                -- straight into the "fully built" path.
                pcall(function()
                    local cs = a.CompletionStatus
                    if cs and cs.AmountNeeded then
                        local needed = cs.AmountNeeded
                        local current = cs.CurrentAmount
                        local n = #needed
                        for k = 1, n do
                            current[k] = needed[k]
                        end
                    end
                end)
                -- EBuildInteractionType::Donation = 2
                local ok = pcall(function()
                    bic:Server_InteractActor(2, a, pc, empty_inv)
                end)
                if ok then committed = committed + 1 else skipped = skipped + 1 end
            end
        else
            skipped = skipped + 1
        end
    end
    print(string.format(
        "[RSDWTools] world.buildings.commit_ghosts: committed=%d scanned=%d skipped=%d (via Server_InteractActor)",
        committed, scanned, skipped))
    return true, string.format("committed=%d scanned=%d skipped=%d",
        committed, scanned, skipped)
end

-- ---------------------------------------------------------------------------
-- world.buildings.requirements <save|clear|restore|status>
--
-- Manage the per-asset Requirements TArray on every loaded
-- UBuildingPieceData. Replaces the previous "world.foreach
-- BuildingPieceData clear Requirements" sledgehammer because that
-- approach has a nasty side effect : with empty Requirements, ANY
-- placement (including manual in-game ghost building) is auto-completed
-- by the engine instantly, so the player can never make a real ghost.
--
-- Subcommands:
--   save     : snapshot current Requirements into M._requirements_snapshot
--              (keyed by asset GetFullName()). Idempotent ; will not
--              overwrite an existing snapshot unless one isn't there yet.
--   clear    : auto-saves first if no snapshot exists, then empties
--              every asset's Requirements TArray. Use BEFORE a Deliver
--              if you want non-ghost-mode pieces to spawn for free.
--   restore  : copy the snapshot back into every asset, restoring
--              normal in-game build costs. Drops the snapshot.
--   status   : report whether a snapshot is held, how many entries
--              are cleared right now, and how many are intact.
--
-- WARNING: clear affects ALL placements globally including yours and
-- other players in co-op. Always restore when you're done delivering.
-- ---------------------------------------------------------------------------
M._requirements_snapshot = nil

local function deepcopy_req_array(arr)
    -- TArray<FResourceRequirement> -> Lua list of { Amount, ItemData }.
    -- We hold raw UItemData* pointers ; assets stay alive for the whole
    -- session so this is safe.
    local out = {}
    if not arr then return out end
    local n = 0
    pcall(function() n = #arr end)
    for i = 1, n do
        local entry = arr[i]
        if entry then
            out[#out + 1] = {
                Amount   = entry.Amount or 0,
                ItemData = entry.ItemData,
            }
        end
    end
    return out
end

function M.set_requirements(args_str)
    local raw = (args_str or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if raw == "" then
        return false, "usage: world.buildings.requirements <save|clear|restore|status>"
    end

    local assets = find_all_live("BuildingPieceData")
    if #assets == 0 then
        return false, "FindAllOf BuildingPieceData returned 0 ; assets not loaded?"
    end

    if raw == "status" then
        local snap = M._requirements_snapshot
        local snap_count = 0
        if snap then for _ in pairs(snap) do snap_count = snap_count + 1 end end
        local empty_now, intact_now = 0, 0
        for i = 1, #assets do
            local a = assets[i]
            local n = 0
            pcall(function() n = #a.Requirements end)
            if n == 0 then empty_now = empty_now + 1 else intact_now = intact_now + 1 end
        end
        return true, string.format("snapshot=%d empty=%d intact=%d total=%d",
            snap_count, empty_now, intact_now, #assets)
    end

    if raw == "save" then
        if M._requirements_snapshot then
            return true, "snapshot already exists ; restore first or use clear (which auto-saves)"
        end
        local snap = {}
        local n = 0
        for i = 1, #assets do
            local a = assets[i]
            local key
            pcall(function() key = a:GetFullName() end)
            if key then
                snap[key] = deepcopy_req_array(a.Requirements)
                n = n + 1
            end
        end
        M._requirements_snapshot = snap
        print(string.format("[RSDWTools] requirements: snapshot saved (%d assets)", n))
        return true, string.format("saved=%d", n)
    end

    if raw == "clear" then
        if not M._requirements_snapshot then
            -- Auto-save first so restore works later.
            local snap = {}
            for i = 1, #assets do
                local a = assets[i]
                local key
                pcall(function() key = a:GetFullName() end)
                if key then
                    snap[key] = deepcopy_req_array(a.Requirements)
                end
            end
            M._requirements_snapshot = snap
            print("[RSDWTools] requirements: auto-saved snapshot before clear")
        end
        local cleared = 0
        for i = 1, #assets do
            local a = assets[i]
            local ok = pcall(function() a.Requirements = {} end)
            if ok then cleared = cleared + 1 end
        end
        print(string.format("[RSDWTools] requirements: cleared %d asset(s)", cleared))
        return true, string.format("cleared=%d", cleared)
    end

    if raw == "restore" then
        local snap = M._requirements_snapshot
        if not snap then
            return false, "no snapshot to restore (call save or clear first)"
        end
        local restored, missing = 0, 0
        for i = 1, #assets do
            local a = assets[i]
            local key
            pcall(function() key = a:GetFullName() end)
            local entries = key and snap[key] or nil
            if entries then
                local rebuilt = {}
                for j = 1, #entries do
                    rebuilt[j] = {
                        Amount   = entries[j].Amount,
                        ItemData = entries[j].ItemData,
                    }
                end
                local ok = pcall(function() a.Requirements = rebuilt end)
                if ok then restored = restored + 1 else missing = missing + 1 end
            else
                missing = missing + 1
            end
        end
        M._requirements_snapshot = nil
        print(string.format("[RSDWTools] requirements: restored %d asset(s) (missing=%d) ; snapshot dropped",
            restored, missing))
        return true, string.format("restored=%d missing=%d", restored, missing)
    end

    return false, "unknown subcommand '" .. raw .. "' ; expected save|clear|restore|status"
end

-- ---------------------------------------------------------------------------
-- world.buildings.rotation.step <deg> -- precision control over the
-- build-mode preview rotation snap. The shipping value (15 by default ;
-- 30 in some configs) is what makes the mouse wheel "tick" in coarse
-- jumps. Writing 1 to UBuildingSettings.ModifyRotationStepDeg gives full
-- per-degree control. The property is on the UDeveloperSettings CDO,
-- so we resolve the singleton via StaticFindObject and write the int32
-- field directly. No restart required ; the build-mode component reads
-- this every wheel input.
--
-- Bounds : the field is int32 and fully signed. We clamp to 1..180
-- because 0 freezes rotation and values >180 alias to a negative
-- direction. Negatives are technically valid (inverts wheel) but
-- aren't what the user asked for ; clamp keeps the UI predictable.
-- Pass no arg to read the current value.
-- ---------------------------------------------------------------------------
function M.set_rotation_step(args_str)
    local raw = (args_str or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local settings = StaticFindObject and StaticFindObject("/Script/Dominion.Default__BuildingSettings") or nil
    if not is_valid(settings) then
        return false, "could not resolve /Script/Dominion.Default__BuildingSettings (not loaded?)"
    end

    if raw == "" then
        local cur
        local ok = pcall(function() cur = settings.ModifyRotationStepDeg end)
        if not ok or cur == nil then
            return false, "read failed: ModifyRotationStepDeg unreadable"
        end
        return true, "current=" .. tostring(cur)
    end

    local n = tonumber(raw)
    if not n then return false, "usage: world.buildings.rotation.step <deg 1-180>  (current: read with no arg)" end
    n = math.floor(n + 0.5)
    if n < 1   then n = 1   end
    if n > 180 then n = 180 end

    local prev
    pcall(function() prev = settings.ModifyRotationStepDeg end)
    local ok, err = pcall(function() settings.ModifyRotationStepDeg = n end)
    if not ok then return false, "write failed: " .. tostring(err) end

    print(string.format("[RSDWTools] world.buildings.rotation.step: %s -> %d",
        tostring(prev), n))
    return true, string.format("ModifyRotationStepDeg=%d (was %s)", n, tostring(prev))
end

-- Public re-exports for sibling modules (feature_build_preview).
-- Kept underscore-prefixed to signal "internal helper, not a router verb".
M._parse_pieces = parse_pieces
M._parse_items = parse_items
M._parse_actors = parse_actors
M._capture_path_for = export_path_for
M._sanitize_name = sanitize_name
M._get_local_pc_and_bmc = get_local_pc_and_bmc
M._make_transform = make_transform
M._replay_items_absolute = replay_items_absolute
M._replay_items_relative = replay_items_relative
M._replay_actors_absolute = replay_actors_absolute
M._replay_actors_relative = replay_actors_relative

return M
