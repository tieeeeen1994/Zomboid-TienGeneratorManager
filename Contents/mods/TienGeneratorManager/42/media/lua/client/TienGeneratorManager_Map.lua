--[[
    Tien's Generator Manager -- client: the Manage Power map

    A top-down map of one floor of the generator's reach (north up: world -y, as the world
    map). Each square in reach is drawn as floor (room or outside), nothing, walls, doors and
    windows (IsoFlagType WallN / WallW / WallNW, doorN / doorW, windowN / windowW), so the
    building can be recognised. Squares with devices are filled with this generator's
    setting: green connected, red not connected, yellow auto; a dot in the middle shows who
    powers it now (a closer generator may win): white = this generator, blue = another one,
    black = nobody (power cut), none = no running generator reaches it. A key under the map
    names the dot colours; the right-click box says it in words too.

    Pick a brush and click or drag over squares (a drag paints every square the mouse crossed
    since its last position, so a fast drag leaves no gaps); each stroke is one request (applied by the
    server, which answers "applied" to everyone or "refused" to the sender). Until then the
    painted squares show the brush. Connect all / Disconnect all / Auto all (after a yes/no)
    set the default of the floor shown for every square of it in reach, devices or not, and
    clear those squares' own settings (TGM.floorKey); empty squares are tinted with the
    setting they have. Hovering a square highlights its devices in the world (TGM.Highlight,
    client file). Right-click a square (a right press that moves less than a few pixels;
    more is a pan) pins a box beside it with a picture of the square, drawn the way
    vanilla's pick-up box does (ISMoveableInfoWindow.setTexture / drawTexture: a 64x128
    box, the floor and every object's getTextureName() plus child sprites, raised by
    getRenderYOffset(), 2x tiles at half scale; the devices drawn solid, the rest faded),
    and the list of its devices.

    Lights reach one tile further and one floor up (TGM.reachesAround, the engine's
    IsoLightSwitch.hasElectricityAround): the grid has one cell more on every side than the
    circle, and the floor above the top floor can be shown; outside the circle only the lights
    this generator reaches that way are drawn and can be painted.

    The map sits in a fixed viewport: the mouse wheel zooms around the cursor (the - and +
    buttons around the centre), right-drag pans; drawing is clipped with setStencilRect and
    only visible cells are drawn. It is rebuilt from the client's loaded squares every half
    second (one floor, in cell coordinates, the background merged into runs).
--]]

require "ISUI/ISCollapsableWindow"
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISModalDialog"
require "TienGeneratorManager"

local TGM = TienGeneratorManager

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local PAD = 8
local BTN_H = FONT_HGT_SMALL + 6
local GAP = 4
local REBUILD_MS = 500
local PENDING_MS = 5000
local MAX_CELL = 48
local KEYS_PER_REQUEST = 2000
-- squares without devices: a faint tint of their setting (stronger while a stroke is on its way)
local EMPTY_ALPHA = 0.15
local EMPTY_PENDING_ALPHA = 0.25

local C = {
    outside = { 0.0, 0.0, 0.0 },
    nothing = { 0.07, 0.07, 0.08 },
    ground = { 0.18, 0.2, 0.17 },
    room = { 0.3, 0.3, 0.33 },
    wall = { 0.85, 0.85, 0.85 },
    door = { 0.75, 0.55, 0.3 },
    window = { 0.55, 0.75, 0.95 },
}
local SETTING_COLOR = {
    [TGM.GREEN] = { 0.2, 0.8, 0.25 },
    [TGM.RED] = { 0.85, 0.2, 0.2 },
    [TGM.AUTO] = { 0.95, 0.8, 0.15 },
}
local DOT_COLOR = {
    this = { 1, 1, 1 },
    other = { 0.35, 0.6, 1 },
    off = { 0, 0, 0 },
}

TGM.Map = TGM.Map or {}
local Map = TGM.Map
Map.windows = Map.windows or {}

local function measure(text)
    return getTextManager():MeasureStringX(UIFont.Small, text)
end

-- ---- the grid ------------------------------------------------------------------------

local Grid = ISPanel:derive("TGM_MapGrid")

-- cells: squares across the reach; view: viewport size in pixels (square); the fitted cell
-- size shows the whole reach and is the most zoomed out.
function Grid:new(x, y, cells, view, win)
    local o = ISPanel.new(self, x, y, view, view)
    o.win = win
    o.cells = cells
    o.half = (cells - 1) / 2
    o.fitCell = math.max(1, view / cells)
    o.cell = o.fitCell
    o.offX, o.offY = 0, 0
    o.background = true
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 1 }
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    o.rects, o.lines, o.devices, o.generators, o.deviceAt, o.tints = {}, {}, {}, {}, {}, {}
    return o
end

local function wallLines(lines, square, i, j)
    local north, west = nil, nil
    if square:has(IsoFlagType.doorN) or square:has(IsoFlagType.DoorWallN) then north = C.door
    elseif square:has(IsoFlagType.windowN) or square:has(IsoFlagType.WindowN) then north = C.window
    elseif square:has(IsoFlagType.WallN) or square:has(IsoFlagType.WallNW) then north = C.wall end
    if square:has(IsoFlagType.doorW) or square:has(IsoFlagType.DoorWallW) then west = C.door
    elseif square:has(IsoFlagType.windowW) or square:has(IsoFlagType.WindowW) then west = C.window
    elseif square:has(IsoFlagType.WallW) or square:has(IsoFlagType.WallNW) then west = C.wall end
    if north then lines[#lines + 1] = { i, j, true, north } end
    if west then lines[#lines + 1] = { i, j, false, west } end
end

function Grid:rebuild()
    local win = self.win
    local g = TGM.geom()
    local r, z = self.half, win.floor
    local gen = win:liveGen()
    local floorInReach = z >= math.max(-32, win.gz - g.vr) and z <= math.min(31, win.gz + g.vr)
    local rects, lines, devices, tints = {}, {}, {}, {}
    for j = 0, self.cells - 1 do
        local y = win.gy - r + j
        local runColor, runStart = nil, 0
        local tintColor, tintStart = nil, 0
        for i = 0, self.cells - 1 do
            local tint = nil
            local x = win.gx - r + i
            local dx, dy = i - r, j - r
            local color = C.outside
            local inDisc = floorInReach and dx * dx + dy * dy <= g.r2
            local list, square = nil, nil
            if inDisc then
                square = getSquare(x, y, z)
                list = square and TGM.devicesOn(square) or {}
            elseif TGM.nearRange(g, win.gx, win.gy, win.gz, x, y, z) then
                -- past the circle (or a floor above it): only lights this generator reaches
                square = getSquare(x, y, z)
                list = {}
                if square and TGM.reachesAround(g, win.gx, win.gy, win.gz, x, y, z) then
                    local all = TGM.devicesOn(square)
                    for k = 1, #all do
                        if TGM.isLightSwitch(all[k]) then list[#list + 1] = all[k] end
                    end
                end
            end
            if inDisc then
                color = C.nothing
                if square then
                    if square:getRoom() then color = C.room
                    elseif square:has(IsoFlagType.solidfloor) then color = C.ground end
                    wallLines(lines, square, i, j)
                end
            end
            if list and (inDisc or #list > 0) then
                local key = TGM.key(x, y, z)
                local setting = win:settingFor(gen, key)
                if #list > 0 then
                    local lightsOnly = true
                    for k = 1, #list do
                        if not TGM.isLightSwitch(list[k]) then lightsOnly = false end
                    end
                    local owner = TGM.resolve(x, y, z, square, lightsOnly)
                    local result = nil
                    if owner == TGM.OFF then result = "off"
                    elseif owner then result = owner.key == win.genKey and "this" or "other" end
                    devices[#devices + 1] = {
                        i = i, j = j, x = x, y = y, z = z, key = key, objects = list,
                        setting = setting, owner = owner, result = result,
                    }
                elseif setting ~= TGM.AUTO then
                    tint = SETTING_COLOR[setting]
                end
            end
            if color ~= runColor then
                if runColor then rects[#rects + 1] = { runStart, j, i - runStart, runColor } end
                runColor, runStart = color, i
            end
            if tint ~= tintColor then
                if tintColor then tints[#tints + 1] = { tintStart, j, i - tintStart, tintColor } end
                tintColor, tintStart = tint, i
            end
        end
        if runColor then rects[#rects + 1] = { runStart, j, self.cells - runStart, runColor } end
        if tintColor then tints[#tints + 1] = { tintStart, j, self.cells - tintStart, tintColor } end
    end
    local others = {}
    for key, e in pairs(TGM.generators) do
        if e.z == z and math.abs(e.x - win.gx) <= r and math.abs(e.y - win.gy) <= r then
            others[#others + 1] = { i = e.x - win.gx + r, j = e.y - win.gy + r, this = key == win.genKey }
        end
    end
    self.rects, self.lines, self.devices, self.generators, self.tints = rects, lines, devices, others, tints
    self.deviceAt = {}
    for k = 1, #devices do self.deviceAt[devices[k].key] = devices[k] end
end

function Grid:clampOffsets()
    local maxX = math.max(0, self.cells * self.cell - self.width)
    local maxY = math.max(0, self.cells * self.cell - self.height)
    self.offX = math.max(0, math.min(maxX, self.offX))
    self.offY = math.max(0, math.min(maxY, self.offY))
end

-- steps > 0 zooms in; the cell under (mx, my) stays under it
function Grid:zoomAt(steps, mx, my)
    local old = self.cell
    local new = math.floor(old * 1.25 ^ steps + 0.5)
    if steps > 0 then new = math.max(new, old + 1) else new = math.min(new, old - 1) end
    new = math.max(self.fitCell, math.min(MAX_CELL, new))
    if new == old then return end
    local cx, cy = (mx + self.offX) / old, (my + self.offY) / old
    self.cell = new
    self.offX = cx * new - mx
    self.offY = cy * new - my
    self:clampOffsets()
end

function Grid:render()
    local T, ox, oy = self.cell, self.offX, self.offY
    local w, h = self.width, self.height
    local j0, j1 = math.floor(oy / T), math.floor((oy + h) / T)
    local i0, i1 = math.floor(ox / T), math.floor((ox + w) / T)
    local function visible(i, j) return i >= i0 and i <= i1 and j >= j0 and j <= j1 end

    self:setStencilRect(0, 0, w, h)
    for k = 1, #self.rects do
        local rc = self.rects[k]
        if rc[2] >= j0 and rc[2] <= j1 then
            self:drawRect(rc[1] * T - ox, rc[2] * T - oy, rc[3] * T, T, 1, rc[4][1], rc[4][2], rc[4][3])
        end
    end
    for k = 1, #self.tints do
        local rc = self.tints[k]
        if rc[2] >= j0 and rc[2] <= j1 then
            self:drawRect(rc[1] * T - ox, rc[2] * T - oy, rc[3] * T, T, EMPTY_ALPHA, rc[4][1], rc[4][2], rc[4][3])
        end
    end
    local thick = T >= 10 and 2 or 1
    for k = 1, #self.lines do
        local ln = self.lines[k]
        if visible(ln[1], ln[2]) then
            local px, py = ln[1] * T - ox, ln[2] * T - oy
            if ln[3] then
                self:drawRect(px, py, T, thick, 1, ln[4][1], ln[4][2], ln[4][3])
            else
                self:drawRect(px, py, thick, T, 1, ln[4][1], ln[4][2], ln[4][3])
            end
        end
    end
    local pending = self.win.pending
    local inset = T >= 6 and 1 or 0
    for k = 1, #self.devices do
        local d = self.devices[k]
        if visible(d.i, d.j) then
            local col = SETTING_COLOR[pending[d.key] or d.setting]
            local px, py = d.i * T - ox, d.j * T - oy
            self:drawRect(px + inset, py + inset, T - 2 * inset, T - 2 * inset, 0.9, col[1], col[2], col[3])
            local dot = d.result and DOT_COLOR[d.result]
            if dot then
                local s = math.max(2, math.floor(T / 3))
                local o = (T - s) / 2
                self:drawRect(px + o, py + o, s, s, 1, dot[1], dot[2], dot[3])
            end
        end
    end
    -- painted, not answered yet, and not in the list (blank squares)
    local r = self.half
    for key, setting in pairs(pending) do
        if not self.deviceAt[key] then
            local x, y, z = TGM.parseKey(key)
            if z == self.win.floor then
                local i, j = x - self.win.gx + r, y - self.win.gy + r
                if visible(i, j) then
                    local col = SETTING_COLOR[setting]
                    self:drawRect(i * T - ox, j * T - oy, T, T, EMPTY_PENDING_ALPHA, col[1], col[2], col[3])
                end
            end
        end
    end
    for k = 1, #self.generators do
        local e = self.generators[k]
        local col = e.this and { 1, 0.55, 0.1 } or { 0.6, 0.6, 0.6 }
        local px, py = e.i * T - ox, e.j * T - oy
        self:drawRectBorder(px - 1, py - 1, T + 2, T + 2, 1, col[1], col[2], col[3])
        self:drawRectBorder(px, py, T, T, 1, col[1], col[2], col[3])
    end
    local player = getSpecificPlayer(self.win.playerNum)
    if player and math.floor(player:getZ()) == self.win.floor then
        local i = math.floor(player:getX()) - self.win.gx + r
        local j = math.floor(player:getY()) - self.win.gy + r
        local tex = getTexture("media/ui/circle.png")
        if tex and visible(i, j) then
            self:drawTextureScaled(tex, i * T - ox + inset, j * T - oy + inset, T - 2 * inset, T - 2 * inset, 1, 0.3, 0.9, 1)
        end
    end
    if self.hover then
        self:drawRectBorder(self.hover.i * T - ox, self.hover.j * T - oy, T, T, 1, 1, 1, 1)
    end
    self:clearStencilRect()
    self:drawRectBorder(0, 0, w, h, 1, 0.4, 0.4, 0.4)
end

-- the cell under a point of the viewport (any cell of the grid, paintable or not)
function Grid:rawCellAt(x, y)
    if x < 0 or y < 0 or x >= self.width or y >= self.height then return nil end
    local T = self.cell
    local i, j = math.floor((x + self.offX) / T), math.floor((y + self.offY) / T)
    if i < 0 or j < 0 or i >= self.cells or j >= self.cells then return nil end
    return i, j
end

-- cells in reach, plus the lights reached from outside it
function Grid:paintable(i, j)
    if i < 0 or j < 0 or i >= self.cells or j >= self.cells then return false end
    local g = TGM.geom()
    local dx, dy = i - self.half, j - self.half
    local floorInReach = self.win.floor >= math.max(-32, self.win.gz - g.vr)
        and self.win.floor <= math.min(31, self.win.gz + g.vr)
    if floorInReach and dx * dx + dy * dy <= g.r2 then return true end
    return self.deviceAt ~= nil and self.deviceAt[self:keyOf(i, j)] ~= nil
end

function Grid:cellAt(x, y)
    local i, j = self:rawCellAt(x, y)
    if i and self:paintable(i, j) then return i, j end
    return nil
end

function Grid:keyOf(i, j)
    local r = self.half
    return TGM.key(self.win.gx - r + i, self.win.gy - r + j, self.win.floor)
end

function Grid:updateHover(x, y)
    local i, j = self:cellAt(x, y)
    if not i then
        self.hover = nil
        return
    end
    self.hover = { i = i, j = j, key = self:keyOf(i, j) }
end

function Grid:addStroke(i, j)
    local key = self:keyOf(i, j)
    if self.stroke[key] then return end
    self.stroke[key] = true
    self.strokeList[#self.strokeList + 1] = key
    self.win.pending[key] = self.win.brush
end

-- the mouse in cell units (a zoom or pan mid-stroke keeps the stroke's last point valid)
function Grid:mouseCell()
    local T = self.cell
    return (self:getMouseX() + self.offX) / T, (self:getMouseY() + self.offY) / T
end

-- Paints every cell the mouse crossed since the last point of the stroke (a grid walk
-- along the segment), so a fast drag leaves no gaps between mouse events.
-- Cells outside the viewport are left alone, as a click there would be.
function Grid:strokeTo(x1, y1)
    local x0, y0 = self.strokeAt[1], self.strokeAt[2]
    self.strokeAt = { x1, y1 }
    local T = self.cell
    local i0, i1 = math.floor(self.offX / T), math.floor((self.offX + self.width - 1) / T)
    local j0, j1 = math.floor(self.offY / T), math.floor((self.offY + self.height - 1) / T)
    local function paint(i, j)
        if i >= i0 and i <= i1 and j >= j0 and j <= j1 and self:paintable(i, j) then self:addStroke(i, j) end
    end
    local i, j = math.floor(x0), math.floor(y0)
    local iEnd, jEnd = math.floor(x1), math.floor(y1)
    paint(i, j)
    local dx, dy = x1 - x0, y1 - y0
    local si, sj = dx > 0 and 1 or -1, dy > 0 and 1 or -1
    local huge = math.huge
    local tdx = dx ~= 0 and math.abs(1 / dx) or huge
    local tdy = dy ~= 0 and math.abs(1 / dy) or huge
    local tx = dx ~= 0 and ((si > 0 and (i + 1 - x0) or (x0 - i)) * tdx) or huge
    local ty = dy ~= 0 and ((sj > 0 and (j + 1 - y0) or (y0 - j)) * tdy) or huge
    local steps = math.abs(iEnd - i) + math.abs(jEnd - j)
    for _ = 1, steps do
        if j == jEnd or (i ~= iEnd and tx < ty) then
            i, tx = i + si, tx + tdx
        else
            j, ty = j + sj, ty + tdy
        end
        paint(i, j)
    end
end

function Grid:onMouseDown(x, y)
    if self.panning then return true end
    self.win.pinned = nil
    if not self:cellAt(x, y) then return true end
    self.stroke, self.strokeList = {}, {}
    local cx, cy = self:mouseCell()
    self.strokeAt = { cx, cy }
    self:strokeTo(cx, cy)
    self:setCapture(true)
    return true
end

function Grid:onMouseMove(dx, dy)
    local mx, my = self:getMouseX(), self:getMouseY()
    if self.panning then
        self.offX = self.panning.offX - (mx - self.panning.x)
        self.offY = self.panning.offY - (my - self.panning.y)
        self:clampOffsets()
        return
    end
    if self.stroke then self:strokeTo(self:mouseCell()) end
    self:updateHover(mx, my)
end

function Grid:onMouseMoveOutside(dx, dy)
    if self.panning or self.stroke then
        self:onMouseMove(dx, dy)
    else
        self.hover = nil
    end
end

function Grid:finishStroke()
    if not self.stroke then return end
    if not self.panning then self:setCapture(false) end
    local keys = self.strokeList
    self.stroke, self.strokeList = nil, nil
    self.strokeAt = nil
    if #keys > 0 then self.win:send(keys, self.win.brush) end
end

function Grid:onMouseUp(x, y)
    self:finishStroke()
    return true
end

function Grid:onMouseUpOutside(x, y)
    self:finishStroke()
end

function Grid:onRightMouseDown(x, y)
    if self.stroke then return true end
    self.panning = { x = x, y = y, offX = self.offX, offY = self.offY }
    self:setCapture(true)
    return true
end

local CLICK_PX = 4

-- Ends a right press; true when it was a click (moved less than CLICK_PX), not a pan.
local function endPan(self)
    if not self.panning then return nil end
    local p = self.panning
    self.panning = nil
    if not self.stroke then self:setCapture(false) end
    return math.abs(self:getMouseX() - p.x) < CLICK_PX and math.abs(self:getMouseY() - p.y) < CLICK_PX
end

-- a right click (not a drag) pins the device list of that square, or unpins it
function Grid:onRightMouseUp(x, y)
    if endPan(self) then
        local i, j = self:cellAt(x, y)
        local key = i and self:keyOf(i, j)
        if key and self.win.pinned ~= key then
            self.win.pinned = key
            self.win.pinnedCell = { i = i, j = j }
        else
            self.win.pinned = nil
        end
    end
    return true
end

function Grid:onRightMouseUpOutside(x, y)
    endPan(self)
end

function Grid:onMouseWheel(del)
    self:zoomAt(-del, self:getMouseX(), self:getMouseY())
    return true
end

-- ---- the window ----------------------------------------------------------------------

local Window = ISCollapsableWindow:derive("TGM_MapWindow")

local function stateLabel(state)
    if state == TGM.GREEN then return getText("IGUI_TGM_StateConnected") end
    if state == TGM.RED then return getText("IGUI_TGM_StateDisconnected") end
    return getText("IGUI_TGM_StateAuto")
end

local function brushLabel(state)
    if state == TGM.GREEN then return getText("IGUI_TGM_Connected") end
    if state == TGM.RED then return getText("IGUI_TGM_NotConnected") end
    return getText("IGUI_TGM_Auto")
end

local ALL_LABEL = { [TGM.GREEN] = "IGUI_TGM_ConnectAll", [TGM.RED] = "IGUI_TGM_DisconnectAll", [TGM.AUTO] = "IGUI_TGM_AutoAll" }
local ALL_CONFIRM = { [TGM.GREEN] = "IGUI_TGM_ConfirmConnectAll", [TGM.RED] = "IGUI_TGM_ConfirmDisconnectAll", [TGM.AUTO] = "IGUI_TGM_ConfirmAutoAll" }

function Window:new(x, y, w, h, playerNum, gx, gy, gz, cells, view)
    local o = ISCollapsableWindow.new(self, x, y, w, h)
    o:setTitle(getText("IGUI_TGM_Title"))
    o:setResizable(false)
    o:setWantKeyEvents(true)
    o.playerNum = playerNum
    o.gx, o.gy, o.gz = gx, gy, gz
    o.genKey = TGM.key(gx, gy, gz)
    o.floor = gz
    o.cellsCount, o.viewSize = cells, view
    o.tileCacheOrder = {}
    o.brush = TGM.GREEN
    o.pending = {}
    o.pendingAll = nil
    o.lastRebuild = 0
    return o
end

function Window:liveGen()
    return TGM.generatorAt(self.gx, self.gy, self.gz)
end

-- A square's setting as shown: a stroke on its way, else an "all" on its way for this
-- floor, else stored.
function Window:settingFor(gen, key)
    if self.pending[key] then return self.pending[key] end
    if self.pendingAll and self.pendingAllFloor == self.floor then return self.pendingAll end
    return gen and TGM.settingAt(gen, key, self.floor) or TGM.AUTO
end

local function newButton(win, x, y, w, title, onclick, internal)
    local btn = ISButton:new(x, y, w, BTN_H, title, win, onclick)
    btn.internal = internal
    btn:initialise()
    btn:instantiate()
    win:addChild(btn)
    return btn
end

-- Words of text laid out in lines no wider than width.
local function wrap(text, width)
    local lines, line = {}, ""
    for word in string.gmatch(text, "%S+") do
        local try = line == "" and word or line .. " " .. word
        if line ~= "" and measure(try) > width then
            lines[#lines + 1] = line
            line = word
        else
            line = try
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
end

function Window:createChildren()
    ISCollapsableWindow.createChildren(self)
    local view = self.viewSize
    local width = math.max(view + PAD * 2, 420)
    local inner = width - PAD * 2
    local y = self:titleBarHeight() + PAD
    self.statusY = y
    y = y + FONT_HGT_SMALL + 6

    -- floor and zoom
    local downW = measure(getText("IGUI_TGM_FloorDown")) + 16
    local upW = measure(getText("IGUI_TGM_FloorUp")) + 16
    self.btnDown = newButton(self, PAD, y, downW, getText("IGUI_TGM_FloorDown"), Window.onFloor, "DOWN")
    self.btnUp = newButton(self, PAD + downW + GAP, y, upW, getText("IGUI_TGM_FloorUp"), Window.onFloor, "UP")
    self.floorX = PAD + downW + GAP + upW + 8
    self.floorY = y + (BTN_H - FONT_HGT_SMALL) / 2
    local zoomW = BTN_H + 6
    self.btnZoomIn = newButton(self, PAD + inner - zoomW, y, zoomW, "+", Window.onZoom, "IN")
    self.btnZoomOut = newButton(self, PAD + inner - zoomW * 2 - GAP, y, zoomW, "-", Window.onZoom, "OUT")
    y = y + BTN_H + 6

    -- brushes, then the same for every square, in one row
    local x = PAD
    self.brushButtons = {}
    for _, state in ipairs({ TGM.GREEN, TGM.RED, TGM.AUTO }) do
        local label = brushLabel(state)
        local w = measure(label) + 20
        self.brushButtons[state] = newButton(self, x, y, w, label, Window.onBrush, state)
        x = x + w + GAP
    end
    x = x + 12
    for _, state in ipairs({ TGM.GREEN, TGM.RED, TGM.AUTO }) do
        local label = getText(ALL_LABEL[state])
        local w = measure(label) + 20
        local btn = newButton(self, x, y, w, label, Window.onAll, state)
        local col = SETTING_COLOR[state]
        btn.borderColor = { r = col[1], g = col[2], b = col[3], a = 0.8 }
        x = x + w + GAP
    end
    if x - GAP + PAD > width then
        width = x - GAP + PAD
        inner = width - PAD * 2
        self.btnZoomIn:setX(PAD + inner - zoomW)
        self.btnZoomOut:setX(PAD + inner - zoomW * 2 - GAP)
    end
    y = y + BTN_H + 6

    self.grid = Grid:new(PAD + math.floor((inner - view) / 2), y, self.cellsCount, view, self)
    self.grid:initialise()
    self:addChild(self.grid)
    y = y + view + 6

    -- key: "Dot = who powers it now:" and three samples, wrapped as items
    self.legend = {}
    local sw = FONT_HGT_SMALL - 4
    local title = getText("IGUI_TGM_LegendTitle")
    self.legendTitle = { x = PAD, y = y, text = title }
    local lx = PAD + measure(title) + 8
    local items = {
        { DOT_COLOR.this, getText("IGUI_TGM_LegendThis") },
        { DOT_COLOR.other, getText("IGUI_TGM_LegendOther") },
        { DOT_COLOR.off, getText("IGUI_TGM_LegendOff") },
    }
    for k = 1, #items do
        local itemW = sw + 4 + measure(items[k][2])
        if lx + itemW > PAD + inner then
            lx = PAD
            y = y + FONT_HGT_SMALL + 2
        end
        self.legend[#self.legend + 1] = { x = lx, y = y, color = items[k][1], text = items[k][2], sw = sw }
        lx = lx + itemW + 14
    end
    y = y + FONT_HGT_SMALL + 2
    self.help = {}
    local helpLines = wrap(getText("IGUI_TGM_Help"), inner)
    for k = 1, #helpLines do
        self.help[#self.help + 1] = { x = PAD, y = y, text = helpLines[k] }
        y = y + FONT_HGT_SMALL
    end

    self:setWidth(width)
    self:setHeight(y + PAD)
    self:setX((getCore():getScreenWidth() - width) / 2)
    self:setY(math.max(0, (getCore():getScreenHeight() - self.height) / 2))
    self:syncButtons()
    self:refresh()
end

function Window:syncButtons()
    local g = TGM.geom()
    self.btnDown:setEnable(self.floor > math.max(-32, self.gz - g.vr))
    -- one floor above the top floor: lights lit from below (TGM.reachesAround)
    self.btnUp:setEnable(self.floor < math.min(31, self.gz + g.vr + 1))
    for state, btn in pairs(self.brushButtons) do
        local col = SETTING_COLOR[state]
        local a = state == self.brush and 0.9 or 0.25
        btn.backgroundColor = { r = col[1] * 0.6, g = col[2] * 0.6, b = col[3] * 0.6, a = a }
        btn.backgroundColorMouseOver = { r = col[1] * 0.7, g = col[2] * 0.7, b = col[3] * 0.7, a = 1 }
        btn.borderColor = state == self.brush and { r = 1, g = 1, b = 1, a = 1 } or { r = 0.5, g = 0.5, b = 0.5, a = 1 }
    end
end

function Window:onFloor(button)
    self.pinned = nil
    self.floor = self.floor + (button.internal == "UP" and 1 or -1)
    self:syncButtons()
    self:refresh()
end

function Window:onZoom(button)
    self.grid:zoomAt(button.internal == "IN" and 1 or -1, self.grid.width / 2, self.grid.height / 2)
end

function Window:onBrush(button)
    self.brush = button.internal
    self:syncButtons()
end

-- Sends keys in requests the server accepts (it reads at most 5000 per request).
function Window:send(keys, state)
    local player = getSpecificPlayer(self.playerNum)
    if not player then return end
    self.pendingTime = getTimestampMs()
    local batch = {}
    for k = 1, #keys do
        self.pending[keys[k]] = state
        batch[#batch + 1] = keys[k]
        if #batch >= KEYS_PER_REQUEST then
            TGM.requestSet(player, self.gx, self.gy, self.gz, batch, state)
            batch = {}
        end
    end
    if #batch > 0 then TGM.requestSet(player, self.gx, self.gy, self.gz, batch, state) end
end

function Window:onAll(button)
    local state = button.internal
    local w, h = 380, 150
    local modal = ISModalDialog:new((getCore():getScreenWidth() - w) / 2, (getCore():getScreenHeight() - h) / 2,
        w, h, getText(ALL_CONFIRM[state], string.format("%d", self.floor)), true, self, Window.onAllConfirmed,
        self.playerNum, state)
    modal:initialise()
    modal:addToUIManager()
end

function Window:onAllConfirmed(button, state)
    if button.internal ~= "YES" or not self:liveGen() then return end
    local player = getSpecificPlayer(self.playerNum)
    if not player then return end
    self.pending = {}
    self.pendingAll = state
    self.pendingAllFloor = self.floor
    self.pendingTime = getTimestampMs()
    TGM.requestSet(player, self.gx, self.gy, self.gz, TGM.ALL, state, self.floor)
    self.grid:rebuild()
end

function Window:refresh()
    if not self:liveGen() then
        self:close()
        return
    end
    self.grid:rebuild()
    self.lastRebuild = getTimestampMs()
end

function Window:onReply(command, args)
    self.pending = {}
    self.pendingAll = nil
    self.pendingTime = nil
    if command == "refused" then
        self.message = getText(args.reason or "IGUI_TGM_Refused")
        self.messageTime = getTimestampMs()
    end
    self:refresh()
end

function Window:update()
    ISCollapsableWindow.update(self)
    local now = getTimestampMs()
    if self.pendingTime and now - self.pendingTime > PENDING_MS then
        self.pending = {}
        self.pendingAll = nil
        self.pendingTime = nil
    end
    if now - self.lastRebuild >= REBUILD_MS then self:refresh() end
    -- devices on the hovered square, in the world
    local hover = self.grid and self.grid.hover
    local d = hover and self.grid.deviceAt and self.grid.deviceAt[hover.key]
    if d and #d.objects > 0 then
        TGM.Highlight.set(self.playerNum, d.objects)
        self.highlighting = true
    elseif self.highlighting then
        -- only the window that set it clears it (another map may be hovered)
        TGM.Highlight.clear()
        self.highlighting = false
    end
end

function Window:prerender()
    ISCollapsableWindow.prerender(self)
    local gen = self:liveGen()
    local status
    if not gen then
        status = ""
    elseif gen:isActivated() then
        local info = TGM.state.byGen[self.genKey]
        status = getText("IGUI_TGM_StatusRunning", gen:getTotalPowerUsingString(),
            string.format("%d", info and info.squares or 0))
    else
        status = getText("IGUI_TGM_StatusOff")
    end
    if self.message and getTimestampMs() - (self.messageTime or 0) < 4000 then
        self:drawText(self.message, PAD, self.statusY, 1, 0.4, 0.4, 1, UIFont.Small)
    else
        self:drawText(status, PAD, self.statusY, 0.9, 0.9, 0.9, 1, UIFont.Small)
    end
    local floorText = getText("IGUI_TGM_Floor", string.format("%d", self.floor))
    if self.floor == self.gz then floorText = floorText .. " " .. getText("IGUI_TGM_GeneratorFloor") end
    self:drawText(floorText, self.floorX, self.floorY, 0.9, 0.9, 0.9, 1, UIFont.Small)
end

local function tooltipLines(win, d)
    local lines = {}
    lines[#lines + 1] = { getText("IGUI_TGM_SquareTitle", string.format("%d", d.x), string.format("%d", d.y),
        string.format("%d", d.z)), 1, 1, 1 }
    local setting = win.pending[d.key] or d.setting or TGM.AUTO
    local col = SETTING_COLOR[setting]
    lines[#lines + 1] = { getText("IGUI_TGM_ThisGenerator", stateLabel(setting)), col[1], col[2], col[3] }
    if #d.objects == 0 then
        lines[#lines + 1] = { getText("IGUI_TGM_NoDevices"), 0.7, 0.7, 0.7 }
        return lines
    end
    local who
    if d.result == "this" then who = getText("IGUI_TGM_PoweredByThis")
    elseif d.result == "other" then
        who = getText("IGUI_TGM_PoweredByOther", string.format("%d", d.owner.x), string.format("%d", d.owner.y),
            string.format("%d", d.owner.z))
    elseif d.result == "off" then who = getText("IGUI_TGM_PowerCut")
    else who = getText("IGUI_TGM_NoGenerator") end
    lines[#lines + 1] = { who, 0.8, 0.8, 0.8 }
    local mult = TGM.fuelMultiplier()
    for k = 1, #d.objects do
        local obj = d.objects[k]
        local state
        if TGM.isUnplugged(obj) then state = getText("IGUI_TGM_Unplugged")
        else
            local on = TGM.isOn(obj)
            if on == true then state = getText("IGUI_TGM_On")
            elseif on == false then state = getText("IGUI_TGM_Off")
            else state = getText("IGUI_TGM_AlwaysOn") end
        end
        lines[#lines + 1] = { "  " .. TGM.deviceName(obj) .. " - " .. state .. " - "
            .. string.format("%.3f", TGM.draw(obj) * mult) .. " L/h", 1, 1, 1 }
    end
    return lines
end

-- ---- the hovered square's tiles (vanilla pick-up box) ----------------------------------

local TILE_W, TILE_H = 64, 128

local function addTexture(list, name, offsetY, device)
    local tex = name and getTexture(name)
    if tex then list[#list + 1] = { tex = tex, offsetY = offsetY, device = device } end
end

-- ISMoveableInfoWindow.setTexture: the floor, then every other object and its child sprites
local function squareTextures(square, devices)
    local list = {}
    local isDevice = {}
    for k = 1, #devices do isDevice[devices[k]] = true end
    local floor = square:getFloor()
    if floor then addTexture(list, floor:getTextureName(), 0, false) end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if obj ~= floor then
            local offsetY = obj:getRenderYOffset()
            local device = isDevice[obj] == true
            addTexture(list, obj:getTextureName(), offsetY, device)
            local children = obj:getChildSprites()
            if children and not instanceof(obj, "IsoBarbecue") then
                for c = children:size() - 1, 0, -1 do
                    local sprite = children:get(c):getParentSprite()
                    addTexture(list, sprite and sprite:getName(), offsetY, device)
                end
            end
        end
    end
    return list
end

-- ISMoveableInfoWindow:drawTexture: 2x tiles (128x256) at half scale
local function drawTile(self, tex, x, y, a)
    if tex:getWidthOrig() == TILE_W * 2 and tex:getHeightOrig() == TILE_H * 2 then
        ISUIElement.drawTextureScaledUniform(self, tex, x, y, 0.5, a, 1, 1, 1)
    else
        ISUIElement.drawTexture(self, tex, x, y, a, 1, 1, 1)
    end
end

-- x, y: where a w x h box wants to be (window coordinates); flipped to flipX - w / flipY - h
-- when it would leave the screen
local function onScreen(self, x, y, w, h, flipX, flipY)
    local ax, ay = self:getAbsoluteX(), self:getAbsoluteY()
    if ax + x + w > getCore():getScreenWidth() then x = flipX - w end
    if ay + y + h > getCore():getScreenHeight() then y = flipY - h end
    return math.max(-ax, x), math.max(-ay, y)
end

-- The tiles of a square (cached per square, refreshed with the map), or nil.
function Window:tilesOf(key)
    local cache = self.tileCache or {}
    self.tileCache = cache
    local entry = cache[key]
    if entry and getTimestampMs() - entry.time <= REBUILD_MS then return entry.tiles end
    local x, y, z = TGM.parseKey(key)
    local square = getSquare(x, y, z)
    local tiles = nil
    if square then
        local d = self.grid.deviceAt[key]
        tiles = squareTextures(square, d and d.objects or {})
        if #tiles == 0 then tiles = nil end
    end
    if not entry and #self.tileCacheOrder >= 8 then
        cache[table.remove(self.tileCacheOrder, 1)] = nil
    end
    if not entry then self.tileCacheOrder[#self.tileCacheOrder + 1] = key end
    cache[key] = { tiles = tiles, time = getTimestampMs() }
    return tiles
end

function Window:drawTiles(tiles, x, y)
    self:drawRect(x, y, TILE_W, TILE_H, 1, 0, 0, 0)
    self:setStencilRect(x, y, TILE_W, TILE_H)
    for k = 1, #tiles do
        local t = tiles[k]
        drawTile(self, t.tex, x, y - t.offsetY, t.device and 1 or 0.45)
    end
    self:clearStencilRect()
    self:drawRectBorder(x, y, TILE_W, TILE_H, 0.8, 0.5, 0.5, 0.5)
end

function Window:drawPinned()
    local key = self.pinned
    local x, y, z = TGM.parseKey(key)
    if z ~= self.floor then
        self.pinned = nil
        return
    end
    local d = self.grid.deviceAt[key]
    if not d then
        local gen = self:liveGen()
        d = { x = x, y = y, z = z, key = key, objects = {}, setting = self:settingFor(gen, key) }
    end
    local lines = tooltipLines(self, d)
    local tiles = self:tilesOf(key)
    local textX = tiles and TILE_W + 16 or 8
    local w = 0
    for k = 1, #lines do w = math.max(w, measure(lines[k][1])) end
    w = textX + w + 8
    local h = math.max(#lines * FONT_HGT_SMALL + 10, tiles and TILE_H + 8 or 0)
    -- beside the square, flipped to stay on the screen
    local grid, T = self.grid, self.grid.cell
    local cell = self.pinnedCell
    local cx = grid:getX() + cell.i * T - grid.offX
    local cy = grid:getY() + cell.j * T - grid.offY
    local bx, by = onScreen(self, cx + T + 6, cy, w, h, cx - 6, cy + T)
    self:drawRect(bx, by, w, h, 0.95, 0.05, 0.05, 0.05)
    self:drawRectBorder(bx, by, w, h, 0.9, 0.8, 0.8, 0.8)
    self:drawRectBorder(cx - 1, cy - 1, T + 2, T + 2, 1, 1, 1, 1)
    if tiles then self:drawTiles(tiles, bx + 4, by + 4) end
    for k = 1, #lines do
        local ln = lines[k]
        self:drawText(ln[1], bx + textX, by + 5 + (k - 1) * FONT_HGT_SMALL, ln[2], ln[3], ln[4], 1, UIFont.Small)
    end
end

function Window:render()
    ISCollapsableWindow.render(self)
    local lt = self.legendTitle
    self:drawText(lt.text, lt.x, lt.y, 0.8, 0.8, 0.8, 1, UIFont.Small)
    for k = 1, #self.legend do
        local it = self.legend[k]
        local sy = it.y + (FONT_HGT_SMALL - it.sw) / 2
        self:drawRect(it.x, sy, it.sw, it.sw, 1, it.color[1], it.color[2], it.color[3])
        self:drawRectBorder(it.x, sy, it.sw, it.sw, 1, 0.6, 0.6, 0.6)
        self:drawText(it.text, it.x + it.sw + 4, it.y, 0.8, 0.8, 0.8, 1, UIFont.Small)
    end
    for k = 1, #self.help do
        self:drawText(self.help[k].text, self.help[k].x, self.help[k].y, 0.6, 0.6, 0.6, 1, UIFont.Small)
    end
    if self.pinned then self:drawPinned() end
end

-- Esc closes the pinned list (ISBaseEntityWindow pattern: setWantKeyEvents, isKeyConsumed,
-- onKeyRelease); without a pinned list Esc is left to the game menu.
function Window:isKeyConsumed(key)
    return key == Keyboard.KEY_ESCAPE and self.pinned ~= nil
end

function Window:onKeyRelease(key)
    if key == Keyboard.KEY_ESCAPE and self.pinned then
        self.pinned = nil
        return true
    end
    return false
end

function Window:close()
    if self.highlighting then TGM.Highlight.clear() end
    self:setVisible(false)
    self:removeFromUIManager()
    if Map.windows[self.genKey] == self then Map.windows[self.genKey] = nil end
end

-- ---- opening and replies ---------------------------------------------------------------

function Map.open(player, gen)
    local square = gen:getSquare()
    if not square then return end
    local gx, gy, gz = square:getX(), square:getY(), square:getZ()
    TGM.registerGenerator(gen)
    TGM.requestRegister(player, gx, gy, gz)
    if isClient() then TGM.recompute(true) end

    local key = TGM.key(gx, gy, gz)
    local existing = Map.windows[key]
    if existing then
        existing:addToUIManager()
        existing:setVisible(true)
        existing:bringToTop()
        return
    end

    local g = TGM.refreshGeom()
    -- one cell more on every side: lights just past the circle (TGM.reachesAround)
    local cells = 2 * (g.radius + 1) + 1
    local screenH = getCore():getScreenHeight()
    -- title, status, two button rows, key and help (about three lines)
    local chrome = 24 + PAD + (FONT_HGT_SMALL + 6) + (BTN_H + 6) * 2 + FONT_HGT_SMALL * 4 + PAD * 2
    local view = math.floor(math.min(screenH * 0.85 - chrome, 700) / cells) * cells
    view = math.max(cells * 4, view)
    local win = Window:new(0, 0, view + PAD * 2, view + chrome, player:getPlayerNum(), gx, gy, gz, cells, view)
    win:initialise()
    win:addToUIManager()
    Map.windows[key] = win
end

function Map.onReply(command, args)
    local key = args.gx and TGM.key(args.gx, args.gy, args.gz)
    -- copied first: refresh() closes a window whose generator is gone
    local wins = {}
    for k, win in pairs(Map.windows) do wins[#wins + 1] = { k, win } end
    for i = 1, #wins do
        if wins[i][1] == key then wins[i][2]:onReply(command, args) else wins[i][2]:refresh() end
    end
end
