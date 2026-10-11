--[[
    Tien's Generator Manager -- server: bills fuel, cuts and restores power, takes the map's
    requests. Runs on a dedicated server, on the host of a hosted game and in single player.

    Unpowered squares are an emulated power cut (a square cannot really lose power, see the
    shared file):
    - Devices with a switch that are on get switched off and remembered (modData WAS_ON), and
      anything switched on there is switched off again within a second. Once the square has
      power again (or no running generator reaches it any more, or CutPower is turned off)
      they are switched back on: the same as power coming back. All calls are server ones
      that sync themselves: IsoLightSwitch.setActive (switchLight + syncIsoObject, plus the
      room's lightsActive through GameServer.sendMetaGrid), IsoStove.setActivated + sync(),
      washers/dryers setActivated + sendObjectChange(WASHER_STATE / DRYER_STATE) as
      ISToggleClothingWasher does, IsoCarBatteryCharger.setActivated + sync() as
      ISActivateCarBatteryChargerAction does, DeviceData.setIsTurnedOn (transmits itself).
    - Ceiling lights switch their whole room (IsoLightSwitch.switchLight sets every switch of
      the room), so a room is cut only when none of its switches is on a powered square.
    - Fridges and freezers have no switch: the food code asks the square's power directly
      (Food ~756 ageing: getSourceGrid().haveElectricity(); Food.isFreezing: isInFreezer and
      isPowered()), but every such test first asks isFridge()/isFreezer(), which compare the
      container type. So they are unplugged by ItemContainer.setType("tgm_fridge" /
      "tgm_freezer") and plugged back with the original types (modData TYPES). Then the food
      ages at the normal rate, thaws, warms to 1.0 and nothing freezes, exactly as in a
      fridge without power, and the fridge draws nothing. The type is saved with the
      container (ItemContainer.save) and sent to clients with
      sendObjectChange(IsoObjectChange.CONTAINERS), which rebuilds their containers in place.

    Squares with a mark are kept in TGM.marked (and found again by LoadGridsquare after a
    restart or when their chunk loads), so a device is never left cut once its square has
    power again.

    Fuel: TGM.recompute bills every device square to the generator powering it and TGM.reassert
    puts that back on each generator every tick (only the server drains:
    IsoGenerator.update returns early on clients). A generator first updated after its
    chunk loads drains the hours it missed at the engine's own geometric value; devices on
    cut squares are really off by then, so only shared squares are over-billed for that
    catch-up.
--]]

require "TienGeneratorManager"

if isClient() then return end

local TGM = TienGeneratorManager

TGM.marked = TGM.marked or {}

-- ---- switching -----------------------------------------------------------------------

local function sendWasherDryer(obj, washer, dryer)
    if washer then obj:sendObjectChange(IsoObjectChange.WASHER_STATE) end
    if dryer then obj:sendObjectChange(IsoObjectChange.DRYER_STATE) end
end

-- Switches a device off; returns what to give back later (true, or "w"/"d"/"wd" for a
-- stacked washer and dryer).
local function switchOff(obj)
    if instanceof(obj, "IsoLightSwitch") then
        obj:setActive(false, false, true)
        return true
    elseif instanceof(obj, "IsoStove") then
        obj:setActivated(false)
        obj:sync()
        return true
    elseif instanceof(obj, "IsoTelevision") or instanceof(obj, "IsoRadio") then
        obj:getDeviceData():setIsTurnedOn(false)
        return true
    elseif instanceof(obj, "IsoStackedWasherDryer") then
        local washer, dryer = obj:isWasherActivated(), obj:isDryerActivated()
        obj:setWasherActivated(false)
        obj:setDryerActivated(false)
        sendWasherDryer(obj, washer, dryer)
        return (washer and "w" or "") .. (dryer and "d" or "")
    elseif instanceof(obj, "IsoCombinationWasherDryer") then
        obj:setActivated(false)
        sendWasherDryer(obj, obj:isModeWasher(), not obj:isModeWasher())
        return true
    elseif instanceof(obj, "IsoClothingWasher") then
        obj:setActivated(false)
        sendWasherDryer(obj, true, false)
        return true
    elseif instanceof(obj, "IsoClothingDryer") then
        obj:setActivated(false)
        sendWasherDryer(obj, false, true)
        return true
    elseif instanceof(obj, "IsoCarBatteryCharger") then
        obj:setActivated(false)
        obj:sync()
        return true
    end
    return nil
end

local function switchOn(obj, was)
    if instanceof(obj, "IsoLightSwitch") then
        obj:setActive(true, false, true)
    elseif instanceof(obj, "IsoStove") then
        obj:setActivated(true)
        obj:sync()
    elseif instanceof(obj, "IsoTelevision") or instanceof(obj, "IsoRadio") then
        obj:getDeviceData():setIsTurnedOn(true)
    elseif instanceof(obj, "IsoStackedWasherDryer") then
        local washer = type(was) == "string" and string.find(was, "w", 1, true) ~= nil
        local dryer = type(was) == "string" and string.find(was, "d", 1, true) ~= nil
        if washer then obj:setWasherActivated(true) end
        if dryer then obj:setDryerActivated(true) end
        sendWasherDryer(obj, washer, dryer)
    elseif instanceof(obj, "IsoCombinationWasherDryer") then
        obj:setActivated(true)
        sendWasherDryer(obj, obj:isModeWasher(), not obj:isModeWasher())
    elseif instanceof(obj, "IsoClothingWasher") then
        obj:setActivated(true)
        sendWasherDryer(obj, true, false)
    elseif instanceof(obj, "IsoClothingDryer") then
        obj:setActivated(true)
        sendWasherDryer(obj, false, true)
    elseif instanceof(obj, "IsoCarBatteryCharger") then
        obj:setActivated(true)
        obj:sync()
    end
end

local function unplug(obj)
    local types = {}
    local changed = false
    for i = 0, obj:getContainerCount() - 1 do
        local container = obj:getContainerByIndex(i)
        local offType = container and TGM.UNPLUGGED_TYPE[container:getType()]
        if offType then
            types[i + 1] = container:getType()
            container:setType(offType)
            changed = true
        end
    end
    if not changed then return false end
    obj:getModData()[TGM.TYPES] = types
    obj:sendObjectChange(IsoObjectChange.CONTAINERS)
    obj:transmitModData()
    return true
end

local function plugIn(obj)
    local md = obj:getModData()
    local types = md[TGM.TYPES]
    if type(types) == "table" then
        for index, original in pairs(types) do
            local container = obj:getContainerByIndex(index - 1)
            if container and TGM.PLUGGED_TYPE[container:getType()] == original then
                container:setType(original)
            end
        end
    end
    md[TGM.TYPES] = nil
    obj:sendObjectChange(IsoObjectChange.CONTAINERS)
    obj:transmitModData()
end

-- ---- cutting and restoring -----------------------------------------------------------

local function markSquare(square)
    local x, y, z = square:getX(), square:getY(), square:getZ()
    TGM.marked[TGM.key(x, y, z)] = { x = x, y = y, z = z }
end

local function remember(obj, was)
    local md = obj:getModData()
    if md[TGM.WAS_ON] == nil and was ~= nil and was ~= "" then
        md[TGM.WAS_ON] = was
    end
end

-- A square with devices every running generator that reaches them has red: keep those
-- without power (decided per device: light switches reach further, TGM.resolveDevice).
-- Returns true when it switched something off.
local function cutSquare(square)
    local changed = false
    local devices = TGM.devicesOn(square)
    for i = 1, #devices do
        local obj = devices[i]
        if TGM.resolveDevice(obj, square) ~= TGM.OFF then
            -- powered (or left to vanilla): nothing to cut
        elseif TGM.isFridge(obj) then
            if TGM.unplugsFridges() and not TGM.isUnplugged(obj) and unplug(obj) then
                markSquare(square)
                changed = true
            end
        elseif TGM.isRoomLight(obj) then
            if not TGM.state.roomPowered[square:getRoom()] and obj:isActivated() then
                remember(obj, switchOff(obj))
                markSquare(square)
                changed = true
            end
        elseif TGM.isOn(obj) == true then
            remember(obj, switchOff(obj))
            markSquare(square)
            changed = true
        end
    end
    return changed
end

-- A square with cut devices: give them back once it has power (or is left to vanilla).
local function restoreSquare(square, key)
    local left = false
    local changed = false
    local devices = TGM.devicesOn(square)
    for i = 1, #devices do
        local obj = devices[i]
        local stillCut = TGM.resolveDevice(obj, square) == TGM.OFF
        if TGM.isUnplugged(obj) then
            if stillCut and TGM.unplugsFridges() then
                left = true
            else
                plugIn(obj)
                changed = true
            end
        end
        local was = obj:hasModData() and obj:getModData()[TGM.WAS_ON]
        if was then
            local keepCut = stillCut
            if TGM.isRoomLight(obj) then
                keepCut = stillCut and not TGM.state.roomPowered[square:getRoom()]
            end
            if keepCut then
                left = true
            else
                obj:getModData()[TGM.WAS_ON] = nil
                switchOn(obj, was)
                changed = true
            end
        end
    end
    if not left then TGM.marked[key] = nil end
    return changed
end

local function restoreAll()
    local changed = false
    for key, s in pairs(TGM.marked) do
        local square = getSquare(s.x, s.y, s.z)
        if square and restoreSquare(square, key) then changed = true end
    end
    return changed
end

local function cutAll()
    local changed = false
    for _, s in pairs(TGM.state.cut) do
        local square = getSquare(s.x, s.y, s.z)
        if square and cutSquare(square) then changed = true end
    end
    return changed
end

-- Recompute when something changed, give back what has power again, cut what has none.
-- Switching changes what is drawn, so a pass that switched anything bills again in the next
-- one (a second later).
function TGM.serverPass(force)
    local changed = false
    if force or TGM.dirty then
        TGM.recompute(not isServer())
        changed = restoreAll()
    end
    if TGM.cutsPower() and cutAll() then changed = true end
    if changed then TGM.dirty = true end
end

-- ---- loop ----------------------------------------------------------------------------

local lastSecond = 0
local lastActive = {}
local failed = false

local function everySecond()
    for key, e in pairs(TGM.generators) do
        local gen = TGM.liveGenerator(e)
        local active = gen ~= nil and gen:isActivated()
        if lastActive[key] ~= active then
            lastActive[key] = active
            TGM.dirty = true
        end
    end
    TGM.serverPass(false)
end

local function onTick()
    if failed then return end
    local ok, err = pcall(function()
        TGM.reassert()
        local now = getTimestampMs()
        if now - lastSecond >= 1000 then
            lastSecond = now
            everySecond()
        end
    end)
    if not ok then
        failed = true
        TGM.log("stopped after an error: " .. tostring(err))
    end
end

local function onEveryOneMinute()
    -- new or moved devices, changed sandbox options
    TGM.dirty = true
end

-- Marked devices are found again when their chunk loads (after a restart, or when a player
-- comes back), so they are given back or kept cut by the next pass.
function TGM.onSquareLoaded(square)
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if obj:hasModData() then
            local md = obj:getModData()
            if md[TGM.WAS_ON] ~= nil or md[TGM.TYPES] ~= nil then
                markSquare(square)
                TGM.dirty = true
                return
            end
        end
    end
end

-- ---- requests ------------------------------------------------------------------------

local MAX_KEYS = 5000

-- Returns true, or false and a reason (an IG_UI key).
function TGM.applySet(player, args)
    local gx, gy, gz = tonumber(args.gx), tonumber(args.gy), tonumber(args.gz)
    local state = args.state
    local all = args.all == true
    local floor = tonumber(args.floor)
    if not (gx and gy and gz) or (not all and type(args.keys) ~= "table") or (all and not floor)
            or (state ~= TGM.GREEN and state ~= TGM.RED and state ~= TGM.AUTO) then
        return false, "IGUI_TGM_Refused"
    end
    local gen = TGM.generatorAt(gx, gy, gz)
    if not gen then return false, "IGUI_TGM_RefusedNoGenerator" end
    local g = TGM.refreshGeom()
    if player then
        if math.abs(player:getX() - gx) > g.radius + 5 or math.abs(player:getY() - gy) > g.radius + 5 then
            return false, "IGUI_TGM_RefusedTooFar"
        end
        if not SafeHouse.isSafehouseAllowInteract(gen:getSquare(), player) then
            return false, "IGUI_TGM_RefusedSafehouse"
        end
    end
    local md = gen:getModData()
    local settings = md[TGM.SETTINGS]
    if type(settings) ~= "table" then settings = {} end
    local count = 0
    if all then
        -- every square of one floor in reach: that floor's default, its squares' own settings cleared
        if floor < math.max(-32, gz - g.vr) or floor > math.min(31, gz + g.vr + 1) then
            return false, "IGUI_TGM_Refused"
        end
        local kept = {}
        for key, value in pairs(settings) do
            local _, _, z = TGM.parseKey(key)
            if z ~= floor and key ~= TGM.floorKey(floor) then kept[key] = value end
        end
        settings = kept
        if state ~= TGM.AUTO then settings[TGM.floorKey(floor)] = state end
        count = -1
    else
        for _, key in pairs(args.keys) do
            count = count + 1
            if count > MAX_KEYS then break end
            local x, y, z = TGM.parseKey(key)
            -- in reach, or within one tile of it (lights, see TGM.reachesAround)
            if x and TGM.nearRange(g, gx, gy, gz, x, y, z) then
                -- auto against a floor default of connect / disconnect has to be stored, or
                -- the square would fall back to that default; otherwise auto = no entry
                local floorDefault = settings[TGM.floorKey(z)]
                if state == TGM.AUTO and floorDefault ~= TGM.GREEN and floorDefault ~= TGM.RED then
                    settings[key] = nil
                else
                    settings[key] = state
                end
            end
        end
    end
    md[TGM.SETTINGS] = settings
    gen:transmitModData()
    TGM.register(gx, gy, gz)
    TGM.serverPass(true)
    if player and isServer() then
        TGM.log(string.format("%s set %s of the generator at %d,%d,%d to %s", player:getUsername(),
            all and string.format("every square of floor %d", floor) or string.format("%d squares", count),
            gx, gy, gz, state))
    end
    return true
end

local function onClientCommand(module, command, player, args)
    if module ~= TGM.MODULE then return end
    args = args or {}
    if command == "set" then
        local ok, reason = TGM.applySet(player, args)
        local reply = { gx = args.gx, gy = args.gy, gz = args.gz, reason = reason }
        if ok then
            sendServerCommand(TGM.MODULE, "applied", reply)
        else
            sendServerCommand(player, TGM.MODULE, "refused", reply)
        end
    elseif command == "register" then
        local gx, gy, gz = tonumber(args.gx), tonumber(args.gy), tonumber(args.gz)
        if gx and gy and gz and TGM.generatorAt(gx, gy, gz) then
            TGM.register(gx, gy, gz)
        end
    end
end

Events.OnTick.Add(onTick)
Events.EveryOneMinute.Add(onEveryOneMinute)
Events.OnClientCommand.Add(onClientCommand)
