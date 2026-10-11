--[[
    Tien's Generator Manager -- client: Show range and Show devices (Generator submenu)

    Show range tints every square the generator reaches on the player's floor: a faint even
    fill, edge to edge, with a stronger band along the boundary. Show devices outlines every
    device in reach on every floor, coloured by who powers it (green this generator, blue
    another one, red nobody: power cut, grey no running generator), with the screen markers
    of the highlight (client file) so devices on other floors are found too. One generator
    at a time for each.

    The tint is made of WorldMarkers grid square markers (42.21), drawn in the default
    renderer by FBORenderWorldMarkers.render: one flat quad on the floor per marker, centred
    on the square, (size * 0.69) tiles from the centre to each side, depth tested so walls and
    objects stand in front of it. size = 0.5 / 0.69 fills exactly one tile, so neighbours join
    into one surface. Only the vanilla circle textures are mapped there; any other texture
    name leaves the quad untextured (VBORenderer: textureId null = GL_TEXTURE_2D off), i.e. a
    flat colour, and the second (overlay) quad is drawn the same way, so the alpha is applied
    twice (1 - (1 - a)^2). GridSquareMarker.init still loads
    media/textures/highlights/<name>.png and reads its width (missing = error), so the mod
    ships tgm_fill.png, a tile-shaped diamond the older renderer would draw. The alpha
    always runs the fade between alphaMin and alphaMax (WorldMarkers update), so a steady
    tint is fadeSpeed 0 with min = max. Markers are drawn only on the player's floor
    (renderGridSquareMarkers: m.z == player.getZ()), so only that floor gets markers, rebuilt
    when the player changes floor (and every 10 s, for squares loaded meanwhile).
--]]

require "TienGeneratorManager"

local TGM = TienGeneratorManager

TGM.Range = TGM.Range or {}
local Range = TGM.Range

local FILL_TEXTURE = "tgm_fill"
local TILE_SIZE = 0.5 / 0.69
local FILL = { r = 0.3, g = 0.95, b = 0.45, a = 0.07 }   -- a per quad (two quads drawn)
local EDGE = { r = 0.3, g = 0.95, b = 0.45, a = 0.25 }
local RANGE_REBUILD_MS = 10000
local DEVICES_SCAN_MS = 1000

local DEVICE_COLOR = {
    this = { 0.2, 0.9, 0.25 },
    other = { 0.35, 0.6, 1 },
    off = { 0.9, 0.2, 0.2 },
    none = { 0.6, 0.6, 0.6 },
}

local function genCoords(gen)
    local square = gen:getSquare()
    if not square then return nil end
    return square:getX(), square:getY(), square:getZ()
end

-- ---- range ---------------------------------------------------------------------------

Range.range = nil   -- { key, x, y, z, playerNum, floor, built, markers }

local function clearMarkers(r)
    for i = 1, #r.markers do r.markers[i]:remove() end
    r.markers = {}
end

local function tileMarker(square, c)
    local m = getWorldMarkers():addGridSquareMarker(FILL_TEXTURE, nil, square, c.r, c.g, c.b, true, TILE_SIZE, 0, c.a, c.a)
    if m then m:setAlpha(c.a) end
    return m
end

local function buildRange(r)
    clearMarkers(r)
    local player = getSpecificPlayer(r.playerNum)
    r.built = getTimestampMs()
    if not player then return end
    local z = math.floor(player:getZ())
    r.floor = z
    local g = TGM.refreshGeom()
    if z < math.max(-32, r.z - g.vr) or z > math.min(31, r.z + g.vr) then return end
    local function inReach(x, y)
        local dx, dy = x - r.x, y - r.y
        return dx * dx + dy * dy <= g.r2
    end
    for x = r.x - g.radius, r.x + g.radius do
        for y = r.y - g.radius, r.y + g.radius do
            if inReach(x, y) then
                local square = getSquare(x, y, z)
                if square and (g.allowExt or not square:has(IsoFlagType.exterior)) then
                    local edge = not (inReach(x - 1, y) and inReach(x + 1, y) and inReach(x, y - 1) and inReach(x, y + 1))
                    local m = tileMarker(square, edge and EDGE or FILL)
                    if m then r.markers[#r.markers + 1] = m end
                end
            end
        end
    end
end

function Range.isRangeShown(gen)
    local x, y, z = genCoords(gen)
    return Range.range ~= nil and x ~= nil and Range.range.key == TGM.key(x, y, z)
end

function Range.hideRange()
    if Range.range then clearMarkers(Range.range) end
    Range.range = nil
end

function Range.toggleRange(gen, playerNum)
    if Range.isRangeShown(gen) then
        Range.hideRange()
        return
    end
    Range.hideRange()
    local x, y, z = genCoords(gen)
    if not x then return end
    Range.range = { key = TGM.key(x, y, z), x = x, y = y, z = z, playerNum = playerNum, markers = {} }
    buildRange(Range.range)
end

-- ---- devices -------------------------------------------------------------------------

Range.devices = nil   -- { key, x, y, z, playerNum, scanned }

local function scanDevices(d)
    d.scanned = getTimestampMs()
    local g = TGM.geom()
    local map = {}
    for z = math.max(-32, d.z - g.vr), math.min(31, d.z + g.vr) do
        for x = d.x - g.radius, d.x + g.radius do
            local dx = x - d.x
            for y = d.y - g.radius, d.y + g.radius do
                local dy = y - d.y
                if dx * dx + dy * dy <= g.r2 then
                    local square = getSquare(x, y, z)
                    if square then
                        local list = TGM.devicesOn(square)
                        if #list > 0 then
                            local owner = TGM.resolve(x, y, z, square)
                            local col
                            if owner == TGM.OFF then col = DEVICE_COLOR.off
                            elseif not owner then col = DEVICE_COLOR.none
                            elseif owner.key == d.key then col = DEVICE_COLOR.this
                            else col = DEVICE_COLOR.other end
                            for i = 1, #list do
                                map[list[i]] = { playerNum = d.playerNum, r = col[1], g = col[2], b = col[3] }
                            end
                        end
                    end
                end
            end
        end
    end
    TGM.Highlight.setSource("devices", map)
end

function Range.isDevicesShown(gen)
    local x, y, z = genCoords(gen)
    return Range.devices ~= nil and x ~= nil and Range.devices.key == TGM.key(x, y, z)
end

function Range.hideDevices()
    Range.devices = nil
    if TGM.Highlight then TGM.Highlight.setSource("devices", nil) end
end

function Range.toggleDevices(gen, playerNum)
    if Range.isDevicesShown(gen) then
        Range.hideDevices()
        return
    end
    local x, y, z = genCoords(gen)
    if not x then return end
    TGM.registerGenerator(gen)
    Range.devices = { key = TGM.key(x, y, z), x = x, y = y, z = z, playerNum = playerNum }
    scanDevices(Range.devices)
end

-- ---- upkeep --------------------------------------------------------------------------

local failed = false

local function onTick()
    if failed then return end
    local ok, err = pcall(function()
        local now = getTimestampMs()
        local r = Range.range
        if r then
            local player = getSpecificPlayer(r.playerNum)
            if not TGM.generatorAt(r.x, r.y, r.z) or not player then
                Range.hideRange()
            elseif math.floor(player:getZ()) ~= r.floor or now - r.built >= RANGE_REBUILD_MS then
                buildRange(r)
            end
        end
        local d = Range.devices
        if d then
            if not TGM.generatorAt(d.x, d.y, d.z) then
                Range.hideDevices()
            elseif now - d.scanned >= DEVICES_SCAN_MS then
                scanDevices(d)
            end
        end
    end)
    if not ok then
        failed = true
        TGM.log("range display stopped after an error: " .. tostring(err))
        pcall(Range.hideRange)
        pcall(Range.hideDevices)
    end
end

Events.OnTick.Add(onTick)
