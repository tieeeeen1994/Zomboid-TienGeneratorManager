# Tien's Generator Manager

Wire your generators. Right-click a generator, Generator > Manage Power, and you get a top-down map of everything it
reaches, one floor at a time. Paint squares:

- **Connect** (green): this generator powers it.
- **Disconnect** (red): this generator does not.
- **Auto** (yellow, the default): any generator may power it.

A square is powered by the closest running generator that has it connected; if none does, by the closest running one
that has it on auto. If every running generator in reach has it disconnected, the square loses power like in a
blackout: lights, stoves, TVs, radios, washers, dryers and battery chargers there switch off, fridges and freezers are
unplugged (food spoils at the normal rate, frozen food thaws), and everything comes back on when the square gets power
again. Fuel is only used for what each generator really powers.

On the map, squares with devices show this generator's choice in colour, with a dot for who powers them now (a closer
generator may win): white = this generator, blue = another generator, black = no power. Hover a square to highlight its devices in the
world, on any floor. Right-click a square for a picture of it, the list of its devices
and which generator really powers it. Connect all, Disconnect all and
Auto all set every square in reach on the floor shown at once, with or without devices (after asking); squares painted
afterwards override that. Zoom with the mouse wheel or the - and + buttons, right-drag to move the map.

The Generator menu also has **Show range** (a light green tint on every square the generator reaches on your floor,
with a stronger band along the edge) and **Show devices** (every device in reach outlined, on every floor: green = this
generator powers it, blue = another generator, red = no power, grey = no generator running). They replace the Generator
Range mod.

Sandbox (page Tien's Generator Manager): disconnected squares lose power (on), unplug fridges and freezers (on).

## Caveats

Project Zomboid has no power per square: a running generator powers every square in its reach and nothing can take
that away from one square. So a blackout is imitated:

- **Devices are switched off, not cut off.** Switching one back on on a disconnected square works for a moment, then it
  switches off again within a second. The mod remembers it was wanted on and switches it on once the square has power.
- **Fridges and freezers have no switch**, so they are unplugged by turning their shelves into a plain container
  (Fridge (no power) / Freezer (no power) in the loot window): food spoils at the normal rate, frozen food thaws. They
  become fridges again when the square has power. While unplugged, other mods that look for fridges do not see them.
  The sandbox option Unplug fridges and freezers turns this off.
- **Ceiling lights belong to a whole room**: a room stays lit while any of its light switches is on a powered square,
  and goes dark only when all of them are disconnected. Lamps follow their own square.
- Fuel pumps cannot be switched off. Radios and TVs on batteries are left alone.
- Switching happens on the server where the area is loaded; devices in an area nobody is near are switched when it
  loads again.

## Adding it to a running save or server

- **Safe to add mid-save.** Every square starts on auto, so nothing loses power until you paint something. The only
  change from the start: a device in reach of several running generators uses fuel from the closest one, not all.
- Remove Nick's Generator Manager first (not compatible; its choices are not carried over). Generator Range is not
  needed any more.
- **Removing it:** untick both sandbox options and visit every base once (switched-off devices come back on, unplugged
  fridges become fridges again), then remove the mod. Without that, switched-off devices stay off until switched on by
  hand, and unplugged fridges stay plain containers for good (their food is kept).

Build 42. Install on the server and every client.

Inspired by [Nick's Generator Manager](https://steamcommunity.com/sharedfiles/filedetails/?id=3794099205), which first
let players choose which generator pays for each device.
