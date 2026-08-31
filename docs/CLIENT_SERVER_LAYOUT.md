# RSDW Client / Server Kit Layout

This branch introduces a physical package split for cloud-hosted dedicated servers.

## Goals

- Build two independent deliverables: `RSDWClientKit` and `RSDWServerKit`.
- Keep shared source reusable without shipping client-only files to the server or server-only files to the client.
- Keep the existing `ue4ss/` package intact while the split is introduced incrementally.

## Source layout

- `common/` — source shared by both packages.
- `client/` — client-only UE4SS entrypoint/configuration and future client-only mods.
- `server/` — headless dedicated-server UE4SS entrypoint/configuration and future server-only mods.
- `packaging/` — scripts that assemble physically separate packages under `dist/`.

## Side manifest

New mods should include a `mod.json` with one of these side values:

- `client`
- `server`
- `both`

Packaging scripts can use this metadata as the mod library grows.

## Current migration rule

Do not move or delete the existing `ue4ss/` tree yet. It remains the compatibility baseline while features are migrated into explicit client/server ownership.

Client-only examples include UMG, hotkeys, camera/freecam, viewport console, and local UI helpers.

Server-only examples include authoritative world mutations, remote-player administration, persistence controls, server rules, and headless admin commands.

Shared code should avoid assuming that a local player exists. Dedicated servers must resolve target players through server-side PlayerController/PlayerState/Pawn lookup rather than `local_pawn()`.
