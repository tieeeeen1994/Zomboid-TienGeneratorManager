--[[
    Tien's Generator Manager -- client: the update loop of a multiplayer client, the menu
    entry, the server's replies, the vanilla Info window, and the world highlight of the
    devices on the square the mouse is over in the map.

    A multiplayer client resolves squares and bills generators itself only for what it
    shows: the map, and the vanilla Generator Info window, which reads the client's copy of
    totalPowerUsing (re-asserted here too, else it shows the engine's geometric value). The
    server does the real billing, cutting and restoring. In single player the server file
    runs in the same Lua state and keeps TGM.state; nothing here repeats it.

    Highlight: an outline (setOutlineHighlightCol + setOutlineHighlight, re-applied every
    tick) is drawn by FBORenderObjectOutline only while the game draws the object
    (renderInfo.layer not None, alpha above 0), so nothing shows for a device on a floor
    that is cut away above the player or covered below. Every highlighted device therefore
    also gets a dot drawn from OnPreUIDraw (after the world, before the UI) at
    isoToScreenX/Y(playerNum, x + 0.5, y + 0.5, z) (absolute screen pixels, zoom included)
    with getRenderer():render(tex, x, y, w, h, r, g, b, a, nil) (the only overload), labelled
    with how many floors up or down it is. ISInventoryPage.OnObjectHighlighted keeps the loot
    window from repainting a highlighted fridge (vanilla's own hover highlights do the same).
--]]

require "TienGeneratorManager"
require "ISUI/ISGeneratorInfoWindow"
require "Definitions/ContainerButtonIcons"

local TGM = TienGeneratorManager

-- unplugged fridges keep the fridge icons in the loot window
if ContainerButtonIcons then
    ContainerButtonIcons.tgm_fridge = ContainerButtonIcons.fridge
    ContainerButtonIcons.tgm_freezer = ContainerButtonIcons.freezer
end

-- ---- update loop (multiplayer clients) ------------------------------------------------

local lastPass = 0
local PASS_MS = 2000

local function onTick()
    if not isClient() then return end
    TGM.reassert()
    local now = getTimestampMs()
    if TGM.dirty or now - lastPass >= PASS_MS then
        lastPass = now
        TGM.recompute(true)
    end
end

local function onEveryOneMinute()
    TGM.dirty = true
end

-- the server has no event for a generator placed on a loaded chunk: tell it
function TGM.onGeneratorAdded(gen)
    if not isClient() then return end
    local player = getSpecificPlayer(0)
    local square = gen:getSquare()
    if player and square then
        TGM.requestRegister(player, square:getX(), square:getY(), square:getZ())
    end
end

-- ---- replies -------------------------------------------------------------------------

function TGM.onReply(command, args)
    TGM.dirty = true
    if not isClient() then
        -- single player: the server pass already ran, names included
    else
        TGM.recompute(true)
        lastPass = getTimestampMs()
    end
    if TGM.Map and TGM.Map.onReply then TGM.Map.onReply(command, args or {}) end
end

local function onServerCommand(module, command, args)
    if module ~= TGM.MODULE then return end
    if command == "applied" or command == "refused" then
        TGM.onReply(command, args)
    end
end

-- ---- menu ----------------------------------------------------------------------------

local function onManagePower(worldObjects, gen, playerNum)
    local player = getSpecificPlayer(playerNum)
    if player and TGM.Map then TGM.Map.open(player, gen) end
end

local function onFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    if test then return end
    local player = getSpecificPlayer(playerNum)
    if not player or player:getVehicle() then return end
    local gen = nil
    for _, obj in ipairs(worldObjects) do
        local square = obj:getSquare()
        gen = square and square:getGenerator()
        if gen then break end
    end
    if not gen then return end
    local option = context:getOptionFromName(getText("ContextMenu_Generator"))
    local menu = option and option.subOption and context:getSubMenu(option.subOption) or context
    menu:addOption(getText("ContextMenu_TGM_ManagePower"), worldObjects, onManagePower, gen, playerNum)
    local Range = TGM.Range
    if Range then
        local rangeShown = Range.isRangeShown(gen)
        menu:addOption(getText(rangeShown and "ContextMenu_TGM_HideRange" or "ContextMenu_TGM_ShowRange"),
            gen, Range.toggleRange, playerNum)
        local devicesShown = Range.isDevicesShown(gen)
        menu:addOption(getText(devicesShown and "ContextMenu_TGM_HideDevices" or "ContextMenu_TGM_ShowDevices"),
            gen, Range.toggleDevices, playerNum)
    end
end

-- ---- vanilla Generator Info window: what this generator really powers -------------------

local function fmtLh(v)
    return string.format("%.3f", v)
end

local vanillaRichText = ISGeneratorInfoWindow.getRichText

function ISGeneratorInfoWindow.getRichText(object, displayStats, ...)
    local square = displayStats and object:getSquare()
    local info = square and TGM.state.byGen[TGM.key(square:getX(), square:getY(), square:getZ())]
    if not info or not object:isActivated() then
        return vanillaRichText(object, displayStats, ...)
    end
    local fuel = math.ceil(object:getFuelPercentage())
    local text = getText("IGUI_Generator_FuelAmount", fuel) .. " <LINE> "
        .. getText("IGUI_Generator_Condition", object:getCondition()) .. " <LINE> "
    text = text .. " <LINE> " .. getText("IGUI_PowerConsumption") .. ": <LINE> <INDENT:10> "
    local mult = TGM.fuelMultiplier()
    for i = 1, #info.items do
        local item = info.items[i]
        text = text .. "   " .. item.label .. " x" .. string.format("%d", item.count)
            .. " (" .. fmtLh(item.draw * mult) .. " L/h) <LINE> "
    end
    text = text .. getText("IGUI_Generator_TypeGas") .. " (" .. object:getBasePowerConsumptionString() .. ") <LINE> "
    text = text .. getText("IGUI_Total") .. ": " .. object:getTotalPowerUsingString() .. " <LINE> "
    if not square:isOutside() and square:getBuilding() then
        text = text .. " <LINE> <RED> " .. getText("IGUI_Generator_IsToxic")
    end
    return text
end

-- ---- world highlight: outlines + screen markers -------------------------------------------

-- Sources of highlighted objects, each { [object] = { playerNum, r, g, b } }; a later source
-- in ORDER wins for an object in both. "devices" = Show devices (range file), "hover" = the
-- devices of the square under the mouse in the map (yellow).
local ORDER = { "devices", "hover" }
local HOVER = { r = 1.0, g = 0.85, b = 0.1 }
local MARKER = 14

TGM.Highlight = TGM.Highlight or {}
local Highlight = TGM.Highlight
Highlight.sources = {}
Highlight.applied = {}  -- object -> { playerNum, r, g, b, wasOutlined }

function Highlight.setSource(name, objects)
    Highlight.sources[name] = objects
end

function Highlight.set(playerNum, objects)
    local map = {}
    for i = 1, #(objects or {}) do
        map[objects[i]] = { playerNum = playerNum, r = HOVER.r, g = HOVER.g, b = HOVER.b }
    end
    Highlight.sources.hover = map
end

function Highlight.clear()
    Highlight.sources.hover = nil
end

local function unapply(obj, mark)
    obj:setOutlineHighlight(mark.playerNum, mark.wasOutlined)
    ISInventoryPage.OnObjectHighlighted(mark.playerNum, obj, false)
end

local function updateHighlight()
    local wanted = {}
    for i = 1, #ORDER do
        local source = Highlight.sources[ORDER[i]]
        if source then
            for obj, spec in pairs(source) do wanted[obj] = spec end
        end
    end
    for obj, mark in pairs(Highlight.applied) do
        local spec = wanted[obj]
        if not spec or spec.playerNum ~= mark.playerNum then
            unapply(obj, mark)
            Highlight.applied[obj] = nil
        end
    end
    for obj, spec in pairs(wanted) do
        local mark = Highlight.applied[obj]
        if not mark then
            mark = { playerNum = spec.playerNum, wasOutlined = obj:isOutlineHighlight(spec.playerNum) }
            Highlight.applied[obj] = mark
            ISInventoryPage.OnObjectHighlighted(spec.playerNum, obj, true)
        end
        mark.r, mark.g, mark.b = spec.r, spec.g, spec.b
        obj:setOutlineHighlightCol(spec.playerNum, spec.r, spec.g, spec.b, 0.9)
        obj:setOutlineHighlight(spec.playerNum, true)
    end
end

local circle = nil

local function drawMarker(obj, playerNum, r, g, b)
    local square = obj:getSquare()
    local player = getSpecificPlayer(playerNum)
    if not square or not player or obj:getObjectIndex() == -1 then return end
    local x, y, z = square:getX(), square:getY(), square:getZ()
    local sx = isoToScreenX(playerNum, x + 0.5, y + 0.5, z)
    local sy = isoToScreenY(playerNum, x + 0.5, y + 0.5, z) - MARKER
    local left, top = getPlayerScreenLeft(playerNum), getPlayerScreenTop(playerNum)
    if sx < left or sy < top or sx > left + getPlayerScreenWidth(playerNum)
            or sy > top + getPlayerScreenHeight(playerNum) then
        return
    end
    local renderer = getRenderer()
    renderer:render(circle, sx - MARKER / 2 - 2, sy - MARKER / 2 - 2, MARKER + 4, MARKER + 4, 0, 0, 0, 0.85, nil)
    renderer:render(circle, sx - MARKER / 2, sy - MARKER / 2, MARKER, MARKER, r, g, b, 1, nil)
    local floors = z - math.floor(player:getZ())
    if floors ~= 0 then
        local text = floors > 0
            and getText("IGUI_TGM_FloorsUp", string.format("%d", floors))
            or getText("IGUI_TGM_FloorsDown", string.format("%d", -floors))
        local tm = getTextManager()
        local ty = sy + MARKER / 2 + 1
        tm:DrawStringCentre(UIFont.Small, sx + 1, ty + 1, text, 0, 0, 0, 1)
        tm:DrawStringCentre(UIFont.Small, sx, ty, text, r, g, b, 1)
    end
end

local drawFailed = false

local function onPreUIDraw()
    if drawFailed then return end
    local ok, err = pcall(function()
        if not circle then circle = getTexture("media/ui/circle.png") end
        if not circle then return end
        -- several objects on one square (or one multi-tile device): one dot per square
        local done = {}
        for obj, mark in pairs(Highlight.applied) do
            local square = obj:getSquare()
            if square and not done[square] then
                done[square] = true
                drawMarker(obj, mark.playerNum, mark.r, mark.g, mark.b)
            end
        end
    end)
    if not ok then
        drawFailed = true
        TGM.log("markers stopped after an error: " .. tostring(err))
    end
end

local highlightFailed = false

local function onTickHighlight()
    if highlightFailed then return end
    local ok, err = pcall(updateHighlight)
    if not ok then
        highlightFailed = true
        TGM.log("highlight stopped after an error: " .. tostring(err))
    end
end

-- after every mod's file-level handlers (other mods' outlines are set before ours each tick)
local handlersAdded = false
Events.OnGameStart.Add(function()
    if handlersAdded then return end
    handlersAdded = true
    Events.OnTick.Add(onTickHighlight)
    Events.OnPreUIDraw.Add(onPreUIDraw)
end)

Events.OnTick.Add(onTick)
Events.EveryOneMinute.Add(onEveryOneMinute)
Events.OnServerCommand.Add(onServerCommand)
Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
