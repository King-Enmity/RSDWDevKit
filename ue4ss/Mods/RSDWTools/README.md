# RSDWTools (UE4SS mod)

## Controls

- **Insert**: toggles the **UMG** overlay (player-facing). Preferred path is `RegisterKeyBindAsync(Key.INS)`.
- **Console**: `rsdwt_help`, `rsdwt_toggle`, `rsdwt_umg_toggle`, `rsdwt_umg_text <text>`, `rsdwt_bridge_status`, `tele <x> <y> <z>`, `scan <name_part> [radius|all]`

## Contents

- `scripts/main.lua` — loads features and bridge command loop, registers hooks/keybinds/console.
- `scripts/bridge_shm.lua` — thin wrapper around the `BridgeLine*Cpp` globals (shared-mem transport).
- `scripts/command_line_router.lua` — central dispatcher. Header comment lists every verb the router currently understands and links removed verbs to `NOTES/cheats-to-revisit.md` sections.
- `scripts/feature_teleport.lua` — `tele` / `tele.dir` + teleport-cinematic tweaks.
- `scripts/feature_scan.lua` — `scan` command; writes `ipc/scan_results.json`.
- `scripts/feature_actor.lua` — per-actor verbs (goto/bring/del/vis/col/scale) + shared pawn / player-controller helpers used by other modules.
- `scripts/feature_player.lua` — **the main curated cheat module.** Every `player.*` verb (movement, vitals, survival stats, mounts, abilities).
- `scripts/feature_ge.lua` — `player.ge.<apply|remove|toggle|has|list>` against `UDominionGameplayEffectsComponent`.
- `scripts/feature_field.lua` — generic write builder (`player.field.set` / `set_index` / `set_key` / `set_object` / `add` / `remove` / `clear` / `call`); the verb the Catalog tab dispatches.
- `scripts/feature_attr.lua` — attribute reads/writes against `UAttributeSet`-derived components.
- `scripts/feature_world.lua` — world-side verbs (time-of-day, weather, subsystem reads/writes).
- `scripts/feature_ui.lua` — `ui.tab` dispatch (legacy in-game UMG tab switcher).
- `scripts/feature_umg.lua` — in-game UMG overlay (legacy; primary UI is now the WPF app). Insert toggles it.
- `tools/Generate-Catalog.ps1` — out-of-game catalog builder spawned by the WPF Catalog tab. **PowerShell only ; lives in `tools/` so it never co-mingles with the Lua modules in `scripts/`.**
- `RSDWTools.dll` — native shared-memory bridge (transport only).
- `dlls/main.dll` — UE4SS C++ wrapper exporting Lua globals (`BridgeLine*Cpp`).
- `RSDWTools.exe` — shipped WPF desktop UI that drives everything above over the bridge.

> Folder rule: `scripts/` is **Lua modules only.** Every PowerShell helper that ships inside the deployed mod lives under `tools/`. Sync-ModPayload enforces this on every build.

## Wrapper IPC (canonical)

Command line contract:

- Request line examples:
  - `tele <x> <y> <z>`, `tele.dir <dir> [step]`
  - `scan <name_part> [radius|all]`
  - `actor.<verb> <name> [arg]` (goto / bring / del / vis / col / scale)
  - `player.<verb> [args]` — movement, vitals, survival drains, mounts,
    abilities (see `command_line_router.lua` for the authoritative
    list; it's the header comment at the top of the file)
  - `player.ge.<apply|remove|toggle|has|list> <ClassName> [on|off]` — apply/remove a `UDominionGameplayEffectData`
  - `player.field.<set|set_index|set_key|set_object|add|remove|clear|call> <root> <path> [args]` — generic catalog write builder
  - `dump.types` — regenerate UE4SS Lua type stubs (catalog pipeline step 1)
  - `ui.tab <name>`
- Ack line: `ok <verb> <detail>` or `err <reason>`

Runtime path:

- `RSDWTools.exe` ↔ shared memory block (`Local\RSDWTools_SharedLine_v1`)
- `dlls/main.dll` registers Lua globals (`BridgeLineInitCpp`, `BridgeLinePollRequestCpp`, `BridgeLineWriteAckCpp`)
- `scripts/main.lua` polls bridge, routes command via `command_line_router`, writes ack
- Feature modules execute game work on game thread where required

> For the full architectural overview (who owns which DLL, why the split,
> Lua-module conventions, build/deploy loop), see the top-level
> [`RSDWTools/README.md`](../../README.md) and
> [`RSDWTools/ARCHITECTURE_IPC_COMMAND_STACK.md`](../../ARCHITECTURE_IPC_COMMAND_STACK.md).

## Desktop UI usage

Launch:

```powershell
.\RSDWTools.exe
```

## Desktop UI source location

Desktop UI source/build project is kept in the repository source tree, not in mod runtime payload:

- `RSDWTools/Exe/RSDWToolsApp`
- `RSDWTools/tools/Sync-ModPayload.ps1` (publishes UI and syncs shipped `Mods/RSDWTools/RSDWTools.exe`)

