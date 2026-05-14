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
