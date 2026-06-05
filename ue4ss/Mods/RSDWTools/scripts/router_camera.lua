local support = require("router_support")
local lazy_feature = support.lazy_feature

local feature_camera = lazy_feature("feature_camera")
local feature_grab = lazy_feature("feature_grab")
local feature_oculus = lazy_feature("feature_oculus")
local feature_oculus_config = lazy_feature("feature_oculus_config")
local feature_oculus_clone = lazy_feature("feature_oculus_clone")
local feature_oculus_duplicate = lazy_feature("feature_oculus_duplicate")
local feature_oculus_rotation = lazy_feature("feature_oculus_rotation")
local feature_oculus_scale = lazy_feature("feature_oculus_scale")
local feature_oculus_transform = lazy_feature("feature_oculus_transform")

local M = {}

local function stop_oculus_transform_modes()
    if feature_oculus_rotation.is_active and feature_oculus_rotation.is_active() then
        feature_oculus_rotation.stop()
    end
    if feature_oculus_scale.is_active and feature_oculus_scale.is_active() then
        feature_oculus_scale.stop()
    end
end

local function safe_cancel_grab()
    if feature_grab.safe_cancel then
        return feature_grab.safe_cancel()
    end
    if feature_grab.is_active and feature_grab.is_active() then
        return feature_grab.cancel()
    end
    return true, "not grabbing"
end

function M.try_handle(line, handle_line)
    local route_line = handle_line or function()
        return false, "router callback missing"
    end
    -- ---- camera.debug.* + camera.grab.* + camera.lookat (top-level ; longest-prefix order) ----
    -- Must live OUTSIDE the actor.* block above ; the dispatcher gates that
    -- whole block on `line:sub(1,6) == "actor."`, so any camera.* line
    -- typed there would silently fall through. Keep these grouped here so
    -- the next refactor doesn't re-nest them by accident.
    --   camera.debug.status         report stock DebugCamera controller state
    --   camera.debug.enable         enable Unreal's stock DebugCamera
    --   camera.debug.disable        disable Unreal's stock DebugCamera
    --   camera.debug.toggle         toggle Unreal's stock DebugCamera
    --   camera.debug.force_restore  explicit fallback if stock disable fails
    --   camera.debug.speed <scale>  scale DebugCamera pawn movement speed
    --   camera.debug.display        toggle DebugCamera overlay
    --   camera.debug.selected       report DebugCamera selected actor
    --   camera.streaming.status     report DebugCamera + World Partition streaming state
    --   camera.streaming.scale <n> [range]  scale camera source shapes / WP grid range
    --   camera.streaming.reset      restore runtime streaming experiment snapshot
    --   camera.lod.status [radius] [limit]  count render components near camera
    --   camera.lod.force <radius> [lod] [limit]  disabled after Shipping crash reports
    --   camera.lod.reset            restore camera-local LOD experiment snapshot
    --   camera.rig.*                first DebugCamera-backed pose/path verbs
    --   camera.rig.roll.add/set/reset/step/status  hotkeyable roll controls
    --   camera.grab.release         drop in place
    --   camera.grab.cancel          drop and restore start transform
    --   camera.grab.status          report state
    --   camera.grab.mode <m>        m in {move,rot,z,scale}
    --   camera.grab.delta <signed>  one wheel-tick in the active mode
    --   camera.grab.safety <on|off|toggle|status> toggle unsafe target blocks
    --   camera.grab.rotate <signed> dedicated yaw nudge (mode-independent)
    --   camera.grab.start [name]    latch named (or look-at) actor
    --   camera.grab.item            latch/release runtime world item nearest reticle
    --   camera.lookat               probe what the camera trace hits
    --   camera.lookat.item          inspect runtime world item nearest reticle
    --   camera.oculus.clone         spawn same class as look-at actor and grab it
    --   camera.oculus.duplicate     smart copy: building piece preview, otherwise clone
    --   camera.oculus.rotation.*    repair-mode in-place mouse rotation
    --   camera.oculus.scale.*       repair-mode in-place mouse scaling
    --   camera.oculus.transform.inspect   inspect/capture actor under reticle
    --   camera.oculus.transform.reload ... re-read selected live actor transform
    --   camera.oculus.transform.apply ... apply edited transform to capture
    --   camera.destroy.lookat       destroy actor under the active camera reticle
    if line == "camera.debug.status" then
        local ok, detail = feature_camera.status()
        if ok then return true, true, "ok camera.debug.status " .. tostring(detail) end
        return true, false, "camera.debug.status failed: " .. tostring(detail)
    end
    if line == "camera.streaming.status" then
        local ok, detail = feature_camera.streaming_status()
        if ok then return true, true, "ok camera.streaming.status " .. tostring(detail) end
        return true, false, "camera.streaming.status failed: " .. tostring(detail)
    end
    if line == "camera.streaming.scale" or line:sub(1, 23) == "camera.streaming.scale " then
        local arg = line:sub(24):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.streaming_scale(arg)
        if ok then return true, true, "ok camera.streaming.scale " .. tostring(detail) end
        return true, false, "camera.streaming.scale failed: " .. tostring(detail)
    end
    if line == "camera.streaming.reset" then
        local ok, detail = feature_camera.streaming_reset()
        if ok then return true, true, "ok camera.streaming.reset " .. tostring(detail) end
        return true, false, "camera.streaming.reset failed: " .. tostring(detail)
    end
    if line == "camera.lod.status" or line:sub(1, 18) == "camera.lod.status " then
        local arg = line:sub(19):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.lod_status(arg)
        if ok then return true, true, "ok camera.lod.status " .. tostring(detail) end
        return true, false, "camera.lod.status failed: " .. tostring(detail)
    end
    if line == "camera.lod.force" or line:sub(1, 17) == "camera.lod.force " then
        local arg = line:sub(18):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.lod_force(arg)
        if ok then return true, true, "ok camera.lod.force " .. tostring(detail) end
        return true, false, "camera.lod.force failed: " .. tostring(detail)
    end
    if line == "camera.lod.reset" then
        local ok, detail = feature_camera.lod_reset()
        if ok then return true, true, "ok camera.lod.reset " .. tostring(detail) end
        return true, false, "camera.lod.reset failed: " .. tostring(detail)
    end
    if line == "camera.rig.status" then
        local ok, detail = feature_camera.rig_status()
        if ok then return true, true, "ok camera.rig.status " .. tostring(detail) end
        return true, false, "camera.rig.status failed: " .. tostring(detail)
    end
    if line == "camera.rig.start" or line:sub(1, 17) == "camera.rig.start " then
        local arg = line:sub(18):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_start(arg)
        if ok then return true, true, "ok camera.rig.start " .. tostring(detail) end
        return true, false, "camera.rig.start failed: " .. tostring(detail)
    end
    if line == "camera.rig.stop" then
        local ok, detail = feature_camera.rig_stop()
        if ok then return true, true, "ok camera.rig.stop " .. tostring(detail) end
        return true, false, "camera.rig.stop failed: " .. tostring(detail)
    end
    if line == "camera.rig.list" then
        local ok, detail = feature_camera.rig_list()
        if ok then return true, true, "ok camera.rig.list " .. tostring(detail) end
        return true, false, "camera.rig.list failed: " .. tostring(detail)
    end
    if line == "camera.rig.clear" then
        local ok, detail = feature_camera.rig_clear()
        if ok then return true, true, "ok camera.rig.clear " .. tostring(detail) end
        return true, false, "camera.rig.clear failed: " .. tostring(detail)
    end
    if line:sub(1, 19) == "camera.rig.pose.set" then
        local arg = line:sub(20):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_pose_set(arg)
        if ok then return true, true, "ok camera.rig.pose.set " .. tostring(detail) end
        return true, false, "camera.rig.pose.set failed: " .. tostring(detail)
    end
    if line == "camera.rig.poses.file" or line:sub(1, 22) == "camera.rig.poses.file " then
        local arg = line:sub(23):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_poses_file(arg)
        if ok then return true, true, "ok camera.rig.poses.file " .. tostring(detail) end
        return true, false, "camera.rig.poses.file failed: " .. tostring(detail)
    end
    if line:sub(1, 17) == "camera.rig.delete" then
        local arg = line:sub(18):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_delete(arg)
        if ok then return true, true, "ok camera.rig.delete " .. tostring(detail) end
        return true, false, "camera.rig.delete failed: " .. tostring(detail)
    end
    if line:sub(1, 18) == "camera.rig.capture" then
        local arg = line:sub(19):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_capture(arg)
        if ok then return true, true, "ok camera.rig.capture " .. tostring(detail) end
        return true, false, "camera.rig.capture failed: " .. tostring(detail)
    end
    if line == "camera.rig.goto.file" or line:sub(1, 21) == "camera.rig.goto.file " then
        local arg = line:sub(22):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_goto_file(arg)
        if ok then return true, true, "ok camera.rig.goto.file " .. tostring(detail) end
        return true, false, "camera.rig.goto.file failed: " .. tostring(detail)
    end
    if line:sub(1, 15) == "camera.rig.goto" then
        local arg = line:sub(16):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_goto(arg)
        if ok then return true, true, "ok camera.rig.goto " .. tostring(detail) end
        return true, false, "camera.rig.goto failed: " .. tostring(detail)
    end
    if line == "camera.rig.play.stop" then
        local ok, detail = feature_camera.rig_play_stop()
        if ok then return true, true, "ok camera.rig.play.stop " .. tostring(detail) end
        return true, false, "camera.rig.play.stop failed: " .. tostring(detail)
    end
    if line == "camera.rig.play.file" or line:sub(1, 21) == "camera.rig.play.file " then
        local arg = line:sub(22):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_play_file(arg)
        if ok then return true, true, "ok camera.rig.play.file " .. tostring(detail) end
        return true, false, "camera.rig.play.file failed: " .. tostring(detail)
    end
    if line == "camera.rig.play.chain" or line:sub(1, 22) == "camera.rig.play.chain " then
        local arg = line:sub(23):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_play_chain(arg)
        if ok then return true, true, "ok camera.rig.play.chain " .. tostring(detail) end
        return true, false, "camera.rig.play.chain failed: " .. tostring(detail)
    end
    if line:sub(1, 15) == "camera.rig.play" then
        local arg = line:sub(16):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_play(arg)
        if ok then return true, true, "ok camera.rig.play " .. tostring(detail) end
        return true, false, "camera.rig.play failed: " .. tostring(detail)
    end
    if line:sub(1, 14) == "camera.rig.fov" then
        local arg = line:sub(15):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_fov(arg)
        if ok then return true, true, "ok camera.rig.fov " .. tostring(detail) end
        return true, false, "camera.rig.fov failed: " .. tostring(detail)
    end
    if line == "camera.rig.roll.status" then
        local ok, detail = feature_camera.rig_roll_status()
        if ok then return true, true, "ok camera.rig.roll.status " .. tostring(detail) end
        return true, false, "camera.rig.roll.status failed: " .. tostring(detail)
    end
    if line == "camera.rig.roll.reset" then
        local ok, detail = feature_camera.rig_roll_reset()
        if ok then return true, true, "ok camera.rig.roll.reset " .. tostring(detail) end
        return true, false, "camera.rig.roll.reset failed: " .. tostring(detail)
    end
    if line == "camera.rig.roll.step" or line:sub(1, 21) == "camera.rig.roll.step " then
        local arg = line:sub(22):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_roll_step(arg)
        if ok then return true, true, "ok camera.rig.roll.step " .. tostring(detail) end
        return true, false, "camera.rig.roll.step failed: " .. tostring(detail)
    end
    if line == "camera.rig.roll.add" or line:sub(1, 20) == "camera.rig.roll.add " then
        local arg = line:sub(21):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_roll_add(arg)
        if ok then return true, true, "ok camera.rig.roll.add " .. tostring(detail) end
        return true, false, "camera.rig.roll.add failed: " .. tostring(detail)
    end
    if line == "camera.rig.roll.set" or line:sub(1, 20) == "camera.rig.roll.set " then
        local arg = line:sub(21):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_roll_set(arg)
        if ok then return true, true, "ok camera.rig.roll.set " .. tostring(detail) end
        return true, false, "camera.rig.roll.set failed: " .. tostring(detail)
    end
    if line == "camera.fps" or line:sub(1, 11) == "camera.fps " then
        local arg = line:sub(12):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.fps(arg)
        if ok then return true, true, "ok camera.fps " .. tostring(detail) end
        return true, false, "camera.fps failed: " .. tostring(detail)
    end
    if line == "camera.vsync" or line:sub(1, 13) == "camera.vsync " then
        local arg = line:sub(14):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.vsync(arg)
        if ok then return true, true, "ok camera.vsync " .. tostring(detail) end
        return true, false, "camera.vsync failed: " .. tostring(detail)
    end
    if line == "camera.rig.lookat" or line:sub(1, 18) == "camera.rig.lookat " then
        local arg = line:sub(19):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_lookat(arg)
        if ok then return true, true, "ok camera.rig.lookat " .. tostring(detail) end
        return true, false, "camera.rig.lookat failed: " .. tostring(detail)
    end
    if line == "camera.debug.enable" then
        local ok, detail = feature_camera.enable()
        if ok then return true, true, "ok camera.debug.enable " .. tostring(detail) end
        return true, false, "camera.debug.enable failed: " .. tostring(detail)
    end
    if line == "camera.debug.disable" then
        local ok, detail = feature_camera.disable()
        if ok then return true, true, "ok camera.debug.disable " .. tostring(detail) end
        return true, false, "camera.debug.disable failed: " .. tostring(detail)
    end
    if line == "camera.debug.toggle" then
        local ok, detail = feature_camera.toggle()
        if ok then return true, true, "ok camera.debug.toggle " .. tostring(detail) end
        return true, false, "camera.debug.toggle failed: " .. tostring(detail)
    end
    if line == "camera.debug.force_restore" then
        local ok, detail = feature_camera.force_restore()
        if ok then return true, true, "ok camera.debug.force_restore " .. tostring(detail) end
        return true, false, "camera.debug.force_restore failed: " .. tostring(detail)
    end
    if line == "camera.debug.display" then
        local ok, detail = feature_camera.display()
        if ok then return true, true, "ok camera.debug.display " .. tostring(detail) end
        return true, false, "camera.debug.display failed: " .. tostring(detail)
    end
    if line == "camera.debug.selected" then
        local ok, detail = feature_camera.selected()
        if ok then return true, true, "ok camera.debug.selected " .. tostring(detail) end
        return true, false, "camera.debug.selected failed: " .. tostring(detail)
    end
    if line == "camera.debug.speed" or line:sub(1, 19) == "camera.debug.speed " then
        local arg = line:sub(20):match("^%s*(.-)%s*$") or ""
        if arg == "" then return true, false, "usage: camera.debug.speed <scale>" end
        local ok, detail = feature_camera.speed(arg)
        if ok then return true, true, "ok camera.debug.speed " .. tostring(detail) end
        return true, false, "camera.debug.speed failed: " .. tostring(detail)
    end
    if line == "camera.oculus.status" then
        local ok, detail = feature_oculus.status()
        if ok then return true, true, "ok camera.oculus.status " .. tostring(detail) end
        return true, false, "camera.oculus.status failed: " .. tostring(detail)
    end
    if line == "camera.oculus.start" then
        local ok, detail = feature_oculus.start()
        if ok then
            local active_ok, active_detail = feature_oculus.require_state("active")
            if not active_ok then
                return true, false, "camera.oculus.start init blocked: " .. tostring(active_detail)
            end
            local init_ok, init_detail = feature_oculus_config.run_init(function(cmd)
                return route_line(cmd)
            end)
            if init_ok then
                local help_ok, help_detail = feature_oculus_config.show_hotkey_help(function(cmd)
                    return route_line(cmd)
                end)
                if help_ok then return true, true, "ok camera.oculus.start " .. tostring(detail) .. "; " .. tostring(init_detail) .. "; " .. tostring(help_detail) end
                return true, false, "camera.oculus.start help failed: " .. tostring(help_detail)
            end
            return true, false, "camera.oculus.start init failed: " .. tostring(init_detail)
        end
        return true, false, "camera.oculus.start failed: " .. tostring(detail)
    end
    if line == "camera.oculus.help" or line:sub(1, 19) == "camera.oculus.help " then
        local arg = line:sub(20):match("^%s*(.-)%s*$") or ""
        local ok, detail
        if arg == "" then
            ok, detail = feature_oculus_config.set_hotkey_help_visibility("on")
        else
            ok, detail = feature_oculus_config.set_hotkey_help_visibility(arg)
        end
        if ok then return true, true, "ok camera.oculus.help " .. tostring(detail) end
        return true, false, "camera.oculus.help failed: " .. tostring(detail)
    end
    if line == "camera.oculus.umg" or line:sub(1, 18) == "camera.oculus.umg " then
        local arg = line:sub(19):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_config.set_hotkey_help_visibility(arg)
        if ok then return true, true, "ok camera.oculus.umg " .. tostring(detail) end
        return true, false, "camera.oculus.umg failed: " .. tostring(detail)
    end
    if line == "camera.oculus.init" then
        local active_ok, active_detail = feature_oculus.require_state("active")
        if not active_ok then return true, false, "camera.oculus.init failed: " .. tostring(active_detail) end
        local init_ok, init_detail = feature_oculus_config.run_init(function(cmd)
            return route_line(cmd)
        end)
        if init_ok then
            local help_ok, help_detail = feature_oculus_config.show_hotkey_help(function(cmd)
                return route_line(cmd)
            end)
            if help_ok then return true, true, "ok camera.oculus.init " .. tostring(init_detail) .. "; " .. tostring(help_detail) end
            return true, false, "camera.oculus.init help failed: " .. tostring(help_detail)
        end
        return true, false, "camera.oculus.init failed: " .. tostring(init_detail)
    end
    if line == "camera.oculus.stop" then
        stop_oculus_transform_modes()
        safe_cancel_grab()
        local ok, detail = feature_oculus.stop()
        if ok then
            local exit_ok, exit_detail = feature_oculus_config.run_exit(function(cmd)
                return route_line(cmd)
            end)
            feature_oculus_config.hide_hotkey_help()
            if exit_ok then return true, true, "ok camera.oculus.stop " .. tostring(detail) .. "; " .. tostring(exit_detail) end
            return true, false, "camera.oculus.stop exit failed: " .. tostring(exit_detail)
        end
        return true, false, "camera.oculus.stop failed: " .. tostring(detail)
    end
    if line == "camera.oculus.exit" then
        stop_oculus_transform_modes()
        safe_cancel_grab()
        local ok, detail = feature_oculus_config.run_exit(function(cmd)
            return route_line(cmd)
        end, true)
        if ok then return true, true, "ok camera.oculus.exit " .. tostring(detail) end
        return true, false, "camera.oculus.exit failed: " .. tostring(detail)
    end
    if line == "camera.oculus.toggle" then
        local was_active = feature_oculus.require_state("active")
        if was_active then
            stop_oculus_transform_modes()
            safe_cancel_grab()
        end
        local ok, detail = feature_oculus.toggle()
        if ok then
            local active_ok = feature_oculus.require_state("active")
            if active_ok then
                feature_oculus_config.show_hotkey_help(function(cmd)
                    return route_line(cmd)
                end)
            else
                local exit_ok, exit_detail = feature_oculus_config.run_exit(function(cmd)
                    return route_line(cmd)
                end)
                feature_oculus_config.hide_hotkey_help()
                if not exit_ok then return true, false, "camera.oculus.toggle exit failed: " .. tostring(exit_detail) end
                detail = tostring(detail) .. "; " .. tostring(exit_detail)
            end
            return true, true, "ok camera.oculus.toggle " .. tostring(detail)
        end
        return true, false, "camera.oculus.toggle failed: " .. tostring(detail)
    end
    if line == "camera.oculus.require" or line:sub(1, 22) == "camera.oculus.require " then
        local arg = line:sub(23):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus.require_state(arg)
        if ok then return true, true, "ok camera.oculus.require " .. tostring(detail) end
        return true, false, "camera.oculus.require failed: " .. tostring(detail)
    end
    if line == "camera.oculus.speed" or line:sub(1, 20) == "camera.oculus.speed " then
        local arg = line:sub(21):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus.speed(arg)
        if ok then return true, true, "ok camera.oculus.speed " .. tostring(detail) end
        return true, false, "camera.oculus.speed failed: " .. tostring(detail)
    end
    if line == "camera.oculus.distance" or line:sub(1, 23) == "camera.oculus.distance " then
        local arg = line:sub(24):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus.distance(arg)
        if ok then return true, true, "ok camera.oculus.distance " .. tostring(detail) end
        return true, false, "camera.oculus.distance failed: " .. tostring(detail)
    end
    if line == "camera.oculus.vignette" or line:sub(1, 23) == "camera.oculus.vignette " then
        local arg = line:sub(24):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus.vignette(arg)
        if ok then return true, true, "ok camera.oculus.vignette " .. tostring(detail) end
        return true, false, "camera.oculus.vignette failed: " .. tostring(detail)
    end
    if line == "camera.oculus.watermark" or line:sub(1, 24) == "camera.oculus.watermark " then
        local arg = line:sub(25):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus.watermark(arg)
        if ok then return true, true, "ok camera.oculus.watermark " .. tostring(detail) end
        return true, false, "camera.oculus.watermark failed: " .. tostring(detail)
    end
    if line == "camera.oculus.rotation.toggle" then
        local ok, detail = feature_oculus_rotation.toggle()
        if ok then return true, true, "ok camera.oculus.rotation.toggle " .. tostring(detail) end
        return true, false, "camera.oculus.rotation.toggle failed: " .. tostring(detail)
    end
    if line == "camera.oculus.rotation.start" then
        local ok, detail = feature_oculus_rotation.start()
        if ok then return true, true, "ok camera.oculus.rotation.start " .. tostring(detail) end
        return true, false, "camera.oculus.rotation.start failed: " .. tostring(detail)
    end
    if line == "camera.oculus.rotation.stop" then
        local ok, detail = feature_oculus_rotation.stop()
        if ok then return true, true, "ok camera.oculus.rotation.stop " .. tostring(detail) end
        return true, false, "camera.oculus.rotation.stop failed: " .. tostring(detail)
    end
    if line == "camera.oculus.rotation.reset" then
        local ok, detail = feature_oculus_rotation.reset()
        if ok then return true, true, "ok camera.oculus.rotation.reset " .. tostring(detail) end
        return true, false, "camera.oculus.rotation.reset failed: " .. tostring(detail)
    end
    if line == "camera.oculus.rotation.status" then
        local ok, detail = feature_oculus_rotation.status()
        if ok then return true, true, "ok camera.oculus.rotation.status " .. tostring(detail) end
        return true, false, "camera.oculus.rotation.status failed: " .. tostring(detail)
    end
    if line == "camera.oculus.rotation.sensitivity" or line:sub(1, 35) == "camera.oculus.rotation.sensitivity " then
        local arg = line:sub(36):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_rotation.sensitivity(arg)
        if ok then return true, true, "ok camera.oculus.rotation.sensitivity " .. tostring(detail) end
        return true, false, "camera.oculus.rotation.sensitivity failed: " .. tostring(detail)
    end
    if line == "camera.oculus.rotation.freeze" or line:sub(1, 30) == "camera.oculus.rotation.freeze " then
        local arg = line:sub(31):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_rotation.freeze(arg)
        if ok then return true, true, "ok camera.oculus.rotation.freeze " .. tostring(detail) end
        return true, false, "camera.oculus.rotation.freeze failed: " .. tostring(detail)
    end
    local rotation_look_prefix = "camera.oculus.rotation.look"
    if line == rotation_look_prefix or line:sub(1, #rotation_look_prefix + 1) == rotation_look_prefix .. " " then
        local arg = line:sub(#rotation_look_prefix + 2):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_rotation.look(arg)
        if ok then return true, true, "ok camera.oculus.rotation.look " .. tostring(detail) end
        return true, false, "camera.oculus.rotation.look failed: " .. tostring(detail)
    end
    if line == "camera.oculus.rotation.mode" or line:sub(1, 28) == "camera.oculus.rotation.mode " then
        local arg = line:sub(29):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_rotation.mode(arg)
        if ok then return true, true, "ok camera.oculus.rotation.mode " .. tostring(detail) end
        return true, false, "camera.oculus.rotation.mode failed: " .. tostring(detail)
    end
    if line == "camera.oculus.scale.toggle" then
        local ok, detail = feature_oculus_scale.toggle()
        if ok then return true, true, "ok camera.oculus.scale.toggle " .. tostring(detail) end
        return true, false, "camera.oculus.scale.toggle failed: " .. tostring(detail)
    end
    if line == "camera.oculus.scale.start" then
        local ok, detail = feature_oculus_scale.start()
        if ok then return true, true, "ok camera.oculus.scale.start " .. tostring(detail) end
        return true, false, "camera.oculus.scale.start failed: " .. tostring(detail)
    end
    if line == "camera.oculus.scale.stop" then
        local ok, detail = feature_oculus_scale.stop()
        if ok then return true, true, "ok camera.oculus.scale.stop " .. tostring(detail) end
        return true, false, "camera.oculus.scale.stop failed: " .. tostring(detail)
    end
    if line == "camera.oculus.scale.reset" then
        local ok, detail = feature_oculus_scale.reset()
        if ok then return true, true, "ok camera.oculus.scale.reset " .. tostring(detail) end
        return true, false, "camera.oculus.scale.reset failed: " .. tostring(detail)
    end
    if line == "camera.oculus.scale.status" then
        local ok, detail = feature_oculus_scale.status()
        if ok then return true, true, "ok camera.oculus.scale.status " .. tostring(detail) end
        return true, false, "camera.oculus.scale.status failed: " .. tostring(detail)
    end
    if line == "camera.oculus.scale.sensitivity" or line:sub(1, 32) == "camera.oculus.scale.sensitivity " then
        local arg = line:sub(33):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_scale.sensitivity(arg)
        if ok then return true, true, "ok camera.oculus.scale.sensitivity " .. tostring(detail) end
        return true, false, "camera.oculus.scale.sensitivity failed: " .. tostring(detail)
    end
    if line == "camera.oculus.scale.bounds" or line:sub(1, 27) == "camera.oculus.scale.bounds " then
        local arg = line:sub(28):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_scale.bounds(arg)
        if ok then return true, true, "ok camera.oculus.scale.bounds " .. tostring(detail) end
        return true, false, "camera.oculus.scale.bounds failed: " .. tostring(detail)
    end
    if line == "camera.oculus.scale.freeze" or line:sub(1, 27) == "camera.oculus.scale.freeze " then
        local arg = line:sub(28):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_scale.freeze(arg)
        if ok then return true, true, "ok camera.oculus.scale.freeze " .. tostring(detail) end
        return true, false, "camera.oculus.scale.freeze failed: " .. tostring(detail)
    end
    local scale_look_prefix = "camera.oculus.scale.look"
    if line == scale_look_prefix or line:sub(1, #scale_look_prefix + 1) == scale_look_prefix .. " " then
        local arg = line:sub(#scale_look_prefix + 2):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_scale.look(arg)
        if ok then return true, true, "ok camera.oculus.scale.look " .. tostring(detail) end
        return true, false, "camera.oculus.scale.look failed: " .. tostring(detail)
    end
    if line == "camera.oculus.scale.mode" or line:sub(1, 25) == "camera.oculus.scale.mode " then
        local arg = line:sub(26):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_scale.mode(arg)
        if ok then return true, true, "ok camera.oculus.scale.mode " .. tostring(detail) end
        return true, false, "camera.oculus.scale.mode failed: " .. tostring(detail)
    end
    if line:sub(1, 19) == "camera.grab.release" then
        local ok, detail = feature_grab.release()
        if ok then return true, true, "ok camera.grab.release " .. tostring(detail) end
        return true, false, "camera.grab.release failed: " .. tostring(detail)
    end
    if line == "camera.grab.safe_cancel" then
        local ok, detail = safe_cancel_grab()
        if ok then return true, true, "ok camera.grab.safe_cancel " .. tostring(detail) end
        return true, false, "camera.grab.safe_cancel failed: " .. tostring(detail)
    end
    if line:sub(1, 18) == "camera.grab.cancel" then
        local ok, detail = feature_grab.cancel()
        if ok then return true, true, "ok camera.grab.cancel " .. tostring(detail) end
        return true, false, "camera.grab.cancel failed: " .. tostring(detail)
    end
    if line:sub(1, 18) == "camera.grab.status" then
        local ok, detail = feature_grab.status()
        if ok then return true, true, "ok camera.grab.status " .. tostring(detail) end
        return true, false, "camera.grab.status failed: " .. tostring(detail)
    end
    if line == "camera.grab.steps" or line:sub(1, 18) == "camera.grab.steps " then
        local arg = line:sub(19):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_grab.steps(arg)
        if ok then return true, true, "ok camera.grab.steps " .. tostring(detail) end
        return true, false, "camera.grab.steps failed: " .. tostring(detail)
    end
    if line == "camera.grab.safety" or line:sub(1, 19) == "camera.grab.safety " then
        local arg = line:sub(20):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_grab.safety(arg)
        if ok then return true, true, "ok camera.grab.safety " .. tostring(detail) end
        return true, false, "camera.grab.safety failed: " .. tostring(detail)
    end
    if line:sub(1, 17) == "camera.grab.delta" then
        local arg = line:sub(18):match("^%s*(.-)%s*$") or ""
        if arg == "" then return true, false, "usage: camera.grab.delta <signed-number>" end
        local ok, detail = feature_grab.delta(arg)
        if ok then return true, true, "ok camera.grab.delta " .. tostring(detail) end
        return true, false, "camera.grab.delta failed: " .. tostring(detail)
    end
    if line:sub(1, 18) == "camera.grab.rotate" then
        local arg = line:sub(19):match("^%s*(.-)%s*$") or ""
        if arg == "" then return true, false, "usage: camera.grab.rotate <signed-number>" end
        local ok, detail = feature_grab.rotate(arg)
        if ok then return true, true, "ok camera.grab.rotate " .. tostring(detail) end
        return true, false, "camera.grab.rotate failed: " .. tostring(detail)
    end
    if line:sub(1, 17) == "camera.grab.scale" then
        local arg = line:sub(18):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_grab.scale_delta(arg ~= "" and arg or "1")
        if ok then return true, true, "ok camera.grab.scale " .. tostring(detail) end
        return true, false, "camera.grab.scale failed: " .. tostring(detail)
    end
    if line:sub(1, 16) == "camera.grab.lift" then
        local arg = line:sub(17):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_grab.lift(arg ~= "" and arg or "1")
        if ok then return true, true, "ok camera.grab.lift " .. tostring(detail) end
        return true, false, "camera.grab.lift failed: " .. tostring(detail)
    end
    if line:sub(1, 18) == "camera.grab.toggle" then
        local arg = line:sub(19):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_grab.toggle(arg ~= "" and arg or nil)
        if ok then return true, true, "ok camera.grab.toggle " .. tostring(detail) end
        return true, false, "camera.grab.toggle failed: " .. tostring(detail)
    end
    if line == "camera.grab.lastspawned" then
        local ok, detail = feature_grab.start_lastspawned()
        if ok then return true, true, "ok camera.grab.lastspawned " .. tostring(detail) end
        return true, false, "camera.grab.lastspawned failed: " .. tostring(detail)
    end
    if line == "camera.grab.item" then
        local ok, detail = feature_grab.toggle_item()
        if ok then return true, true, "ok camera.grab.item " .. tostring(detail) end
        return true, false, "camera.grab.item failed: " .. tostring(detail)
    end
    if line:sub(1, 17) == "camera.grab.start" then
        local arg = line:sub(18):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_grab.start(arg ~= "" and arg or nil)
        if ok then return true, true, "ok camera.grab.start " .. tostring(detail) end
        return true, false, "camera.grab.start failed: " .. tostring(detail)
    end
    if line:sub(1, 16) == "camera.grab.mode" then
        local arg = line:sub(17):match("^%s*(.-)%s*$") or ""
        if arg == "" then return true, false, "usage: camera.grab.mode <move|rot|z|scale>" end
        local ok, detail = feature_grab.mode(arg)
        if ok then return true, true, "ok camera.grab.mode " .. tostring(detail) end
        return true, false, "camera.grab.mode failed: " .. tostring(detail)
    end
    if line == "camera.lookat.item" then
        local ok, detail = feature_grab.lookat_item()
        if ok then return true, true, "ok camera.lookat.item " .. tostring(detail) end
        return true, false, "camera.lookat.item failed: " .. tostring(detail)
    end
    if line:sub(1, 13) == "camera.lookat" then
        local ok, detail = feature_grab.lookat()
        if ok then return true, true, "ok camera.lookat " .. tostring(detail) end
        return true, false, "camera.lookat failed: " .. tostring(detail)
    end
    if line == "camera.oculus.transform.inspect" then
        local ok, detail = feature_grab.lookat()
        if ok then return true, true, "ok camera.oculus.transform.inspect " .. tostring(detail) end
        return true, false, "camera.oculus.transform.inspect failed: " .. tostring(detail)
    end
    if line == "camera.oculus.clone" then
        local ok, detail = feature_oculus_clone.clone()
        if ok then return true, true, "ok camera.oculus.clone " .. tostring(detail) end
        return true, false, "camera.oculus.clone failed: " .. tostring(detail)
    end
    if line == "camera.oculus.duplicate" then
        local ok, detail = feature_oculus_duplicate.duplicate()
        if ok then return true, true, "ok camera.oculus.duplicate " .. tostring(detail) end
        return true, false, "camera.oculus.duplicate failed: " .. tostring(detail)
    end
    if line == "camera.oculus.transform.reload" or line:sub(1, 31) == "camera.oculus.transform.reload " then
        local arg = line:sub(32):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_transform.reload(arg)
        if ok then return true, true, "ok camera.oculus.transform.reload " .. tostring(detail) end
        return true, false, "camera.oculus.transform.reload failed: " .. tostring(detail)
    end
    if line == "camera.oculus.transform.apply" or line:sub(1, 30) == "camera.oculus.transform.apply " then
        local arg = line:sub(31):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_transform.apply(arg)
        if ok then return true, true, "ok camera.oculus.transform.apply " .. tostring(detail) end
        return true, false, "camera.oculus.transform.apply failed: " .. tostring(detail)
    end
    if line == "camera.destroy.lookat" then
        local ok, detail = feature_grab.destroy_lookat()
        if ok then return true, true, "ok camera.destroy.lookat " .. tostring(detail) end
        return true, false, "camera.destroy.lookat failed: " .. tostring(detail)
    end


    return false, nil, nil
end

return M
