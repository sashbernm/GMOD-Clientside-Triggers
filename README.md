# GMOD-Clientside-Triggers

A WIP addon for making certain Garry's Mod map triggers feel clientside predicted.

This is basically meant to reduce the delay / correction you get when a map trigger is handled only by the server. The goal is to make supported triggers react immediately on the client, while still keeping the server as the real authority.

This is not a perfect final release yet. It is still being worked on, and right now it only supports a small set of trigger behavior.

## What it does

- Sends supported map trigger data from the server to clients.
- Lets the client predict supported `trigger_multiple` behavior.
- Replaces supported `trigger_teleport` behavior with a predicted version.
- Keeps the server running the same trigger logic so prediction can match server movement.
- Tracks trigger bounds, spawnflags, disabled state, and basic cooldown / wait behavior.
- Refreshes trigger snapshots when the map loads, reloads, or changes.
- Handles player hull checks instead of only checking the player's origin.

## Supported triggers

Right now, the addon supports:

- `trigger_multiple`
- `trigger_teleport`

## trigger_multiple support

The current `trigger_multiple` code predicts simple velocity-style trigger behavior.

It currently handles outputs like:

```txt
OnStartTouch -> !activator -> AddOutput -> basevelocity x y z
OnEndTouch -> !activator -> AddOutput -> basevelocity x y z
```

The addon reads those outputs from the map, sends them to the client, and applies the basevelocity change during predicted movement.

It also supports basic trigger settings like:

- trigger bounds
- spawnflags
- wait time
- disabled state
- start touch
- end touch
- moving fully through a trigger in one tick

There is also a clientside hook when a predicted `trigger_multiple` touch happens:

```lua
hook.Run("PredictedTriggerMultipleTouch", trigger_id, trigger_data)
```

## trigger_teleport support

The current `trigger_teleport` code replaces native teleport behavior for supported map teleports.

The server captures the teleport trigger, sends the useful data to clients, disables the native `trigger_teleport`, and then both the client and server run matching movement logic.

It currently tracks / supports:

- trigger bounds
- target destination
- landmark offset teleporting
- destination angle
- spawnflags
- `StartDisabled`
- `Enable` / `Disable` inputs
- basic teleport cooldown
- clientside position prediction
- server-side authoritative teleporting

## Current behavior

For teleports, the client predicts the teleport position immediately during movement prediction.

The server then applies the same destination position when it processes the player's movement command. This is meant to avoid the old behavior where the client waits for the server and then gets corrected afterward.

Destination angles are also sent through the snapshot. The client applies the predicted angle through `CreateMove`, and the server applies matching angle behavior where possible.

## Commands

There are currently no user commands.

The addon runs automatically when loaded.

## Install

Put the addon folder in:

```txt
garrysmod/addons/clientside_triggers
```

The folder should contain:

```txt
lua/autorun/sh_init.lua
```

So it should look roughly like:

```txt
garrysmod/addons/clientside_triggers/lua/autorun/sh_init.lua
```

After that, restart the server / game and load a map that uses supported triggers.

## File structure

```txt
lua/autorun/sh_init.lua
```

Loads the addon and includes the shared trigger modules.

```txt
lua/clientside_triggers/sh_trigger_multiple_fix.lua
```

Handles syncing and predicting supported `trigger_multiple` behavior.

```txt
lua/clientside_triggers/sh_trigger_teleport_fix.lua
```

Handles syncing, replacing, and predicting supported `trigger_teleport` behavior.

## Current status

This is still WIP.

The addon is currently focused on making specific common movement triggers feel better. It is not a full Source trigger reimplementation, and it should not be expected to support every possible map setup yet.

The main idea is to get the common movement cases working first, then keep expanding map compatibility.

## Notes

- This is for Garry's Mod.
- This is a shared client/server addon.
- No external addon should be required.
- The server still stays authoritative.
- Clients receive compressed trigger snapshots from the server.
- Native `trigger_teleport` entities are disabled for supported teleports so the replacement logic can handle them.
- `trigger_multiple` prediction is currently focused on basevelocity outputs.
- `trigger_teleport` output forwarding is not fully reimplemented yet.

## Known limitations

- Only `trigger_multiple` and `trigger_teleport` are supported right now.
- `trigger_multiple` does not predict every possible output type.
- Delayed `basevelocity` outputs are ignored.
- `trigger_teleport` does not currently copy and fire every native trigger output.
- Complex maps may still have edge cases.
- Vehicles, bots, disabled triggers, landmarks, and unusual spawnflags need more testing.
- Prediction can still feel wrong if the client and server disagree about trigger state.

## TODO / planned

- improve teleport angle handling
- test more real maps
- support more `trigger_multiple` output patterns
- support more native `trigger_teleport` behavior
- copy / replay important teleport outputs where possible
- add debug tools or console commands
- add optional logging
- clean up naming and structure more
- test edge cases like noclip, water, ladders, vehicles, bots, and high ping
- add support for more trigger classes if they are useful
