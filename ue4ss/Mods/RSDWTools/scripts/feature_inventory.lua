-- feature_inventory.lua
--
-- Player inventory + recipe-progression RPC verbs. Backs the Item
-- Service / Recipe Service panes in the WPF UI.
--
-- Verbs:
--   world.items.give    <asset_short_name> [count]
--   world.recipes.unlock <asset_short_name>
--
-- Resolution strategy for an asset short name (e.g. "ITEM_Armour_T2_Body_Linen"
-- or "RECIPE_Ammo_Arrows_Bone_Bleed"):
--
--   1. FindFirstOf(name) -- if a CDO or live instance is already in
--      the global object array, use it directly. Cheap and avoids a
--      registry sweep.
--   2. AssetRegistry sweep cache: on first use we call
--      registry:GetAssetsByClass({ItemData,RecipeData}) (subclasses
--      included) and build a lookup `asset_name -> package_name`.
--      Subsequent calls hit the cache. The cache is invalidated
--      lazily ; if a name misses we re-sweep once before giving up
--      to handle plugins that loaded after our first sweep.
--   3. LoadAsset(package_name) + StaticFindObject(package_name + "." + name)
--      to materialize the UItemData / URecipeData object.
--
-- Game-side calls used:
--   pc.BP_Components_PersonalInventory:AddItemByData(itemData, count, durability=1.0, tags=empty)
--   pc.BP_Components_Progress:UnlockRecipes({recipeData})
--
-- Component reach paths come from the catalog dump (rootKind=component,
-- reachPath=pawn->PlayerController->BP_Components_<Name>). We try the
-- shipped BP wrapper component first ; if unavailable we fall back to
-- the native parent (PersonalInventoryComponent / ProgressComponent)
-- which exposes the same API.

local M = {}

local feature_actor = require("feature_actor")

-- ---------------------------------------------------------------------------
-- Local lookup helpers.
-- ---------------------------------------------------------------------------
local function is_valid(obj)
    return feature_actor.is_valid_object(obj)
end

local function get_pawn()
    local pawn = feature_actor.get_local_pawn()
    if not is_valid(pawn) then return nil, "no local pawn" end
    return pawn
end

local function get_pc()
    local pawn, err = get_pawn()
    if not pawn then return nil, err end
    local ok, pc = pcall(function() return pawn:GetController() end)
    if ok and is_valid(pc) then return pc end
    ok, pc = pcall(function() return pawn.Controller end)
    if ok and is_valid(pc) then return pc end
    return nil, "no player controller"
end

-- Resolve a component on the player controller. Tries the BP wrapper
-- first (e.g. BP_Components_PersonalInventory) and falls back to the
-- native parent (PersonalInventoryComponent) so the verbs still work
-- on stripped builds where the BP wrapper isn't present.
local function get_component(field_candidates)
    local pc, err = get_pc()
    if not pc then return nil, err end
    for _, name in ipairs(field_candidates) do
        local ok, v = pcall(function() return pc[name] end)
        if ok and is_valid(v) then return v end
    end
    return nil, "no component (" .. table.concat(field_candidates, " / ") .. ") on PC"
end

-- ---------------------------------------------------------------------------
-- AssetRegistry helpers + per-class lookup cache.
-- ---------------------------------------------------------------------------

-- UE4SS wraps reflected TArray<TStruct> elements in LocalUnrealParam ;
-- one or two :get() calls peel back to the real userdata. Without this
-- `entry.PackageName` returns a wrapper whose own fields are nil and the
-- whole sweep silently produces zero records. Mirrors feature_assets.unwrap_param.
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

local function fname_to_string(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    if type(v) == "userdata" then
        -- Peel LocalUnrealParam wrappers first.
        for _ = 1, 2 do
            if type(v) == "userdata" then
                local has_get = false
                pcall(function() has_get = (type(v.get) == "function") end)
                if has_get then
                    local ok, inner = pcall(function() return v:get() end)
                    if ok and inner ~= nil then v = inner else break end
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
        end
    end
    return nil
end

local function resolve_registry()
    if not StaticFindObject then return nil, nil, "StaticFindObject unavailable" end
    local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    if not is_valid(helpers) then return nil, nil, "UAssetRegistryHelpers CDO not found" end
    local ok, reg = pcall(function() return helpers:GetAssetRegistry() end)
    if not ok or not is_valid(reg) then return nil, helpers, "GetAssetRegistry failed" end
    return reg, helpers, nil
end

-- per-class cache of asset_name -> package_name (e.g. "ITEM_Foo" -> "/Game/.../ITEM_Foo")
local _name_lookup = {}     -- [class_name] = { asset_name = package_name }
local _name_lookup_ci = {}  -- [class_name] = { lower(asset_name) = package_name }
local _swept = {}           -- [class_name] = true (already swept once this session)

local function build_lookup(class_name)
    -- class_name e.g. "ItemData" or "RecipeData" (native /Script/Dominion class).
    local registry, _helpers, rerr = resolve_registry()
    if not registry then return nil, nil, rerr end
    local class_path = { PackageName = FName("/Script/Dominion"), AssetName = FName(class_name) }
    local out = {}
    local ok, err = pcall(function()
        registry:GetAssetsByClass(class_path, out, true)
    end)
    if not ok then return nil, nil, "GetAssetsByClass failed: " .. tostring(err) end
    local n = 0
    pcall(function() n = #out end)
    local lut, lut_ci = {}, {}
    local count = 0
    for i = 1, n do
        local entry = unwrap_param(out[i])
        local pkg, name
        if entry then
            pcall(function() pkg = fname_to_string(entry.PackageName) end)
            pcall(function() name = fname_to_string(entry.AssetName) end)
        end
        if pkg and name and name ~= "" then
            lut[name] = pkg
            local low = name:lower()
            lut_ci[low] = pkg
            -- Tail key: drop the leading prefix segment so the website's
            -- internal_name (e.g. "spell_axtralprojection") can match the
            -- cooked asset ("USD_AxtralProjection"). Only set when not
            -- already taken so a literal hit always wins over a tail hit.
            local tail = low:match("^[%w]+_(.+)$")
            if tail and not lut_ci[tail] then
                lut_ci[tail] = pkg
            end
            count = count + 1
        end
    end
    print(string.format("[RSDWTools] inventory: AssetRegistry sweep %s -> %d entries",
        class_name, count))
    return lut, lut_ci, nil
end

-- Resolve a short asset name to a live UObject (DataAsset). Returns
-- (obj, err). The class_name argument is the native AR class to seed
-- the sweep cache from (e.g. "ItemData" or "RecipeData").
local function resolve_asset(short_name, class_name)
    if type(short_name) ~= "string" or short_name == "" then
        return nil, "empty asset name"
    end

    -- Phase 1: cheap FindFirstOf if the asset is already in memory.
    if FindFirstOf then
        local ok, obj = pcall(FindFirstOf, short_name)
        if ok and type(obj) == "userdata" and is_valid(obj) then
            local fn
            pcall(function() fn = obj:GetFullName() end)
            -- Skip Default__ CDOs ; the asset object itself is what we want.
            if type(fn) ~= "string" or not fn:find("Default__", 1, true) then
                return obj, nil
            end
        end
    end

    -- Phase 2: AssetRegistry lookup (build cache on first miss).
    local lut = _name_lookup[class_name]
    if not lut then
        local built, built_ci, berr = build_lookup(class_name)
        if not built then return nil, berr end
        _name_lookup[class_name] = built
        _name_lookup_ci[class_name] = built_ci
        _swept[class_name] = true
        lut = built
    end

    local pkg = lut[short_name]
    if not pkg then
        -- Case-insensitive try (website internal_name is often lowercased
        -- e.g. "spell_accesspersonalchest" while the cooked asset is
        -- PascalCase "USD_AccessPersonalChest"). build_lookup also indexes
        -- the tail-after-first-underscore so prefix mismatches still resolve.
        local lut_ci = _name_lookup_ci[class_name]
        if lut_ci then
            local low = short_name:lower()
            pkg = lut_ci[low]
            if not pkg then
                local tail = low:match("^[%w]+_(.+)$")
                if tail then pkg = lut_ci[tail] end
            end
        end
    end
    if not pkg then
        -- Force one rebuild in case the asset just loaded (plugin etc).
        if _swept[class_name] then
            _swept[class_name] = false
            local rebuilt, rebuilt_ci = build_lookup(class_name)
            if rebuilt then
                _name_lookup[class_name] = rebuilt
                _name_lookup_ci[class_name] = rebuilt_ci
                _swept[class_name] = true
                pkg = rebuilt[short_name]
                if not pkg and rebuilt_ci then
                    local low = short_name:lower()
                    pkg = rebuilt_ci[low]
                    if not pkg then
                        local tail = low:match("^[%w]+_(.+)$")
                        if tail then pkg = rebuilt_ci[tail] end
                    end
                end
            end
        end
        if not pkg then
            return nil, "asset not found in registry: " .. short_name
        end
    end

    -- Phase 3: ensure loaded + materialise.
    if LoadAsset then pcall(LoadAsset, pkg) end
    -- The case-insensitive path may have given us a pkg whose leaf is
    -- the canonical case (e.g. Spell_AccessPersonalChest). Recover the
    -- canonical leaf from the package path itself so StaticFindObject
    -- gets the matching object_path.
    local canonical = pkg:match("([^/]+)$") or short_name
    local obj_path = pkg .. "." .. canonical
    if not StaticFindObject then return nil, "StaticFindObject unavailable" end
    local ok, obj = pcall(StaticFindObject, obj_path)
    if not ok or not is_valid(obj) then
        return nil, "StaticFindObject failed for " .. obj_path
    end
    return obj, nil
end

-- ---------------------------------------------------------------------------
-- world.items.give <ITEM_AssetName> [count]
-- ---------------------------------------------------------------------------
function M.give(args_str)
    local raw = tostring(args_str or ""):match("^%s*(.-)%s*$")
    if raw == "" then
        return false, "usage: world.items.give <ITEM_AssetName> [count]"
    end
    -- First whitespace-delimited token is the asset name ; the rest
    -- (if numeric) is the count. We do not split on dots because asset
    -- short names may legitimately contain underscores but never dots.
    local name, count_str = raw:match("^(%S+)%s*(.*)$")
    local count = tonumber(count_str)
    if not count then count = 1 end
    if count < 1 then count = 1 end
    if count > 9999 then count = 9999 end

    local item, ierr = resolve_asset(name, "ItemData")
    if not item then return false, ierr end

    local inv, cerr = get_component({ "BP_Components_PersonalInventory", "PersonalInventoryComponent" })
    if not inv then return false, cerr end

    -- We previously tried AddItemByData first and only fell back to
    -- DropItemByData when it returned false. In practice AddItemByData
    -- has a long list of silent-reject conditions (no compatible slot
    -- category yet, weight cap, slot lock, etc.) and on a fresh
    -- character it just never accepts anything. DropItemByData is the
    -- same path the game's own "drop from inventory" UI uses ; it
    -- spawns AWorldItem actors at the supplied transform that the
    -- player picks up immediately. Use it as the primary path.
    -- Header: bool DropItemByData(UItemData*, FTransform, int32, TSet<AWorldItem*>&).
    if not inv.DropItemByData then
        return false, "DropItemByData missing on inventory component"
    end

    local pawn = feature_actor.get_local_pawn()
    local loc
    if is_valid(pawn) then
        local ok_loc, v = pcall(function() return pawn:K2_GetActorLocation() end)
        if ok_loc and v then loc = v end
        if not loc then
            local ok_loc2, v2 = pcall(function() return pawn:GetActorLocation() end)
            if ok_loc2 and v2 then loc = v2 end
        end
    end
    if not loc then
        return false, "could not get pawn location to drop item"
    end

    local xform = {
        Rotation    = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
        Translation = { X = loc.X, Y = loc.Y, Z = loc.Z },
        Scale3D     = { X = 1.0, Y = 1.0, Z = 1.0 },
    }
    local out_set = {}
    local ok, ret = pcall(function()
        return inv:DropItemByData(item, xform, count, out_set)
    end)
    if not ok then return false, "DropItemByData errored: " .. tostring(ret) end
    if ret == false then
        return false, string.format("DropItemByData refused %s", name)
    end
    print(string.format("[RSDWTools] items.give %s x%d -> dropped", name, count))
    return true, string.format("%s x%d (dropped)", name, count)
end

-- ---------------------------------------------------------------------------
-- world.recipes.unlock <RECIPE_AssetName>
--
-- Wraps a single recipe in a one-element TArray<URecipeData> for the
-- BP UnlockRecipes(TArray) signature. Bulk callers should issue the
-- verb once per recipe ; the PIE round-trip is cheap and per-call
-- console feedback is more useful than batching.
-- ---------------------------------------------------------------------------
function M.unlock_recipe(args_str)
    local name = tostring(args_str or ""):match("^%s*(.-)%s*$")
    if name == "" then
        return false, "usage: world.recipes.unlock <RECIPE_AssetName>"
    end

    local recipe, rerr = resolve_asset(name, "RecipeData")
    if not recipe then return false, rerr end

    local prog, cerr = get_component({ "BP_Components_Progress", "ProgressComponent" })
    if not prog then return false, cerr end

    if not prog.UnlockRecipes and not prog["UnlockRecipes"] then
        return false, "UnlockRecipes not on progress component"
    end

    local arr = { recipe }
    local ok, err = pcall(function() prog:UnlockRecipes(arr) end)
    if not ok then return false, "UnlockRecipes errored: " .. tostring(err) end
    print(string.format("[RSDWTools] recipes.unlock %s -> ok", name))
    return true, name
end

-- ---------------------------------------------------------------------------
-- world.buildings.unlock_all
--
-- Bulk variant of unlock_recipe for UBuildingPieceData. Sweeps the
-- AssetRegistry for every BuildingPieceData (subclasses included),
-- materialises each via LoadAsset + StaticFindObject, then calls
-- progress:UnlockBuildings(arr) once with the full list.
--
-- Header: void UnlockBuildings(const TArray<UBuildingPieceData*>&)
-- Same shape as UnlockRecipes ; same OnRep_BuildingsUnlocked delegate
-- on the client side. Replicated, so a single call updates the full
-- BuildingsUnlocked TArray on the player's progress component.
-- ---------------------------------------------------------------------------
function M.unlock_all_buildings(_args_str)
    local prog, cerr = get_component({ "BP_Components_Progress", "ProgressComponent" })
    if not prog then return false, cerr end
    if not prog.UnlockBuildings and not prog["UnlockBuildings"] then
        return false, "UnlockBuildings not on progress component"
    end

    -- Reuse the lookup cache that resolve_asset builds, but force a
    -- fresh sweep so a freshly-loaded plugin's pieces are picked up.
    local lut, lut_ci, berr = build_lookup("BuildingPieceData")
    if not lut then return false, berr end
    _name_lookup["BuildingPieceData"] = lut
    _name_lookup_ci["BuildingPieceData"] = lut_ci
    _swept["BuildingPieceData"] = true

    local arr = {}
    local materialised, missed = 0, 0
    for short_name, pkg in pairs(lut) do
        if LoadAsset then pcall(LoadAsset, pkg) end
        local obj_path = pkg .. "." .. short_name
        local ok, obj = pcall(StaticFindObject, obj_path)
        if ok and is_valid(obj) then
            arr[#arr + 1] = obj
            materialised = materialised + 1
        else
            missed = missed + 1
        end
    end

    if materialised == 0 then
        return false, "no BuildingPieceData assets resolved"
    end

    local ok, err = pcall(function() prog:UnlockBuildings(arr) end)
    if not ok then return false, "UnlockBuildings errored: " .. tostring(err) end

    print(string.format("[RSDWTools] buildings.unlock_all -> %d unlocked, %d unresolved",
        materialised, missed))
    return true, string.format("unlocked=%d unresolved=%d", materialised, missed)
end

-- ---------------------------------------------------------------------------
-- world.spells.unlock <SpellAssetName>
--
-- Mirrors unlock_recipe but for UUtilitySpellData. The website's
-- spells.json uses lowercased internal_names (e.g. "spell_axtralprojection")
-- ; resolve_asset's case-insensitive fallback handles the case difference
-- against the cooked asset (e.g. "Spell_AxtralProjection").
--
-- Header: void UnlockSpells(const TArray<UUtilitySpellData*>&)
-- ---------------------------------------------------------------------------
function M.unlock_spell(args_str)
    local name = tostring(args_str or ""):match("^%s*(.-)%s*$")
    if name == "" then
        return false, "usage: world.spells.unlock <SpellAssetName>"
    end

    local spell, serr = resolve_asset(name, "UtilitySpellData")
    if not spell then return false, serr end

    local prog, cerr = get_component({ "BP_Components_Progress", "ProgressComponent" })
    if not prog then return false, cerr end
    if not prog.UnlockSpells and not prog["UnlockSpells"] then
        return false, "UnlockSpells not on progress component"
    end

    local arr = { spell }
    local ok, err = pcall(function() prog:UnlockSpells(arr) end)
    if not ok then return false, "UnlockSpells errored: " .. tostring(err) end
    print(string.format("[RSDWTools] spells.unlock %s -> ok", name))
    return true, name
end

-- ---------------------------------------------------------------------------
-- world.spells.unlock_all
--
-- Bulk variant of unlock_spell. Sweeps every UUtilitySpellData visible
-- to the AssetRegistry, materialises each, then calls UnlockSpells once.
-- ---------------------------------------------------------------------------
function M.unlock_all_spells(_args_str)
    local prog, cerr = get_component({ "BP_Components_Progress", "ProgressComponent" })
    if not prog then return false, cerr end
    if not prog.UnlockSpells and not prog["UnlockSpells"] then
        return false, "UnlockSpells not on progress component"
    end

    local lut, lut_ci, berr = build_lookup("UtilitySpellData")
    if not lut then return false, berr end
    _name_lookup["UtilitySpellData"] = lut
    _name_lookup_ci["UtilitySpellData"] = lut_ci
    _swept["UtilitySpellData"] = true

    local arr = {}
    local materialised, missed = 0, 0
    for short_name, pkg in pairs(lut) do
        if LoadAsset then pcall(LoadAsset, pkg) end
        local obj_path = pkg .. "." .. short_name
        local ok, obj = pcall(StaticFindObject, obj_path)
        if ok and is_valid(obj) then
            arr[#arr + 1] = obj
            materialised = materialised + 1
        else
            missed = missed + 1
        end
    end

    if materialised == 0 then
        return false, "no UtilitySpellData assets resolved"
    end

    local ok, err = pcall(function() prog:UnlockSpells(arr) end)
    if not ok then return false, "UnlockSpells errored: " .. tostring(err) end

    print(string.format("[RSDWTools] spells.unlock_all -> %d unlocked, %d unresolved",
        materialised, missed))
    return true, string.format("unlocked=%d unresolved=%d", materialised, missed)
end

return M
