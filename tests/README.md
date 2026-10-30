# Layer-content contract checks

Run from the MPAPI root:

```sh
lua tests/test_layer_content.lua
luajit tests/test_layer_content.lua
```

Checks `included_*` indexing/composition across all supported pool categories,
existing rework gates, modifier overlays, multiple owners, bespoke overrides and
missing-membership warnings for isolated consumer mods. SMODS registration is
stubbed; these checks do not exercise Lovely patches or real game pools.
