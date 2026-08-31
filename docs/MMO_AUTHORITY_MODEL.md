# MMO-ish authority model

The player-facing RSDW client is a presentation/input layer. The cloud server is authoritative for all persistent or competitive game state.

## Trust boundary

Never trust the client for:

- health, damage, death or revive outcomes
- inventory, item grants, loot rolls or currencies
- XP, progression, unlocks, quest completion or achievements
- player/world position used for authoritative travel
- dungeon/raid state, seeds, mutations, boss state or rewards
- PvP hits, kills, scores, team state or match outcomes
- server/shard destination or transfer authorization
- admin/mod commands

A player-owned machine can always be modified. Security comes from making altered client state irrelevant to authoritative decisions.

## Client capabilities

The production client should expose only named UI actions such as:

- session.status
- dungeon.queue
- raid.queue
- pvp.queue
- travel.request

There must be no generic player-facing `rsdwt_cmd`, raw command router, SHM admin console, cheat-manager, or arbitrary world/player mutation interface in the production Client Kit.

The server uses a default-deny action registry. Unknown actions are rejected.

## Server roles

Recommended service topology:

1. **Coordinator / account service**
   - stable player identity
   - progression/inventory/currency persistence
   - party/group state
   - shard directory
   - queue/matchmaking
   - signed transfer tickets

2. **World shards**
   - social/open-world gameplay
   - server-authoritative progression requests
   - portals/queue UI triggers

3. **Dungeon instances**
   - mutation seed/tier owned by server
   - encounter state and loot owned by server
   - short-lived disposable instance

4. **Raid instances**
   - encounter lockouts
   - group roster
   - authoritative boss state and rewards

5. **PvP instances**
   - match roster/rules/team assignment
   - server-authoritative scoring and rewards

The official dedicated-server player cap means MMO scale is achieved through many small shards/instances rather than one very large Dragonwilds process.

## Server hopping / instancing

A transfer should be initiated by the authoritative server/coordinator, not by a client selecting an arbitrary endpoint.

Suggested flow:

1. Client UI sends `dungeon.queue` / `raid.queue` / `pvp.queue` / `travel.request`.
2. Current server validates player state and forwards the request to the coordinator.
3. Coordinator allocates or selects an instance.
4. Coordinator creates a short-lived single-use transfer ticket bound to player + destination + expiry.
5. Current server prepares/persists the player and tells the client which destination to join plus the ticket.
6. Destination validates/consumes the ticket before restoring authoritative state.
7. Destination acknowledges arrival; coordinator closes the transfer state.

Do not trust a client-supplied inventory/progression snapshot during transfer.

## Dungeon mutations

Treat mutations as server data, e.g. `{tier, seed, affixes, difficulty, loot_table_version}`. The server chooses them and applies encounter/world changes. The client receives only display information necessary for UI/FX.

Examples of server-owned affixes:

- enemy health/damage scaling
- elite/boss modifiers
- timed objectives
- environmental hazards
- restricted healing/resources
- bonus objectives
- altered encounter composition
- reward multipliers

## Production package rule

Client-only and server-only packages are physically separate. Shared code may exist in source, but the package builders copy only the files permitted for the target side.
