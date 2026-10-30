# Layers

A layer is a reusable bundle of ruleset fields: ban lists (`banned_*`), rework
lists (`reworked_*`), included lists (`included_*`), dict fields such as
`game_modifiers` and `starting_params`, scalars, and a `calculate(self, context)`
hook. A ruleset lists the layers it is composed from instead of repeating them.

```lua
MPAPI.Layer('the_order', {
	reworked_tags = { 'tag_uncommon', 'tag_rare' },
})

MPAPI.Ruleset({
	key = 'my_ruleset',
	layers = { 'the_order' },
})
```

Registration lives in `api/layers/`. Rulesets resolve their layers at
construction (`MPAPI.resolve_layers` in `api/layers/fields.lua`); runtime
modifier layers (`MPAPI.add_modifier`) stack on top of the active ruleset.

## Origin

The layer system was introduced in Balatro Multiplayer by
[PR #396 "Layer system for rulesets"](https://github.com/Balatro-Multiplayer/BalatroMultiplayerPvP/pull/396)
(merged 2026-04-20). Registration has since moved into this repo
(`MPAPI.Layer`); PvP's layer definitions live in
[BalatroMultiplayerPvP](https://github.com/Balatro-Multiplayer/BalatroMultiplayerPvP)'s
`layers/`.
