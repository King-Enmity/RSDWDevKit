-- Feature: actor introspection (Scan -> Inspect drilldown).
--
-- Restored in Round 30+ after the Round 29 catalog refactor stripped the
-- per-system dumpers. The Scan tab's "Inspect" right-click button still
-- expects the same JSON shape it always did:
--
--   {
--     "name":  "<actor short name>",
--     "class": "<runtime UClass FName>",
--     "class_chain": { "0": "TopMost", "1": "Super", ... },
--     "groups": {
--       "0": {
--         "class":   "<class FName for this strut>",
--         "resolved": true,
--         "fields":  { "0": { "name", "type", "value", "readable" }, ... },
--         "methods": { "0": { "name", "signature" }, ... }
--       },
--       "1": { ... }
--     }
--   }
--
-- Groups are emitted top-down from runtime class -> ... -> UObject so the
-- WPF tree shows the most-specific class first.
--
-- Two router verbs land here:
--   actor.info <short-name>
--     -> dump the named actor.
--   actor.info.field <short-name> <segment>[.<segment>...]
--     -> walk one or more nested UObject* fields starting at the named
--        actor and dump the leaf object. Each segment is a property name
--        on the object reached by the previous segment. Falls back to a
--        single-flat dump of the parent + an explanatory message in the
--        ack if a segment isn't readable as an object.
--
-- The dump file is written atomically to <modroot>/ipc/actor_info.json and
-- WPF picks it up by polling the mtime (see RunInspect / WaitForActorInfo
-- in MainWindow.xaml.cs). All native touches are pcall-guarded ; an AV
-- inside Lua-bound UE reflection still kills the process, but Lua-level
-- type errors / missing methods will be reported back via the ack instead
-- of crashing the game thread.

local M = {}

local feature_actor = require("feature_actor")
local mod_paths = require("mod_paths")

-- Set INTROSPECT_VERBOSE = true to log every property + method as
-- they're enumerated. Costly (large classes get noisy), but the log
-- breadcrumb is the only way to identify which field crashed the
-- game thread when a non-pcall'able native AV hits. Toggled here
-- because Lua reflection AVs are reproducible per-actor-class but
-- *not* discoverable any other way.
-- DEFAULT ON until inspect is proven stable across the actor zoo ;
-- flip to false once we've added enough class names to the deny set.
-- Round 31: flipped OFF. Per-property prints made AiHealthComponent
-- (and presumably any UActorComponent-derived) dumps slow enough that
-- the C# 12s mtime-poll window was timing out before the JSON landed.
-- Re-enable temporarily if a new crash class appears.
local INTROSPECT_VERBOSE = false

-- ============================================================
-- JSON encoding
-- ============================================================

-- Same conservative escape as feature_ui.escape_json. Strips control bytes
-- so the WPF JsonDocument parser never trips on a stray 0x01 in a property
-- name (UE FNames can contain them on corrupted slots).
local function escape_json(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
    s = s:gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    s = s:gsub("[%z\1-\8\11\12\14-\31]", "")
    return s
end

local function jstr(s) return '"' .. escape_json(s) .. '"' end
local function jbool(b) return b and "true" or "false" end

-- Emit an ordered map keyed by stringified indices ("0","1",...). The C#
-- parser rebuilds the order from those keys (see ParseInspectGroup), so
-- as long as we hand out monotonic indices the WPF tree shows fields in
-- the order we walked them.
local function emit_indexed_map(parts, items, item_to_json)
    local n = #items
    parts[#parts + 1] = "{"
    for i = 1, n do
        if i > 1 then parts[#parts + 1] = "," end
        parts[#parts + 1] = '"' .. tostring(i - 1) .. '":'
        parts[#parts + 1] = item_to_json(items[i])
    end
    parts[#parts + 1] = "}"
end

-- ============================================================
-- UE reflection helpers
-- ============================================================

local function is_valid(obj)
    return obj and obj.IsValid and obj:IsValid()
end

local function safe_fname(obj, getter)
    -- getter is the method name on `obj` returning an FName. Returns the
    -- string form, or "" if the call fails / the FName is None.
    if not obj then return "" end
    local ok, fname = pcall(function() return obj[getter](obj) end)
    if not ok or fname == nil then return "" end
    local ok2, name = pcall(function()
        if fname.ToString then return fname:ToString() end
        return tostring(fname)
    end)
    if not ok2 or not name then return "" end
    return name
end

-- Returns the class FName of an arbitrary UObject (or "").
local function obj_class_name(obj)
    if not obj then return "" end
    local ok, cls = pcall(function() return obj:GetClass() end)
    if not ok or not cls then return "" end
    return safe_fname(cls, "GetFName")
end

-- Walk the class chain starting at obj's runtime class up through every
-- super struct. Returns an ordered list of UStruct handles (most-derived
-- first).
--
-- Termination strategy mirrors the official UE4SS ConsoleCommandsMod
-- dump_object.lua: keep walking while the struct's :IsValid() is true.
-- The earlier attempt that compared the returned super against nil /
-- against the current pointer was the AV: GetSuperStruct() hands back
-- an INVALID userdata (not nil) at the top of the chain, and any further
-- vtable call on it crashes in native code. :IsValid() is the safe probe
-- because UE4SS implements it on the wrapper without dispatching into
-- the underlying object.
local function build_class_chain(obj)
    local chain = {}
    if not obj then return chain end
    local ok_cls, cls = pcall(function() return obj:GetClass() end)
    if not ok_cls or not cls then return chain end
    local current = cls
    for _ = 1, 64 do
        local ok_valid, valid = pcall(function() return current:IsValid() end)
        if not ok_valid or not valid then break end
        chain[#chain + 1] = current
        local ok_super, super = pcall(function() return current:GetSuperStruct() end)
        if not ok_super or not super then break end
        current = super
    end
    return chain
end

-- Stringify a value read off a property. Numeric / bool / string types
-- print directly. UObject-typed values get class + short name. Everything
-- else falls back to type(...) + tostring(...) and gets truncated so the
-- WPF tree doesn't have to render multi-MB structs.
local MAX_VALUE_LEN = 240

local function stringify_value(v)
    if v == nil then return "nil" end
    local t = type(v)
    if t == "string" then
        if #v > MAX_VALUE_LEN then return v:sub(1, MAX_VALUE_LEN) .. "..." end
        return v
    end
    if t == "number" then
        if v ~= v then return "nan" end          -- NaN
        if v == math.huge then return "inf" end
        if v == -math.huge then return "-inf" end
        -- Trim trailing zeros on floats so 1.0 doesn't show as "1.0000000".
        local s = tostring(v)
        return s
    end
    if t == "boolean" then return v and "true" or "false" end
    if t == "userdata" then
        -- Probe IsValid FIRST. ObjectProperty reads on Actor::Owner /
        -- AttachParent / similar can return an invalid userdata wrapper
        -- (NOT nil). Calling :GetClass() / :GetFName() on that wrapper
        -- AVs in native code. IsValid() is implemented on the wrapper
        -- itself and is safe regardless of underlying pointer state.
        local ok_valid, valid = pcall(function() return v:IsValid() end)
        if not ok_valid or not valid then return "<invalid>" end
        local cls = obj_class_name(v)
        local nm = safe_fname(v, "GetFName")
        if cls ~= "" and nm ~= "" then return cls .. " '" .. nm .. "'" end
        if cls ~= "" then return cls end
        local ok_str, s = pcall(tostring, v)
        if ok_str and s then
            if #s > MAX_VALUE_LEN then return s:sub(1, MAX_VALUE_LEN) .. "..." end
            return s
        end
        return "<userdata>"
    end
    if t == "table" then return "<table>" end
    local ok_str, s = pcall(tostring, v)
    if not ok_str or not s then return "<" .. t .. ">" end
    if #s > MAX_VALUE_LEN then return s:sub(1, MAX_VALUE_LEN) .. "..." end
    return s
end

-- Property classes whose values we trust ourselves to read off a live
-- UObject via `obj[name]`. Anything outside this set gets type-only
-- output (value shows "<unsupported>", readable=false). This is a
-- crash-avoidance whitelist: AV'd a Redberry bush dump in the wild
-- because some non-scalar / non-object property hit unmarshalable
-- memory inside UE4SS. Containers (Array/Map/Set), structs, and
-- delegates are the usual offenders ; expand this set deliberately
-- once a given class has been smoke-tested.
--
-- DO NOT add TextProperty / NameProperty / StrProperty back without a
-- proven-safe reader: marshalling FText / FName / FString back to Lua
-- routes through the userdata wrapper layer and AVs on certain BP
-- properties (confirmed: WorldActor::DisplayName, 2026-05-03). The
-- safety.lua module documents the same shape hazard for these types.
local READABLE_PROPERTY_CLASSES = {
    BoolProperty       = true,
    ByteProperty       = true,
    Int8Property       = true,
    Int16Property      = true,
    IntProperty        = true,
    Int64Property      = true,
    UInt16Property     = true,
    UInt32Property     = true,
    UInt64Property     = true,
    FloatProperty      = true,
    DoubleProperty     = true,
    EnumProperty       = true,
    ObjectProperty     = true,
    WeakObjectProperty = true,
    LazyObjectProperty = true,
    SoftObjectProperty = true,
    ClassProperty      = true,
    SoftClassProperty  = true,
    InterfaceProperty  = true,
}

-- Try to read property `name` off the live object. Returns
-- (ok_bool, value_or_nil, value_string). ok_bool is the true/false the
-- WPF "readable" flag will use ; when ok is false the value string is
-- the error text so the user sees *why* the field couldn't be read.
-- prop_class_name is the FName of the UProperty's runtime class ; we
-- consult the whitelist before even attempting the read.
local function try_read_field(obj, name, prop_class_name)
    if not obj or not name or name == "" then return false, nil, "no property name" end
    if prop_class_name and prop_class_name ~= "" and not READABLE_PROPERTY_CLASSES[prop_class_name] then
        return false, nil, "<unsupported: " .. prop_class_name .. ">"
    end
    local ok, value = pcall(function() return obj[name] end)
    if not ok then return false, nil, "<read error: " .. tostring(value) .. ">" end
    return true, value, stringify_value(value)
end

-- Iterate properties on a UStruct. Calls the canonical UE4SS API
-- directly ; probing `struct.ForEachProperty` via dot-lookup before
-- calling it returns nil on UE4SS userdata (methods aren't exposed
-- as table fields), which silently dropped us into the empty-fallback
-- and produced fields=0 dumps.
local function iter_properties(struct, callback)
    if not struct then return end
    pcall(function()
        struct:ForEachProperty(function(p)
            callback(p)
            -- Don't return anything ; ForEachProperty treats truthy
            -- returns as "stop iterating".
        end)
    end)
end

-- Iterate functions declared on a UStruct. Same direct-call rationale
-- as iter_properties.
local function iter_functions(struct, callback)
    if not struct then return end
    pcall(function()
        struct:ForEachFunction(function(f)
            callback(f)
        end)
    end)
end

-- Property type display string. Just the UProperty's runtime class
-- FName ("FloatProperty", "ObjectProperty", ...). We deliberately
-- DO NOT introspect PropertyClass / Inner anymore: reading those
-- fields on the wrong UProperty subclass dereferences uninitialised
-- storage and AVs the game thread (Lua pcall does not catch native
-- crashes). The downside is users only see "ObjectProperty" instead
-- of "ObjectProperty<UFooClass>" ; acceptable cost for not crashing.
local function property_type_string(prop)
    if not prop then return "" end
    return obj_class_name(prop)
end

-- Build a UFunction signature string. Walks the function's own properties
-- and partitions them into return / parm. Keeps the output short ; param
-- types use property_type_string so the WPF tree row stays readable.
local function function_signature(fn)
    if not fn then return "" end
    local name = safe_fname(fn, "GetFName")
    -- Same crash-avoidance as property_type_string: walking a UFunction's
    -- internal property list to read parameter types has cratered the
    -- game thread on certain BP function objects. Just return the bare
    -- function name until we have a proven-safe signature builder.
    return name .. "(...)"
end

-- ============================================================
-- Group / field / method serialisers
-- ============================================================

local function field_to_json(f)
    return "{"
        .. '"name":' .. jstr(f.name)
        .. ',"type":' .. jstr(f.type)
        .. ',"value":' .. jstr(f.value)
        .. ',"readable":' .. jbool(f.readable)
        .. "}"
end

local function method_to_json(m)
    return "{"
        .. '"name":' .. jstr(m.name)
        .. ',"signature":' .. jstr(m.signature)
        .. "}"
end

local function group_to_json(g)
    local parts = { "{" }
    parts[#parts + 1] = '"class":' .. jstr(g.class_name)
    parts[#parts + 1] = ',"resolved":' .. jbool(g.resolved)
    parts[#parts + 1] = ',"fields":'
    emit_indexed_map(parts, g.fields, field_to_json)
    parts[#parts + 1] = ',"methods":'
    emit_indexed_map(parts, g.methods, method_to_json)
    parts[#parts + 1] = "}"
    return table.concat(parts)
end

-- Builds the per-class group for a single UStruct in the chain. obj is the
-- live UObject we read field values from ; struct is the class layer we
-- enumerate properties / functions on.
local function build_group(obj, struct)
    local group = {
        class_name = safe_fname(struct, "GetFName"),
        resolved = true,                    -- always true for live walks
        fields = {},
        methods = {},
    }
    iter_properties(struct, function(p)
        pcall(function()
            local nm = safe_fname(p, "GetFName")
            if nm == "" then return end
            local prop_class = obj_class_name(p)
            if INTROSPECT_VERBOSE then
                print(string.format("[RSDWTools] introspect: prop %s::%s : %s",
                    group.class_name, nm, prop_class))
            end
            local tp = property_type_string(p)
            local readable, _, sval = try_read_field(obj, nm, prop_class)
            group.fields[#group.fields + 1] = {
                name = nm,
                type = tp,
                value = sval or "",
                readable = readable == true,
            }
        end)
    end)
    iter_functions(struct, function(fn)
        pcall(function()
            local nm = safe_fname(fn, "GetFName")
            if nm == "" then return end
            group.methods[#group.methods + 1] = {
                name = nm,
                signature = function_signature(fn),
            }
        end)
    end)
    -- Stable alphabetical sort within a class layer keeps the WPF tree
    -- predictable across runs (UE iteration order is not guaranteed).
    table.sort(group.fields, function(a, b) return a.name < b.name end)
    table.sort(group.methods, function(a, b) return a.name < b.name end)
    return group
end

-- ============================================================
-- Top-level dump
-- ============================================================

-- Returns the resolved short name to display in the WPF target label.
-- For follow-field dumps we synthesise "<actor>.<seg>.<seg>" so the user
-- sees the breadcrumb-aware label.
local function build_display_name(actor_name, path_segments)
    if not path_segments or #path_segments == 0 then return actor_name end
    return actor_name .. "." .. table.concat(path_segments, ".")
end

-- Walk path_segments (a list of property names) starting at root_obj.
-- Returns (final_obj, err_or_nil). Stops as soon as a step yields nil /
-- non-userdata ; that's reported back through the ack.
local function walk_field_path(root_obj, path_segments)
    local cur = root_obj
    for i, seg in ipairs(path_segments) do
        print(string.format("[RSDWTools] introspect: walk step %d/%d seg=%s",
            i, #path_segments, tostring(seg)))
        if not is_valid(cur) then
            print("[RSDWTools] introspect: walk FAIL parent invalid")
            return nil, "step " .. i .. " (" .. seg .. "): parent invalid"
        end
        local ok, val = pcall(function() return cur[seg] end)
        if not ok then
            print("[RSDWTools] introspect: walk FAIL read error: " .. tostring(val))
            return nil, "step " .. i .. " (" .. seg .. "): read error: " .. tostring(val)
        end
        if val == nil then
            print("[RSDWTools] introspect: walk FAIL nil at " .. seg)
            return nil, "step " .. i .. " (" .. seg .. "): nil"
        end
        if type(val) ~= "userdata" then
            print("[RSDWTools] introspect: walk FAIL non-object (" .. type(val) .. ") at " .. seg)
            return nil, "step " .. i .. " (" .. seg .. "): not an object (" .. type(val) .. ")"
        end
        -- Probe the wrapper for validity BEFORE we hand it to the next
        -- iteration ; an invalid userdata wrapper passes type(...) ==
        -- "userdata" but AVs on any vtable call.
        local ok_v, v_ok = pcall(function() return val:IsValid() end)
        if not ok_v or not v_ok then
            print("[RSDWTools] introspect: walk FAIL invalid wrapper at " .. seg)
            return nil, "step " .. i .. " (" .. seg .. "): invalid object"
        end
        cur = val
    end
    print("[RSDWTools] introspect: walk OK")
    return cur, nil
end

local function info_path()
    local d = mod_paths.ipc_dir()
    if not d then return nil end
    return d .. "\\actor_info.json"
end

-- Serialise the full payload + atomically write it. Returns
-- (true, path) or (false, err).
local function emit_dump(target_obj, display_name)
    if not is_valid(target_obj) then
        return false, "target object invalid"
    end
    print("[RSDWTools] introspect: stage=valid target=" .. tostring(display_name))
    local class_name = obj_class_name(target_obj)
    print("[RSDWTools] introspect: stage=class_name='" .. class_name .. "'")
    local chain = build_class_chain(target_obj)
    print("[RSDWTools] introspect: stage=chain_built depth=" .. tostring(#chain))

    local groups = {}
    for ci, struct in ipairs(chain) do
        local sn = safe_fname(struct, "GetFName")
        print(string.format("[RSDWTools] introspect: stage=group_begin %d/%d class=%s",
            ci, #chain, sn))
        groups[#groups + 1] = build_group(target_obj, struct)
        print(string.format("[RSDWTools] introspect: stage=group_end %d/%d fields=%d methods=%d",
            ci, #chain, #(groups[#groups].fields), #(groups[#groups].methods)))
    end
    print("[RSDWTools] introspect: stage=serialise")

    local parts = { "{" }
    parts[#parts + 1] = '"name":' .. jstr(display_name)
    parts[#parts + 1] = ',"class":' .. jstr(class_name)
    parts[#parts + 1] = ',"class_chain":'
    -- class_chain emitted as the indexed map the C# parser already
    -- understands (see TryLoadAndRenderInspect's chainElem handling).
    do
        local chain_names = {}
        for _, st in ipairs(chain) do
            chain_names[#chain_names + 1] = safe_fname(st, "GetFName")
        end
        emit_indexed_map(parts, chain_names, function(s) return jstr(s) end)
    end
    parts[#parts + 1] = ',"groups":'
    emit_indexed_map(parts, groups, group_to_json)
    parts[#parts + 1] = "}"

    local body = table.concat(parts)
    local p = info_path()
    if not p then return false, "ipc dir unavailable" end
    local ok_write, path_or_err = mod_paths.write_atomic(p, body)
    if not ok_write then return false, "write failed: " .. tostring(path_or_err) end
    return true, path_or_err
end

-- ============================================================
-- Public API (called from command_line_router)
-- ============================================================

-- actor.info <name>
function M.dump_actor(name)
    if not name or name == "" then return false, "usage: actor.info <name>" end
    local obj = feature_actor.resolve_actor_by_name(name)
    if not obj then return false, "actor not found: " .. tostring(name) end
    local ok, detail = emit_dump(obj, name)
    if not ok then return false, detail end
    return true, "wrote " .. tostring(detail)
end

-- actor.info.field <name> <seg>[.<seg>...]
function M.dump_actor_field(name, path_str)
    print(string.format("[RSDWTools] introspect: dump_actor_field name=%s path=%s",
        tostring(name), tostring(path_str)))
    if not name or name == "" then return false, "usage: actor.info.field <name> <segments>" end
    if not path_str or path_str == "" then
        -- No segments: behave like a plain dump.
        return M.dump_actor(name)
    end
    local segments = {}
    for seg in string.gmatch(path_str, "[^%.]+") do
        segments[#segments + 1] = seg
    end
    if #segments == 0 then return M.dump_actor(name) end
    local root = feature_actor.resolve_actor_by_name(name)
    if not root then
        print("[RSDWTools] introspect: dump_actor_field FAIL actor not found")
        return false, "actor not found: " .. tostring(name)
    end
    local target, err = walk_field_path(root, segments)
    if not target then
        print("[RSDWTools] introspect: dump_actor_field FAIL " .. tostring(err))
        return false, "follow-field failed at " .. (err or "?")
    end
    local display = build_display_name(name, segments)
    local ok, detail = emit_dump(target, display)
    if not ok then return false, detail end
    return true, "wrote " .. tostring(detail)
end

return M
