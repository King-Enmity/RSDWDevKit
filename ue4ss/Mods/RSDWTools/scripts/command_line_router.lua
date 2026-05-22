-- Command-line router.
-- Supported commands:
--   tele <x> <y> <z>
--   tele.dir <left|right|forward|backward|up|down> [step]
--   player.loc
--   scan <name_part> [radius|all]
--   actor.goto <name>
--   actor.bring <name>
--   actor.del <name>
--   actor.vis <name> [on|off]         (no arg = toggle)
--   actor.col <name> [on|off]         (no arg = toggle)
--   actor.scale <name> [value]        (no value = report current uniform scale)
--   player.time <scale>               (CustomTimeDilation on pawn)
--   player.jump.count <int>           (JumpMaxCount on pawn)
--   player.jump.hold <sec>            (JumpMaxHoldTime on pawn)
--   player.buildings <on|off>         (Server_SetCanDamageBuildings)
--   player.invisible <on|off>         (HideCharacter(on, locker=pawn))
--   player.soulrift <on|off>          (Server_SetSoulRiftImmunity)
--   player.tp.delay <sec>             (TeleportLoadingScreenDelay)
--   player.tp.vfx <sec>               (TeleportBeginVFXDelay)
--   player.tp.timeout <sec>           (TeleportTimeout)
--   player.invincible <on|off>        (DamageComponent.SetCanTakeDamage(!on))
--   player.immortal <on|off>          (HealthComponent.SetCanDie(!on))
--   player.health <n>                 (HealthComponent.SetHealth(n, "rsdw.set"))
--   player.health.heal                (sets current to max)
--   player.health.damage <n>          (HealthComponent.DecreaseHealth(n, ...))
--   player.fall_immune <on|off>       (CharacterMovement.SetFallDamageImmune)
--   player.walkspeed <n>              (CharacterMovement.MaxWalkSpeed)
--   player.jumpvel <n>                (CharacterMovement.JumpZVelocity)
--   player.gravity <n>                (CharacterMovement.GravityScale)
--   player.aircontrol <n>             (CharacterMovement.AirControl)
--   player.speedmult <n>              (DominionMovementComponent.MovementSpeedMultiplier)
--   player.flyspeed <n>               (CharacterMovement.MaxFlySpeed)
--   player.acceleration <n>           (CharacterMovement.MaxAcceleration)
--   player.movemode <walk|fly|fall|custom|none>  (SetMovementMode)
--   player.noclip <on|off>            (bCheatFlying + SetActorEnableCollision + SetMovementMode)
--   player.hydration <n>              (HydrationComponent.CurrentHydration)
--   player.hydration.refill           (tops up to max)
--   player.sustenance <n>             (SustenanceComponent.CurrentSustenance)
--   player.sustenance.refill          (tops up to max)
--   player.endurance <n>              (EnduranceComponent.CurrentEndurance)
--   player.endurance.refill           (tops up to max)
--   player.toxicity <n>               (ToxicityComponent.CurrentToxicity)
--   player.toxicity.clear             (sets toxicity to 0)
--   player.stealth <on|off>           (PlayerStealthComponent.Multicast_EnterStealth/Exit)
--   player.stamina.refill             (StaminaComponent.DecreaseStamina(-max) + ResetRegen)
--   player.wakeup                     (PlayerRestComponent.Server_RequestWakeUp)
--   player.durabilityloss <on|off>    (ItemDurabilityComponent.DurabilityLossRate +
--                                      DamageComponent.DamagedByDurabilityMultiplier)
--   player.magnet <n>                 (ItemMagnet.MagnetRange)
--   player.fov <n>                    (PlayerController.FOV -> PlayerCameraManager.DefaultFOV)
--   player.silent <on|off>            (NoiseEmitter.* loudness fields -> 0)
--   player.surge <on|off>             (PlayerEvadeComponent.EnableSurge + SurgeEffectMaxUsages
--                                      + SurgeEffectDuration)
--   player.parrywindow <ms>           (PlayerBlockingComponent.ParryWindowLength)
--   player.blockangle <deg>           (PlayerBlockingComponent.BlockingAngle)
--   player.lockon <scale>             (scales LockOnTargetingComponent's 4 distance fields)
--   player.respawninvul <sec>         (PlayerDamageComponent.RespawnInvulnerabilityLength)
--   player.wellrested <sec>           (PlayerRestComponent.WellRestedDurationSeconds)
--   player.poise <on|off>             (HitReactionsComponent.*ForceThreshold -> 1e9)
--   player.perfectaim <on|off>        (PlayerRangedAttackComponent.{Base,Minimum}Inaccuracy -> 0)
--   player.ge.apply  <ClassName>      (UDominionGameplayEffectsComponent.InstantiateGameplayEffect +
--                                      ApplyGameplayEffect; caches the returned handle so a later
--                                      player.ge.remove hits the exact instance we spawned)
--   player.ge.remove <ClassName>      (BP_RemoveAllGameplayEffectsWithData + cached-handle fallback)
--   player.ge.toggle <ClassName> <on|off>  (thin wrapper around apply/remove)
--   player.ge.has    <ClassName>      (true|false using HasGameplayEffect on the cached handle)
--   player.ge.list                    (returns "N applied: A, B, ..." inline in the ack body;
--                                      diagnostic for reconciling UI state after a reload)
--   player.attr.set <ClassName> <value>  (Round 22: writes the live UDominionAttributesComponent
--                                         AttributeValues[i] / SharedAttributeValues[i] slot for
--                                         the matching UFloatAttribute subclass. New path
--                                         distinct from §5/§13/§17/§18/§23/§12 attempts.
--                                         Known broken: MaxCarryWeight (§26 -- cached threshold
--                                         on EncumbranceComponent, write lands but no recompute).)
--   player.attr.get <ClassName>          (Round 22: reads the same slot for diagnostics.)
--   player.mounts.unlockall [on|off]  (MountComponent.SetAllMountsUnlocked; no arg = unlock)
--   player.mount.invincible <on|off>  (MountComponent.bDamageForcesDismount + bIgnoreSurvivalDamage)
--   player.aimpitch <on|off>          (RangedAttack min/target pitch angles unlocked to -90)
--   player.arrowrange <cm>            (RangedAttack.MaxProjectileTraceDistance; clamp 1000..100000)
--   player.revivedelay <sec>          (PlayerRespawnComponent.SelfReviveDelay; clamp 2..60)
--   world.class.load <ClassPath>      (diagnostic: Kismet soft-class load without spawning)
--   world.spawn.safe <ClassPath>      (spawn first, fall back to native summon)
--   world.spawn.transform <ClassPath> {"loc":[x,y,z],"rot":[pitch,yaw,roll],"scale":[x,y,z]}
--   player.critchance (removed in 11.5; see cheats-to-revisit.md section 13)
--   player.foliagerange (removed in 11.5; see cheats-to-revisit.md section 14)
--   player.spell.cancel               (PlayerMagicComponent.Server_CancelSpell on both magic components)
--   actor.spectate <name>             (PlayerController.SetViewTargetWithBlend to named actor)
--   actor.spectate.reset              (SetViewTargetWithBlend back to the local pawn)
--   camera.debug.status               (diagnose stock Unreal DebugCamera state)
--   camera.debug.enable|disable|toggle
--   camera.debug.force_restore
--   camera.debug.speed <scale>
--   camera.rig.start [speed]
--   camera.rig.stop
--   camera.rig.capture <name>
--   camera.rig.pose.set <name> <x> <y> <z> <pitch> <yaw> <roll> <fov>
--   camera.rig.poses.file <filename>
--   camera.rig.delete <name>
--   camera.rig.clear
--   camera.rig.list
--   camera.rig.goto <name> [seconds]
--   camera.rig.goto.file <filename> <name> [seconds]
--   camera.rig.play <from> <to> [seconds]
--   camera.rig.play.file <filename>
--   camera.rig.fov <degrees>
--   camera.rig.lookat <actorName|off>
--   camera.oculus.status
--   camera.oculus.start|stop|toggle
--   camera.oculus.init
--   camera.oculus.help [on|off|toggle]
--   camera.oculus.umg <on|off|toggle>
--   camera.oculus.require <active|inactive|preview|repair>
--   camera.oculus.speed [<maxSpeed> [acceleration] [deceleration]]
--   camera.oculus.distance [<maxDistance> [falloffThreshold]]
--   camera.oculus.vignette <off|on> [duration] [r,g,b,a]
--   camera.oculus.watermark <off|on>
--   player.get <key>                  (reads one of: time, jump.count, jump.hold, buildings,
--                                                 tp.delay, tp.vfx, tp.timeout,
--                                                 health, maxhealth, walkspeed, jumpvel,
--                                                 gravity, aircontrol, speedmult,
--                                                 flyspeed, acceleration,
--                                                 hydration, sustenance, endurance, toxicity,
--                                                 stamina, maxstamina, stealth,
--                                                 durabilityloss, magnet,
--                                                 fov, silent, surge,
--                                                 parrywindow, blockangle, lockon,
--                                                 respawninvul, wellrested, poise,
--                                                 perfectaim)
--   dump.types                        (Round 29: invokes UE4SS GenerateLuaTypes()
--                                      to regenerate the EmmyLua type stubs under
--                                      <ue4ss>/Mods/shared/types/. Step 1 of the
--                                      static catalog pipeline; the WPF Catalog tab
--                                      then runs Generate-Catalog.ps1 to produce
--                                      ipc/catalog/catalog.jsonl. Replaces every
--                                      former player.dump.* probe verb.)
--   player.spells.unlock              (writes bNeedsUnlocking=false on every live
--                                      UUtilitySpellData in SelectedSpells AND inserts
--                                      each into pc.ProgressComponent.SpellsUnlocked TSet
--                                      -- the actual runtime gate the cast code reads.
--                                      on=unlock+TSet add, off=restore + TSet remove)
--   player.spells.zerocooldown        (writes CooldownDuration=0 on every live
--                                      UUtilitySpellData in SelectedSpells; on=zero all,
--                                      off=restore cached originals)
--   player.spells.continuouscast      (EXPERIMENTAL: flips bContinuouslyCast=true on
--                                      every UUtilitySpellData -- hypothesis is the
--                                      caster auto-recasts buffs like Tempest Shield /
--                                      Enchant Weapon. Behaviour on placement spells
--                                      may be chaotic. Off restores cached originals.)
--   world.time <hour>                 (DayNightCycleVarsSourceActor.ForcedDayTime overlay; visual only.
--                                      Round 25: StoredTime no longer written here -- see world.storedtime.)
--   world.time.release                (clear ForcedDayTime override on all DayNight actors)
--   world.time.probe                  (read-only dump : InGameTimeActor + DayNight actors + IsDayOrNight)
--   world.time.pause <on|off>         (AInGameTimeActor.bIsTimePaused)
--   world.time.speed <minutes>        (AInGameTimeActor.RealTimeMinutesPerInGameDay)
--   world.dawn <hour>                 (AInGameTimeActor.TimeOfDawn; vanilla 4.5)
--   world.dusk <hour>                 (AInGameTimeActor.TimeOfDusk; vanilla 22)
--   world.storedtime <hour>           (Round 25 EXPERIMENTAL: writes the persistent
--                                      AInGameTimeActor.StoredTime accumulator. Preserves
--                                      day counter (recomputes today's day floor + offsets
--                                      by hour). Round 22 disabled this path on the safe
--                                      slider due to corruption risk on bigger jumps.)
--   world.weather <type>              (WeatherSubsystem.TrySetWeather; 0-8 or name)
--   world.weather.pause <on|off>      (WeatherSubsystem.PauseWeather)
--   world.weather.probe               (read-only dump : subsystem + RegionSpecific actors + RegionalWeather)
--   world.weather.where               (WeatherSubsystem.GetWeatherAtLocation at player)
--   world.weather.list                (enumerate every accepted EWeatherType value + alias ; pipe-delimited)
--   world.weather.regional <type>     (RAW : write WeatherType on every UDynamicRegionalWeather +
--                                      UStaticRegionalWeather. Bypasses TrySetWeather to test if
--                                      regional state is overriding it. Fires OnRep_WeatherType.)
--   world.weather.region_priority <n> (RAW : write Priority on every ARegionSpecificGlobalWeatherActor.
--                                      Higher wins when overlapping ; useful to test biome routing.)
--   world.progress.probe              (locate AWorldProgressManager and count defeated boss flags)
--   world.progress.has <InternalName>       (membership check for boss defeated flag)
--   world.progress.defeat <InternalName>    (SaveGame TSet<FString>, e.g. ai_boss_velgar)
--   world.progress.undefeat <InternalName>  (remove that boss flag again)
--   world.progress.value.list               (known TaggedWorldProgressValues aliases)
--   world.progress.value.get <Alias>        (GetWorldProgressValue for known aliases)
--   world.progress.value.set <Alias> <Num>  (SetWorldProgressValue for known aliases)
--   world.progress.hook.has <AssetPath>     (UWorldHook triggered membership check)
--   world.progress.hook.probe <AssetPath>   (UWorldHook state diagnostics)
--   world.progress.hook.trigger <AssetPath> (EXPERIMENTAL UWorldHook trigger)
--   world.progress.hook.fire <AssetPath>    (EXPERIMENTAL direct OnTriggered call)
--   world.progress.hook.mark <AssetPath>    (directly add to WorldHooksTriggered)
--   world.progress.hook.reset <AssetPath>   (safe direct remove from WorldHooksTriggered)
--   world.resource.probe [reachSpec]        (placed UResourceRespawnComponent SaveGame state)
--   world.resource.set [reachSpec] <amount> (SetResourceAmount on placed resource)
--   world.resource.pause [reachSpec] <on|off>
--   world.resource.take [reachSpec]         (TakeResource on placed resource)
--   world.chest.probe [reachSpec]           (placed AWorldChest SaveGame state)
--   world.chest.state [reachSpec] <state>   (unopened|opened|emptied|0|1|2)
--   world.chest.respawn_disabled [reachSpec] <on|off>
--   world.spud.persist <reachSpec> <stableName>  (EXPERIMENTAL AddPersistentGlobalObjectWithName)
--   world.spud.unpersist <reachSpec>             (EXPERIMENTAL RemovePersistentGlobalObject)
--
-- Round 26 round A -- Generic uniform-schema write verbs. See
-- docs/MODS_CATALOG_METHODOLOGY.md section 5. These four verbs back every
-- editable row produced by the new uniform JSON catalog, replacing the
-- per-category writers (player.attr.set / player.comp.set) over time.
--   player.field.set        <pawn|world> <path> <value>
--   player.field.set_index  <pawn|world> <containerPath> <index> <value>
--   player.field.set_key    <pawn|world> <containerPath> <key>   <value>
--   player.field.call       <pawn|world> <path> [args...]
-- REMOVED (see NOTES/cheats-to-revisit.md):
--   player.damageable, player.ai.attacks, player.ai.movement
--   player.fly, player.ghost, player.walk
--   player.revive, player.health.max
--   player.swimspeed, player.movemode swim
--   player.interact (InteractionRanges is a TMap<enum,float> we can't edit cleanly)
--   player.potion.slots (MaxPotionSlots write round-trips but consume-potion
--                        overwrites the single active slot rather than appending;
--                        would need BP-level changes to actually expand the belt)
--   player.instantdraw (PreChargeUpDuration / ChargeUpDuration write cleanly but
--                       damage-vs-draw-time curve lives on the per-weapon
--                       PlayerRangedAttackData asset, not the component)
--   player.castmoving  (bShouldBlockMovement write cleanly but spell-cast montages
--                       carry Root Motion Enabled on the anim asset itself, which
--                       overrides the component flag)
--   player.alwayssprint, player.envimmunity, player.meleeassist, player.inputbuffer
--                      (round 8 component-field cheats; all four removed after writes
--                       landed but behaviour didn't change -- see cheats-to-revisit.md §11.
--                       Re-attempt via the GE system, not component fields.)
--   player.unlock.corruptionshot (round 11; bCorruptionShotUnlockedSimProxy
--                                 write didn't survive server replication.
--                                 See cheats-to-revisit.md §16.)
-- Round 12 rolled back entirely (see NOTES/cheats-to-revisit.md §16):
--   player.spells.nomagiccost, player.spells.noutilcd, player.spells.unlockall
--   dev.* (UDominionCheatManager dom* wrappers -- every one was a no-op in
--          the shipping build; cheat-manager method bodies are stripped).
--   ui.tab <player|teleport|scan|settings>  (legacy "home" accepted as alias of player)

local feature_teleport = require("feature_teleport")
local feature_umg = require("feature_umg")
local feature_scan = require("feature_scan")
local feature_actor = require("feature_actor")
local feature_player = require("feature_player")
local feature_field  = require("feature_field")
local feature_probe  = require("feature_probe")
local feature_introspect = require("feature_introspect")
local feature_grab = require("feature_grab")
local feature_camera = require("feature_camera")
local feature_oculus = require("feature_oculus")
local feature_oculus_config = require("feature_oculus_config")

-- Round 30: when true the probe.* verbs print failure detail to the
-- UE4SS console (in addition to the ack going back to the WPF). Useful
-- for chasing "why is this chip not live" without having to hover the
-- WPF chip's tooltip. Set to false once the resolver is stable.
RSDWTOOLS_PROBE_DEBUG = true

-- Categorise a probe failure body so the console only logs the
-- interesting ones. "Expected" failures are the normal cost of probing
-- every static reach candidate against a partially-loaded world: a
-- subsystem that isn't installed in this game, a controller field that's
-- nil before login, a pawn the player doesn't own. They still surface as
-- NotLive on the WPF chip ; we just don't spam the UE4SS console with them.
local PROBE_NOISE_PATTERNS = {
    "not currently live",
    "no live instance",
    "no live instance of",
    "FindAllOf failed",
}
local function probe_failure_is_noise(body)
    if type(body) ~= "string" then return false end
    for _, p in ipairs(PROBE_NOISE_PATTERNS) do
        if body:find(p, 1, true) then return true end
    end
    return false
end
local feature_ge = require("feature_ge")
local feature_ui = require("feature_ui")
local feature_world = require("feature_world")
local feature_progress = require("feature_progress")
local feature_spud = require("feature_spud")
local feature_persistence = require("feature_persistence")
local feature_foliage = require("feature_foliage")
local feature_foreach = require("feature_foreach")
local feature_buildings = require("feature_buildings")
local feature_build_preview = require("feature_build_preview")
local feature_world_settings = require("feature_world_settings")
local feature_assets = require("feature_assets")
local feature_inventory = require("feature_inventory")
local feature_skills = require("feature_skills")
local feature_debug_hud = require("feature_debug_hud")
local feature_debug_watch = require("feature_debug_watch")
local feature_net = require("feature_net")
local feature_cvars = require("feature_cvars")

local M = {}

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ---------- envelope parsing ----------
--
-- Optional command prefix : "@@key=val[,key=val]* <rest>". The router
-- strips the envelope, stashes its keys as a dispatch context on
-- feature_net for the duration of the call, then dispatches the
-- remainder exactly as before. The envelope is invisible to every
-- existing verb. Verbs that opt into multiplayer targeting call
local function parse_tele(line)
    local x, y, z = line:match("^tele%s+([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)%s*$")
    if not x then
        return nil, "usage: tele <x> <y> <z>"
    end
    local xn, yn, zn = tonumber(x), tonumber(y), tonumber(z)
    if not xn or not yn or not zn then
        return nil, "tele args must be numbers"
    end
    return xn, yn, zn
end

local function parse_scan(line)
    local body = line:match("^scan%s+(.+)$")
    if not body then
        return nil, nil, "usage: scan <name_part> [radius|all]"
    end
    local query, mode = body:match("^([^%s]+)%s*(.-)%s*$")
    if not query or query == "" then
        return nil, nil, "usage: scan <name_part> [radius|all]"
    end
    return query, mode or "", nil
end

local VALID_DIRECTIONS = {
    left = true, right = true, forward = true, backward = true, up = true, down = true,
}

-- Splits the remainder of an actor.* command into { name, optional_tail }.
-- Scan emits names via GetName() which has no spaces, so we can safely split
-- on whitespace: the first token is the actor name; anything after (if
-- present) is the optional parameter (on|off|<scale_value>).
local function split_actor_body(line, verb_len)
    local rest = line:sub(verb_len + 1)
    rest = (tostring(rest or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    if rest == "" then
        return nil, nil
    end
    local name, tail = rest:match("^(%S+)%s+(.+)$")
    if name then
        return name, tail
    end
    return rest, nil
end

local function parse_tele_dir(line)
    local dir, rest = line:match("^tele%.dir%s+([%w]+)%s*(.-)%s*$")
    if not dir or dir == "" then
        return nil, nil, "usage: tele.dir <left|right|forward|backward|up|down> [step]"
    end
    dir = string.lower(dir)
    if not VALID_DIRECTIONS[dir] then
        return nil, nil, "tele.dir direction must be left|right|forward|backward|up|down"
    end
    local step = nil
    if rest and rest ~= "" then
        step = tonumber(rest)
        if not step then
            return nil, nil, "tele.dir step must be a number"
        end
    end
    return dir, step, nil
end

function M.handle_line(raw_line)
    local line = trim(raw_line)
    if line == "" then
        return false, "empty command"
    end

    local ok, ok_cmd, msg = pcall(function() return M._dispatch(line) end)
    if not ok then
        return false, "router error : " .. tostring(ok_cmd)
    end
    return ok_cmd, msg
end

function M._dispatch(line)
    -- Check compound verbs before their prefixes.
    if line:sub(1, 8) == "tele.dir" then
        local dir, step, perr = parse_tele_dir(line)
        if not dir then
            return false, perr
        end
        local ok, result = feature_teleport.apply_directional(dir, step)
        if ok then
            return true, "ok tele.dir " .. dir .. " " .. tostring(result or "")
        end
        return false, "tele.dir failed: " .. tostring(result)
    end

    if line == "player.loc" or line:sub(1, 11) == "player.loc " then
        local ok, result = feature_teleport.report_current_location()
        if ok then
            -- Plain coordinate ack so the WPF side can parse it with one split.
            return true, tostring(result)
        end
        return false, "player.loc failed: " .. tostring(result)
    end

    -- Round 51: transient on-screen toast. Wire format
    --   umg <duration_seconds> <message...>
    -- Duration is parsed as a number (decimal allowed) ; the remainder
    -- of the line, verbatim including spaces, is the toast text.
    -- Re-firing while a toast is up replaces text + restarts timer.
    if line == "umg" or line:sub(1, 4) == "umg " then
        local rest = line:sub(5)
        local dur_str, text = rest:match("^%s*(%S+)%s+(.+)$")
        if not dur_str then
            return false, "umg requires <duration_seconds> <message>"
        end
        local dur = tonumber(dur_str)
        if not dur then
            return false, "umg duration must be a number ; got '" .. dur_str .. "'"
        end
        feature_umg.toast(text, dur)
        return true, "ok umg " .. dur_str
    end

    -- Round 30: probe.* verbs live at the top level (NOT inside the
    -- player.* prefix block) because their reachSpec arg may target any
    -- engine-level root, not just the local pawn.
    --
    --   probe.resolve <reachSpec>
    --     Returns the concrete short class name of the live UObject the
    --     reachSpec resolves to. Used by the WPF Catalog tab to populate
    --     its Live targets chip strip and decide which static reach
    --     candidates are currently instantiated.
    --
    --   probe.read <reachSpec> <fieldPath>
    --     Returns the live value at the given field as a flat ack body
    --     (bool / number / string / "<obj:Class>"). Used by the WPF row
    --     editors to prefill themselves with the current in-game value.
    --
    -- Both verbs print failure detail to the UE4SS console when the
    -- module-level RSDWTOOLS_PROBE_DEBUG flag is true (default true while
    -- we're stabilizing the resolver ; flip off later to quiet logs).
    if line:sub(1, 14) == "probe.resolve " then
        local ok, detail = feature_probe.resolve(line:sub(15))
        if ok then return true, "ok probe.resolve " .. tostring(detail) end
        if RSDWTOOLS_PROBE_DEBUG and not probe_failure_is_noise(detail) then
            print("[RSDWTools][probe.resolve] " .. line:sub(15) .. " -> " .. tostring(detail))
        end
        return false, "probe.resolve failed: " .. tostring(detail)
    end
    if line:sub(1, 11) == "probe.read " then
        local ok, detail = feature_probe.read(line:sub(12))
        if ok then return true, "ok probe.read " .. tostring(detail) end
        if RSDWTOOLS_PROBE_DEBUG and not probe_failure_is_noise(detail) then
            print("[RSDWTools][probe.read] " .. line:sub(12) .. " -> " .. tostring(detail))
        end
        return false, "probe.read failed: " .. tostring(detail)
    end
    if line:sub(1, 17) == "probe.find_class " then
        local ok, detail = feature_probe.find_class(line:sub(18))
        if ok then return true, "ok probe.find_class " .. tostring(detail) end
        if RSDWTOOLS_PROBE_DEBUG and not probe_failure_is_noise(detail) then
            print("[RSDWTools][probe.find_class] " .. line:sub(18) .. " -> " .. tostring(detail))
        end
        return false, "probe.find_class failed: " .. tostring(detail)
    end

    -- probe.widget.spawn / .remove / .list
    --   Construct a UserWidget directly from its blueprint class and
    --   push it to the viewport. Lets us test whether dev menu pages
    --   (and any other catalog-surfaced widget) render in shipping
    --   builds independent of their normal input gating. See
    --   feature_probe.widget_* for the actual logic.
    if line:sub(1, 19) == "probe.widget.spawn " then
        local ok, detail = feature_probe.widget_spawn(line:sub(20))
        if ok then return true, "ok probe.widget.spawn " .. tostring(detail) end
        return false, "probe.widget.spawn failed: " .. tostring(detail)
    end
    if line == "probe.widget.remove" or line:sub(1, 20) == "probe.widget.remove " then
        local ok, detail = feature_probe.widget_remove(line:sub(21))
        if ok then return true, "ok probe.widget.remove " .. tostring(detail) end
        return false, "probe.widget.remove failed: " .. tostring(detail)
    end
    if line == "probe.widget.list" then
        local ok, detail = feature_probe.widget_list("")
        if ok then return true, "ok probe.widget.list " .. tostring(detail) end
        return false, "probe.widget.list failed: " .. tostring(detail)
    end

    -- player.* cheat / read verbs. Grouped under one prefix check so every
    -- new one lives right here (not scattered around the file) and so we
    -- don't have to touch main dispatch each time a verb is added. Each
    -- verb pulls its single argument off the line via a fixed offset that
    -- matches its string length; the offset constant lives next to the
    -- call site so refactoring a verb name only changes two adjacent
    -- numbers in one block.
    if line:sub(1, 7) == "player." then
        local function arg_after(verb)
            local rest = line:sub(#verb + 1)
            return (tostring(rest or ""):gsub("^%s+", ""):gsub("%s+$", ""))
        end

        -- Movement
        if line:sub(1, 11) == "player.time" then
            local ok, detail = feature_player.set_time_dilation(arg_after("player.time"))
            if ok then return true, "ok player.time " .. tostring(detail) end
            return false, "player.time failed: " .. tostring(detail)
        end
        if line:sub(1, 17) == "player.jump.count" then
            local ok, detail = feature_player.set_jump_count(arg_after("player.jump.count"))
            if ok then return true, "ok player.jump.count " .. tostring(detail) end
            return false, "player.jump.count failed: " .. tostring(detail)
        end
        if line:sub(1, 16) == "player.jump.hold" then
            local ok, detail = feature_player.set_jump_hold(arg_after("player.jump.hold"))
            if ok then return true, "ok player.jump.hold " .. tostring(detail) end
            return false, "player.jump.hold failed: " .. tostring(detail)
        end

        -- Combat
        if line:sub(1, 16) == "player.buildings" then
            local ok, detail = feature_player.set_can_damage_buildings(arg_after("player.buildings"))
            if ok then return true, "ok player.buildings " .. tostring(detail) end
            return false, "player.buildings failed: " .. tostring(detail)
        end
        if line:sub(1, 16) == "player.invisible" then
            local ok, detail = feature_player.set_invisible(arg_after("player.invisible"))
            if ok then return true, "ok player.invisible " .. tostring(detail) end
            return false, "player.invisible failed: " .. tostring(detail)
        end
        if line:sub(1, 15) == "player.soulrift" then
            local ok, detail = feature_player.set_soul_rift_immunity(arg_after("player.soulrift"))
            if ok then return true, "ok player.soulrift " .. tostring(detail) end
            return false, "player.soulrift failed: " .. tostring(detail)
        end

        -- Vitals (component-backed cheats)
        if line:sub(1, 17) == "player.invincible" then
            local ok, detail = feature_player.set_invincible(arg_after("player.invincible"))
            if ok then return true, "ok player.invincible " .. tostring(detail) end
            return false, "player.invincible failed: " .. tostring(detail)
        end
        if line:sub(1, 15) == "player.immortal" then
            local ok, detail = feature_player.set_immortal(arg_after("player.immortal"))
            if ok then return true, "ok player.immortal " .. tostring(detail) end
            return false, "player.immortal failed: " .. tostring(detail)
        end
        -- health.heal / health.damage MUST be checked before player.health
        -- (the shorter prefix would otherwise eat the compound verbs and
        -- send their numeric tail as the new "current health").
        -- NOTE: player.health.max and player.revive removed 2026-04-17 --
        -- see NOTES/cheats-to-revisit.md sections 4 and 5.
        if line == "player.health.heal" or line:sub(1, 19) == "player.health.heal " then
            local ok, detail = feature_player.heal_full()
            if ok then return true, "ok player.health.heal " .. tostring(detail) end
            return false, "player.health.heal failed: " .. tostring(detail)
        end
        if line:sub(1, 20) == "player.health.damage" then
            local ok, detail = feature_player.damage_self(arg_after("player.health.damage"))
            if ok then return true, "ok player.health.damage " .. tostring(detail) end
            return false, "player.health.damage failed: " .. tostring(detail)
        end
        if line:sub(1, 13) == "player.health" then
            local ok, detail = feature_player.set_health(arg_after("player.health"))
            if ok then return true, "ok player.health " .. tostring(detail) end
            return false, "player.health failed: " .. tostring(detail)
        end

        -- Movement (component-backed)
        if line:sub(1, 18) == "player.fall_immune" then
            local ok, detail = feature_player.set_fall_immune(arg_after("player.fall_immune"))
            if ok then return true, "ok player.fall_immune " .. tostring(detail) end
            return false, "player.fall_immune failed: " .. tostring(detail)
        end
        if line:sub(1, 16) == "player.walkspeed" then
            local ok, detail = feature_player.set_walkspeed(arg_after("player.walkspeed"))
            if ok then return true, "ok player.walkspeed " .. tostring(detail) end
            return false, "player.walkspeed failed: " .. tostring(detail)
        end
        if line:sub(1, 14) == "player.jumpvel" then
            local ok, detail = feature_player.set_jumpvel(arg_after("player.jumpvel"))
            if ok then return true, "ok player.jumpvel " .. tostring(detail) end
            return false, "player.jumpvel failed: " .. tostring(detail)
        end
        if line:sub(1, 14) == "player.gravity" then
            local ok, detail = feature_player.set_gravity(arg_after("player.gravity"))
            if ok then return true, "ok player.gravity " .. tostring(detail) end
            return false, "player.gravity failed: " .. tostring(detail)
        end
        if line:sub(1, 17) == "player.aircontrol" then
            local ok, detail = feature_player.set_air_control(arg_after("player.aircontrol"))
            if ok then return true, "ok player.aircontrol " .. tostring(detail) end
            return false, "player.aircontrol failed: " .. tostring(detail)
        end
        if line:sub(1, 16) == "player.speedmult" then
            local ok, detail = feature_player.set_speed_mult(arg_after("player.speedmult"))
            if ok then return true, "ok player.speedmult " .. tostring(detail) end
            return false, "player.speedmult failed: " .. tostring(detail)
        end
        if line:sub(1, 15) == "player.movemode" then
            local ok, detail = feature_player.set_movement_mode(arg_after("player.movemode"))
            if ok then return true, "ok player.movemode " .. tostring(detail) end
            return false, "player.movemode failed: " .. tostring(detail)
        end
        if line:sub(1, 13) == "player.noclip" then
            local ok, detail = feature_player.set_noclip(arg_after("player.noclip"))
            if ok then return true, "ok player.noclip " .. tostring(detail) end
            return false, "player.noclip failed: " .. tostring(detail)
        end
        if line:sub(1, 15) == "player.flyspeed" then
            local ok, detail = feature_player.set_flyspeed(arg_after("player.flyspeed"))
            if ok then return true, "ok player.flyspeed " .. tostring(detail) end
            return false, "player.flyspeed failed: " .. tostring(detail)
        end
        -- player.swimspeed removed in round 5 -- see cheats-to-revisit.md §6.
        if line:sub(1, 19) == "player.acceleration" then
            local ok, detail = feature_player.set_acceleration(arg_after("player.acceleration"))
            if ok then return true, "ok player.acceleration " .. tostring(detail) end
            return false, "player.acceleration failed: " .. tostring(detail)
        end

        -- Survival stats. The .refill / .clear compound verbs MUST be
        -- checked before their short form so the shorter prefix doesn't
        -- swallow them (same pattern as health.heal vs health).
        if line == "player.hydration.refill" or line:sub(1, 24) == "player.hydration.refill " then
            local ok, detail = feature_player.refill_hydration()
            if ok then return true, "ok player.hydration.refill " .. tostring(detail) end
            return false, "player.hydration.refill failed: " .. tostring(detail)
        end
        -- Round 15: DecayBuffer per stat (must come before the generic
        -- player.hydration prefix or it'll swallow this).
        if line:sub(1, 28) == "player.hydration.decaybuffer" then
            local ok, detail = feature_player.set_hydration_decaybuffer(arg_after("player.hydration.decaybuffer"))
            if ok then return true, "ok player.hydration.decaybuffer " .. tostring(detail) end
            return false, "player.hydration.decaybuffer failed: " .. tostring(detail)
        end
        if line:sub(1, 16) == "player.hydration" then
            local ok, detail = feature_player.set_hydration(arg_after("player.hydration"))
            if ok then return true, "ok player.hydration " .. tostring(detail) end
            return false, "player.hydration failed: " .. tostring(detail)
        end
        if line == "player.sustenance.refill" or line:sub(1, 25) == "player.sustenance.refill " then
            local ok, detail = feature_player.refill_sustenance()
            if ok then return true, "ok player.sustenance.refill " .. tostring(detail) end
            return false, "player.sustenance.refill failed: " .. tostring(detail)
        end
        if line:sub(1, 29) == "player.sustenance.decaybuffer" then
            local ok, detail = feature_player.set_sustenance_decaybuffer(arg_after("player.sustenance.decaybuffer"))
            if ok then return true, "ok player.sustenance.decaybuffer " .. tostring(detail) end
            return false, "player.sustenance.decaybuffer failed: " .. tostring(detail)
        end
        if line:sub(1, 17) == "player.sustenance" then
            local ok, detail = feature_player.set_sustenance(arg_after("player.sustenance"))
            if ok then return true, "ok player.sustenance " .. tostring(detail) end
            return false, "player.sustenance failed: " .. tostring(detail)
        end
        if line == "player.endurance.refill" or line:sub(1, 24) == "player.endurance.refill " then
            local ok, detail = feature_player.refill_endurance()
            if ok then return true, "ok player.endurance.refill " .. tostring(detail) end
            return false, "player.endurance.refill failed: " .. tostring(detail)
        end
        if line:sub(1, 28) == "player.endurance.decaybuffer" then
            local ok, detail = feature_player.set_endurance_decaybuffer(arg_after("player.endurance.decaybuffer"))
            if ok then return true, "ok player.endurance.decaybuffer " .. tostring(detail) end
            return false, "player.endurance.decaybuffer failed: " .. tostring(detail)
        end
        if line:sub(1, 16) == "player.endurance" then
            local ok, detail = feature_player.set_endurance(arg_after("player.endurance"))
            if ok then return true, "ok player.endurance " .. tostring(detail) end
            return false, "player.endurance failed: " .. tostring(detail)
        end
        if line == "player.toxicity.clear" or line:sub(1, 22) == "player.toxicity.clear " then
            local ok, detail = feature_player.clear_toxicity()
            if ok then return true, "ok player.toxicity.clear " .. tostring(detail) end
            return false, "player.toxicity.clear failed: " .. tostring(detail)
        end
        if line:sub(1, 15) == "player.toxicity" then
            local ok, detail = feature_player.set_toxicity(arg_after("player.toxicity"))
            if ok then return true, "ok player.toxicity " .. tostring(detail) end
            return false, "player.toxicity failed: " .. tostring(detail)
        end

        -- Stealth / Stamina / Sleep (one-shot or toggle verbs, no numeric arg).
        if line:sub(1, 14) == "player.stealth" then
            local ok, detail = feature_player.set_stealth(arg_after("player.stealth"))
            if ok then return true, "ok player.stealth " .. tostring(detail) end
            return false, "player.stealth failed: " .. tostring(detail)
        end
        if line == "player.stamina.refill" or line:sub(1, 22) == "player.stamina.refill " then
            local ok, detail = feature_player.refill_stamina()
            if ok then return true, "ok player.stamina.refill " .. tostring(detail) end
            return false, "player.stamina.refill failed: " .. tostring(detail)
        end
        if line == "player.wakeup" or line:sub(1, 14) == "player.wakeup " then
            local ok, detail = feature_player.wake_up()
            if ok then return true, "ok player.wakeup " .. tostring(detail) end
            return false, "player.wakeup failed: " .. tostring(detail)
        end

        -- Round 5: Items / Interaction / Camera / Stealth / Evade.
        --
        -- Compound-verb ordering rule still applies: longer prefix first.
        -- The only compound-risk ones here are the .* family for camera
        -- (player.fov has no sub-verbs so the bare prefix check is fine).
        if line:sub(1, 21) == "player.durabilityloss" then
            local ok, detail = feature_player.set_no_durability_loss(arg_after("player.durabilityloss"))
            if ok then return true, "ok player.durabilityloss " .. tostring(detail) end
            return false, "player.durabilityloss failed: " .. tostring(detail)
        end
        if line:sub(1, 13) == "player.magnet" then
            local ok, detail = feature_player.set_magnet_range(arg_after("player.magnet"))
            if ok then return true, "ok player.magnet " .. tostring(detail) end
            return false, "player.magnet failed: " .. tostring(detail)
        end
        if line:sub(1, 10) == "player.fov" then
            local ok, detail = feature_player.set_fov(arg_after("player.fov"))
            if ok then return true, "ok player.fov " .. tostring(detail) end
            return false, "player.fov failed: " .. tostring(detail)
        end
        -- Phase 2: Camera + UI tabs. Generic component field setter
        -- handles any UCameraComponent / USpringArmComponent / PC / HUD
        -- field by alias. The Lua resolver also accepts PC, HUD, and
        -- CameraManager as special root tokens.
        --   player.comp.set <Alias> <Field> <value>      (16)
        --   player.comp.get <Alias> <Field>              (16)
        if line:sub(1, 16) == "player.comp.set " then
            local ok, detail = feature_player.comp_set(line:sub(17))
            if ok then return true, "ok player.comp.set " .. tostring(detail) end
            return false, "player.comp.set failed: " .. tostring(detail)
        end
        if line:sub(1, 16) == "player.comp.get " then
            local ok, detail = feature_player.comp_get(line:sub(17))
            if ok then return true, tostring(detail) end
            return false, "player.comp.get failed: " .. tostring(detail)
        end
        -- Round 26 round A: generic uniform-schema write verbs. Methodology
        -- doc `docs/MODS_CATALOG_METHODOLOGY.md` section 5. Eight verbs cover
        -- every Mods-tab category by walking dot-paths against either the
        -- local pawn (`pawn`) or a world subsystem/actor (`world`).
        --   player.field.set         <root> <path> <value>           (17)
        --   player.field.set_index   <root> <ctnrPath> <idx> <value> (23)
        --   player.field.set_key     <root> <ctnrPath> <key> <value> (21)
        --   player.field.set_object  <root> <path> <ClassName>       (24)  -- round 27
        --   player.field.add         <root> <ctnrPath> <value>       (17)  -- round 27
        --   player.field.remove      <root> <ctnrPath> <idxOrValue>  (20)  -- round 27
        --   player.field.clear       <root> <ctnrPath>               (19)  -- round 27
        --   player.field.call        <root> <path> [args...]         (18)
        -- Each branch checks an exact-length prefix string, so prefix
        -- shadowing is handled per-branch (no longest-first requirement).
        if line:sub(1, 24) == "player.field.set_object " then
            local ok, detail = feature_field.set_object(line:sub(25))
            if ok then return true, "ok player.field.set_object " .. tostring(detail) end
            return false, "player.field.set_object failed: " .. tostring(detail)
        end
        if line:sub(1, 23) == "player.field.set_asset " then
            local ok, detail = feature_field.set_asset(line:sub(24))
            if ok then return true, "ok player.field.set_asset " .. tostring(detail) end
            return false, "player.field.set_asset failed: " .. tostring(detail)
        end
        if line:sub(1, 23) == "player.field.set_index " then
            local ok, detail = feature_field.set_index(line:sub(24))
            if ok then return true, "ok player.field.set_index " .. tostring(detail) end
            return false, "player.field.set_index failed: " .. tostring(detail)
        end
        if line:sub(1, 21) == "player.field.set_key " then
            local ok, detail = feature_field.set_key(line:sub(22))
            if ok then return true, "ok player.field.set_key " .. tostring(detail) end
            return false, "player.field.set_key failed: " .. tostring(detail)
        end
        if line:sub(1, 20) == "player.field.remove " then
            local ok, detail = feature_field.remove(line:sub(21))
            if ok then return true, "ok player.field.remove " .. tostring(detail) end
            return false, "player.field.remove failed: " .. tostring(detail)
        end
        if line:sub(1, 19) == "player.field.clear " then
            local ok, detail = feature_field.clear(line:sub(20))
            if ok then return true, "ok player.field.clear " .. tostring(detail) end
            return false, "player.field.clear failed: " .. tostring(detail)
        end
        if line:sub(1, 18) == "player.field.call " then
            local ok, detail = feature_field.call(line:sub(19))
            if ok then return true, "ok player.field.call " .. tostring(detail) end
            return false, "player.field.call failed: " .. tostring(detail)
        end
        if line:sub(1, 17) == "player.field.set " then
            local ok, detail = feature_field.set(line:sub(18))
            if ok then return true, "ok player.field.set " .. tostring(detail) end
            return false, "player.field.set failed: " .. tostring(detail)
        end
        if line:sub(1, 17) == "player.field.add " then
            local ok, detail = feature_field.add(line:sub(18))
            if ok then return true, "ok player.field.add " .. tostring(detail) end
            return false, "player.field.add failed: " .. tostring(detail)
        end
        if line:sub(1, 13) == "player.silent" then
            local ok, detail = feature_player.set_silent(arg_after("player.silent"))
            if ok then return true, "ok player.silent " .. tostring(detail) end
            return false, "player.silent failed: " .. tostring(detail)
        end
        if line:sub(1, 12) == "player.surge" then
            local ok, detail = feature_player.set_surge(arg_after("player.surge"))
            if ok then return true, "ok player.surge " .. tostring(detail) end
            return false, "player.surge failed: " .. tostring(detail)
        end

        -- Round 6: Combat (parry / block) + Targeting (lock-on range).
        -- Note: "player.parrywindow" must be checked before any shorter
        -- "player.p*" prefix would be added in future, and "player.blockangle"
        -- likewise. The current ordering is safe; keep in mind if expanding.
        if line:sub(1, 18) == "player.parrywindow" then
            local ok, detail = feature_player.set_parry_window(arg_after("player.parrywindow"))
            if ok then return true, "ok player.parrywindow " .. tostring(detail) end
            return false, "player.parrywindow failed: " .. tostring(detail)
        end
        if line:sub(1, 17) == "player.blockangle" then
            local ok, detail = feature_player.set_block_angle(arg_after("player.blockangle"))
            if ok then return true, "ok player.blockangle " .. tostring(detail) end
            return false, "player.blockangle failed: " .. tostring(detail)
        end
        if line:sub(1, 13) == "player.lockon" then
            local ok, detail = feature_player.set_lockon_scale(arg_after("player.lockon"))
            if ok then return true, "ok player.lockon " .. tostring(detail) end
            return false, "player.lockon failed: " .. tostring(detail)
        end

        -- Round 7: Vitals / Survival sliders + Combat / Ranged / Magic toggles.
        -- Ordering: "player.respawninvul" must precede any future "player.respawn"
        -- prefix match; "player.wellrested" is unique already; the toggles are
        -- all unique prefixes.
        if line:sub(1, 19) == "player.respawninvul" then
            local ok, detail = feature_player.set_respawn_invul(arg_after("player.respawninvul"))
            if ok then return true, "ok player.respawninvul " .. tostring(detail) end
            return false, "player.respawninvul failed: " .. tostring(detail)
        end
        if line:sub(1, 17) == "player.wellrested" then
            local ok, detail = feature_player.set_well_rested(arg_after("player.wellrested"))
            if ok then return true, "ok player.wellrested " .. tostring(detail) end
            return false, "player.wellrested failed: " .. tostring(detail)
        end
        if line:sub(1, 12) == "player.poise" then
            local ok, detail = feature_player.set_poise(arg_after("player.poise"))
            if ok then return true, "ok player.poise " .. tostring(detail) end
            return false, "player.poise failed: " .. tostring(detail)
        end
        if line:sub(1, 17) == "player.perfectaim" then
            local ok, detail = feature_player.set_perfect_aim(arg_after("player.perfectaim"))
            if ok then return true, "ok player.perfectaim " .. tostring(detail) end
            return false, "player.perfectaim failed: " .. tostring(detail)
        end

        -- Round 9: Gameplay-Effect apply/remove/toggle/has. One verb family
        -- covers every attribute-driven cheat (Max Health, resistances,
        -- stamina regen, damage multipliers, XP boosters, etc.) because the
        -- game's attribute system ONLY accepts mutations through the GE
        -- apply path -- see NOTES/cheats-to-revisit.md §11 and the round
        -- 8.5 probe dump (ipc/probes/gameplay_effects/).
        --
        -- Ordering: the longest prefix must be matched first. The verb
        -- lengths are:
        --   player.ge.apply  = 15
        --   player.ge.remove = 16
        --   player.ge.toggle = 16
        --   player.ge.list   = 14
        --   player.ge.has    = 13   (this is a strict prefix of "has...")
        -- Round 56 added the CDO field editor:
        --   player.ge.cdo.dump  = 19
        --   player.ge.cdo.set   = 18
        --   player.ge.cdo.get   = 18
        --   player.ge.cdo.reset = 20
        -- Since all five share "player.ge." as a prefix, we check the
        -- specific tails via exact-length substring comparisons.

        -- Round 56: CDO editor verbs first (they all share the longer
        -- "player.ge.cdo." prefix and would otherwise be eaten by the
        -- shorter ge.apply / ge.remove checks below if any of them ever
        -- get a tail that lands on the same length).
        if line:sub(1, 20) == "player.ge.cdo.reset " or line == "player.ge.cdo.reset" then
            local arg = arg_after("player.ge.cdo.reset")
            if arg == "" then return false, "usage: player.ge.cdo.reset <ClassName>" end
            local ok, detail = feature_ge.cdo_reset(arg)
            if ok then return true, "ok player.ge.cdo.reset " .. tostring(detail) end
            return false, "player.ge.cdo.reset failed: " .. tostring(detail)
        end
        -- Round 56.1: chunked-dump fetch verb. Must be checked BEFORE
        -- the bare "player.ge.cdo.dump " prefix below since it shares
        -- the same first 19 characters.
        if line:sub(1, 25) == "player.ge.cdo.dump.chunk " then
            local rest = arg_after("player.ge.cdo.dump.chunk")
            local class_name, index = rest:match("^(%S+)%s+(%S+)$")
            if not class_name then
                return false, "usage: player.ge.cdo.dump.chunk <ClassName> <Index>"
            end
            local ok, detail = feature_ge.cdo_dump_chunk(class_name, index)
            -- Raw chunk body, no verb echo: keeps every byte of the
            -- 1024-byte mailbox available for JSON payload.
            if ok then return true, tostring(detail) end
            return false, "player.ge.cdo.dump.chunk failed: " .. tostring(detail)
        end
        if line:sub(1, 19) == "player.ge.cdo.dump " or line == "player.ge.cdo.dump" then
            local arg = arg_after("player.ge.cdo.dump")
            if arg == "" then return false, "usage: player.ge.cdo.dump <ClassName>" end
            local ok, detail = feature_ge.cdo_dump(arg)
            if ok then return true, "ok player.ge.cdo.dump " .. tostring(detail) end
            return false, "player.ge.cdo.dump failed: " .. tostring(detail)
        end
        if line:sub(1, 18) == "player.ge.cdo.set " then
            local rest = arg_after("player.ge.cdo.set")
            -- ClassName Field Value ; value may contain spaces, so split
            -- on the first two whitespace runs only.
            local class_name, path, value = rest:match("^(%S+)%s+(%S+)%s+(.+)$")
            if not class_name then
                return false, "usage: player.ge.cdo.set <ClassName> <FieldPath> <Value>"
            end
            local ok, detail = feature_ge.cdo_set(class_name, path, value)
            if ok then return true, "ok player.ge.cdo.set " .. tostring(detail) end
            return false, "player.ge.cdo.set failed: " .. tostring(detail)
        end
        if line:sub(1, 18) == "player.ge.cdo.get " then
            local rest = arg_after("player.ge.cdo.get")
            local class_name, path = rest:match("^(%S+)%s+(%S+)$")
            if not class_name then
                return false, "usage: player.ge.cdo.get <ClassName> <FieldPath>"
            end
            local ok, detail = feature_ge.cdo_get(class_name, path)
            if ok then return true, tostring(detail) end
            return false, "player.ge.cdo.get failed: " .. tostring(detail)
        end

        if line:sub(1, 16) == "player.ge.remove" then
            local arg = arg_after("player.ge.remove")
            if arg == "" then return false, "usage: player.ge.remove <ClassName>" end
            local ok, detail = feature_ge.remove_ge(arg)
            if ok then return true, "ok player.ge.remove " .. tostring(detail) end
            return false, "player.ge.remove failed: " .. tostring(detail)
        end
        if line:sub(1, 16) == "player.ge.toggle" then
            local rest = arg_after("player.ge.toggle")
            local class_name, value = rest:match("^(%S+)%s+(%S+)$")
            if not class_name then return false, "usage: player.ge.toggle <ClassName> <on|off>" end
            local ok, detail = feature_ge.toggle_ge(class_name, value)
            if ok then return true, "ok player.ge.toggle " .. tostring(detail) end
            return false, "player.ge.toggle failed: " .. tostring(detail)
        end
        if line:sub(1, 15) == "player.ge.apply" then
            local arg = arg_after("player.ge.apply")
            if arg == "" then return false, "usage: player.ge.apply <ClassName>" end
            local ok, detail = feature_ge.apply_ge(arg)
            if ok then return true, "ok player.ge.apply " .. tostring(detail) end
            return false, "player.ge.apply failed: " .. tostring(detail)
        end
        if line:sub(1, 14) == "player.ge.list" then
            local ok, detail = feature_ge.list_applied()
            if ok then return true, "ok player.ge.list " .. tostring(detail) end
            return false, "player.ge.list failed: " .. tostring(detail)
        end
        if line:sub(1, 13) == "player.ge.has" then
            local arg = arg_after("player.ge.has")
            if arg == "" then return false, "usage: player.ge.has <ClassName>" end
            local ok, detail = feature_ge.has_ge(arg)
            if ok then return true, tostring(detail) end
            return false, "player.ge.has failed: " .. tostring(detail)
        end

        -- Round 22: direct GAS attribute writes (player.attr.set/get).
        -- Bypasses the GE pipeline (which §12 proved unreliable) and the
        -- per-component scalar fields (which §5/§13/§17/§18/§23 all proved
        -- ineffective). Writes the live AttributeValues[i] / SharedAttribute
        -- Values[i] slot the game's combat/stamina/regen code reads on the
        -- next tick. See feature_attr.lua for the full rationale.
        --
        -- player.attr.set = 15
        -- player.attr.get = 15
        -- Both are unique with no shared prefixes against existing verbs.
        if line:sub(1, 15) == "player.attr.set" then
            local rest = arg_after("player.attr.set")
            local class_name, value = rest:match("^(%S+)%s+(%S+)$")
            if not class_name then return false, "usage: player.attr.set <ClassName> <value>" end
            local feature_attr = require("feature_attr")
            local ok, detail = feature_attr.set_attribute(class_name, value)
            if ok then return true, "ok player.attr.set " .. tostring(detail) end
            return false, "player.attr.set failed: " .. tostring(detail)
        end
        if line:sub(1, 15) == "player.attr.get" then
            local arg = arg_after("player.attr.get")
            if arg == "" then return false, "usage: player.attr.get <ClassName>" end
            local feature_attr = require("feature_attr")
            local ok, detail = feature_attr.get_attribute(arg)
            if ok then return true, tostring(detail) end
            return false, "player.attr.get failed: " .. tostring(detail)
        end

        -- Teleport tweaks
        if line:sub(1, 15) == "player.tp.delay" then
            local ok, detail = feature_player.set_tp_loading_delay(arg_after("player.tp.delay"))
            if ok then return true, "ok player.tp.delay " .. tostring(detail) end
            return false, "player.tp.delay failed: " .. tostring(detail)
        end
        if line:sub(1, 13) == "player.tp.vfx" then
            local ok, detail = feature_player.set_tp_vfx_delay(arg_after("player.tp.vfx"))
            if ok then return true, "ok player.tp.vfx " .. tostring(detail) end
            return false, "player.tp.vfx failed: " .. tostring(detail)
        end
        if line:sub(1, 17) == "player.tp.timeout" then
            local ok, detail = feature_player.set_tp_timeout(arg_after("player.tp.timeout"))
            if ok then return true, "ok player.tp.timeout " .. tostring(detail) end
            return false, "player.tp.timeout failed: " .. tostring(detail)
        end

        -- Round 11: new-capability cheats. Ordering rules applied (compound
        -- / longer verbs first, matching the rest of this file):
        --   player.mounts.unlockall       = 23   (not a prefix of anything)
        --   player.mount.invincible       = 23   (not a prefix of anything)
        --   player.spell.cancel           = 19
        --   player.revivedelay            = 18
        --   player.arrowrange             = 17
        --   player.aimpitch               = 15
        -- critchance + foliagerange dispatch removed in 11.5 (see header doc).
        -- player.unlock.corruptionshot + player.spells.* removed in round 12
        -- rollback (see NOTES/cheats-to-revisit.md §16).
        -- None of these share prefixes with each other or with existing
        -- player.* verbs (verified by grep against the full verb list).
        if line:sub(1, 23) == "player.mounts.unlockall" then
            local ok, detail = feature_player.unlock_all_mounts(arg_after("player.mounts.unlockall"))
            if ok then return true, "ok player.mounts.unlockall " .. tostring(detail) end
            return false, "player.mounts.unlockall failed: " .. tostring(detail)
        end
        if line:sub(1, 23) == "player.mount.invincible" then
            local ok, detail = feature_player.set_mount_invincible(arg_after("player.mount.invincible"))
            if ok then return true, "ok player.mount.invincible " .. tostring(detail) end
            return false, "player.mount.invincible failed: " .. tostring(detail)
        end
        if line == "player.spell.cancel" or line:sub(1, 20) == "player.spell.cancel " then
            local ok, detail = feature_player.cancel_spell()
            if ok then return true, "ok player.spell.cancel " .. tostring(detail) end
            return false, "player.spell.cancel failed: " .. tostring(detail)
        end
        -- Round 13 spell cheats. player.spells. (14) vs player.spell. (13) -- no
        -- overlap. Within player.spells.* the prefix lengths are:
        --   player.spells.continuouscast   (28)
        --   player.spells.zerocooldown     (26)
        --   player.spells.unlock           (20)
        -- None is a prefix of another so dispatch order is purely cosmetic;
        -- we keep them sorted longest-first per the project's house style.
        if line:sub(1, 28) == "player.spells.continuouscast" then
            local ok, detail = feature_player.set_spells_continuouscast(arg_after("player.spells.continuouscast"))
            if ok then return true, "ok player.spells.continuouscast " .. tostring(detail) end
            return false, "player.spells.continuouscast failed: " .. tostring(detail)
        end
        if line:sub(1, 26) == "player.spells.zerocooldown" then
            local ok, detail = feature_player.set_spells_zerocooldown(arg_after("player.spells.zerocooldown"))
            if ok then return true, "ok player.spells.zerocooldown " .. tostring(detail) end
            return false, "player.spells.zerocooldown failed: " .. tostring(detail)
        end
        if line:sub(1, 20) == "player.spells.unlock" then
            local ok, detail = feature_player.set_spells_unlock(arg_after("player.spells.unlock"))
            if ok then return true, "ok player.spells.unlock " .. tostring(detail) end
            return false, "player.spells.unlock failed: " .. tostring(detail)
        end
        if line:sub(1, 18) == "player.revivedelay" then
            local ok, detail = feature_player.set_revive_delay(arg_after("player.revivedelay"))
            if ok then return true, "ok player.revivedelay " .. tostring(detail) end
            return false, "player.revivedelay failed: " .. tostring(detail)
        end
        if line:sub(1, 17) == "player.arrowrange" then
            local ok, detail = feature_player.set_arrow_range(arg_after("player.arrowrange"))
            if ok then return true, "ok player.arrowrange " .. tostring(detail) end
            return false, "player.arrowrange failed: " .. tostring(detail)
        end
        if line:sub(1, 15) == "player.aimpitch" then
            local ok, detail = feature_player.set_aim_pitch_unlock(arg_after("player.aimpitch"))
            if ok then return true, "ok player.aimpitch " .. tostring(detail) end
            return false, "player.aimpitch failed: " .. tostring(detail)
        end

        -- Round 29: every player.dump.* probe verb was deleted. Per-system
        -- dumpers under Scripts/dumpers/ + their feature_introspect wrappers
        -- (dump_player_*, dump_world, dump_skills, dump_inventory, ...) are
        -- gone. Catalog data now flows through the static pipeline:
        --   1. dump.types     -> UE4SS GenerateLuaTypes() emits EmmyLua type
        --                        stubs to <ue4ss>/Mods/shared/types/.
        --   2. WPF spawns     -> scripts/Generate-Catalog.ps1 parses those
        --                        and writes ipc/catalog/catalog.jsonl.
        --   3. WPF Catalog    -> reads the JSONL and surfaces every UClass
        --      tab               with at least one field as a write target.
        -- Live-write verbs (player.field.set / set_index / set_key / call /
        -- set_object / add / remove / clear) handled below remain unchanged.
        if line == "dump.types" then
            if type(GenerateLuaTypes) ~= "function" then
                return false, "dump.types failed: GenerateLuaTypes global not registered (UE4SS too old?)"
            end
            local ok, err = pcall(GenerateLuaTypes)
            if not ok then
                return false, "dump.types failed: " .. tostring(err)
            end
            return true, "ok dump.types -- types regenerated under ue4ss/Mods/shared/types/"
        end

        -- Reader: "player.get <key>" returns the raw field value so the WPF
        -- can prime its sliders on first open. Ack body is just the value.
        if line:sub(1, 10) == "player.get" then
            local key = arg_after("player.get")
            if key == "" then return false, "usage: player.get <key>" end
            local getters = {
                ["time"]         = feature_player.get_time_dilation,
                ["jump.count"]   = feature_player.get_jump_count,
                ["jump.hold"]    = feature_player.get_jump_hold,
                ["buildings"]    = feature_player.get_can_damage_buildings,
                ["tp.delay"]     = feature_player.get_tp_loading_delay,
                ["tp.vfx"]       = feature_player.get_tp_vfx_delay,
                ["tp.timeout"]   = feature_player.get_tp_timeout,
                ["health"]       = feature_player.get_health,
                ["maxhealth"]    = feature_player.get_max_health,
                ["walkspeed"]    = feature_player.get_walkspeed,
                ["jumpvel"]      = feature_player.get_jumpvel,
                ["gravity"]      = feature_player.get_gravity,
                ["aircontrol"]   = feature_player.get_air_control,
                ["speedmult"]    = feature_player.get_speed_mult,
                ["flyspeed"]     = feature_player.get_flyspeed,
                ["acceleration"] = feature_player.get_acceleration,
                ["hydration"]    = feature_player.get_hydration,
                ["sustenance"]   = feature_player.get_sustenance,
                ["endurance"]    = feature_player.get_endurance,
                ["toxicity"]     = feature_player.get_toxicity,
                ["stamina"]      = feature_player.get_stamina,
                ["maxstamina"]   = feature_player.get_max_stamina,
                ["stealth"]      = feature_player.get_stealth,
                -- Round 5 (potion.slots removed in round 7).
                ["durabilityloss"] = feature_player.get_no_durability_loss,
                ["magnet"]       = feature_player.get_magnet_range,
                ["fov"]          = feature_player.get_fov,
                ["silent"]       = feature_player.get_silent,
                ["surge"]        = feature_player.get_surge,
                -- Round 6
                ["parrywindow"]  = feature_player.get_parry_window,
                ["blockangle"]   = feature_player.get_block_angle,
                ["lockon"]       = feature_player.get_lockon_scale,
                -- Round 7
                ["respawninvul"] = feature_player.get_respawn_invul,
                ["wellrested"]   = feature_player.get_well_rested,
                ["poise"]        = feature_player.get_poise,
                ["perfectaim"]   = feature_player.get_perfect_aim,
                -- Round 11 (critchance + foliagerange removed in 11.5)
                ["mounts.unlocked"]      = feature_player.get_mounts_unlocked,
                ["mount.invincible"]     = feature_player.get_mount_invincible,
                ["aimpitch"]             = feature_player.get_aim_pitch_unlock,
                ["arrowrange"]           = feature_player.get_arrow_range,
                ["revivedelay"]          = feature_player.get_revive_delay,
            }
            local fn = getters[key]
            if not fn then return false, "unknown key: " .. key end
            local ok, detail = fn()
            if ok then return true, tostring(detail) end
            return false, "player.get failed: " .. tostring(detail)
        end

        return false, "unknown player.* verb"
    end

    -- cvars.dump
    --   Experimental : asks the engine to enumerate every live
    --   IConsoleManager entry by issuing the stock Help +
    --   DumpConsoleCommands + DumpConsoleVariables console commands
    --   through KismetSystemLibrary::ExecuteConsoleCommand. The actual
    --   listings land in the game log
    --   (%LOCALAPPDATA%\<Project>\Saved\Logs\<Project>.log) and the
    --   HelpConsoleCommands.html file under <Project>\Saved\. We drop
    --   a small marker JSON at ipc\cvars\cvars-dump-marker.json so the
    --   offline tools\Parse-RuntimeCVars.py knows which files to parse
    --   and when the dump was triggered. No UI yet per design ; this
    --   is the raw experimental verb. Sits at top level (NOT inside the
    --   world.* prefix guard) because the verb name does not start
    --   with "world.".
    if line == "cvars.dump" then
        local ok, detail = feature_cvars.dump()
        if ok then return true, "ok cvars.dump " .. tostring(detail) end
        return false, "cvars.dump failed: " .. tostring(detail)
    end

    if line == "cvars.filming" or line:sub(1, 14) == "cvars.filming " then
        local ok, detail = feature_cvars.filming(trim(line:sub(14)))
        if ok then return true, "ok cvars.filming " .. tostring(detail) end
        return false, "cvars.filming failed: " .. tostring(detail)
    end

    if line:sub(1, 9) == "cvars.set" then
        local ok, detail = feature_cvars.set(trim(line:sub(10)))
        if ok then return true, "ok cvars.set " .. tostring(detail) end
        return false, "cvars.set failed: " .. tostring(detail)
    end

    -- world.* verbs: time-of-day, weather (Round 17).
    if line:sub(1, 6) == "world." then
        local function arg_after(verb)
            local rest = line:sub(#verb + 1)
            return (tostring(rest or ""):gsub("^%s+", ""):gsub("%s+$", ""))
        end

        if line == "world.progress.probe" or line:sub(1, 21) == "world.progress.probe " then
            local ok, detail = feature_progress.probe(arg_after("world.progress.probe"))
            if ok then return true, "ok world.progress.probe " .. tostring(detail) end
            return false, "world.progress.probe failed: " .. tostring(detail)
        end
        if line == "world.progress.has" or line:sub(1, 19) == "world.progress.has " then
            local ok, detail = feature_progress.has(arg_after("world.progress.has"))
            if ok then return true, "ok world.progress.has " .. tostring(detail) end
            return false, "world.progress.has failed: " .. tostring(detail)
        end
        if line == "world.progress.defeat" or line:sub(1, 22) == "world.progress.defeat " then
            local ok, detail = feature_progress.defeat(arg_after("world.progress.defeat"))
            if ok then return true, "ok world.progress.defeat " .. tostring(detail) end
            return false, "world.progress.defeat failed: " .. tostring(detail)
        end
        if line == "world.progress.undefeat" or line:sub(1, 24) == "world.progress.undefeat " then
            local ok, detail = feature_progress.undefeat(arg_after("world.progress.undefeat"))
            if ok then return true, "ok world.progress.undefeat " .. tostring(detail) end
            return false, "world.progress.undefeat failed: " .. tostring(detail)
        end
        if line == "world.progress.value.list" or line:sub(1, #"world.progress.value.list ") == "world.progress.value.list " then
            local ok, detail = feature_progress.value_list(arg_after("world.progress.value.list"))
            if ok then return true, "ok world.progress.value.list " .. tostring(detail) end
            return false, "world.progress.value.list failed: " .. tostring(detail)
        end
        if line == "world.progress.value.get" or line:sub(1, #"world.progress.value.get ") == "world.progress.value.get " then
            local ok, detail = feature_progress.value_get(arg_after("world.progress.value.get"))
            if ok then return true, "ok world.progress.value.get " .. tostring(detail) end
            return false, "world.progress.value.get failed: " .. tostring(detail)
        end
        if line == "world.progress.value.set" or line:sub(1, #"world.progress.value.set ") == "world.progress.value.set " then
            local ok, detail = feature_progress.value_set(arg_after("world.progress.value.set"))
            if ok then return true, "ok world.progress.value.set " .. tostring(detail) end
            return false, "world.progress.value.set failed: " .. tostring(detail)
        end
        if line == "world.progress.hook.probe" or line:sub(1, #"world.progress.hook.probe ") == "world.progress.hook.probe " then
            local ok, detail = feature_progress.hook_probe(arg_after("world.progress.hook.probe"))
            if ok then return true, "ok world.progress.hook.probe " .. tostring(detail) end
            return false, "world.progress.hook.probe failed: " .. tostring(detail)
        end
        if line == "world.progress.hook.has" or line:sub(1, #"world.progress.hook.has ") == "world.progress.hook.has " then
            local ok, detail = feature_progress.hook_has(arg_after("world.progress.hook.has"))
            if ok then return true, "ok world.progress.hook.has " .. tostring(detail) end
            return false, "world.progress.hook.has failed: " .. tostring(detail)
        end
        if line == "world.progress.hook.fire" or line:sub(1, #"world.progress.hook.fire ") == "world.progress.hook.fire " then
            local ok, detail = feature_progress.fire_hook(arg_after("world.progress.hook.fire"))
            if ok then return true, "ok world.progress.hook.fire " .. tostring(detail) end
            return false, "world.progress.hook.fire failed: " .. tostring(detail)
        end
        if line == "world.progress.hook.mark" or line:sub(1, #"world.progress.hook.mark ") == "world.progress.hook.mark " then
            local ok, detail = feature_progress.mark_hook(arg_after("world.progress.hook.mark"))
            if ok then return true, "ok world.progress.hook.mark " .. tostring(detail) end
            return false, "world.progress.hook.mark failed: " .. tostring(detail)
        end
        if line == "world.progress.hook.trigger" or line:sub(1, #"world.progress.hook.trigger ") == "world.progress.hook.trigger " then
            local ok, detail = feature_progress.trigger_hook(arg_after("world.progress.hook.trigger"))
            if ok then return true, "ok world.progress.hook.trigger " .. tostring(detail) end
            return false, "world.progress.hook.trigger failed: " .. tostring(detail)
        end
        if line == "world.progress.hook.reset" or line:sub(1, #"world.progress.hook.reset ") == "world.progress.hook.reset " then
            local ok, detail = feature_progress.reset_hook(arg_after("world.progress.hook.reset"))
            if ok then return true, "ok world.progress.hook.reset " .. tostring(detail) end
            return false, "world.progress.hook.reset failed: " .. tostring(detail)
        end
        if line == "world.resource.probe" or line:sub(1, #"world.resource.probe ") == "world.resource.probe " then
            local ok, detail = feature_persistence.resource_probe(arg_after("world.resource.probe"))
            if ok then return true, "ok world.resource.probe " .. tostring(detail) end
            return false, "world.resource.probe failed: " .. tostring(detail)
        end
        if line == "world.resource.set" or line:sub(1, #"world.resource.set ") == "world.resource.set " then
            local ok, detail = feature_persistence.resource_set(arg_after("world.resource.set"))
            if ok then return true, "ok world.resource.set " .. tostring(detail) end
            return false, "world.resource.set failed: " .. tostring(detail)
        end
        if line == "world.resource.pause" or line:sub(1, #"world.resource.pause ") == "world.resource.pause " then
            local ok, detail = feature_persistence.resource_pause(arg_after("world.resource.pause"))
            if ok then return true, "ok world.resource.pause " .. tostring(detail) end
            return false, "world.resource.pause failed: " .. tostring(detail)
        end
        if line == "world.resource.take" or line:sub(1, #"world.resource.take ") == "world.resource.take " then
            local ok, detail = feature_persistence.resource_take(arg_after("world.resource.take"))
            if ok then return true, "ok world.resource.take " .. tostring(detail) end
            return false, "world.resource.take failed: " .. tostring(detail)
        end

        -- world.foliage.* : cautious developer/test verbs for interactable
        -- foliage ISM discovery, native conversion, and converted-tree state.
        if line == "world.foliage.scan.near" or line:sub(1, #"world.foliage.scan.near ") == "world.foliage.scan.near " then
            local ok, detail = feature_foliage.scan_near(arg_after("world.foliage.scan.near"))
            if ok then return true, "ok world.foliage.scan.near " .. tostring(detail) end
            return false, "world.foliage.scan.near failed: " .. tostring(detail)
        end
        if line == "world.foliage.scan.all" or line:sub(1, #"world.foliage.scan.all ") == "world.foliage.scan.all " then
            local ok, detail = feature_foliage.scan_all(arg_after("world.foliage.scan.all"))
            if ok then return true, "ok world.foliage.scan.all " .. tostring(detail) end
            return false, "world.foliage.scan.all failed: " .. tostring(detail)
        end
        if line == "world.foliage.convert.lookat" or line:sub(1, #"world.foliage.convert.lookat ") == "world.foliage.convert.lookat " then
            local ok, detail = feature_foliage.convert_lookat(arg_after("world.foliage.convert.lookat"))
            if ok then return true, "ok world.foliage.convert.lookat " .. tostring(detail) end
            return false, "world.foliage.convert.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.convert.near" or line:sub(1, #"world.foliage.convert.near ") == "world.foliage.convert.near " then
            local ok, detail = feature_foliage.convert_near(arg_after("world.foliage.convert.near"))
            if ok then return true, "ok world.foliage.convert.near " .. tostring(detail) end
            return false, "world.foliage.convert.near failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.convert.single" or line:sub(1, #"world.foliage.tree.convert.single ") == "world.foliage.tree.convert.single " then
            local ok, detail = feature_foliage.tree_convert_single(arg_after("world.foliage.tree.convert.single"))
            if ok then return true, "ok world.foliage.tree.convert.single " .. tostring(detail) end
            return false, "world.foliage.tree.convert.single failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.stump.single" or line:sub(1, #"world.foliage.tree.stump.single ") == "world.foliage.tree.stump.single " then
            local ok, detail = feature_foliage.tree_stump_single(arg_after("world.foliage.tree.stump.single"))
            if ok then return true, "ok world.foliage.tree.stump.single " .. tostring(detail) end
            return false, "world.foliage.tree.stump.single failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.split.single" or line:sub(1, #"world.foliage.tree.split.single ") == "world.foliage.tree.split.single " then
            local ok, detail = feature_foliage.tree_split_single(arg_after("world.foliage.tree.split.single"))
            if ok then return true, "ok world.foliage.tree.split.single " .. tostring(detail) end
            return false, "world.foliage.tree.split.single failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.destroy.single" or line:sub(1, #"world.foliage.tree.destroy.single ") == "world.foliage.tree.destroy.single " then
            local ok, detail = feature_foliage.tree_destroy_single(arg_after("world.foliage.tree.destroy.single"))
            if ok then return true, "ok world.foliage.tree.destroy.single " .. tostring(detail) end
            return false, "world.foliage.tree.destroy.single failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.destroy.all" or line:sub(1, #"world.foliage.tree.destroy.all ") == "world.foliage.tree.destroy.all " then
            local ok, detail = feature_foliage.tree_destroy_all(arg_after("world.foliage.tree.destroy.all"))
            if ok then return true, "ok world.foliage.tree.destroy.all " .. tostring(detail) end
            return false, "world.foliage.tree.destroy.all failed: " .. tostring(detail)
        end
        if line == "world.foliage.forest.destroy.all" or line:sub(1, #"world.foliage.forest.destroy.all ") == "world.foliage.forest.destroy.all " then
            local ok, detail = feature_foliage.tree_destroy_all(arg_after("world.foliage.forest.destroy.all"))
            if ok then return true, "ok world.foliage.forest.destroy.all " .. tostring(detail) end
            return false, "world.foliage.forest.destroy.all failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.properdestroy.all" or line:sub(1, #"world.foliage.tree.properdestroy.all ") == "world.foliage.tree.properdestroy.all " then
            local ok, detail = feature_foliage.tree_destroy_all(arg_after("world.foliage.tree.properdestroy.all"))
            if ok then return true, "ok world.foliage.tree.properdestroy.all " .. tostring(detail) end
            return false, "world.foliage.tree.properdestroy.all failed: " .. tostring(detail)
        end
        if line == "world.foliage.forest.properdestroy.all" or line:sub(1, #"world.foliage.forest.properdestroy.all ") == "world.foliage.forest.properdestroy.all " then
            local ok, detail = feature_foliage.tree_destroy_all(arg_after("world.foliage.forest.properdestroy.all"))
            if ok then return true, "ok world.foliage.forest.properdestroy.all " .. tostring(detail) end
            return false, "world.foliage.forest.properdestroy.all failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.delete.all" or line:sub(1, #"world.foliage.tree.delete.all ") == "world.foliage.tree.delete.all " then
            local ok, detail = feature_foliage.tree_destroy_all(arg_after("world.foliage.tree.delete.all"))
            if ok then return true, "ok world.foliage.tree.delete.all " .. tostring(detail) end
            return false, "world.foliage.tree.delete.all failed: " .. tostring(detail)
        end
        if line == "world.foliage.forest.delete.all" or line:sub(1, #"world.foliage.forest.delete.all ") == "world.foliage.forest.delete.all " then
            local ok, detail = feature_foliage.tree_destroy_all(arg_after("world.foliage.forest.delete.all"))
            if ok then return true, "ok world.foliage.forest.delete.all " .. tostring(detail) end
            return false, "world.foliage.forest.delete.all failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.stump.all" or line:sub(1, #"world.foliage.tree.stump.all ") == "world.foliage.tree.stump.all " then
            local ok, detail = feature_foliage.tree_stump_all(arg_after("world.foliage.tree.stump.all"))
            if ok then return true, "ok world.foliage.tree.stump.all " .. tostring(detail) end
            return false, "world.foliage.tree.stump.all failed: " .. tostring(detail)
        end
        if line == "world.foliage.forest.stump.all" or line:sub(1, #"world.foliage.forest.stump.all ") == "world.foliage.forest.stump.all " then
            local ok, detail = feature_foliage.tree_stump_all(arg_after("world.foliage.forest.stump.all"))
            if ok then return true, "ok world.foliage.forest.stump.all " .. tostring(detail) end
            return false, "world.foliage.forest.stump.all failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.split.all" or line:sub(1, #"world.foliage.tree.split.all ") == "world.foliage.tree.split.all " then
            local ok, detail = feature_foliage.tree_split_all(arg_after("world.foliage.tree.split.all"))
            if ok then return true, "ok world.foliage.tree.split.all " .. tostring(detail) end
            return false, "world.foliage.tree.split.all failed: " .. tostring(detail)
        end
        if line == "world.foliage.forest.split.all" or line:sub(1, #"world.foliage.forest.split.all ") == "world.foliage.forest.split.all " then
            local ok, detail = feature_foliage.tree_split_all(arg_after("world.foliage.forest.split.all"))
            if ok then return true, "ok world.foliage.forest.split.all " .. tostring(detail) end
            return false, "world.foliage.forest.split.all failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.destroy.lookat" or line:sub(1, #"world.foliage.tree.destroy.lookat ") == "world.foliage.tree.destroy.lookat " then
            local ok, detail = feature_foliage.tree_destroy_lookat(arg_after("world.foliage.tree.destroy.lookat"))
            if ok then return true, "ok world.foliage.tree.destroy.lookat " .. tostring(detail) end
            return false, "world.foliage.tree.destroy.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.forest.destroy.lookat" or line:sub(1, #"world.foliage.forest.destroy.lookat ") == "world.foliage.forest.destroy.lookat " then
            local ok, detail = feature_foliage.tree_destroy_lookat(arg_after("world.foliage.forest.destroy.lookat"))
            if ok then return true, "ok world.foliage.forest.destroy.lookat " .. tostring(detail) end
            return false, "world.foliage.forest.destroy.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.properdestroy.lookat" or line:sub(1, #"world.foliage.tree.properdestroy.lookat ") == "world.foliage.tree.properdestroy.lookat " then
            local ok, detail = feature_foliage.tree_destroy_lookat(arg_after("world.foliage.tree.properdestroy.lookat"))
            if ok then return true, "ok world.foliage.tree.properdestroy.lookat " .. tostring(detail) end
            return false, "world.foliage.tree.properdestroy.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.forest.properdestroy.lookat" or line:sub(1, #"world.foliage.forest.properdestroy.lookat ") == "world.foliage.forest.properdestroy.lookat " then
            local ok, detail = feature_foliage.tree_destroy_lookat(arg_after("world.foliage.forest.properdestroy.lookat"))
            if ok then return true, "ok world.foliage.forest.properdestroy.lookat " .. tostring(detail) end
            return false, "world.foliage.forest.properdestroy.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.delete.lookat" or line:sub(1, #"world.foliage.tree.delete.lookat ") == "world.foliage.tree.delete.lookat " then
            local ok, detail = feature_foliage.tree_destroy_lookat(arg_after("world.foliage.tree.delete.lookat"))
            if ok then return true, "ok world.foliage.tree.delete.lookat " .. tostring(detail) end
            return false, "world.foliage.tree.delete.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.forest.delete.lookat" or line:sub(1, #"world.foliage.forest.delete.lookat ") == "world.foliage.forest.delete.lookat " then
            local ok, detail = feature_foliage.tree_destroy_lookat(arg_after("world.foliage.forest.delete.lookat"))
            if ok then return true, "ok world.foliage.forest.delete.lookat " .. tostring(detail) end
            return false, "world.foliage.forest.delete.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.stump.lookat" or line:sub(1, #"world.foliage.tree.stump.lookat ") == "world.foliage.tree.stump.lookat " then
            local ok, detail = feature_foliage.tree_stump_lookat(arg_after("world.foliage.tree.stump.lookat"))
            if ok then return true, "ok world.foliage.tree.stump.lookat " .. tostring(detail) end
            return false, "world.foliage.tree.stump.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.forest.stump.lookat" or line:sub(1, #"world.foliage.forest.stump.lookat ") == "world.foliage.forest.stump.lookat " then
            local ok, detail = feature_foliage.tree_stump_lookat(arg_after("world.foliage.forest.stump.lookat"))
            if ok then return true, "ok world.foliage.forest.stump.lookat " .. tostring(detail) end
            return false, "world.foliage.forest.stump.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.stump.near" or line:sub(1, #"world.foliage.tree.stump.near ") == "world.foliage.tree.stump.near " then
            local ok, detail = feature_foliage.tree_stump_near(arg_after("world.foliage.tree.stump.near"))
            if ok then return true, "ok world.foliage.tree.stump.near " .. tostring(detail) end
            return false, "world.foliage.tree.stump.near failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.split.lookat" or line:sub(1, #"world.foliage.tree.split.lookat ") == "world.foliage.tree.split.lookat " then
            local ok, detail = feature_foliage.tree_split_lookat(arg_after("world.foliage.tree.split.lookat"))
            if ok then return true, "ok world.foliage.tree.split.lookat " .. tostring(detail) end
            return false, "world.foliage.tree.split.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.forest.split.lookat" or line:sub(1, #"world.foliage.forest.split.lookat ") == "world.foliage.forest.split.lookat " then
            local ok, detail = feature_foliage.tree_split_lookat(arg_after("world.foliage.forest.split.lookat"))
            if ok then return true, "ok world.foliage.forest.split.lookat " .. tostring(detail) end
            return false, "world.foliage.forest.split.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.split.near" or line:sub(1, #"world.foliage.tree.split.near ") == "world.foliage.tree.split.near " then
            local ok, detail = feature_foliage.tree_split_near(arg_after("world.foliage.tree.split.near"))
            if ok then return true, "ok world.foliage.tree.split.near " .. tostring(detail) end
            return false, "world.foliage.tree.split.near failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.redundant.lookat" or line:sub(1, #"world.foliage.tree.redundant.lookat ") == "world.foliage.tree.redundant.lookat " then
            local ok, detail = feature_foliage.tree_redundant_lookat(arg_after("world.foliage.tree.redundant.lookat"))
            if ok then return true, "ok world.foliage.tree.redundant.lookat " .. tostring(detail) end
            return false, "world.foliage.tree.redundant.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.forest.redundant.lookat" or line:sub(1, #"world.foliage.forest.redundant.lookat ") == "world.foliage.forest.redundant.lookat " then
            local ok, detail = feature_foliage.tree_redundant_lookat(arg_after("world.foliage.forest.redundant.lookat"))
            if ok then return true, "ok world.foliage.forest.redundant.lookat " .. tostring(detail) end
            return false, "world.foliage.forest.redundant.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.redundant.near" or line:sub(1, #"world.foliage.tree.redundant.near ") == "world.foliage.tree.redundant.near " then
            local ok, detail = feature_foliage.tree_redundant_near(arg_after("world.foliage.tree.redundant.near"))
            if ok then return true, "ok world.foliage.tree.redundant.near " .. tostring(detail) end
            return false, "world.foliage.tree.redundant.near failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.destroy.near" or line:sub(1, #"world.foliage.tree.destroy.near ") == "world.foliage.tree.destroy.near " then
            local ok, detail = feature_foliage.tree_destroy_near(arg_after("world.foliage.tree.destroy.near"))
            if ok then return true, "ok world.foliage.tree.destroy.near " .. tostring(detail) end
            return false, "world.foliage.tree.destroy.near failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.properdestroy.near" or line:sub(1, #"world.foliage.tree.properdestroy.near ") == "world.foliage.tree.properdestroy.near " then
            local ok, detail = feature_foliage.tree_destroy_near(arg_after("world.foliage.tree.properdestroy.near"))
            if ok then return true, "ok world.foliage.tree.properdestroy.near " .. tostring(detail) end
            return false, "world.foliage.tree.properdestroy.near failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.delete.near" or line:sub(1, #"world.foliage.tree.delete.near ") == "world.foliage.tree.delete.near " then
            local ok, detail = feature_foliage.tree_destroy_near(arg_after("world.foliage.tree.delete.near"))
            if ok then return true, "ok world.foliage.tree.delete.near " .. tostring(detail) end
            return false, "world.foliage.tree.delete.near failed: " .. tostring(detail)
        end
        if line == "world.chest.probe" or line:sub(1, #"world.chest.probe ") == "world.chest.probe " then
            local ok, detail = feature_persistence.chest_probe(arg_after("world.chest.probe"))
            if ok then return true, "ok world.chest.probe " .. tostring(detail) end
            return false, "world.chest.probe failed: " .. tostring(detail)
        end
        if line == "world.chest.state" or line:sub(1, #"world.chest.state ") == "world.chest.state " then
            local ok, detail = feature_persistence.chest_state(arg_after("world.chest.state"))
            if ok then return true, "ok world.chest.state " .. tostring(detail) end
            return false, "world.chest.state failed: " .. tostring(detail)
        end
        if line == "world.chest.respawn_disabled" or line:sub(1, #"world.chest.respawn_disabled ") == "world.chest.respawn_disabled " then
            local ok, detail = feature_persistence.chest_respawn_disabled(arg_after("world.chest.respawn_disabled"))
            if ok then return true, "ok world.chest.respawn_disabled " .. tostring(detail) end
            return false, "world.chest.respawn_disabled failed: " .. tostring(detail)
        end
        if line == "world.spud.persist" or line:sub(1, 19) == "world.spud.persist " then
            local ok, detail = feature_spud.persist(arg_after("world.spud.persist"))
            if ok then return true, "ok world.spud.persist " .. tostring(detail) end
            return false, "world.spud.persist failed: " .. tostring(detail)
        end
        if line == "world.spud.unpersist" or line:sub(1, 21) == "world.spud.unpersist " then
            local ok, detail = feature_spud.unpersist(arg_after("world.spud.unpersist"))
            if ok then return true, "ok world.spud.unpersist " .. tostring(detail) end
            return false, "world.spud.unpersist failed: " .. tostring(detail)
        end

        -- Round 54: bulk per-class operations -- the "loop" primitive
        -- the single-target Mod model can't express. Powers things like
        -- a one-shot "Free Build" mod entry that zeroes Requirements
        -- on every BuildingPieceData live in the world.
        --   world.findall <ClassName>
        --   world.foreach <ClassName> set <Field> <Value>
        --   world.foreach <ClassName> call <Method> [args...]   ($it = current instance)
        --   world.foreach <ClassName> clear <Field>
        if line:sub(1, 13) == "world.findall" then
            local val = arg_after("world.findall")
            if val == "" then return false, "usage: world.findall <ClassName>" end
            local ok, detail = feature_foreach.findall(val)
            if ok then return true, "ok world.findall " .. tostring(detail) end
            return false, "world.findall failed: " .. tostring(detail)
        end

        -- world.cdo.dump.all
        --   Bulk variant : dumps every UDeveloperSettings CDO into
        --   ipc/cdo/<ClassName>.json, one file per class. Powers the
        --   "snapshot every settings class at once" workflow so the C#
        --   side can iterate the directory rather than re-dispatching
        --   per class. Must be checked BEFORE the bare `world.cdo.dump`
        --   prefix below since they share the first 14 characters.
        if line == "world.cdo.dump.all" or line:sub(1, 19) == "world.cdo.dump.all " then
            local ok, detail = feature_introspect.dump_cdo_all()
            if ok then return true, "ok world.cdo.dump.all " .. tostring(detail) end
            return false, "world.cdo.dump.all failed: " .. tostring(detail)
        end

        -- world.cdo.dump.deep <ClassName> [maxDepth=2]
        --   Recursive dump : dumps the class, then for every soft path
        --   / class ref / object path in its fields, follows and dumps
        --   that too. Output goes to ipc/cdo/<Class>.json (per-class
        --   files, NOT actor_info.json) and ipc/asset/<sanitised>.json.
        --   A walk audit lands at ipc/cdo_deep_log.txt. Depth-limited
        --   (default 2, hard cap 5) and cycle-protected. MUST be matched
        --   before the bare `world.cdo.dump` prefix.
        if line == "world.cdo.dump.deep" or line:sub(1, 20) == "world.cdo.dump.deep " then
            local val = arg_after("world.cdo.dump.deep")
            if val == "" then return false, "usage: world.cdo.dump.deep <ClassName> [maxDepth=2]" end
            local ok, detail = feature_introspect.dump_cdo_deep(val)
            if ok then return true, "ok world.cdo.dump.deep " .. tostring(detail) end
            return false, "world.cdo.dump.deep failed: " .. tostring(detail)
        end

        -- world.cdo.dump <ClassName | /Script/Module.Class>
        --   Reuses the actor-info reflection pipeline against the named
        --   class's CDO and writes ipc/actor_info.json so the WPF Inspect
        --   tab can browse settings classes (BuildingSettings, ItemSettings,
        --   etc.) the same way it browses live actors. Path form is
        --   preferred -- it mirrors the .ini section header
        --   `[/Script/Module.Class]`. Short-name form falls back to
        --   FindFirstOf, which works for any class with at least one
        --   live instance (true for most UDeveloperSettings, where the
        --   CDO _is_ the runtime instance).
        if line:sub(1, 14) == "world.cdo.dump" then
            local val = arg_after("world.cdo.dump")
            if val == "" then return false, "usage: world.cdo.dump <ClassName|/Script/Module.Class>" end
            local ok, detail = feature_introspect.dump_cdo(val)
            if ok then return true, "ok world.cdo.dump " .. tostring(detail) end
            return false, "world.cdo.dump failed: " .. tostring(detail)
        end

        -- world.asset.dump </Game/Path/To/Asset.Asset | SoftPath>
        --   Force-loads a soft asset reference and dumps the resolved
        --   UObject the same way world.cdo.dump dumps a class default.
        --   Used to crack open soft refs harvested from CDO dumps
        --   (GearPresets, BuildPieceCatalogueRef, etc.) without
        --   exposing the live engine to in-place container/struct
        --   walks (which have crashed in the past -- see comments
        --   in feature_introspect.try_read_field).
        --   Output : ipc/asset/<sanitized>.json.
        if line:sub(1, 16) == "world.asset.dump" then
            local val = arg_after("world.asset.dump")
            if val == "" then return false, "usage: world.asset.dump </Game/...|SoftPath>" end
            local ok, detail = feature_introspect.dump_asset(val)
            if ok then return true, "ok world.asset.dump " .. tostring(detail) end
            return false, "world.asset.dump failed: " .. tostring(detail)
        end

        -- world.func.call <Target> <Method> [args...]
        --   Resolve a UObject and invoke a UFunction. Target accepts
        --   short-name, full path, or shortcuts ("cheatmgr", "player").
        --   Args are space-separated and lightly coerced (true/false,
        --   numbers, otherwise string). Pcall-wrapped end-to-end so
        --   typos don't crash the game thread.
        if line:sub(1, 15) == "world.func.call" then
            local val = arg_after("world.func.call")
            if val == "" then return false, "usage: world.func.call <Target> <Method> [args...]" end
            local ok, detail = feature_introspect.func_call(val)
            if ok then return true, "ok world.func.call " .. tostring(detail) end
            return false, "world.func.call failed: " .. tostring(detail)
        end

        -- world.cheat.exec <command [args...]>
        --   Send the entire payload as one console command through the
        --   local PlayerController. Goes through UE's exec dispatcher
        --   so cheat-manager methods bind to the LIVE local pawn /
        --   cheat manager, not whichever instance FindFirstOf returned.
        --   Use this when world.func.call reports success but nothing
        --   happens in-game.
        if line == "world.cheat.exec" or line:sub(1, 17) == "world.cheat.exec " then
            local val = arg_after("world.cheat.exec")
            if val == "" then return false, "usage: world.cheat.exec <command [args...]>" end
            local ok, detail = feature_introspect.cheat_exec(val)
            if ok then return true, "ok world.cheat.exec " .. tostring(detail) end
            return false, "world.cheat.exec failed: " .. tostring(detail)
        end

        -- world.diff.cdo.snap <ClassName>
        -- world.diff.cdo.compare <ClassName>
        --   Snapshot/compare a class's CDO field values to discover
        --   what a cheat or runtime event mutated. The .compare verb
        --   writes ipc/cdo_diff_<Class>.json. Snapshots live in
        --   Lua-side memory only -- they're not persisted across
        --   game restarts. Order matters : snap first, mutate, compare.
        --
        --   Longer prefix MUST be checked first (snap/compare share
        --   the `world.diff.cdo` stem).
        if line == "world.diff.cdo.snap" or line:sub(1, 20) == "world.diff.cdo.snap " then
            local val = arg_after("world.diff.cdo.snap")
            if val == "" then return false, "usage: world.diff.cdo.snap <ClassName>" end
            local ok, detail = feature_introspect.diff_cdo_snap(val)
            if ok then return true, "ok world.diff.cdo.snap " .. tostring(detail) end
            return false, "world.diff.cdo.snap failed: " .. tostring(detail)
        end
        if line == "world.diff.cdo.compare" or line:sub(1, 23) == "world.diff.cdo.compare " then
            local val = arg_after("world.diff.cdo.compare")
            if val == "" then return false, "usage: world.diff.cdo.compare <ClassName>" end
            local ok, detail = feature_introspect.diff_cdo_compare(val)
            if ok then return true, "ok world.diff.cdo.compare " .. tostring(detail) end
            return false, "world.diff.cdo.compare failed: " .. tostring(detail)
        end

        -- world.diff.actor.snap <ActorName | player | cheatmgr | /Path>
        -- world.diff.actor.compare <same target>
        --   Snapshot/compare a LIVE actor instance (not its CDO).
        --   This is what cheats actually mutate -- domFullHeal touches
        --   the live ASC / pawn, not the class default. Walks the
        --   full class chain so inherited fields are caught too.
        --   Output : ipc/actor_diff_<name>.json.
        if line == "world.diff.actor.snap" or line:sub(1, 22) == "world.diff.actor.snap " then
            local val = arg_after("world.diff.actor.snap")
            if val == "" then return false, "usage: world.diff.actor.snap <ActorName|player|cheatmgr|/Path>" end
            local ok, detail = feature_introspect.diff_actor_snap(val)
            if ok then return true, "ok world.diff.actor.snap " .. tostring(detail) end
            return false, "world.diff.actor.snap failed: " .. tostring(detail)
        end
        if line == "world.diff.actor.compare" or line:sub(1, 25) == "world.diff.actor.compare " then
            local val = arg_after("world.diff.actor.compare")
            if val == "" then return false, "usage: world.diff.actor.compare <same target as snap>" end
            local ok, detail = feature_introspect.diff_actor_compare(val)
            if ok then return true, "ok world.diff.actor.compare " .. tostring(detail) end
            return false, "world.diff.actor.compare failed: " .. tostring(detail)
        end

        if line:sub(1, 13) == "world.foreach" then
            local val = arg_after("world.foreach")
            if val == "" then return false, "usage: world.foreach <ClassName> <set|call|clear> <args...>" end
            local ok, detail = feature_foreach.foreach(val)
            if ok then return true, "ok world.foreach " .. tostring(detail) end
            return false, "world.foreach failed: " .. tostring(detail)
        end

        -- world.buildings.* : player-placed building inspection (read-only v1).
        --   world.buildings.count            -- cross-check totals to log
        --   world.buildings.nearest          -- dump the closest piece to player
        --   world.buildings.describe [N]     -- dump N closest pieces (default 3)
        -- Output is logged to stdout ; the router-returned detail is a one-liner.
        if line == "world.buildings.count" then
            local ok, detail = feature_buildings.count()
            if ok then return true, "ok world.buildings.count " .. tostring(detail) end
            return false, "world.buildings.count failed: " .. tostring(detail)
        end
        -- world.buildings.lookat_anchor
        --   Returns the BuildingPieceDataIndex of the actor under the
        --   reticle without entering placing mode. Used by the WPF
        --   Capture Build "Specify a Build Anchor" flow.
        if line == "world.buildings.lookat_anchor" then
            local ok, detail = feature_build_preview.lookat_anchor()
            if ok then return true, "ok world.buildings.lookat_anchor " .. tostring(detail) end
            return false, "world.buildings.lookat_anchor failed: " .. tostring(detail)
        end
        if line == "world.buildings.nearest" then
            local ok, detail = feature_buildings.nearest()
            if ok then return true, "ok world.buildings.nearest " .. tostring(detail) end
            return false, "world.buildings.nearest failed: " .. tostring(detail)
        end
        if line:sub(1, 24) == "world.buildings.describe" then
            local ok, detail = feature_buildings.describe(arg_after("world.buildings.describe"))
            if ok then return true, "ok world.buildings.describe " .. tostring(detail) end
            return false, "world.buildings.describe failed: " .. tostring(detail)
        end
        -- world.buildings.export <name>
        --   writes ipc/buildings_<name>.json with the registered pieces.
        if line:sub(1, 22) == "world.buildings.export" then
            local ok, detail = feature_buildings.export(arg_after("world.buildings.export"))
            if ok then return true, "ok world.buildings.export " .. tostring(detail) end
            return false, "world.buildings.export failed: " .. tostring(detail)
        end
        -- world.buildings.import <name>
        --   reads ipc/buildings_<name>.json and replays each piece via
        --   UBuildModeComponent.Server_SpawnBuilding. Assumes the
        --   free-build mod (world.foreach BuildingPieceData clear
        --   Requirements) has zeroed costs ; otherwise the spawn RPC
        --   will reject for missing materials.
        if line:sub(1, 22) == "world.buildings.import" then
            local ok, detail = feature_buildings.import(arg_after("world.buildings.import"))
            if ok then return true, "ok world.buildings.import " .. tostring(detail) end
            return false, "world.buildings.import failed: " .. tostring(detail)
        end
        -- world.buildings.list : enumerate available exports.
        if line == "world.buildings.list" then
            local ok, detail = feature_buildings.list()
            if ok then return true, "ok world.buildings.list " .. tostring(detail) end
            return false, "world.buildings.list failed: " .. tostring(detail)
        end
        -- world.buildings.catalog.disk [name]
        --   AssetRegistry sweep of BuildingPieceData on disk
        --   (loaded or not). Writes ipc/building/_catalog_disk.json.
        --   Must precede the world.buildings.catalog check below
        --   because the prefix-23 substring check would otherwise
        --   swallow ".disk" as the name argument.
        if line:sub(1, 28) == "world.buildings.catalog.disk" then
            local ok, detail = feature_buildings.catalog_disk(arg_after("world.buildings.catalog.disk"))
            if ok then return true, "ok world.buildings.catalog.disk " .. tostring(detail) end
            return false, "world.buildings.catalog.disk failed: " .. tostring(detail)
        end
        -- world.buildings.catalog [name]
        --   FindAllOf BuildingPieceData -> dump short_name +
        --   piece_data_index + piece_data_name to
        --   ipc/building/_catalog[_<name>].json. Use to resolve
        --   indices for hand-crafted Server_SpawnBuilding calls or
        --   to seed a delivery JSON without first capturing live
        --   pieces in a world.
        if line:sub(1, 23) == "world.buildings.catalog" then
            local ok, detail = feature_buildings.catalog(arg_after("world.buildings.catalog"))
            if ok then return true, "ok world.buildings.catalog " .. tostring(detail) end
            return false, "world.buildings.catalog failed: " .. tostring(detail)
        end

        -- world.buildings.stability <on|off>
        --   Toggle the building stability simulation. "off" stops the
        --   stability tick + pins every existing piece to max so
        --   replayed structures don't collapse. "on" restores normal
        --   behavior. See feature_buildings.set_stability for the
        --   three independent levers it pulls.
        if line:sub(1, 25) == "world.buildings.stability" then
            local ok, detail = feature_buildings.set_stability(arg_after("world.buildings.stability"))
            if ok then return true, "ok world.buildings.stability " .. tostring(detail) end
            return false, "world.buildings.stability failed: " .. tostring(detail)
        end

        -- world.buildings.protect <on|off>
        --   Background watcher (16ms) that pins bIsGhosted=false +
        --   StabilityValue=1.0 + bIsPreview=false on every live
        --   BaseBuildingActor so the engine's post-spawn validity /
        --   ghost-decay path doesn't auto-destroy force_place'd or
        --   Server_SpawnBuilding'd pieces. Enable BEFORE you fire
        --   build.preview.commit / force_place ; disable after the
        --   structure settles to save CPU.
        if line:sub(1, 23) == "world.buildings.protect" then
            local ok, detail = feature_buildings.set_protect(arg_after("world.buildings.protect"))
            if ok then return true, "ok world.buildings.protect " .. tostring(detail) end
            return false, "world.buildings.protect failed: " .. tostring(detail)
        end

        -- world.buildings.delete_ghosts
        --   K2_DestroyActor every live BaseBuildingActor whose bIsGhosted
        --   is true. Pairs with the WPF "Ghost Building Mode" workflow.
        if line == "world.buildings.delete_ghosts" then
            local ok, detail = feature_buildings.delete_ghosts()
            if ok then return true, "ok world.buildings.delete_ghosts " .. tostring(detail) end
            return false, "world.buildings.delete_ghosts failed: " .. tostring(detail)
        end

        -- world.buildings.commit_ghosts
        --   Flip bIsGhosted=false (and pin StabilityValue=1.0) on every
        --   live BaseBuildingActor whose bIsGhosted is true. Converts
        --   "tentative" placements into real pieces.
        if line == "world.buildings.commit_ghosts" then
            local ok, detail = feature_buildings.commit_ghosts()
            if ok then return true, "ok world.buildings.commit_ghosts " .. tostring(detail) end
            return false, "world.buildings.commit_ghosts failed: " .. tostring(detail)
        end

        -- world.buildings.requirements <save|clear|restore|status>
        --   Manage Requirements TArray on every UBuildingPieceData.
        --   Use save+clear before a Deliver Build that should spawn for
        --   free, then restore once you're done so manual ghost-mode
        --   building works again. status reports the current state.
        if line:sub(1, 28) == "world.buildings.requirements" then
            local ok, detail = feature_buildings.set_requirements(arg_after("world.buildings.requirements"))
            if ok then return true, "ok world.buildings.requirements " .. tostring(detail) end
            return false, "world.buildings.requirements failed: " .. tostring(detail)
        end

        -- world.buildings.rotation.step [deg]
        --   Precision control for the in-game build-preview rotation
        --   snap (the wheel-tick angle in oculus / build mode). Writes
        --   UBuildingSettings.ModifyRotationStepDeg on the CDO. Default
        --   is 15 ; pass 1 for full per-degree control. Read with no
        --   arg. Range clamps to 1..180 (0 freezes, >180 wraps).
        if line:sub(1, 29) == "world.buildings.rotation.step" then
            local ok, detail = feature_buildings.set_rotation_step(arg_after("world.buildings.rotation.step"))
            if ok then return true, "ok world.buildings.rotation.step " .. tostring(detail) end
            return false, "world.buildings.rotation.step failed: " .. tostring(detail)
        end

        -- world.settings.unlock_all
        --   Flip every loaded UDifficultySettingData so PlayerAdjustable
        --   = AllModes (3) and bCanBeChangedAfterWorldCreation = true.
        --   Result : the Main Menu "Edit Settings" panel exposes every
        --   setting on every world (Standard / Hardcore / Custom /
        --   Creative), and post-creation edits are no longer blocked.
        --   Idempotent ; first call snapshots originals so .restore can
        --   undo it.
        if line == "world.settings.unlock_all" then
            local ok, detail = feature_world_settings.apply()
            if ok then return true, "ok world.settings.unlock_all " .. tostring(detail) end
            return false, "world.settings.unlock_all failed: " .. tostring(detail)
        end

        -- world.settings.restore
        --   Walk the snapshot taken by .unlock_all and write the
        --   original PlayerAdjustable / bCanBeChangedAfterWorldCreation
        --   values back. No-op if no snapshot exists.
        if line == "world.settings.restore" then
            local ok, detail = feature_world_settings.restore()
            if ok then return true, "ok world.settings.restore " .. tostring(detail) end
            return false, "world.settings.restore failed: " .. tostring(detail)
        end

        -- world.settings.list
        --   Dump every loaded UDifficultySettingData with its current
        --   PlayerAdjustable + bCanBeChangedAfterWorldCreation values.
        --   Useful for verifying .unlock_all actually took.
        if line == "world.settings.list" then
            local ok, detail = feature_world_settings.list()
            if ok then return true, "ok world.settings.list " .. tostring(detail) end
            return false, "world.settings.list failed: " .. tostring(detail)
        end

        -- world.settings.scan
        --   Enumerate every loaded UDifficultySettingData, write
        --   ipc/world_settings.json (id, name, tag, slider min/max,
        --   PlayerAdjustable, current value, etc.), and stash an
        --   id->asset registry the .set verb can resolve. The World
        --   Service tab calls this on Scan.
        if line == "world.settings.scan" then
            local ok, detail = feature_world_settings.scan()
            if ok then return true, "ok world.settings.scan " .. tostring(detail) end
            return false, "world.settings.scan failed: " .. tostring(detail)
        end

        -- world.settings.set_range <id> <min> <max>
        --   Overwrite the FrontEndSliderData.MinValue/MaxValue on the
        --   target UDifficultySettingData so the in-game World Settings
        --   slider can travel outside its developer-defined bounds.
        --   `id` is the integer the last scan assigned.
        if line:sub(1, 25) == "world.settings.set_range " then
            local ok, detail = feature_world_settings.set_range(line:sub(26))
            if ok then return true, "ok world.settings.set_range " .. tostring(detail) end
            return false, "world.settings.set_range failed: " .. tostring(detail)
        end


        -- world.items.give <ITEM_AssetName> [count]
        --   Resolves the item DataAsset by short name (with an
        --   AssetRegistry sweep cache + LoadAsset fallback) and calls
        --   pc.BP_Components_PersonalInventory:AddItemByData. Backs the
        --   Item Service "Spawn" button.
        if line:sub(1, 17) == "world.items.give " then
            local ok, detail = feature_inventory.give(line:sub(18))
            if ok then return true, "ok world.items.give " .. tostring(detail) end
            return false, "world.items.give failed: " .. tostring(detail)
        end
        -- world.recipes.unlock <RECIPE_AssetName>
        --   Same resolution path as world.items.give, then calls
        --   pc.BP_Components_Progress:UnlockRecipes({recipe}). Backs the
        --   Recipe Service "Unlock" button.
        if line:sub(1, 21) == "world.recipes.unlock " then
            local ok, detail = feature_inventory.unlock_recipe(line:sub(22))
            if ok then return true, "ok world.recipes.unlock " .. tostring(detail) end
            return false, "world.recipes.unlock failed: " .. tostring(detail)
        end
        -- world.buildings.unlock_all
        --   AssetRegistry sweep of every UBuildingPieceData ; bulk
        --   pc.BP_Components_Progress:UnlockBuildings({...}). Backs
        --   the Build Service "Unlock All Buildings" button.
        if line == "world.buildings.unlock_all" then
            local ok, detail = feature_inventory.unlock_all_buildings("")
            if ok then return true, "ok world.buildings.unlock_all " .. tostring(detail) end
            return false, "world.buildings.unlock_all failed: " .. tostring(detail)
        end
        -- world.spells.unlock <SpellAssetName>
        --   Same shape as world.recipes.unlock but for UUtilitySpellData.
        --   Backs the Spell Service "Unlock spell" right-click action.
        if line:sub(1, 20) == "world.spells.unlock " then
            local ok, detail = feature_inventory.unlock_spell(line:sub(21))
            if ok then return true, "ok world.spells.unlock " .. tostring(detail) end
            return false, "world.spells.unlock failed: " .. tostring(detail)
        end
        -- world.spells.unlock_all
        --   AssetRegistry sweep of every UUtilitySpellData ; bulk
        --   pc.BP_Components_Progress:UnlockSpells({...}). Backs the
        --   Spell Service "Unlock All Spells" button.
        if line == "world.spells.unlock_all" then
            local ok, detail = feature_inventory.unlock_all_spells("")
            if ok then return true, "ok world.spells.unlock_all " .. tostring(detail) end
            return false, "world.spells.unlock_all failed: " .. tostring(detail)
        end
        -- world.skills.dump
        --   Dump every entry of pc.SkillComponent.Skills with current
        --   XP / level / max / next-level threshold. Used by Skill
        --   Service to populate / refresh the per-skill cards.
        if line == "world.skills.dump" then
            local ok, detail = feature_skills.dump("")
            if ok then return true, "ok world.skills.dump " .. tostring(detail) end
            return false, "world.skills.dump failed: " .. tostring(detail)
        end

        -- world.skills.add_xp <SKILL_AssetName> <amount>
        if line:sub(1, 20) == "world.skills.add_xp " then
            local ok, detail = feature_skills.add_xp(line:sub(21))
            if ok then return true, "ok world.skills.add_xp " .. tostring(detail) end
            return false, "world.skills.add_xp failed: " .. tostring(detail)
        end
        -- world.skills.set_level <SKILL_AssetName> <level>
        if line:sub(1, 23) == "world.skills.set_level " then
            local ok, detail = feature_skills.set_level(line:sub(24))
            if ok then return true, "ok world.skills.set_level " .. tostring(detail) end
            return false, "world.skills.set_level failed: " .. tostring(detail)
        end

        -- world.assets.classes
        --   AssetRegistry sweep : enumerate every subclass of
        --   DataAsset / PrimaryDataAsset / DominionDataAsset visible
        --   to the cooked build. Output : ipc/assets/_classes.json
        if line == "world.assets.classes" then
            local ok, detail = feature_assets.classes()
            if ok then return true, "ok world.assets.classes " .. tostring(detail) end
            return false, "world.assets.classes failed: " .. tostring(detail)
        end
        -- world.assets.catalog <ClassName>
        --   Sweep every cooked asset of <ClassName> (subclasses
        --   included) and dump ipc/assets/_catalog_<ClassName>.json.
        --   <ClassName> may be bare (defaults to /Script/Dominion),
        --   short-qualified (Engine.PrimaryAssetLabel), or fully
        --   qualified (/Script/Engine.PrimaryAssetLabel).
        if line:sub(1, 20) == "world.assets.catalog" then
            local ok, detail = feature_assets.catalog(arg_after("world.assets.catalog"))
            if ok then return true, "ok world.assets.catalog " .. tostring(detail) end
            return false, "world.assets.catalog failed: " .. tostring(detail)
        end
        -- world.assets.paths [root]
        --   Dump GetSubPaths(root, recursive=true) so we can see what
        --   folder trees exist before scoping a class catalog by path.
        --   Default root is /Game. Output : ipc/assets/_paths_<root>.json
        if line:sub(1, 18) == "world.assets.paths" then
            local ok, detail = feature_assets.paths(arg_after("world.assets.paths"))
            if ok then return true, "ok world.assets.paths " .. tostring(detail) end
            return false, "world.assets.paths failed: " .. tostring(detail)
        end

        -- Round 53: dedicated summon route. Bypasses player.field.call's
        -- reflection-into-CheatManager::Summon path (which uses LoadObject
        -- and fails on un-loaded packages) and instead pipes through
        -- PlayerController:ConsoleCommand("summon ...") which is the same
        -- exec route the in-game `~` console uses and handles asset
        -- on-demand loading + _C class resolution.
        if line:sub(1, 13) == "world.summon " then
            local ok, detail = feature_player.summon(line:sub(14))
            if ok then return true, "ok world.summon " .. tostring(detail) end
            return false, "world.summon failed: " .. tostring(detail)
        end

        -- world.class.load : diagnostic/preload route for the reflected
        -- Kismet soft-class path pipeline. If this succeeds, the class is
        -- now in memory and world.spawn should be able to resolve it via
        -- its normal StaticFindObject fast path.
        if line:sub(1, 17) == "world.class.load " then
            local ok, detail = feature_player.load_class(line:sub(18))
            if ok then return true, "ok world.class.load " .. tostring(detail) end
            return false, "world.class.load failed: " .. tostring(detail)
        end

        -- world.spawn.safe : convenience route for UI/favorites. Prefer the
        -- transform-aware deferred spawn, but fall back to native console
        -- summon for classes that still resist the spawn resolver.
        if line:sub(1, 17) == "world.spawn.safe " then
            local ok, detail = feature_player.spawn_safe(line:sub(18))
            if ok then return true, "ok world.spawn.safe " .. tostring(detail) end
            return false, "world.spawn.safe failed: " .. tostring(detail)
        end

        -- world.spawn.transform : explicit transform variant for tools that
        -- already know world-space placement. Keeps plain world.spawn's
        -- aim-trace/default-scale contract untouched for the Summon view.
        if line:sub(1, 22) == "world.spawn.transform " then
            local ok, detail = feature_player.spawn_transform(line:sub(23))
            if ok then return true, "ok world.spawn.transform " .. tostring(detail) end
            return false, "world.spawn.transform failed: " .. tostring(detail)
        end

        -- world.spawn : transform-aware counterpart to world.summon. Routes
        -- through UGameplayStatics::BeginDeferredActorSpawnFromClass +
        -- FinishSpawningActor so we get (a) aim-trace location instead of
        -- PC origin, (b) a deferred init window for required UPROPERTYs.
        -- Optional JSON tail :  world.spawn <ClassPath> {"ItemData":"/Game/.../IT_X.IT_X"}
        if line:sub(1, 12) == "world.spawn " then
            local ok, detail = feature_player.spawn(line:sub(13))
            if ok then return true, "ok world.spawn " .. tostring(detail) end
            return false, "world.spawn failed: " .. tostring(detail)
        end

        -- world.spawn.item : the WorldItemSubsystem-aware variant. Routes
        -- through UItemHelperLibrary::SpawnAndLaunchItem_Sync, the same
        -- function the game uses internally for every loot drop / craft
        -- output. Result is a fully-wired pickup (collect grants the item,
        -- magnet pull works, inventory queries see it). world.spawn alone
        -- gets you a visible-but-broken pickup because it only constructs
        -- the actor without enrolling it with the subsystem.
        if line:sub(1, 17) == "world.spawn.item " then
            local ok, detail = feature_player.spawn_item(line:sub(18))
            if ok then return true, "ok world.spawn.item " .. tostring(detail) end
            return false, "world.spawn.item failed: " .. tostring(detail)
        end

        -- world.bookmark <slot> -- stash the current `lastspawned` actor
        -- under <slot> so it can be referenced later via the
        -- `slot:<slot>` reach root. Solves the wiring problem when you
        -- need to refer to actor A *after* spawning actor B (B becomes
        -- the new lastspawned, A would otherwise be unreachable).
        -- Bookmarks are session-only ; UObject pointers don't survive
        -- save/reload, but they don't need to -- only the live
        -- configure-then-save flow uses them.
        if line:sub(1, 15) == "world.bookmark " then
            local slot = line:sub(16):match("^%s*(%S+)%s*$")
            if not slot then return false, "usage: world.bookmark <slot>" end
            local ok, detail = feature_field.bookmark_last_spawned(slot)
            if ok then return true, "ok world.bookmark " .. tostring(detail) end
            return false, "world.bookmark failed: " .. tostring(detail)
        end
        if line:sub(1, 22) == "world.bookmark.forget " then
            local slot = line:sub(23):match("^%s*(%S+)%s*$")
            if not slot then return false, "usage: world.bookmark.forget <slot>" end
            local ok, detail = feature_field.forget_bookmark(slot)
            if ok then return true, "ok world.bookmark.forget " .. tostring(detail) end
            return false, "world.bookmark.forget failed: " .. tostring(detail)
        end
        if line == "world.bookmark.list" then
            local entries = feature_field.list_bookmarks()
            if #entries == 0 then return true, "ok world.bookmark.list (empty)" end
            return true, "ok world.bookmark.list " .. table.concat(entries, ",")
        end

        -- world.net.roster : passive roster snapshot for the WPF Multi
        -- tab. Returns a single-line JSON array in the ack body so the
        -- viewer can parse without a follow-up file read.
        if line == "world.net.roster" then
            return true, feature_net.json_roster()
        end

        -- world.time.release (reset visual override)
        if line == "world.time.release" then
            local ok, detail = feature_world.release_time()
            if ok then return true, "ok world.time.release " .. tostring(detail) end
            return false, "world.time.release failed: " .. tostring(detail)
        end

        -- world.time.probe -- read-only dump (must be checked before the
        -- generic `world.time <hour>` prefix so it isn't swallowed).
        if line == "world.time.probe" then
            local ok, detail = feature_world.probe_time()
            if ok then return true, "ok world.time.probe " .. tostring(detail) end
            return false, "world.time.probe failed: " .. tostring(detail)
        end

        -- world.time <hour>
        if line:sub(1, 10) == "world.time" and line:sub(1, 16) ~= "world.time.pause"
            and line:sub(1, 16) ~= "world.time.speed"
            and line:sub(1, 16) ~= "world.time.probe" then
            local val = arg_after("world.time")
            if val == "" then return false, "usage: world.time <hour 0-24>" end
            local ok, detail = feature_world.set_time(val)
            if ok then return true, "ok world.time " .. tostring(detail) end
            return false, "world.time failed: " .. tostring(detail)
        end

        -- world.time.pause <on|off>
        if line:sub(1, 16) == "world.time.pause" then
            local val = arg_after("world.time.pause")
            if val == "" then return false, "usage: world.time.pause <on|off>" end
            local ok, detail = feature_world.pause_time(val)
            if ok then return true, "ok world.time.pause " .. tostring(detail) end
            return false, "world.time.pause failed: " .. tostring(detail)
        end

        -- world.time.speed <minutes>
        if line:sub(1, 16) == "world.time.speed" then
            local val = arg_after("world.time.speed")
            if val == "" then return false, "usage: world.time.speed <minutes>" end
            local ok, detail = feature_world.set_day_speed(val)
            if ok then return true, "ok world.time.speed " .. tostring(detail) end
            return false, "world.time.speed failed: " .. tostring(detail)
        end

        -- world.dawn <hour>
        if line:sub(1, 10) == "world.dawn" then
            local val = arg_after("world.dawn")
            if val == "" then return false, "usage: world.dawn <hour 0-24>" end
            local ok, detail = feature_world.set_dawn(val)
            if ok then return true, "ok world.dawn " .. tostring(detail) end
            return false, "world.dawn failed: " .. tostring(detail)
        end

        -- world.dusk <hour>
        if line:sub(1, 10) == "world.dusk" then
            local val = arg_after("world.dusk")
            if val == "" then return false, "usage: world.dusk <hour 0-24>" end
            local ok, detail = feature_world.set_dusk(val)
            if ok then return true, "ok world.dusk " .. tostring(detail) end
            return false, "world.dusk failed: " .. tostring(detail)
        end

        -- world.storedtime <hour>  (round 25: persistent game-clock write)
        if line:sub(1, 16) == "world.storedtime" then
            local val = arg_after("world.storedtime")
            if val == "" then return false, "usage: world.storedtime <hour 0-24>" end
            local ok, detail = feature_world.set_storedtime(val)
            if ok then return true, "ok world.storedtime " .. tostring(detail) end
            return false, "world.storedtime failed: " .. tostring(detail)
        end

        -- world.weather <type>
        -- Exclusions cover every more-specific world.weather.* verb below.
        if line:sub(1, 13) == "world.weather"
            and line:sub(1, 19) ~= "world.weather.pause"
            and line:sub(1, 19) ~= "world.weather.probe"
            and line:sub(1, 19) ~= "world.weather.where"
            and line:sub(1, 18) ~= "world.weather.list"
            and line:sub(1, 22) ~= "world.weather.regional"
            and line:sub(1, 29) ~= "world.weather.region_priority" then
            local val = arg_after("world.weather")
            if val == "" then return false, "usage: world.weather <0-8 or name>" end
            local ok, detail = feature_world.set_weather(val)
            if ok then return true, "ok world.weather " .. tostring(detail) end
            return false, "world.weather failed: " .. tostring(detail)
        end

        -- world.weather.pause <on|off>
        if line:sub(1, 19) == "world.weather.pause" then
            local val = arg_after("world.weather.pause")
            if val == "" then return false, "usage: world.weather.pause <on|off>" end
            local ok, detail = feature_world.pause_weather(val)
            if ok then return true, "ok world.weather.pause " .. tostring(detail) end
            return false, "world.weather.pause failed: " .. tostring(detail)
        end

        -- world.weather.probe -- read-only dump of subsystem + regional state
        if line == "world.weather.probe" then
            local ok, detail = feature_world.probe_weather()
            if ok then return true, "ok world.weather.probe " .. tostring(detail) end
            return false, "world.weather.probe failed: " .. tostring(detail)
        end

        -- world.weather.where -- GetWeatherAtLocation(player)
        if line == "world.weather.where" then
            local ok, detail = feature_world.weather_where()
            if ok then return true, "ok world.weather.where " .. tostring(detail) end
            return false, "world.weather.where failed: " .. tostring(detail)
        end

        -- world.weather.list -- enumerate every accepted EWeatherType value +
        --   alias. Useful for UI dropdowns ; detail is pipe-delimited.
        if line == "world.weather.list" then
            local ok, detail = feature_world.weather_list()
            if ok then return true, "ok world.weather.list " .. tostring(detail) end
            return false, "world.weather.list failed: " .. tostring(detail)
        end

        -- world.weather.regional <type> -- raw : write WeatherType on every
        --   UDynamicRegionalWeather + UStaticRegionalWeather (bypass
        --   TrySetWeather to test if regional state is overriding it).
        if line:sub(1, 22) == "world.weather.regional" then
            local val = arg_after("world.weather.regional")
            if val == "" then return false, "usage: world.weather.regional <0-8 or name>" end
            local ok, detail = feature_world.set_regional_weather(val)
            if ok then return true, "ok world.weather.regional " .. tostring(detail) end
            return false, "world.weather.regional failed: " .. tostring(detail)
        end

        -- world.weather.region_priority <int> -- raw : write Priority on
        --   every ARegionSpecificGlobalWeatherActor (composite priority test).
        if line:sub(1, 29) == "world.weather.region_priority" then
            local val = arg_after("world.weather.region_priority")
            if val == "" then return false, "usage: world.weather.region_priority <int>" end
            local ok, detail = feature_world.set_region_priority(val)
            if ok then return true, "ok world.weather.region_priority " .. tostring(detail) end
            return false, "world.weather.region_priority failed: " .. tostring(detail)
        end

        return false, "unknown world.* verb"
    end

    -- actor.* verbs. Must check BEFORE the generic "tele"/"scan" prefix checks so
    -- "actor.scale" doesn't get swallowed by a future shorter prefix, and because
    -- these compound verbs are routed together.
    if line:sub(1, 6) == "actor." then
        -- actor.goto <name>
        if line:sub(1, 10) == "actor.goto" then
            local name = select(1, split_actor_body(line, 10))
            if not name then
                return false, "usage: actor.goto <name>"
            end
            local ok, detail = feature_actor.goto_actor(name)
            if ok then return true, "ok actor.goto " .. tostring(detail or name) end
            return false, "actor.goto failed: " .. tostring(detail)
        end

        -- actor.bring <name>
        if line:sub(1, 11) == "actor.bring" then
            local name = select(1, split_actor_body(line, 11))
            if not name then
                return false, "usage: actor.bring <name>"
            end
            local ok, detail = feature_actor.bring_actor(name)
            if ok then return true, "ok actor.bring " .. tostring(detail or name) end
            return false, "actor.bring failed: " .. tostring(detail)
        end

        -- actor.del <name>
        if line:sub(1, 9) == "actor.del" then
            local name = select(1, split_actor_body(line, 9))
            if not name then
                return false, "usage: actor.del <name>"
            end
            local ok, detail = feature_actor.delete_actor(name)
            if ok then return true, "ok actor.del " .. tostring(detail or name) end
            return false, "actor.del failed: " .. tostring(detail)
        end

        -- actor.vis <name> [on|off]
        if line:sub(1, 9) == "actor.vis" then
            local name, tail = split_actor_body(line, 9)
            if not name then
                return false, "usage: actor.vis <name> [on|off]"
            end
            local ok, detail = feature_actor.set_visibility(name, tail)
            if ok then return true, "ok actor.vis " .. name .. " " .. tostring(detail) end
            return false, "actor.vis failed: " .. tostring(detail)
        end

        -- actor.col <name> [on|off]
        if line:sub(1, 9) == "actor.col" then
            local name, tail = split_actor_body(line, 9)
            if not name then
                return false, "usage: actor.col <name> [on|off]"
            end
            local ok, detail = feature_actor.set_collision(name, tail)
            if ok then return true, "ok actor.col " .. name .. " " .. tostring(detail) end
            return false, "actor.col failed: " .. tostring(detail)
        end

        -- actor.spectate.reset -- MUST be checked BEFORE actor.spectate (the
        -- shorter prefix would otherwise swallow the longer match and try to
        -- treat "reset" as an actor name).
        if line == "actor.spectate.reset" or line:sub(1, 21) == "actor.spectate.reset " then
            local ok, detail = feature_actor.spectate_reset()
            if ok then return true, "ok actor.spectate.reset " .. tostring(detail) end
            return false, "actor.spectate.reset failed: " .. tostring(detail)
        end

        -- actor.spectate <name> -- point the camera at a named actor via
        -- SetViewTargetWithBlend. Pawn input still drives the real character
        -- in the background; this is pure view decoupling.
        if line:sub(1, 14) == "actor.spectate" then
            local name = select(1, split_actor_body(line, 14))
            if not name then
                return false, "usage: actor.spectate <name>"
            end
            local ok, detail = feature_actor.spectate_actor(name)
            if ok then return true, "ok actor.spectate " .. tostring(detail or name) end
            return false, "actor.spectate failed: " .. tostring(detail)
        end

        -- actor.info.field <name> <segments>   (must come before actor.info ;
        -- longest-prefix match.) <segments> is dot-separated property names.
        if line:sub(1, 16) == "actor.info.field" then
            local body = line:sub(17)
            -- split body into "<name> <path>"
            body = body:match("^%s*(.-)%s*$") or ""
            local name, path = body:match("^(%S+)%s+(.+)$")
            if not name then
                name = body
                path = ""
            end
            if not name or name == "" then
                return false, "usage: actor.info.field <name> <seg>[.<seg>...]"
            end
            local ok, detail = feature_introspect.dump_actor_field(name, path)
            if ok then return true, "ok actor.info.field " .. tostring(detail) end
            return false, "actor.info.field failed: " .. tostring(detail)
        end

        -- actor.info <name>
        if line:sub(1, 10) == "actor.info" then
            local name = select(1, split_actor_body(line, 10))
            if not name or name == "" then
                return false, "usage: actor.info <name>"
            end
            local ok, detail = feature_introspect.dump_actor(name)
            if ok then return true, "ok actor.info " .. tostring(detail) end
            return false, "actor.info failed: " .. tostring(detail)
        end

        -- actor.scale <name> [value]
        if line:sub(1, 11) == "actor.scale" then
            local name, tail = split_actor_body(line, 11)
            if not name then
                return false, "usage: actor.scale <name> [value]"
            end
            if tail == nil or tail == "" then
                local ok, detail = feature_actor.get_scale_uniform(name)
                if ok then return true, tostring(detail) end
                return false, "actor.scale failed: " .. tostring(detail)
            end
            local ok, detail = feature_actor.set_scale_uniform(name, tail)
            if ok then return true, "ok actor.scale " .. name .. " " .. tostring(detail) end
            return false, "actor.scale failed: " .. tostring(detail)
        end

        return false, "unknown actor.* verb"
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
    --   camera.grab.release         drop in place
    --   camera.grab.cancel          drop and restore start transform
    --   camera.grab.status          report state
    --   camera.grab.mode <m>        m in {move,rot,z,scale}
    --   camera.grab.delta <signed>  one wheel-tick in the active mode
    --   camera.grab.rotate <signed> dedicated yaw nudge (mode-independent)
    --   camera.grab.start [name]    latch named (or look-at) actor
    --   camera.lookat               probe what the camera trace hits
    --   camera.destroy.lookat       destroy actor under the active camera reticle
    if line == "camera.debug.status" then
        local ok, detail = feature_camera.status()
        if ok then return true, "ok camera.debug.status " .. tostring(detail) end
        return false, "camera.debug.status failed: " .. tostring(detail)
    end
    if line == "camera.streaming.status" then
        local ok, detail = feature_camera.streaming_status()
        if ok then return true, "ok camera.streaming.status " .. tostring(detail) end
        return false, "camera.streaming.status failed: " .. tostring(detail)
    end
    if line == "camera.streaming.scale" or line:sub(1, 23) == "camera.streaming.scale " then
        local arg = line:sub(24):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.streaming_scale(arg)
        if ok then return true, "ok camera.streaming.scale " .. tostring(detail) end
        return false, "camera.streaming.scale failed: " .. tostring(detail)
    end
    if line == "camera.streaming.reset" then
        local ok, detail = feature_camera.streaming_reset()
        if ok then return true, "ok camera.streaming.reset " .. tostring(detail) end
        return false, "camera.streaming.reset failed: " .. tostring(detail)
    end
    if line == "camera.lod.status" or line:sub(1, 18) == "camera.lod.status " then
        local arg = line:sub(19):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.lod_status(arg)
        if ok then return true, "ok camera.lod.status " .. tostring(detail) end
        return false, "camera.lod.status failed: " .. tostring(detail)
    end
    if line == "camera.lod.force" or line:sub(1, 17) == "camera.lod.force " then
        local arg = line:sub(18):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.lod_force(arg)
        if ok then return true, "ok camera.lod.force " .. tostring(detail) end
        return false, "camera.lod.force failed: " .. tostring(detail)
    end
    if line == "camera.lod.reset" then
        local ok, detail = feature_camera.lod_reset()
        if ok then return true, "ok camera.lod.reset " .. tostring(detail) end
        return false, "camera.lod.reset failed: " .. tostring(detail)
    end
    if line == "camera.rig.status" then
        local ok, detail = feature_camera.rig_status()
        if ok then return true, "ok camera.rig.status " .. tostring(detail) end
        return false, "camera.rig.status failed: " .. tostring(detail)
    end
    if line == "camera.rig.start" or line:sub(1, 17) == "camera.rig.start " then
        local arg = line:sub(18):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_start(arg)
        if ok then return true, "ok camera.rig.start " .. tostring(detail) end
        return false, "camera.rig.start failed: " .. tostring(detail)
    end
    if line == "camera.rig.stop" then
        local ok, detail = feature_camera.rig_stop()
        if ok then return true, "ok camera.rig.stop " .. tostring(detail) end
        return false, "camera.rig.stop failed: " .. tostring(detail)
    end
    if line == "camera.rig.list" then
        local ok, detail = feature_camera.rig_list()
        if ok then return true, "ok camera.rig.list " .. tostring(detail) end
        return false, "camera.rig.list failed: " .. tostring(detail)
    end
    if line == "camera.rig.clear" then
        local ok, detail = feature_camera.rig_clear()
        if ok then return true, "ok camera.rig.clear " .. tostring(detail) end
        return false, "camera.rig.clear failed: " .. tostring(detail)
    end
    if line:sub(1, 19) == "camera.rig.pose.set" then
        local arg = line:sub(20):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_pose_set(arg)
        if ok then return true, "ok camera.rig.pose.set " .. tostring(detail) end
        return false, "camera.rig.pose.set failed: " .. tostring(detail)
    end
    if line == "camera.rig.poses.file" or line:sub(1, 22) == "camera.rig.poses.file " then
        local arg = line:sub(23):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_poses_file(arg)
        if ok then return true, "ok camera.rig.poses.file " .. tostring(detail) end
        return false, "camera.rig.poses.file failed: " .. tostring(detail)
    end
    if line:sub(1, 17) == "camera.rig.delete" then
        local arg = line:sub(18):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_delete(arg)
        if ok then return true, "ok camera.rig.delete " .. tostring(detail) end
        return false, "camera.rig.delete failed: " .. tostring(detail)
    end
    if line:sub(1, 18) == "camera.rig.capture" then
        local arg = line:sub(19):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_capture(arg)
        if ok then return true, "ok camera.rig.capture " .. tostring(detail) end
        return false, "camera.rig.capture failed: " .. tostring(detail)
    end
    if line == "camera.rig.goto.file" or line:sub(1, 21) == "camera.rig.goto.file " then
        local arg = line:sub(22):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_goto_file(arg)
        if ok then return true, "ok camera.rig.goto.file " .. tostring(detail) end
        return false, "camera.rig.goto.file failed: " .. tostring(detail)
    end
    if line:sub(1, 15) == "camera.rig.goto" then
        local arg = line:sub(16):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_goto(arg)
        if ok then return true, "ok camera.rig.goto " .. tostring(detail) end
        return false, "camera.rig.goto failed: " .. tostring(detail)
    end
    if line == "camera.rig.play.stop" then
        local ok, detail = feature_camera.rig_play_stop()
        if ok then return true, "ok camera.rig.play.stop " .. tostring(detail) end
        return false, "camera.rig.play.stop failed: " .. tostring(detail)
    end
    if line == "camera.rig.play.file" or line:sub(1, 21) == "camera.rig.play.file " then
        local arg = line:sub(22):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_play_file(arg)
        if ok then return true, "ok camera.rig.play.file " .. tostring(detail) end
        return false, "camera.rig.play.file failed: " .. tostring(detail)
    end
    if line == "camera.rig.play.chain" or line:sub(1, 22) == "camera.rig.play.chain " then
        local arg = line:sub(23):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_play_chain(arg)
        if ok then return true, "ok camera.rig.play.chain " .. tostring(detail) end
        return false, "camera.rig.play.chain failed: " .. tostring(detail)
    end
    if line:sub(1, 15) == "camera.rig.play" then
        local arg = line:sub(16):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_play(arg)
        if ok then return true, "ok camera.rig.play " .. tostring(detail) end
        return false, "camera.rig.play failed: " .. tostring(detail)
    end
    if line:sub(1, 14) == "camera.rig.fov" then
        local arg = line:sub(15):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_fov(arg)
        if ok then return true, "ok camera.rig.fov " .. tostring(detail) end
        return false, "camera.rig.fov failed: " .. tostring(detail)
    end
    if line == "camera.fps" or line:sub(1, 11) == "camera.fps " then
        local arg = line:sub(12):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.fps(arg)
        if ok then return true, "ok camera.fps " .. tostring(detail) end
        return false, "camera.fps failed: " .. tostring(detail)
    end
    if line == "camera.vsync" or line:sub(1, 13) == "camera.vsync " then
        local arg = line:sub(14):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.vsync(arg)
        if ok then return true, "ok camera.vsync " .. tostring(detail) end
        return false, "camera.vsync failed: " .. tostring(detail)
    end
    if line == "camera.rig.lookat" or line:sub(1, 18) == "camera.rig.lookat " then
        local arg = line:sub(19):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_lookat(arg)
        if ok then return true, "ok camera.rig.lookat " .. tostring(detail) end
        return false, "camera.rig.lookat failed: " .. tostring(detail)
    end
    if line == "camera.debug.enable" then
        local ok, detail = feature_camera.enable()
        if ok then return true, "ok camera.debug.enable " .. tostring(detail) end
        return false, "camera.debug.enable failed: " .. tostring(detail)
    end
    if line == "camera.debug.disable" then
        local ok, detail = feature_camera.disable()
        if ok then return true, "ok camera.debug.disable " .. tostring(detail) end
        return false, "camera.debug.disable failed: " .. tostring(detail)
    end
    if line == "camera.debug.toggle" then
        local ok, detail = feature_camera.toggle()
        if ok then return true, "ok camera.debug.toggle " .. tostring(detail) end
        return false, "camera.debug.toggle failed: " .. tostring(detail)
    end
    if line == "camera.debug.force_restore" then
        local ok, detail = feature_camera.force_restore()
        if ok then return true, "ok camera.debug.force_restore " .. tostring(detail) end
        return false, "camera.debug.force_restore failed: " .. tostring(detail)
    end
    if line == "camera.debug.display" then
        local ok, detail = feature_camera.display()
        if ok then return true, "ok camera.debug.display " .. tostring(detail) end
        return false, "camera.debug.display failed: " .. tostring(detail)
    end
    if line == "camera.debug.selected" then
        local ok, detail = feature_camera.selected()
        if ok then return true, "ok camera.debug.selected " .. tostring(detail) end
        return false, "camera.debug.selected failed: " .. tostring(detail)
    end
    if line == "camera.debug.speed" or line:sub(1, 19) == "camera.debug.speed " then
        local arg = line:sub(20):match("^%s*(.-)%s*$") or ""
        if arg == "" then return false, "usage: camera.debug.speed <scale>" end
        local ok, detail = feature_camera.speed(arg)
        if ok then return true, "ok camera.debug.speed " .. tostring(detail) end
        return false, "camera.debug.speed failed: " .. tostring(detail)
    end
    if line == "camera.oculus.status" then
        local ok, detail = feature_oculus.status()
        if ok then return true, "ok camera.oculus.status " .. tostring(detail) end
        return false, "camera.oculus.status failed: " .. tostring(detail)
    end
    if line == "camera.oculus.start" then
        local ok, detail = feature_oculus.start()
        if ok then
            local active_ok, active_detail = feature_oculus.require_state("active")
            if not active_ok then
                return false, "camera.oculus.start init blocked: " .. tostring(active_detail)
            end
            local init_ok, init_detail = feature_oculus_config.run_init(function(cmd)
                return M.handle_line(cmd)
            end)
            if init_ok then
                local help_ok, help_detail = feature_oculus_config.show_hotkey_help(function(cmd)
                    return M.handle_line(cmd)
                end)
                if help_ok then return true, "ok camera.oculus.start " .. tostring(detail) .. "; " .. tostring(init_detail) .. "; " .. tostring(help_detail) end
                return false, "camera.oculus.start help failed: " .. tostring(help_detail)
            end
            return false, "camera.oculus.start init failed: " .. tostring(init_detail)
        end
        return false, "camera.oculus.start failed: " .. tostring(detail)
    end
    if line == "camera.oculus.help" or line:sub(1, 19) == "camera.oculus.help " then
        local arg = line:sub(20):match("^%s*(.-)%s*$") or ""
        local ok, detail
        if arg == "" then
            ok, detail = feature_oculus_config.set_hotkey_help_visibility("on")
        else
            ok, detail = feature_oculus_config.set_hotkey_help_visibility(arg)
        end
        if ok then return true, "ok camera.oculus.help " .. tostring(detail) end
        return false, "camera.oculus.help failed: " .. tostring(detail)
    end
    if line == "camera.oculus.umg" or line:sub(1, 18) == "camera.oculus.umg " then
        local arg = line:sub(19):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_config.set_hotkey_help_visibility(arg)
        if ok then return true, "ok camera.oculus.umg " .. tostring(detail) end
        return false, "camera.oculus.umg failed: " .. tostring(detail)
    end
    if line == "camera.oculus.init" then
        local active_ok, active_detail = feature_oculus.require_state("active")
        if not active_ok then return false, "camera.oculus.init failed: " .. tostring(active_detail) end
        local init_ok, init_detail = feature_oculus_config.run_init(function(cmd)
            return M.handle_line(cmd)
        end)
        if init_ok then
            local help_ok, help_detail = feature_oculus_config.show_hotkey_help(function(cmd)
                return M.handle_line(cmd)
            end)
            if help_ok then return true, "ok camera.oculus.init " .. tostring(init_detail) .. "; " .. tostring(help_detail) end
            return false, "camera.oculus.init help failed: " .. tostring(help_detail)
        end
        return false, "camera.oculus.init failed: " .. tostring(init_detail)
    end
    if line == "camera.oculus.stop" then
        local ok, detail = feature_oculus.stop()
        if ok then
            local exit_ok, exit_detail = feature_oculus_config.run_exit(function(cmd)
                return M.handle_line(cmd)
            end)
            feature_oculus_config.hide_hotkey_help()
            if exit_ok then return true, "ok camera.oculus.stop " .. tostring(detail) .. "; " .. tostring(exit_detail) end
            return false, "camera.oculus.stop exit failed: " .. tostring(exit_detail)
        end
        return false, "camera.oculus.stop failed: " .. tostring(detail)
    end
    if line == "camera.oculus.exit" then
        local ok, detail = feature_oculus_config.run_exit(function(cmd)
            return M.handle_line(cmd)
        end, true)
        if ok then return true, "ok camera.oculus.exit " .. tostring(detail) end
        return false, "camera.oculus.exit failed: " .. tostring(detail)
    end
    if line == "camera.oculus.toggle" then
        local ok, detail = feature_oculus.toggle()
        if ok then
            local active_ok = feature_oculus.require_state("active")
            if active_ok then
                feature_oculus_config.show_hotkey_help(function(cmd)
                    return M.handle_line(cmd)
                end)
            else
                local exit_ok, exit_detail = feature_oculus_config.run_exit(function(cmd)
                    return M.handle_line(cmd)
                end)
                feature_oculus_config.hide_hotkey_help()
                if not exit_ok then return false, "camera.oculus.toggle exit failed: " .. tostring(exit_detail) end
                detail = tostring(detail) .. "; " .. tostring(exit_detail)
            end
            return true, "ok camera.oculus.toggle " .. tostring(detail)
        end
        return false, "camera.oculus.toggle failed: " .. tostring(detail)
    end
    if line == "camera.oculus.require" or line:sub(1, 22) == "camera.oculus.require " then
        local arg = line:sub(23):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus.require_state(arg)
        if ok then return true, "ok camera.oculus.require " .. tostring(detail) end
        return false, "camera.oculus.require failed: " .. tostring(detail)
    end
    if line == "camera.oculus.speed" or line:sub(1, 20) == "camera.oculus.speed " then
        local arg = line:sub(21):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus.speed(arg)
        if ok then return true, "ok camera.oculus.speed " .. tostring(detail) end
        return false, "camera.oculus.speed failed: " .. tostring(detail)
    end
    if line == "camera.oculus.distance" or line:sub(1, 23) == "camera.oculus.distance " then
        local arg = line:sub(24):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus.distance(arg)
        if ok then return true, "ok camera.oculus.distance " .. tostring(detail) end
        return false, "camera.oculus.distance failed: " .. tostring(detail)
    end
    if line == "camera.oculus.vignette" or line:sub(1, 23) == "camera.oculus.vignette " then
        local arg = line:sub(24):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus.vignette(arg)
        if ok then return true, "ok camera.oculus.vignette " .. tostring(detail) end
        return false, "camera.oculus.vignette failed: " .. tostring(detail)
    end
    if line == "camera.oculus.watermark" or line:sub(1, 24) == "camera.oculus.watermark " then
        local arg = line:sub(25):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus.watermark(arg)
        if ok then return true, "ok camera.oculus.watermark " .. tostring(detail) end
        return false, "camera.oculus.watermark failed: " .. tostring(detail)
    end
    if line:sub(1, 19) == "camera.grab.release" then
        local ok, detail = feature_grab.release()
        if ok then return true, "ok camera.grab.release " .. tostring(detail) end
        return false, "camera.grab.release failed: " .. tostring(detail)
    end
    if line:sub(1, 18) == "camera.grab.cancel" then
        local ok, detail = feature_grab.cancel()
        if ok then return true, "ok camera.grab.cancel " .. tostring(detail) end
        return false, "camera.grab.cancel failed: " .. tostring(detail)
    end
    if line:sub(1, 18) == "camera.grab.status" then
        local ok, detail = feature_grab.status()
        if ok then return true, "ok camera.grab.status " .. tostring(detail) end
        return false, "camera.grab.status failed: " .. tostring(detail)
    end
    if line:sub(1, 17) == "camera.grab.delta" then
        local arg = line:sub(18):match("^%s*(.-)%s*$") or ""
        if arg == "" then return false, "usage: camera.grab.delta <signed-number>" end
        local ok, detail = feature_grab.delta(arg)
        if ok then return true, "ok camera.grab.delta " .. tostring(detail) end
        return false, "camera.grab.delta failed: " .. tostring(detail)
    end
    if line:sub(1, 18) == "camera.grab.rotate" then
        local arg = line:sub(19):match("^%s*(.-)%s*$") or ""
        if arg == "" then return false, "usage: camera.grab.rotate <signed-number>" end
        local ok, detail = feature_grab.rotate(arg)
        if ok then return true, "ok camera.grab.rotate " .. tostring(detail) end
        return false, "camera.grab.rotate failed: " .. tostring(detail)
    end
    if line:sub(1, 17) == "camera.grab.scale" then
        local arg = line:sub(18):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_grab.scale_delta(arg ~= "" and arg or "1")
        if ok then return true, "ok camera.grab.scale " .. tostring(detail) end
        return false, "camera.grab.scale failed: " .. tostring(detail)
    end
    if line:sub(1, 16) == "camera.grab.lift" then
        local arg = line:sub(17):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_grab.lift(arg ~= "" and arg or "1")
        if ok then return true, "ok camera.grab.lift " .. tostring(detail) end
        return false, "camera.grab.lift failed: " .. tostring(detail)
    end
    if line:sub(1, 18) == "camera.grab.toggle" then
        local arg = line:sub(19):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_grab.toggle(arg ~= "" and arg or nil)
        if ok then return true, "ok camera.grab.toggle " .. tostring(detail) end
        return false, "camera.grab.toggle failed: " .. tostring(detail)
    end
    if line == "camera.grab.lastspawned" then
        local ok, detail = feature_grab.start_lastspawned()
        if ok then return true, "ok camera.grab.lastspawned " .. tostring(detail) end
        return false, "camera.grab.lastspawned failed: " .. tostring(detail)
    end
    if line:sub(1, 17) == "camera.grab.start" then
        local arg = line:sub(18):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_grab.start(arg ~= "" and arg or nil)
        if ok then return true, "ok camera.grab.start " .. tostring(detail) end
        return false, "camera.grab.start failed: " .. tostring(detail)
    end
    if line:sub(1, 16) == "camera.grab.mode" then
        local arg = line:sub(17):match("^%s*(.-)%s*$") or ""
        if arg == "" then return false, "usage: camera.grab.mode <move|rot|z|scale>" end
        local ok, detail = feature_grab.mode(arg)
        if ok then return true, "ok camera.grab.mode " .. tostring(detail) end
        return false, "camera.grab.mode failed: " .. tostring(detail)
    end
    if line:sub(1, 13) == "camera.lookat" then
        local ok, detail = feature_grab.lookat()
        if ok then return true, "ok camera.lookat " .. tostring(detail) end
        return false, "camera.lookat failed: " .. tostring(detail)
    end
    if line == "camera.destroy.lookat" then
        local ok, detail = feature_grab.destroy_lookat()
        if ok then return true, "ok camera.destroy.lookat " .. tostring(detail) end
        return false, "camera.destroy.lookat failed: " .. tostring(detail)
    end

    if line:sub(1, 4) == "tele" then
        local x, y, z = parse_tele(line)
        if not x then
            return false, y
        end
        local ok, err = feature_teleport.teleport_now(x, y, z)
        if ok then
            return true, string.format("ok tele %.3f %.3f %.3f", x, y, z)
        end
        return false, "tele failed: " .. tostring(err)
    end

    if line:sub(1, 4) == "scan" then
        local query, mode, perr = parse_scan(line)
        if not query then
            return false, perr
        end
        local ok_scan, result = feature_scan.run_scan(query, mode)
        if ok_scan then
            return true, tostring(result or "ok scan")
        end
        return false, tostring(result or "scan failed")
    end

    local tab = line:match("^ui%.tab%s+([%w_%-]+)%s*$")
    if tab then
        local normalized = tab:lower()
        if normalized == "tele" then
            normalized = "teleport"
        end
        -- Accept "home" as an alias for "player" so older WPF builds keep working.
        if normalized == "home" then
            normalized = "player"
        end
        -- Round 53: ui.tab is a fire-and-forget courtesy from the WPF side
        -- on tab change. feature_umg no longer owns a tabbed overlay (it's
        -- a transient toast now) so this is a soft no-op. We used to
        -- reject unknown tab names, but that produced misleading status
        -- text whenever the WPF added a new section (Summon, Catalog, ...)
        -- because the rejected ack would race into the next sync send's
        -- ack slot. Just always ack ok; the tab name is purely advisory.
        if feature_umg and feature_umg.set_external_tab then
            pcall(function() feature_umg.set_external_tab(normalized) end)
        end
        return true, "ok ui.tab " .. normalized
    end

    -- Phase 2.7: HUD widget control. These are outside the player.* block
    -- because the verb starts with "ui.", not "player.".
    if line == "ui.widgets.scan" then
        local ok, detail = feature_ui.scan_widgets("all")
        if ok then return true, "ok ui.widgets.scan " .. tostring(detail) end
        return false, "ui.widgets.scan failed: " .. tostring(detail)
    end
    if line:sub(1, 16) == "ui.widgets.scan " then
        local scope = line:sub(17):match("^%s*(%S+)") or "all"
        local ok, detail = feature_ui.scan_widgets(scope)
        if ok then return true, "ok ui.widgets.scan " .. tostring(detail) end
        return false, "ui.widgets.scan failed: " .. tostring(detail)
    end
    if line:sub(1, 18) == "ui.widgets.setvis " then
        local ok, detail = feature_ui.set_widget_vis(line:sub(19))
        if ok then return true, "ok ui.widgets.setvis " .. tostring(detail) end
        return false, "ui.widgets.setvis failed: " .. tostring(detail)
    end
    if line:sub(1, 20) == "ui.widgets.activate " then
        local ok, detail = feature_ui.activate_widget(line:sub(21))
        if ok then return true, "ok ui.widgets.activate " .. tostring(detail) end
        return false, "ui.widgets.activate failed: " .. tostring(detail)
    end
    if line:sub(1, 16) == "ui.widgets.push " then
        local ok, detail = feature_ui.push_widget(line:sub(17))
        if ok then return true, "ok ui.widgets.push " .. tostring(detail) end
        return false, "ui.widgets.push failed: " .. tostring(detail)
    end
    if line:sub(1, 18) == "ui.menus.navigate " then
        local ok, detail = feature_ui.menus_navigate(line:sub(19))
        if ok then return true, "ok ui.menus.navigate " .. tostring(detail) end
        return false, "ui.menus.navigate failed: " .. tostring(detail)
    end
    if line:sub(1, 15) == "ui.widgets.set " then
        local ok, detail = feature_ui.set_widget(line:sub(16))
        if ok then return true, "ok ui.widgets.set " .. tostring(detail) end
        return false, "ui.widgets.set failed: " .. tostring(detail)
    end
    if line == "ui.widgets.resetall" then
        local ok, detail = feature_ui.reset_all()
        if ok then return true, "ok ui.widgets.resetall " .. tostring(detail) end
        return false, "ui.widgets.resetall failed: " .. tostring(detail)
    end
    if line == "ui.widgets.hideall" then
        local ok, detail = feature_ui.hide_all()
        if ok then return true, "ok ui.widgets.hideall " .. tostring(detail) end
        return false, "ui.widgets.hideall failed: " .. tostring(detail)
    end

    -- Round 36: WPF "Reload Hotkeys In-Game" toolbar button. Lazy-require
    -- feature_hotkeys here so the module dependency stays one-way
    -- (hotkeys -> router) and we avoid a cyclic require at load time.
    if line == "rsdwt_hotkeys_reload" then
        local ok, mod = pcall(require, "feature_hotkeys")
        if not ok or type(mod) ~= "table" then
            return false, "feature_hotkeys missing: " .. tostring(mod)
        end
        local rok, rerr = pcall(function() mod.reload() end)
        if not rok then return false, "reload crashed: " .. tostring(rerr) end
        return true, "ok rsdwt_hotkeys_reload"
    end

    -- debug.hud.probe
    --   Resolve the live HUD (PC.MyHUD -> FindFirstOf(DebugCameraHUD)
    --   -> FindFirstOf(HUD)) and dump its class, super-chain, the
    --   AHUD bool flags, and DebugDisplay/ToggledDebugCategories
    --   FName arrays to ipc/debug_hud_probe.json. Read-only.
    if line == "debug.hud.probe" then
        local ok, detail = feature_debug_hud.probe()
        if ok then return true, "ok debug.hud.probe " .. tostring(detail) end
        return false, "debug.hud.probe failed: " .. tostring(detail)
    end

    -- debug.hud.functions
    --   Walk the live HUD's class chain and write every UFunction
    --   declared at each tier to ipc/debug_hud_functions.json.
    --   Research aid ; catches anything Dominion overrode beyond
    --   the engine AHUD/ADebugCameraHUD surface.
    if line == "debug.hud.functions" then
        local ok, detail = feature_debug_hud.functions()
        if ok then return true, "ok debug.hud.functions " .. tostring(detail) end
        return false, "debug.hud.functions failed: " .. tostring(detail)
    end

    -- debug.hud.draw.probe [seconds]
    --   Hooks /Script/Engine.HUD:ReceiveDrawHUD for N seconds (default 3,
    --   clamped 1..30) and records: hook fires, canvas validity, canvas
    --   size, per-primitive draw attempt results (DrawText/DrawRect/
    --   DrawLine), and a Project() test. Result lands in
    --   ipc/debug_hud_draw_probe.json after the deadline.
    --   The router ack confirms registration only ; the JSON is the
    --   actual report.
    if line == "debug.hud.draw.probe" or line:sub(1, 21) == "debug.hud.draw.probe " then
        local arg = line:sub(22)
        local ok, detail = feature_debug_hud.draw_probe(arg)
        if ok then return true, "ok debug.hud.draw.probe " .. tostring(detail) end
        return false, "debug.hud.draw.probe failed: " .. tostring(detail)
    end

    -- debug.hud.show.list  (must come BEFORE debug.hud.show <cat>)
    if line == "debug.hud.show.list" then
        local ok, detail = feature_debug_hud.show_list()
        if ok then return true, "ok debug.hud.show.list " .. tostring(detail) end
        return false, "debug.hud.show.list failed: " .. tostring(detail)
    end
    -- debug.hud.show.reset  (must come BEFORE debug.hud.show <cat>)
    if line == "debug.hud.show.reset" then
        local ok, detail = feature_debug_hud.show_reset()
        if ok then return true, "ok debug.hud.show.reset " .. tostring(detail) end
        return false, "debug.hud.show.reset failed: " .. tostring(detail)
    end
    -- debug.hud.show.cats  (must come BEFORE debug.hud.show <cat>)
    if line == "debug.hud.show.cats" then
        local ok, detail = feature_debug_hud.show_cats()
        if ok then return true, "ok debug.hud.show.cats " .. tostring(detail) end
        return false, "debug.hud.show.cats failed: " .. tostring(detail)
    end
    -- debug.hud.show.sub <subcategory>
    if line:sub(1, 19) == "debug.hud.show.sub " then
        local ok, detail = feature_debug_hud.show_sub(line:sub(20))
        if ok then return true, "ok debug.hud.show.sub " .. tostring(detail) end
        return false, "debug.hud.show.sub failed: " .. tostring(detail)
    end
    -- debug.hud.show <category>
    if line:sub(1, 15) == "debug.hud.show " then
        local ok, detail = feature_debug_hud.show(line:sub(16))
        if ok then return true, "ok debug.hud.show " .. tostring(detail) end
        return false, "debug.hud.show failed: " .. tostring(detail)
    end
    -- debug.hud.flag <name> <on|off>
    if line:sub(1, 15) == "debug.hud.flag " then
        local ok, detail = feature_debug_hud.flag(line:sub(16))
        if ok then return true, "ok debug.hud.flag " .. tostring(detail) end
        return false, "debug.hud.flag failed: " .. tostring(detail)
    end
    -- debug.hud.target.next | .prev
    if line == "debug.hud.target.next" then
        local ok, detail = feature_debug_hud.target_next()
        if ok then return true, "ok debug.hud.target.next " .. tostring(detail) end
        return false, "debug.hud.target.next failed: " .. tostring(detail)
    end
    if line == "debug.hud.target.prev" then
        local ok, detail = feature_debug_hud.target_prev()
        if ok then return true, "ok debug.hud.target.prev " .. tostring(detail) end
        return false, "debug.hud.target.prev failed: " .. tostring(detail)
    end

    -- debug.draw.label.clear [actor-name]   (must come BEFORE label <name>)
    if line == "debug.draw.label.clear" or line:sub(1, 23) == "debug.draw.label.clear " then
        local ok, detail = feature_debug_hud.draw_label_clear(line:sub(24))
        if ok then return true, "ok debug.draw.label.clear " .. tostring(detail) end
        return false, "debug.draw.label.clear failed: " .. tostring(detail)
    end
    -- debug.draw.label <actor-name> <text...> [#dur=N] [#color=r,g,b]
    if line:sub(1, 17) == "debug.draw.label " then
        local ok, detail = feature_debug_hud.draw_label(line:sub(18))
        if ok then return true, "ok debug.draw.label " .. tostring(detail) end
        return false, "debug.draw.label failed: " .. tostring(detail)
    end

    -- build.preview.* : in-game ghost preview of captured builds.
    --   build.preview.probe : phase-0 read-only diagnostic. Dumps the
    --     local UBuildModeComponent's CurrentBuildMode, CurrentlyPlacingPieceData,
    --     PreviewPiece and PreviewPiece transform to the UE4SS log. Run
    --     once idle and once while holding a piece to confirm the live
    --     preview state reads cleanly before any spawning code is added.
    if line == "build.preview.probe" then
        local ok, detail = feature_build_preview.probe()
        if ok then return true, "ok build.preview.probe " .. tostring(detail) end
        return false, "build.preview.probe failed: " .. tostring(detail)
    end
    --   build.preview.attach1 <name> : phase-1 sanity test. Reads the
    --     first piece_data_name out of ipc/building/<name>.json,
    --     ForceEnterBuildMode if needed, then OnPieceSelected on the
    --     resolved UBuildingPieceData. Should put a PreviewPiece on the
    --     reticle as if the player had clicked it from the menu.
    if line:sub(1, 22) == "build.preview.attach1 " then
        local ok, detail = feature_build_preview.attach1(line:sub(23))
        if ok then return true, "ok build.preview.attach1 " .. tostring(detail) end
        return false, "build.preview.attach1 failed: " .. tostring(detail)
    end
    --   build.preview.spawn1 <name> : phase-1.5 sanity test. Spawns ONE
    --     phantom of the capture's first piece class 300 units in front
    --     of the player and tags it bIsPreview / bIsGhosted. Lets us
    --     verify SpawnActor works on these BPs and the ghost visual
    --     renders before involving N pieces / attach math.
    if line:sub(1, 21) == "build.preview.spawn1 " then
        local ok, detail = feature_build_preview.spawn1(line:sub(22))
        if ok then return true, "ok build.preview.spawn1 " .. tostring(detail) end
        return false, "build.preview.spawn1 failed: " .. tostring(detail)
    end
    --   build.preview.preview <name> [max] : phase-2 multi-spawn. Spawns
    --     every piece in the capture as a phantom, anchored to a spot
    --     in front of the player and rotated so the build faces the
    --     player's facing direction. Optional second arg overrides the
    --     150-piece hard cap.
    if line:sub(1, 22) == "build.preview.preview " then
        local ok, detail = feature_build_preview.preview(line:sub(23))
        if ok then return true, "ok build.preview.preview " .. tostring(detail) end
        return false, "build.preview.preview failed: " .. tostring(detail)
    end
    --   build.preview.preview_full <name> : same as preview, but ALSO
    --     spawns the rest of the capture as ghost silhouettes
    --     attached to a parent that follows the engine's reticle
    --     preview. The user sees the whole structure as a translucent
    --     ghost on their cursor instead of just the first piece.
    --     Commits/cancels the same way as build.preview.preview.
    if line:sub(1, 27) == "build.preview.preview_full " then
        local ok, detail = feature_build_preview.preview_full(line:sub(28))
        if ok then return true, "ok build.preview.preview_full " .. tostring(detail) end
        return false, "build.preview.preview_full failed: " .. tostring(detail)
    end
    --   build.preview.diag <name> [n] : read-only sanity print of capture
    --     parse + computed world-spawn coords for the first N pieces
    --     (default 5). Use to verify the math before re-running preview.
    if line:sub(1, 19) == "build.preview.diag " then
        local ok, detail = feature_build_preview.diag(line:sub(20))
        if ok then return true, "ok build.preview.diag " .. tostring(detail) end
        return false, "build.preview.diag failed: " .. tostring(detail)
    end
    --   build.preview.clear : destroy every phantom we've spawned via
    --     build.preview.* verbs. Always run before re-running spawn1 /
    --     attach so we don't pile up actors.
    if line == "build.preview.clear" then
        local ok, detail = feature_build_preview.clear()
        if ok then return true, "ok build.preview.clear " .. tostring(detail) end
        return false, "build.preview.clear failed: " .. tostring(detail)
    end
    --   build.preview.cancel : abort the active engine-driven preview
    --     session (drop reticle preview + unregister commit hook).
    if line == "build.preview.cancel" then
        local ok, detail = feature_build_preview.cancel()
        if ok then return true, "ok build.preview.cancel " .. tostring(detail) end
        return false, "build.preview.cancel failed: " .. tostring(detail)
    end
    --   build.preview.commit [ghost] : take the BMC's current PreviewPiece
    --     transform as the anchor and replay every piece in the active
    --     session via Server_SpawnBuilding. Bypasses the engine's UI
    --     validity gate (the player doesn't have to actually click).
    --     Optional "ghost" 2nd token : after spawn, mark all newly-spawned
    --     pieces as bIsGhosted=true (used by WPF Ghost Building Mode).
    if line == "build.preview.commit" then
        local ok, detail = feature_build_preview.commit("")
        if ok then return true, "ok build.preview.commit " .. tostring(detail) end
        return false, "build.preview.commit failed: " .. tostring(detail)
    end
    if line:sub(1, 21) == "build.preview.commit " then
        local ok, detail = feature_build_preview.commit(line:sub(22))
        if ok then return true, "ok build.preview.commit " .. tostring(detail) end
        return false, "build.preview.commit failed: " .. tostring(detail)
    end
    --   build.preview.piece <index|short_name|full_path> : drive the
    --     engine into placing mode with ANY BuildingPieceData on the
    --     reticle, regardless of unlock state. Single piece only ; for
    --     multi-piece replays use build.preview.preview.
    if line:sub(1, 20) == "build.preview.piece " then
        local ok, detail = feature_build_preview.piece(line:sub(21))
        if ok then return true, "ok build.preview.piece " .. tostring(detail) end
        return false, "build.preview.piece failed: " .. tostring(detail)
    end
    --   build.preview.lookat : QOL combo. Probe whatever building piece
    --     the player's reticle is on (same source priority as
    --     camera.lookat) and immediately arm its piece data on the
    --     build reticle. One verb -> one hotkey -> "copy that piece
    --     into my hand".
    if line == "build.preview.lookat" then
        local ok, detail = feature_build_preview.lookat()
        if ok then return true, "ok build.preview.lookat " .. tostring(detail) end
        return false, "build.preview.lookat failed: " .. tostring(detail)
    end
    --   build.preview.force_place : fire Server_SpawnBuilding for
    --     whatever is currently on the BMC reticle, at the reticle's
    --     current world transform. Bypasses the engine's UI validity
    --     gate. Works for pieces armed via the regular build menu OR
    --     build.preview.piece OR build.preview.preview anchor.
    if line == "build.preview.force_place" then
        local ok, detail = feature_build_preview.force_place()
        if ok then return true, "ok build.preview.force_place " .. tostring(detail) end
        return false, "build.preview.force_place failed: " .. tostring(detail)
    end

    -- debug.watch.* (live actor-property overlays)
    -- Order: longest literal first so .probe / .list / .clear / .remove
    -- don't get shadowed by `debug.watch.add` etc.
    if line == "debug.watch.list" then
        local ok, detail = feature_debug_watch.list()
        if ok then return true, "ok debug.watch.list " .. tostring(detail) end
        return false, "debug.watch.list failed: " .. tostring(detail)
    end
    if line == "debug.watch.clear" then
        local ok, detail = feature_debug_watch.clear()
        if ok then return true, "ok debug.watch.clear " .. tostring(detail) end
        return false, "debug.watch.clear failed: " .. tostring(detail)
    end
    if line:sub(1, 18) == "debug.watch.probe " then
        local ok, detail = feature_debug_watch.probe(line:sub(19))
        if ok then return true, "ok debug.watch.probe " .. tostring(detail) end
        return false, "debug.watch.probe failed: " .. tostring(detail)
    end
    if line:sub(1, 17) == "debug.watch.snap " then
        local ok, detail = feature_debug_watch.snap(line:sub(18))
        if ok then return true, "ok debug.watch.snap " .. tostring(detail) end
        return false, "debug.watch.snap failed: " .. tostring(detail)
    end
    if line:sub(1, 17) == "debug.watch.diag " then
        local ok, detail = feature_debug_watch.diag(line:sub(18))
        if ok then return true, "ok debug.watch.diag " .. tostring(detail) end
        return false, "debug.watch.diag failed: " .. tostring(detail)
    end
    if line:sub(1, 19) == "debug.watch.remove " then
        local ok, detail = feature_debug_watch.remove(line:sub(20))
        if ok then return true, "ok debug.watch.remove " .. tostring(detail) end
        return false, "debug.watch.remove failed: " .. tostring(detail)
    end
    if line:sub(1, 16) == "debug.watch.add " then
        local ok, detail = feature_debug_watch.add(line:sub(17))
        if ok then return true, "ok debug.watch.add " .. tostring(detail) end
        return false, "debug.watch.add failed: " .. tostring(detail)
    end

    return false, "unknown command"
end

return M

