local Blitbuffer = require("ffi/blitbuffer")
local Device     = require("device")
local Font       = require("ui/font")
local Geom       = require("ui/geometry")
local RenderText = require("ui/rendertext")
local Size       = require("ui/size")

local Screen = Device.screen

local gwb            = require("grid_widget_base")
local GridWidgetBase = gwb.GridWidgetBase
local drawLine       = gwb.drawLine

-- ---------------------------------------------------------------------------
-- Colour palette
-- ---------------------------------------------------------------------------

local C_BG        = Blitbuffer.COLOR_WHITE
local C_SEL       = Blitbuffer.COLOR_GRAY_D
local C_WRONG     = Blitbuffer.COLOR_GRAY_B
local C_GIVEN_BG  = Blitbuffer.COLOR_GRAY_E
local C_LINE_THIN = Blitbuffer.COLOR_GRAY_9
local C_LINE      = Blitbuffer.COLOR_BLACK
local C_GIVEN_FG  = Blitbuffer.COLOR_BLACK
local C_USER_FG   = Blitbuffer.COLOR_GRAY_2
local C_REVEAL_FG = Blitbuffer.COLOR_GRAY_4
local C_NOTE_FG   = Blitbuffer.COLOR_GRAY_4
local C_LABEL     = Blitbuffer.COLOR_BLACK

-- ---------------------------------------------------------------------------
-- KenKenBoardWidget
-- ---------------------------------------------------------------------------

local KenKenBoardWidget = GridWidgetBase:extend{ board = nil }

function KenKenBoardWidget:init()
    local n   = self.board and self.board.n or 6
    self.cols = n
    self.rows = n
    GridWidgetBase.init(self)

    -- Small font for the cage label drawn in each cage's top-left cell corner.
    -- Font:getFace scales its size by DPI, so a size worked out from pixels
    -- has to be unscaled first or the label comes out nearly twice as big.
    local cell = self.size / n
    local dpi_scale = Screen:scaleBySize(1000) / 1000
    local label_sz = math.max(7, math.floor(cell * 0.3 / dpi_scale))
    self.cage_label_face    = Font:getFace("smallinfofont", label_sz)
    self.cage_label_padding = math.max(1, math.floor(cell * 0.05))
    -- Vertical space reserved at the top of a cage's label cell so the digit
    -- never collides with the label drawn in that same corner.
    self.cage_label_reserve = self.cage_label_padding + self.cage_label_face.size
    -- The base font fills a whole cell; under a label only the part below
    -- the reserve is left, so those cells get a proportionally smaller face.
    local full_h  = math.max(1, cell - 2 * (self.number_padding or 2))
    local ratio   = math.max(0.3, (full_h - self.cage_label_reserve) / full_h)
    self.label_cell_number_face = Font:getFace("cfont",
        math.max(8, math.floor(self.number_face.orig_size * ratio)))
end

function KenKenBoardWidget:onCellTap(row, col)
    if self.onCellSelected then self.onCellSelected(row, col) end
end

-- ---------------------------------------------------------------------------
-- paintTo
-- ---------------------------------------------------------------------------

function KenKenBoardWidget:paintTo(bb, x, y)
    if not self.board then return end
    self.paint_rect = Geom:new{ x=x, y=y, w=self.dimen.w, h=self.dimen.h }

    local board  = self.board
    local n      = board.n
    local cell   = self.dimen.w / n
    local thin   = Size.line.thin  or 1
    local thick  = math.max(2, math.floor(cell * 0.07))

    -- White background
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C_BG)

    -- -----------------------------------------------------------------------
    -- Cell backgrounds
    -- -----------------------------------------------------------------------
    for r = 1, n do
        for c = 1, n do
            local cx = x + math.floor((c-1) * cell)
            local cy = y + math.floor((r-1) * cell)
            local cw = math.ceil(cell)
            local ch = math.ceil(cell)
            if self.selected and self.selected.r==r and self.selected.c==c then
                bb:paintRect(cx, cy, cw, ch, C_SEL)
            elseif board.wrong_marks[r][c] then
                bb:paintRect(cx, cy, cw, ch, C_WRONG)
            elseif board:isGiven(r, c) then
                bb:paintRect(cx, cy, cw, ch, C_GIVEN_BG)
            end
        end
    end

    -- -----------------------------------------------------------------------
    -- Grid lines — draw all internal edges thin first, then overdraw cage
    -- boundaries thick.  Outer border is always thick.
    -- -----------------------------------------------------------------------

    -- Thin interior lines
    for i = 1, n-1 do
        drawLine(bb, x + math.floor(i*cell), y, thin, self.dimen.h, C_LINE_THIN)
        drawLine(bb, x, y + math.floor(i*cell), self.dimen.w, thin, C_LINE_THIN)
    end

    -- Thick outer border
    drawLine(bb, x,                        y,                        self.dimen.w, thick, C_LINE)
    drawLine(bb, x,                        y+self.dimen.h-thick,     self.dimen.w, thick, C_LINE)
    drawLine(bb, x,                        y,                        thick, self.dimen.h, C_LINE)
    drawLine(bb, x+self.dimen.w-thick,     y,                        thick, self.dimen.h, C_LINE)

    -- Thick cage boundaries on internal edges
    local half = math.floor(thick / 2)
    for r = 1, n do
        for c = 1, n-1 do
            -- Right edge of (r,c) / left edge of (r,c+1)
            if board.cage_of[r][c] ~= board.cage_of[r][c+1] then
                local lx = x + math.floor(c * cell) - half
                local ly = y + math.floor((r-1) * cell)
                drawLine(bb, lx, ly, thick, math.ceil(cell), C_LINE)
            end
        end
    end
    for r = 1, n-1 do
        for c = 1, n do
            -- Bottom edge of (r,c) / top edge of (r+1,c)
            if board.cage_of[r][c] ~= board.cage_of[r+1][c] then
                local lx = x + math.floor((c-1) * cell)
                local ly = y + math.floor(r * cell) - half
                drawLine(bb, lx, ly, math.ceil(cell), thick, C_LINE)
            end
        end
    end

    -- -----------------------------------------------------------------------
    -- Cell content: digit or notes
    -- -----------------------------------------------------------------------
    local pad  = self.number_padding or 2
    local cinn = math.max(1, math.floor(cell - 2*pad))

    local label_cells = {}
    for r = 1, n do label_cells[r] = {} end
    for _, cage in ipairs(board.cages) do
        if #cage.cells > 1 then
            label_cells[cage.label_cell[1]][cage.label_cell[2]] = true
        end
    end

    for r = 1, n do
        for c = 1, n do
            local cx = x + math.floor((c-1) * cell)
            local cy = y + math.floor((r-1) * cell)
            local v  = board:getDisplayValue(r, c)

            if v ~= 0 then
                local text     = tostring(v)
                local is_given = board:isGiven(r, c)
                local color = board:isShowingSolution() and not is_given
                    and C_REVEAL_FG
                    or  (is_given and C_GIVEN_FG or C_USER_FG)
                -- Only a cage's label cell carries a label (single-cell cages
                -- aren't labelled); every other cell centres in the full cell.
                local face = label_cells[r][c] and self.label_cell_number_face or self.number_face
                local m    = RenderText:sizeUtf8Text(0, cinn, face, text, true, false)
                local base
                if not label_cells[r][c] then
                    base = cy + pad + math.floor((cinn + m.y_top - m.y_bottom) / 2)
                else
                    local reserve = self.cage_label_reserve
                    local avail_h = math.max(1, math.floor(cell - reserve - pad))
                    base = cy + reserve + math.floor((avail_h + m.y_top - m.y_bottom) / 2)
                end
                local tx = cx + pad + math.floor((cinn - m.x) / 2)
                RenderText:renderUtf8Text(bb, tx, base, face, text, true, false, color)
            else
                -- Notes
                local notes = board.notes[r][c]
                if notes then
                    local cols3 = 3
                    local rows3 = math.ceil(n / cols3)
                    local mw    = cell / cols3
                    local top   = label_cells[r][c] and self.cage_label_reserve or 0
                    local mh    = (cell - top) / rows3
                    local np    = self.note_padding or 1
                    for d = 1, n do
                        if notes[d] then
                            local mc = (d-1) % cols3
                            local mr = math.floor((d-1) / cols3)
                            local mx = cx + math.floor(mc * mw)
                            local my = cy + top + math.floor(mr * mh)
                            local nt = tostring(d)
                            local nm = RenderText:sizeUtf8Text(0, math.floor(mw-2*np), self.note_face, nt, true, false)
                            local nb = my + np + math.floor((math.floor(mh-2*np) + nm.y_top - nm.y_bottom) / 2)
                            local nx = mx + np + math.floor((math.floor(mw-2*np) - nm.x) / 2)
                            RenderText:renderUtf8Text(bb, nx, nb, self.note_face, nt, true, false, C_NOTE_FG)
                        end
                    end
                end
            end
        end
    end

    -- -----------------------------------------------------------------------
    -- Cage labels — drawn last so they sit on top of everything.
    -- Single-cell cages show their value in full via the digit itself, so
    -- they get no separate (redundant) label.
    -- -----------------------------------------------------------------------
    local lpad = self.cage_label_padding

    for _, cage in ipairs(board.cages) do
        if #cage.cells > 1 then
            local lr, lc   = cage.label_cell[1], cage.label_cell[2]
            local label    = board:getCageLabel(cage)
            local lx       = x + math.floor((lc-1) * cell) + lpad + thick
            local ly       = y + math.floor((lr-1) * cell) + lpad + thick
            local lm       = RenderText:sizeUtf8Text(0, math.floor(cell * 0.9),
                                self.cage_label_face, label, true, false)
            -- y_top is the ink above the baseline: the label's top sits on ly.
            local lbase    = ly + lm.y_top
            RenderText:renderUtf8Text(bb, lx, lbase, self.cage_label_face, label, true, false, C_LABEL)
        end
    end
end

function KenKenBoardWidget:setSelected(r, c)
    self.selected = r and c and { r=r, c=c } or nil
end

return KenKenBoardWidget
