--[[
    Tien's Generator Manager -- shared: settings, who powers a square, devices

    Each generator keeps, for the squares in its reach, a setting chosen on its map:
    green (connected), red (not connected) or yellow (auto, the default, nothing stored).
    A square is powered by the closest running generator in reach that has it green, else
    the closest running one that has it yellow; if every running generator in reach has it
    red it is unpowered. Squares no running generator reaches are left to vanilla.

    Power in the engine is per square and computed, never stored (42.21):
    IsoGridSquare.haveElectricity() = chunk.isGeneratorPoweringSquare(x, y, z), a walk over
    the chunk's generatorsTouchingThisChunk list with IsoGenerator.isPoweringSquare (radius
    GeneratorTileRange, GeneratorVerticalPowerRange floors up and down, no outdoor squares
    unless AllowExteriorGenerator). setHaveElectricity is a deprecated no-op, and the list is
    per chunk (8x8, every floor) and rebuilt by setSurroundingElectricity on every
    activation, chunk load and client lighting pass. So a square cannot be unpowered: an
    unpowered square is an emulated power cut (server file), and fuel is billed by
    re-asserting each generator's totalPowerUsing every tick (IsoGenerator.update drains
    totalPowerUsing x GeneratorFuelConsumption per game hour, on the server only, and the
    engine recomputes totalPowerUsing geometrically on many events).

    Devices a generator can power, on or off: IsoObject.couldBePoweredByGenerator() (fridges
    and freezers by container type, fuel pumps, lights except street lights, stoves and
    microwaves, TVs, radios, washers, dryers, battery chargers); their draw:
    getGeneratorPowerConsumption() (0 while off). An unplugged fridge (container types
    swapped, see the server file) is no longer one by that test, so it is recognised by its
    modData mark.

    This file loads on the server, on clients and in single player; it has no UI calls.
--]]

TienGeneratorManager = TienGeneratorManager or {}
local TGM = TienGeneratorManager

TGM.MODULE = "TienGeneratorManager"
TGM.SETTINGS = "TGM"            -- generator modData: { ["x,y,z"] = "g" | "r" | "a", ["*z"] = floor default }
                                -- ("a" on a square only overrides a floor default of g or r)
TGM.ALL = "*"                   -- prefix of a floor's default ("*0", "*-1"): Connect / Disconnect all
TGM.WAS_ON = "TGM_wasOn"        -- device modData: it was on when its power was cut
TGM.TYPES = "TGM_types"         -- device modData: { [container index + 1] = original type }
TGM.GREEN, TGM.RED, TGM.AUTO = "g", "r", "a"
TGM.OFF = "off"                 -- resolve(): every running generator in reach has it red
TGM.BASE_DRAW = 0.02            -- IsoGenerator: a running generator's own draw
TGM.UNPLUGGED_TYPE = { fridge = "tgm_fridge", freezer = "tgm_freezer" }
TGM.PLUGGED_TYPE = { tgm_fridge = "fridge", tgm_freezer = "freezer" }

function TGM.log(msg)
    print("[TienGeneratorManager] " .. tostring(msg))
end

-- ---- sandbox ----------------------------------------------------------------------

local function sandbox(name)
    local vars = SandboxVars and SandboxVars.TienGeneratorManager
    return vars ~= nil and vars[name] == true
end

-- Red squares cut power. Off: red counts as auto, cut devices come back on (uninstalling).
function TGM.cutsPower()
    return sandbox("CutPower")
end

-- Fridges and freezers on unpowered squares are unplugged (container type swap).
function TGM.unplugsFridges()
    return sandbox("CutPower") and sandbox("UnplugFridges")
end

local function gameOption(name, default)
    local option = getSandboxOptions():getOptionByName(name)
    if option then return option:getValue() end
    return default
end

function TGM.refreshGeom()
    local radius = gameOption("GeneratorTileRange", 20)
    local vr = gameOption("GeneratorVerticalPowerRange", 3)
    TGM.geomCache = {
        radius = radius,
        vr = vr,
        r2 = radius * radius,
        allowExt = gameOption("AllowExteriorGenerator", true) ~= false,
    }
    return TGM.geomCache
end

function TGM.geom()
    return TGM.geomCache or TGM.refreshGeom()
end

function TGM.fuelMultiplier()
    local v = gameOption("GeneratorFuelConsumption", 0.1)
    if type(v) == "number" and v > 0 then return v end
    return 0.1
end

-- IsoGenerator.isPoweringSquare: floors within reach, square centres within the radius
-- (the +0.5 of both centres cancel out).
function TGM.inRange(g, gx, gy, gz, x, y, z)
    if z < math.max(-32, gz - g.vr) or z > math.min(31, gz + g.vr) then return false end
    local dx, dy = x - gx, y - gy
    return dx * dx + dy * dy <= g.r2
end

function TGM.key(x, y, z)
    return x .. "," .. y .. "," .. z
end

function TGM.parseKey(key)
    if type(key) ~= "string" then return nil end
    local x, y, z = string.match(key, "^(-?%d+),(-?%d+),(-?%d+)$")
    if not x then return nil end
    return tonumber(x), tonumber(y), tonumber(z)
end

-- ---- generators --------------------------------------------------------------------

-- Known generators by key, coordinates only; the IsoGenerator is fetched from its square
-- each time, so a removed one never lingers. Filled from LoadGridsquare, placements seen
-- by clients (OnObjectAdded fires only there) and the clients' register command.
TGM.generators = TGM.generators or {}
TGM.dirty = true

function TGM.register(x, y, z)
    local key = TGM.key(x, y, z)
    if TGM.generators[key] then return key, false end
    TGM.generators[key] = { x = x, y = y, z = z, key = key }
    TGM.dirty = true
    return key, true
end

function TGM.registerGenerator(gen)
    local square = gen and gen:getSquare()
    if not square then return nil, false end
    return TGM.register(square:getX(), square:getY(), square:getZ())
end

-- (generator, "live"), (nil, "unloaded") or (nil, "gone")
function TGM.liveGenerator(e)
    local square = getSquare(e.x, e.y, e.z)
    if not square then return nil, "unloaded" end
    local gen = square:getGenerator()
    if not gen then return nil, "gone" end
    return gen, "live"
end

function TGM.generatorAt(x, y, z)
    local square = getSquare(x, y, z)
    return square and square:getGenerator() or nil
end

function TGM.settingsOf(gen)
    if not gen:hasModData() then return nil end
    local t = gen:getModData()[TGM.SETTINGS]
    if type(t) == "table" then return t end
    return nil
end

function TGM.floorKey(z)
    return TGM.ALL .. z
end

-- A square's own setting, else its floor's default (Connect all / Disconnect all on that
-- floor), else auto. z: the key's floor, read from the key when not given.
function TGM.settingAt(gen, key, z)
    local t = TGM.settingsOf(gen)
    if not t then return TGM.AUTO end
    local s = t[key]
    if s == TGM.GREEN or s == TGM.RED or s == TGM.AUTO then return s end
    if not z then
        local _, _, kz = TGM.parseKey(key)
        z = kz
    end
    s = z and t[TGM.floorKey(z)]
    if s == TGM.GREEN or s == TGM.RED then return s end
    return TGM.AUTO
end

-- ---- who powers a square -------------------------------------------------------------

local function closer(d, e, bestD, best)
    if not best or d < bestD then return true end
    if d > bestD then return false end
    if e.x ~= best.x then return e.x < best.x end
    if e.y ~= best.y then return e.y < best.y end
    return e.z < best.z
end

-- The generator entry powering x, y, z; TGM.OFF when every running generator in reach
-- has it red; nil when none reaches it (or the square is on mains power, or outdoors while
-- generators may not power outdoor squares): left to vanilla.
function TGM.resolve(x, y, z, square)
    local g = TGM.geom()
    square = square or getSquare(x, y, z)
    if square then
        if not g.allowExt and square:has(IsoFlagType.exterior) then return nil end
        if square:hasGridPower() then return nil end
    end
    local key = TGM.key(x, y, z)
    local cut = TGM.cutsPower()
    local green, greenD, auto, autoD
    local reached = false
    for _, e in pairs(TGM.generators) do
        if TGM.inRange(g, e.x, e.y, e.z, x, y, z) then
            local gen = TGM.liveGenerator(e)
            if gen and gen:isActivated() then
                reached = true
                local setting = TGM.settingAt(gen, key, z)
                if setting == TGM.RED and not cut then setting = TGM.AUTO end
                local dx, dy = x - e.x, y - e.y
                local d = dx * dx + dy * dy
                if setting == TGM.GREEN then
                    if closer(d, e, greenD, green) then green, greenD = e, d end
                elseif setting == TGM.AUTO then
                    if closer(d, e, autoD, auto) then auto, autoD = e, d end
                end
            end
        end
    end
    if green then return green end
    if auto then return auto end
    if reached then return TGM.OFF end
    return nil
end

-- ---- devices -------------------------------------------------------------------------

function TGM.isUnplugged(obj)
    return obj:hasModData() and type(obj:getModData()[TGM.TYPES]) == "table"
end

function TGM.isDevice(obj)
    return obj:couldBePoweredByGenerator() or TGM.isUnplugged(obj)
end

function TGM.devicesOn(square)
    local out = {}
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if TGM.isDevice(obj) then out[#out + 1] = obj end
    end
    return out
end

function TGM.isFridge(obj)
    if TGM.isUnplugged(obj) then return true end
    return obj:getContainerByEitherType("fridge", "freezer") ~= nil
end

-- A ceiling light switch: switches the lights of its whole room (IsoLightSwitch.switchLight).
-- The engine's private lightRoom flag is set exactly when the sprite has no light colour
-- (lamps carry "lightR"/"lightG"/"lightB").
function TGM.isRoomLight(obj)
    if not instanceof(obj, "IsoLightSwitch") then return false end
    local props = obj:getProperties()
    if props and props:has("lightR") then return false end
    local square = obj:getSquare()
    return square ~= nil and square:getRoom() ~= nil
end

-- true / false for a device with a switch that runs on generator power, nil for the rest
-- (fridges and freezers, fuel pumps, a radio or TV on batteries).
function TGM.isOn(obj)
    if instanceof(obj, "IsoLightSwitch") then return obj:isActivated() end
    if instanceof(obj, "IsoStove") then return obj:Activated() end
    if instanceof(obj, "IsoTelevision") or instanceof(obj, "IsoRadio") then
        local data = obj:getDeviceData()
        if not data or data:getIsBatteryPowered() then return nil end
        return data:getIsTurnedOn()
    end
    if instanceof(obj, "IsoStackedWasherDryer") then
        return obj:isWasherActivated() or obj:isDryerActivated()
    end
    if instanceof(obj, "IsoCombinationWasherDryer") or instanceof(obj, "IsoClothingWasher")
            or instanceof(obj, "IsoClothingDryer") or instanceof(obj, "IsoCarBatteryCharger") then
        return obj:isActivated()
    end
    return nil
end

function TGM.draw(obj)
    local v = obj:getGeneratorPowerConsumption()
    if type(v) == "number" then return v end
    return 0
end

-- A readable name (client side; the server never needs it).
function TGM.deviceName(obj)
    if instanceof(obj, "IsoLightSwitch") then
        return getText(TGM.isRoomLight(obj) and "IGUI_TGM_RoomLights" or "IGUI_TGM_Lamp")
    end
    local props = obj:getProperties()
    if props and props:has("CustomName") then
        local name = props:get("CustomName")
        if props:has("GroupName") then name = props:get("GroupName") .. " " .. name end
        return Translator.getMoveableDisplayName(name)
    end
    if TGM.isUnplugged(obj) or obj:getContainerByEitherType("fridge", "freezer") then
        return getText("IGUI_TGM_Fridge")
    end
    if obj:getPipedFuelAmount() > 0 then return getText("IGUI_TGM_FuelPump") end
    local byClass = {
        { "IsoStove", "IGUI_TGM_Stove" }, { "IsoTelevision", "IGUI_TGM_Television" },
        { "IsoRadio", "IGUI_TGM_Radio" }, { "IsoCarBatteryCharger", "IGUI_TGM_Charger" },
        { "IsoStackedWasherDryer", "IGUI_TGM_WasherDryer" },
        { "IsoCombinationWasherDryer", "IGUI_TGM_WasherDryer" },
        { "IsoClothingWasher", "IGUI_TGM_Washer" }, { "IsoClothingDryer", "IGUI_TGM_Dryer" },
    }
    for i = 1, #byClass do
        if instanceof(obj, byClass[i][1]) then return getText(byClass[i][2]) end
    end
    return getText("IGUI_TGM_Device")
end

-- ---- one pass over every running generator's reach ---------------------------------

-- TGM.state, rebuilt by recompute():
--   byGen[genKey] = { total = raw draw incl. base, squares = device squares it powers,
--                     items = { { label, count, draw } } (withNames only) }
--   cut[squareKey] = { x, y, z }   device squares that resolve to TGM.OFF
--   roomPowered[room] / roomCut[room] = true   rooms with a ceiling switch on a powered /
--                                             unpowered square
TGM.state = TGM.state or { byGen = {}, cut = {}, roomPowered = {}, roomCut = {} }

function TGM.recompute(withNames)
    local g = TGM.refreshGeom()
    local state = { byGen = {}, cut = {}, roomPowered = {}, roomCut = {} }
    local labels = {}
    local seen = {}
    local gone = {}
    for key, e in pairs(TGM.generators) do
        local gen, status = TGM.liveGenerator(e)
        if status == "gone" then
            gone[#gone + 1] = key
        elseif gen and gen:isActivated() then
            state.byGen[key] = { total = TGM.BASE_DRAW, squares = 0, items = {} }
            labels[key] = {}
        end
    end
    for i = 1, #gone do TGM.generators[gone[i]] = nil end

    for key, e in pairs(TGM.generators) do
        if state.byGen[key] then
            for z = math.max(-32, e.z - g.vr), math.min(31, e.z + g.vr) do
                for x = e.x - g.radius, e.x + g.radius do
                    local dx = x - e.x
                    for y = e.y - g.radius, e.y + g.radius do
                        local dy = y - e.y
                        if dx * dx + dy * dy <= g.r2 then
                            local sKey = TGM.key(x, y, z)
                            if not seen[sKey] then
                                seen[sKey] = true
                                local square = getSquare(x, y, z)
                                if square then
                                    local devices = TGM.devicesOn(square)
                                    if #devices > 0 then
                                        local owner = TGM.resolve(x, y, z, square)
                                        if owner == TGM.OFF then
                                            state.cut[sKey] = { x = x, y = y, z = z }
                                        end
                                        local info = owner and owner ~= TGM.OFF and state.byGen[owner.key]
                                        if info then info.squares = info.squares + 1 end
                                        for d = 1, #devices do
                                            local obj = devices[d]
                                            if TGM.isRoomLight(obj) then
                                                local room = square:getRoom()
                                                if owner == TGM.OFF then
                                                    state.roomCut[room] = true
                                                elseif owner then
                                                    state.roomPowered[room] = true
                                                end
                                            end
                                            if info then
                                                local draw = TGM.draw(obj)
                                                info.total = info.total + draw
                                                if withNames then
                                                    local label = TGM.deviceName(obj)
                                                    local item = labels[owner.key][label]
                                                    if not item then
                                                        item = { label = label, count = 0, draw = 0 }
                                                        labels[owner.key][label] = item
                                                        info.items[#info.items + 1] = item
                                                    end
                                                    item.count = item.count + 1
                                                    item.draw = item.draw + draw
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    TGM.state = state
    TGM.dirty = false
    return state
end

-- The cheap half, every tick: put each running generator's billed draw back after the
-- engine's own geometric recompute (setSurroundingElectricity) overwrote it.
-- getTotalPowerUsing() returns the raw value times GeneratorFuelConsumption (a Java float),
-- setTotalPowerUsing takes the raw value.
function TGM.reassert()
    local mult = TGM.fuelMultiplier()
    for key, info in pairs(TGM.state.byGen) do
        local e = TGM.generators[key]
        local gen = e and TGM.liveGenerator(e)
        if gen and gen:isActivated() and math.abs(gen:getTotalPowerUsing() - info.total * mult) > 0.00001 then
            gen:setTotalPowerUsing(info.total)
        end
    end
end

-- ---- requests ------------------------------------------------------------------------

-- Ask for squares (keys) of the generator at gx, gy, gz to be set to state (g, r or a);
-- keys == TGM.ALL sets floor's default and clears the own setting of every square on it.
-- Multiplayer: a command the server checks and applies. Single player: applied here
-- (sendServerCommand does nothing outside a server, so the reply is called directly).
function TGM.requestSet(player, gx, gy, gz, keys, state, floor)
    local args = { gx = gx, gy = gy, gz = gz, state = state }
    if keys == TGM.ALL then
        args.all = true
        args.floor = floor
    else
        args.keys = keys
    end
    if isClient() then
        sendClientCommand(player, TGM.MODULE, "set", args)
    elseif TGM.applySet then
        local ok, reason = TGM.applySet(player, args)
        if TGM.onReply then TGM.onReply(ok and "applied" or "refused", { gx = gx, gy = gy, gz = gz, reason = reason }) end
    end
end

function TGM.requestRegister(player, gx, gy, gz)
    if isClient() then
        sendClientCommand(player, TGM.MODULE, "register", { gx = gx, gy = gy, gz = gz })
    else
        TGM.register(gx, gy, gz)
    end
end

-- ---- registry events (every machine) ---------------------------------------------------

local function onLoadGridsquare(square)
    if square:getGenerator() then
        TGM.registerGenerator(square:getGenerator())
    end
    if TGM.onSquareLoaded then TGM.onSquareLoaded(square) end
end

local function onObjectAdded(obj)
    if instanceof(obj, "IsoGenerator") then
        TGM.registerGenerator(obj)
        if TGM.onGeneratorAdded then TGM.onGeneratorAdded(obj) end
    end
end

local function onObjectAboutToBeRemoved(obj)
    if instanceof(obj, "IsoGenerator") then
        TGM.dirty = true
    end
end

Events.LoadGridsquare.Add(onLoadGridsquare)
Events.OnObjectAdded.Add(onObjectAdded)
Events.OnObjectAboutToBeRemoved.Add(onObjectAboutToBeRemoved)
