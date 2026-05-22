-- Transient on-screen toast (Round 51 redesign).
--
-- Old behavior: persistent overlay toggled with Insert that surfaced a
-- "RSDWTools - Player" header. It looked like a debug HUD and didn't do
-- anything useful for the player.
--
-- New behavior: fire-and-forget toast triggered by mod rows. A row of
-- kind "umg" carries (text, duration) ; firing it shows the text on
-- screen for the requested seconds and then auto-hides. Re-firing while
-- a toast is up replaces the text and resets the timer (last-write
-- wins). No input is captured, no key polling, no debounce -- the mod
-- engine + the user's hotkey decide when to fire.

local M = {}

local widget_canvas = nil
local root_border = nil
local toast_text = nil
local oculus_help_canvas = nil
local oculus_help_border = nil
local oculus_help_text = nil
local oculus_help_mode_border = nil
local oculus_help_mode_text = nil
local toast_generation = 0           -- bumped on every show ; auto-hide checks it
local Visibility_HIDDEN = 2
local Visibility_SELF_HIT_TEST_INVISIBLE = 4

local function is_valid(obj)
    return obj and obj.IsValid and obj:IsValid()
end

local function FLinearColor(r, g, b, a)
    return { R = r, G = g, B = b, A = a }
end

local function FSlateColor(r, g, b, a)
    return { SpecifiedColor = FLinearColor(r, g, b, a), ColorUseRule = 0 }
end

local function set_visibility(show)
    if not is_valid(widget_canvas) then return end
    local vis = show and Visibility_SELF_HIT_TEST_INVISIBLE or Visibility_HIDDEN
    widget_canvas:SetVisibility(vis)
    if is_valid(root_border) then
        root_border:SetVisibility(vis)
    end
end

local function set_oculus_help_visibility(show, show_mode_row)
    if not is_valid(oculus_help_canvas) then return end
    local vis = Visibility_SELF_HIT_TEST_INVISIBLE
    local canvas_vis = show and vis or Visibility_HIDDEN
    oculus_help_canvas:SetVisibility(canvas_vis)
    if is_valid(oculus_help_border) then
        oculus_help_border:SetVisibility(canvas_vis)
    end
    if is_valid(oculus_help_mode_border) then
        oculus_help_mode_border:SetVisibility(show and show_mode_row and vis or Visibility_HIDDEN)
    end
end

local function create_widget()
    local UEHelpers
    do
        local ok, mod = pcall(require, "UEHelpers")
        if ok and type(mod) == "table" then UEHelpers = mod end
    end
    if not UEHelpers or not UEHelpers.GetGameInstance then
        print("[RSDWTools.umg] UEHelpers.GetGameInstance unavailable.")
        return false
    end
    local game_instance
    local ok_gi = pcall(function() game_instance = UEHelpers.GetGameInstance() end)
    if not ok_gi or not game_instance then
        print("[RSDWTools.umg] failed to resolve GameInstance.")
        return false
    end

    local user_widget_cls = StaticFindObject and StaticFindObject("/Script/UMG.UserWidget") or nil
    local widget_tree_cls = StaticFindObject and StaticFindObject("/Script/UMG.WidgetTree") or nil
    local canvas_panel_cls = StaticFindObject and StaticFindObject("/Script/UMG.CanvasPanel") or nil
    local border_cls = StaticFindObject and StaticFindObject("/Script/UMG.Border") or nil
    local text_block_cls = StaticFindObject and StaticFindObject("/Script/UMG.TextBlock") or nil
    if not (user_widget_cls and widget_tree_cls and canvas_panel_cls and border_cls and text_block_cls) then
        print("[RSDWTools.umg] required UMG classes not found.")
        return false
    end

    local hud = StaticConstructObject(user_widget_cls, game_instance, FName("RSDWToolsToastHUD"))
    hud.WidgetTree = StaticConstructObject(widget_tree_cls, hud, FName("RSDWToolsToastTree"))

    local canvas = StaticConstructObject(canvas_panel_cls, hud.WidgetTree, FName("RSDWToolsToastCanvas"))
    hud.WidgetTree.RootWidget = canvas

    local border = StaticConstructObject(border_cls, canvas, FName("RSDWToolsToastBorder"))
    border:SetBrushColor(FLinearColor(0.0, 0.0, 0.0, 0.65))
    border:SetPadding({ Left = 14, Top = 8, Right = 14, Bottom = 8 })

    local panel_canvas = StaticConstructObject(canvas_panel_cls, border, FName("RSDWToolsToastPanelCanvas"))
    border:SetContent(panel_canvas)

    -- Anchor the toast to the top-center of the viewport so it reads as
    -- a notification rather than a HUD attachment. Anchors min/max both
    -- (0.5, 0.05), alignment (0.5, 0) keeps it horizontally centered
    -- and pinned 5% down from the top.
    local slot = canvas:AddChildToCanvas(border)
    slot:SetAutoSize(true)
    slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.05 }, Maximum = { X = 0.5, Y = 0.05 } })
    slot:SetAlignment({ X = 0.5, Y = 0.0 })
    slot:SetPosition({ X = 0, Y = 0 })

    local t = StaticConstructObject(text_block_cls, panel_canvas, FName("RSDWToolsToastText"))
    t.Font.Size = 22
    t:SetText(FText(""))
    t:SetColorAndOpacity(FSlateColor(1.0, 1.0, 1.0, 1.0))
    t:SetShadowOffset({ X = 1, Y = 1 })
    t:SetShadowColorAndOpacity(FLinearColor(0.0, 0.0, 0.0, 0.7))
    local ts = panel_canvas:AddChildToCanvas(t)
    ts:SetAutoSize(true)
    ts:SetPosition({ X = 0, Y = 0 })

    canvas.Visibility = Visibility_HIDDEN
    border.Visibility = Visibility_HIDDEN
    panel_canvas.Visibility = Visibility_SELF_HIT_TEST_INVISIBLE

    hud:AddToViewport(95)

    widget_canvas = canvas
    root_border = border
    toast_text = t
    print("[RSDWTools.umg] toast widget created.")
    return true
end

local function create_oculus_help_widget()
    local UEHelpers
    do
        local ok, mod = pcall(require, "UEHelpers")
        if ok and type(mod) == "table" then UEHelpers = mod end
    end
    if not UEHelpers or not UEHelpers.GetGameInstance then
        print("[RSDWTools.umg] UEHelpers.GetGameInstance unavailable for Oculus help.")
        return false
    end

    local game_instance
    local ok_gi = pcall(function() game_instance = UEHelpers.GetGameInstance() end)
    if not ok_gi or not game_instance then
        print("[RSDWTools.umg] failed to resolve GameInstance for Oculus help.")
        return false
    end

    local user_widget_cls = StaticFindObject and StaticFindObject("/Script/UMG.UserWidget") or nil
    local widget_tree_cls = StaticFindObject and StaticFindObject("/Script/UMG.WidgetTree") or nil
    local canvas_panel_cls = StaticFindObject and StaticFindObject("/Script/UMG.CanvasPanel") or nil
    local border_cls = StaticFindObject and StaticFindObject("/Script/UMG.Border") or nil
    local text_block_cls = StaticFindObject and StaticFindObject("/Script/UMG.TextBlock") or nil
    if not (user_widget_cls and widget_tree_cls and canvas_panel_cls and border_cls and text_block_cls) then
        print("[RSDWTools.umg] Oculus help UMG classes not found.")
        return false
    end

    local hud = StaticConstructObject(user_widget_cls, game_instance, FName("RSDWToolsOculusHelpHUD"))
    hud.WidgetTree = StaticConstructObject(widget_tree_cls, hud, FName("RSDWToolsOculusHelpTree"))

    local canvas = StaticConstructObject(canvas_panel_cls, hud.WidgetTree, FName("RSDWToolsOculusHelpCanvas"))
    hud.WidgetTree.RootWidget = canvas

    local border = StaticConstructObject(border_cls, canvas, FName("RSDWToolsOculusHelpBorder"))
    border:SetBrushColor(FLinearColor(0.0, 0.0, 0.0, 0.62))
    border:SetPadding({ Left = 10, Top = 4, Right = 10, Bottom = 4 })

    local t = StaticConstructObject(text_block_cls, border, FName("RSDWToolsOculusHelpText"))
    t.Font.Size = 15
    t:SetText(FText(""))
    t:SetColorAndOpacity(FSlateColor(0.92, 0.95, 1.0, 1.0))
    t:SetShadowOffset({ X = 1, Y = 1 })
    t:SetShadowColorAndOpacity(FLinearColor(0.0, 0.0, 0.0, 0.75))
    pcall(function() t:SetJustification(1) end)
    border:SetContent(t)

    local slot = canvas:AddChildToCanvas(border)
    pcall(function() slot:SetAutoSize(false) end)
    slot:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 0.0 } })
    slot:SetAlignment({ X = 0.0, Y = 0.0 })
    slot:SetPosition({ X = 0, Y = 0 })
    pcall(function() slot:SetSize({ X = 0, Y = 30 }) end)
    pcall(function() slot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 30 }) end)

    local mode_border = StaticConstructObject(border_cls, canvas, FName("RSDWToolsOculusHelpModeBorder"))
    mode_border:SetBrushColor(FLinearColor(0.0, 0.0, 0.0, 0.56))
    mode_border:SetPadding({ Left = 12, Top = 8, Right = 12, Bottom = 8 })

    local mode_t = StaticConstructObject(text_block_cls, mode_border, FName("RSDWToolsOculusHelpModeText"))
    mode_t.Font.Size = 15
    mode_t:SetText(FText(""))
    mode_t:SetColorAndOpacity(FSlateColor(0.92, 0.95, 1.0, 1.0))
    mode_t:SetShadowOffset({ X = 1, Y = 1 })
    mode_t:SetShadowColorAndOpacity(FLinearColor(0.0, 0.0, 0.0, 0.75))
    pcall(function() mode_t:SetJustification(2) end)
    mode_border:SetContent(mode_t)

    local mode_slot = canvas:AddChildToCanvas(mode_border)
    pcall(function() mode_slot:SetAutoSize(true) end)
    mode_slot:SetAnchors({ Minimum = { X = 1.0, Y = 0.5 }, Maximum = { X = 1.0, Y = 0.5 } })
    mode_slot:SetAlignment({ X = 1.0, Y = 0.0 })
    mode_slot:SetPosition({ X = -18, Y = 0 })

    canvas.Visibility = Visibility_HIDDEN
    border.Visibility = Visibility_HIDDEN
    mode_border.Visibility = Visibility_HIDDEN
    hud:AddToViewport(96)

    oculus_help_canvas = canvas
    oculus_help_border = border
    oculus_help_text = t
    oculus_help_mode_border = mode_border
    oculus_help_mode_text = mode_t
    print("[RSDWTools.umg] Oculus help widget created.")
    return true
end

-- Fire a toast on screen.
--   message  : string text to show
--   duration : seconds before auto-hide ; defaults to 3 if nil/<=0
local function show_toast(message, duration)
    if not message or message == "" then return end
    duration = tonumber(duration) or 3
    if duration <= 0 then duration = 3 end

    if not is_valid(toast_text) then
        if not create_widget() then return end
    end
    if is_valid(toast_text) then
        toast_text:SetText(FText(tostring(message)))
    end
    set_visibility(true)

    toast_generation = toast_generation + 1
    local my_gen = toast_generation
    if LoopAsync then
        local delay_ms = math.floor(duration * 1000)
        LoopAsync(delay_ms, function()
            -- Only hide if a newer toast hasn't superseded us.
            if my_gen ~= toast_generation then return true end
            ExecuteInGameThread(function()
                if my_gen == toast_generation then
                    set_visibility(false)
                end
            end)
            return true -- one-shot ; LoopAsync exits when callback returns true
        end)
    end
end

function M.toast(message, duration)
    if not ExecuteInGameThread then
        print("[RSDWTools.umg] ExecuteInGameThread unavailable.")
        return
    end
    ExecuteInGameThread(function()
        show_toast(message, duration)
    end)
end

function M.oculus_help(message, mode_message)
    if not ExecuteInGameThread then
        print("[RSDWTools.umg] ExecuteInGameThread unavailable.")
        return
    end
    ExecuteInGameThread(function()
        local primary = tostring(message or "")
        local secondary = tostring(mode_message or "")
        if primary == "" and secondary == "" then
            set_oculus_help_visibility(false, false)
            return
        end
        if not is_valid(oculus_help_text) then
            if not create_oculus_help_widget() then return end
        end
        if is_valid(oculus_help_text) then
            oculus_help_text:SetText(FText(primary))
        end
        if is_valid(oculus_help_mode_text) then
            oculus_help_mode_text:SetText(FText(secondary))
        end
        set_oculus_help_visibility(primary ~= "", secondary ~= "")
    end)
end

function M.oculus_help_hide()
    M.oculus_help("")
end

-- Backwards-compat shim used by older console handlers ; routes through
-- the toast with the default duration.
function M.set_text(message)
    M.toast(message, 3)
end

function M.on_player_ready()
    -- Lazy-create on first toast ; nothing to do here.
end

function M.register_console()
    if not RegisterConsoleCommandHandler then return end
    RegisterConsoleCommandHandler("rsdwt_umg_text", function(_, parts)
        local txt
        if type(parts) == "table" then
            local chunks = {}
            for i = 2, #parts do chunks[#chunks + 1] = tostring(parts[i]) end
            txt = table.concat(chunks, " ")
        end
        M.toast(txt or "test", 3)
        return true
    end)
end

return M
