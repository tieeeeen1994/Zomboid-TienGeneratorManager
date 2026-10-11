# Tien's Generator Manager — working notes

Wire generators to devices per square. Each generator has a top-down map of its reach (right-click a generator >
Generator > Manage Power); each square is green (connected), red (not connected) or yellow (auto, the default, not
stored). A square is powered by the closest running generator in reach that has it green, else the closest running one
that has it yellow; if every running generator in reach has it red it is unpowered; squares no running generator
reaches are left to vanilla. Ties by coordinates. Replaces Nick's Generator Manager (workshop 3794099205,
`incompatible=\NicksGeneratorManager`): both would fight over `setTotalPowerUsing`.

Engine facts below were traced in the 42.21 jar (Vineflower; recipe in ZomboidFixesB42's CLAUDE.md and the
`pz-java-decompile-workflow` memory). Line numbers are approximate and shift between builds.

## Files

- `media/lua/shared/TienGeneratorManager.lua`: settings in the generator's modData (`TGM = { ["x,y,z"] = "g" | "r" }`),
  generator registry (coords only), `resolve(x, y, z)`, device helpers, `recompute` (one pass over every running
  generator's reach: billing per generator, cut squares, rooms), `reassert` (every tick), requests.
- `media/lua/server/TienGeneratorManager_Server.lua` (`if isClient() then return end`): power cuts and give-backs,
  fridge unplugging, the per-second pass, `set` / `register` commands.
- `media/lua/client/TienGeneratorManager_Client.lua`: multiplayer client loop (cosmetic recompute + reassert for the Info
  window), menu entry, replies, vanilla Info window override, world highlight + screen markers.
- `media/lua/client/TienGeneratorManager_Range.lua`: Show range / Show devices (Generator submenu; replaces the
  Generator Range mod, workshop 3785933155). Range = WorldMarkers grid square markers with the mod's own
  `media/textures/highlights/tgm_fill.png`: `FBORenderWorldMarkers` draws a flat floor quad of `size * 0.69` tiles
  from the centre (size 0.5 / 0.69 = one tile, seamless) and maps only the vanilla circle textures, so any other name
  is drawn untextured (VBORenderer `textureId == null` disables GL_TEXTURE_2D) = flat colour, twice (overlay quad
  too). `GridSquareMarker.init` still loads the png (missing = error). Alpha always fades between alphaMin/alphaMax:
  steady = fadeSpeed 0, min = max. Drawn only on the player's floor (`m.z == player.getZ()`).
  Devices = `TGM.Highlight` source "devices" (client file keeps named sources with their own colours).
- `media/lua/client/TienGeneratorManager_Map.lua`: the map window (fixed viewport, wheel zoom around the cursor,
  right-drag pan, `setStencilRect` clip, strokes sent in batches of 2000 keys since the server reads at most 5000 per
  request; hover = world highlight of the square's devices, right-click = vanilla pick-up style picture of the
  square + device list pinned beside it).
  Connect/Disconnect/Auto all (after an `ISModalDialog`) act on the floor shown: they set that floor's default
  `TGM["*<z>"]` (`TGM.floorKey(z)`) and clear the own settings of that floor's squares (`set` with `all = true,
  floor = z`): one entry covers every square of the floor in reach, unloaded ones and future devices included;
  `settingAt(gen, key, z)` = own setting, else the floor's default, else auto.
- Sandbox: `CutPower` (off = red counts as auto, cut devices come back: for uninstalling), `UnplugFridges`.

## Power is per square and cannot be removed

- `IsoGridSquare.haveElectricity()` = not (exterior and !AllowExteriorGenerator) and
  `chunk.isGeneratorPoweringSquare(x, y, z)`, which walks the chunk's `generatorsTouchingThisChunk` (8x8 squares, every
  floor) with `IsoGenerator.isPoweringSquare` (floors gz ± `GeneratorVerticalPowerRange`, clamped -32..31; distance of
  square centres <= `GeneratorTileRange`). `setHaveElectricity` is a deprecated no-op (only updates light switches).
  `setSurroundingElectricity` rebuilds the chunk lists on activation, chunk load and (clients) lighting passes. So an
  unpowered square is emulated: devices switched off and remembered, fridges unplugged, all given back with power.
- `IsoObject.couldBePoweredByGenerator()`: base = piped fuel or a fridge/freezer container; true for IsoStove,
  IsoTelevision, IsoRadio, IsoClothingWasher/Dryer, IsoCombination/StackedWasherDryer, IsoCarBatteryCharger;
  IsoLightSwitch = not a street light; IsoWorldInventoryObject false. `getGeneratorPowerConsumption()`: fridge 0.08,
  fridge+freezer 0.13, pump 0.03, light 0.002 while on, stove 0.09, TV 0.03, radio 0.01 (not on batteries), washer/dryer
  0.09, charger 0.05; 0 while off.
- Fuel: `IsoGenerator.update` (server and SP only; returns early on clients) drains, per game hour since `lastHour`,
  `totalPowerUsing * GeneratorFuelConsumption`. `getTotalPowerUsing()` returns that product (a float),
  `setTotalPowerUsing` takes the raw value. After a chunk loads the first update drains the missed hours at whatever
  `totalPowerUsing` is then (the engine's geometric value; cut devices are really off, so only shared squares are
  over-billed for that catch-up).

## Switching devices on the server (all sync to clients)

- Light: `setActive(on, false, true)` (third = ignore `canSwitchLight`) → `switchLight` (room lights: sets
  `room.def.lightsActive` and every switch of the room, `GameServer.sendMetaGrid`) + `syncIsoObject`. A switch is a room
  switch (private `lightRoom`) exactly when its sprite has no `lightR` property; lamps have one.
- Stove/microwave (IsoStove): `setActivated` + `sync()`; `Toggle()` is what ISToggleStoveAction uses.
- Washer / dryer / combo: `setActivated` + `sendObjectChange(IsoObjectChange.WASHER_STATE / DRYER_STATE)` (vanilla
  ISToggleClothingWasher etc.). Stacked washer-dryer: `setWasherActivated` / `setDryerActivated` (no vanilla Lua caller;
  synced the same way, untested).
- Charger: `setActivated` + `sync()` (ISActivateCarBatteryChargerAction). TV/radio: `getDeviceData():setIsTurnedOn(b)`
  transmits itself (`transmitDeviceDataState`); battery-powered ones are left alone.

## Fridges

- `ItemContainer.isPowered()` → `parent.checkObjectPowered()` → `ItemContainer.isObjectPowered(obj, true)` → square
  power. `getTemperature()`: `customTemperature` if non-zero, else 0.2 for a powered fridge/freezer, else 1.0 (or the
  shutoff-day warm-up). `customTemperature` is not enough: `Food` ageing in a fridge/freezer is slowed while
  `getSourceGrid().haveElectricity()` (~756), freezing needs `isInFreezer && isPowered()` (`isFreezing` ~2163).
- Every one of those starts with `isFridge()/isFreezer()` = container type. Unplugging = `setType("tgm_fridge" /
  "tgm_freezer")`, originals in modData `TGM_types`; the type is saved (`ItemContainer.save`); clients get it with
  `obj:sendObjectChange(IsoObjectChange.CONTAINERS)` (server only; clients rebuild every container in place,
  `IsoObject.loadChange`). `transmitCompleteItemToClients` would send AddItemToMap (a second copy), not that.
  Loot window: `IGUI_ContainerTitle_<type>` and `ContainerButtonIcons[type]`.
- A mod removed while fridges are unplugged leaves plain containers: turn CutPower off and visit the bases first.

## Highlights

- Outlines (`FBORenderObjectOutline`) only draw for objects the game draws (`renderInfo.layer` not None, alpha > 0),
  so devices on a cut-away or covered floor need the screen-layer markers (`OnPreUIDraw`, `isoToScreenX/Y` = absolute
  screen pixels with zoom, `getRenderer():render(tex, x, y, w, h, r, g, b, a, nil)`, the only overload).
- `ISInventoryPage.OnObjectHighlighted(playerNum, obj, bool)` keeps the loot window from repainting it.

## Networking

- The server has no event for a generator placed on a loaded chunk (`OnObjectAdded` fires only on clients), so clients
  send `register` (on placement and when opening the map); `LoadGridsquare` registers on chunk load everywhere.
- `set {gx, gy, gz, keys, state}`: generator must exist, keys in its reach, player within reach + 5 tiles,
  `SafeHouse.isSafehouseAllowInteract`. Reply `applied` to everyone, `refused {reason}` to the sender. Single player
  calls `applySet` directly (sendServerCommand does nothing outside a server).
- Marks (`TGM_wasOn`, `TGM_types`) are object modData, saved in the server's chunks; `LoadGridsquare` finds them again.

## Testing

- `scratchpad/tgm_test/harness.lua` style: run shared + server files in luaj (`java -cp luaj.jar lua harness.lua <lua
  dir>`) against mocked squares/generators/devices (30 checks on 2026-10-11).
- Local dedicated server: `ProjectZomboidServer.bat` in the game folder.
