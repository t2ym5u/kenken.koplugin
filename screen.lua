local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local ButtonTable     = require("ui/widget/buttontable")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("gettext")
local T               = require("ffi/util").template

local ScreenBase         = require("screen_base")
local MenuHelper         = require("menu_helper")
local KenKenBoard        = lrequire("board")
local KenKenBoardWidget  = lrequire("board_widget")

local DeviceScreen = Device.screen

local GRID_SIZES = { 3, 4, 5, 6, 8 }

-- ---------------------------------------------------------------------------
-- KenKenScreen
-- ---------------------------------------------------------------------------

local GAME_RULES_EN = _([[
KenKen — Rules

Fill the N×N grid with numbers 1 to N so that each row and each column contains each number exactly once (like Sudoku).

Cage constraint:
• Cells are grouped into "cages" labelled with a target number and an arithmetic operation (+, −, ×, ÷).
• The numbers in a cage must produce the target value when the operation is applied.
• For subtraction and division, the operands may be in either order.
• Numbers may repeat within a cage, as long as rows and columns remain valid.

Tap a cell to select it, then tap a digit to fill it in.
]])

local GAME_RULES_FR = [[
KenKen — Règles

Remplissez la grille N×N avec les chiffres de 1 à N de sorte que chaque ligne et colonne contienne chaque chiffre exactement une fois (comme au Sudoku).

Contrainte des cages :
• Les cases sont regroupées en "cages" portant un résultat cible et une opération arithmétique (+, −, ×, ÷).
• Les chiffres d'une cage doivent produire le résultat cible avec l'opération donnée.
• Pour la soustraction et la division, l'ordre des opérandes peut être indifférent.
• Les chiffres peuvent se répéter au sein d'une cage, du moment que les lignes et colonnes restent valides.
]]

local KenKenScreen = ScreenBase:extend{}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function KenKenScreen:init()
    local state = self.plugin:loadState()
    local n     = self.plugin:getSetting("grid_n", 6)
    self.board  = KenKenBoard:new{ n = n }
    if not self.board:load(state) then
        self.board:generate(self.plugin:getSetting("difficulty", "medium"))
    end
    self.selected  = nil
    self.note_mode = false
    ScreenBase.init(self)
end

function KenKenScreen:serializeState()
    return self.board:serialize()
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function KenKenScreen:buildLayout()
    local n            = self.board.n
    local sw           = DeviceScreen:getWidth()
    local is_landscape = self:isLandscape()

    self.board_widget = KenKenBoardWidget:new{
        board          = self.board,
        onCellSelected = function(r, c) self:onCellSelected(r, c) end,
    }
    if self.selected then
        self.board_widget:setSelected(self.selected.r, self.selected.c)
    end

    local board_frame = FrameContainer:new{
        padding = Size.padding.large,
        margin  = Size.margin.default,
        self.board_widget,
    }

    local board_frame_size  = self.board_widget.size + (Size.padding.large + Size.margin.default) * 2
    local right_panel_width = sw - board_frame_size - Size.span.horizontal_default
    local button_width = is_landscape
        and math.max(right_panel_width - Size.span.horizontal_default, 100)
        or  math.floor(sw * 0.9)

    -- Top bar
    local top_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = button_width,
        buttons = {{
            { text = _("New game"),  callback = function() self:onNewGame() end },
            { id = "grid_button",    text = self:getGridButtonText(),
              callback = function() self:openGridMenu() end },
            { id = "diff_button",    text = self:getDiffButtonText(),
              callback = function() self:openDifficultyMenu() end },
            { id = "show_button",    text = self:getShowButtonText(),
              callback = function() self:toggleSolution() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
            self:makeCloseButtonConfig(),
        }},
    }
    self.grid_button = top_buttons:getButtonById("grid_button")
    self.diff_button = top_buttons:getButtonById("diff_button")
    self.show_button = top_buttons:getButtonById("show_button")

    -- Digit buttons 1..n
    local digit_row = {}
    for d = 1, n do
        local dv = d
        digit_row[#digit_row+1] = {
            id       = "digit_" .. dv,
            text     = tostring(dv),
            callback = function() self:onDigit(dv) end,
        }
    end
    local digit_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = button_width,
        buttons = { digit_row },
    }
    self.digit_button_refs = {}
    for d = 1, n do
        self.digit_button_refs[d] = digit_buttons:getButtonById("digit_" .. d)
    end

    -- Bottom bar
    local bottom_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = button_width,
        buttons = {{
            { id = "note_button", text = self:getNoteButtonText(),
              callback = function() self:toggleNoteMode() end },
            { text = _("Erase"),  callback = function() self:onErase() end },
            { text = _("Check"),  callback = function() self:onCheck() end },
            { id = "undo_button", text = _("Undo"),
              callback = function() self:onUndo() end },
        }},
    }
    self.note_button = bottom_buttons:getButtonById("note_button")
    self.undo_button = bottom_buttons:getButtonById("undo_button")
    self:_updateUndoButton()

    if is_landscape then
        local right_panel = VerticalGroup:new{
            align = "center",
            top_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
            VerticalSpan:new{ width = Size.span.vertical_large },
            digit_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            bottom_buttons,
        }
        self.layout = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = Size.span.horizontal_default },
            right_panel,
        }
    else
        self.layout = VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = Size.span.vertical_large },
            top_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            board_frame,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
            VerticalSpan:new{ width = Size.span.vertical_large },
            digit_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            bottom_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
        }
    end
    self[1] = self.layout
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Cell interaction
-- ---------------------------------------------------------------------------

function KenKenScreen:onCellSelected(r, c)
    self.selected = { r=r, c=c }
    self.board_widget:setSelected(r, c)
    self.board_widget:refresh()
    self:updateStatus()
end

function KenKenScreen:onDigit(d)
    if not self.selected then return end
    local r, c = self.selected.r, self.selected.c
    local ok, err
    if self.note_mode then
        ok, err = self.board:toggleNote(r, c, d)
    else
        ok, err = self.board:setValue(r, c,
            self.board.user[r][c] == d and 0 or d)
    end
    if ok then
        self.plugin:saveState(self.board:serialize())
        self:_updateUndoButton()
        self:updateStatus(self.board:isSolved() and _("Congratulations! Puzzle solved.") or nil)
    else
        self:updateStatus(err == "given" and _("Cannot edit a given cell.") or nil)
    end
    self.board_widget:refresh()
end

function KenKenScreen:onErase()
    if not self.selected then return end
    local r, c   = self.selected.r, self.selected.c
    local ok, err = self.board:clearCell(r, c)
    if err == "given" then
        self:updateStatus(_("Cannot edit a given cell."))
        return
    end
    if ok then
        self.plugin:saveState(self.board:serialize())
        self:_updateUndoButton()
    end
    self.board_widget:refresh()
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Game actions
-- ---------------------------------------------------------------------------

function KenKenScreen:onNewGame()
    local diff = self.plugin:getSetting("difficulty", "medium")
    local n    = self.plugin:getSetting("grid_n", 6)
    self.board = KenKenBoard:new{ n=n }
    self.board:generate(diff)
    self.selected  = nil
    self.note_mode = false
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function KenKenScreen:onUndo()
    local ok, msg = self.board:undo()
    if ok then
        self.plugin:saveState(self.board:serialize())
        self:_updateUndoButton()
        self.board_widget:refresh()
        self:updateStatus()
    else
        self:updateStatus(msg)
    end
end

function KenKenScreen:onCheck()
    self.board:checkConflicts()
    self.board_widget:refresh()
    local remaining = self.board:getRemainingCells()
    if remaining > 0 then
        self:updateStatus(T(_("Check done. %1 cell(s) remaining."), remaining))
    elseif self.board:isSolved() then
        self:updateStatus(_("Congratulations! Puzzle solved."))
    else
        self:updateStatus(_("Some cells are incorrect."))
    end
end

function KenKenScreen:toggleSolution()
    self.board:toggleSolution()
    self.board_widget:refresh()
    if self.show_button then
        self.show_button:setText(self:getShowButtonText(), self.show_button.width)
    end
    self:updateStatus()
end

function KenKenScreen:toggleNoteMode()
    self.note_mode = not self.note_mode
    if self.note_button then
        self.note_button:setText(self:getNoteButtonText(), self.note_button.width)
    end
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------

function KenKenScreen:openGridMenu()
    local sizes = {}
    for _, sz in ipairs(GRID_SIZES) do
        sizes[#sizes+1] = { id=sz, text=sz .. "\xC3\x97" .. sz }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select grid size"),
        sizes     = sizes,
        current   = self.plugin:getSetting("grid_n", 6),
        parent    = self,
        on_select = function(sz)
            if sz ~= self.board.n then
                self.plugin:saveSetting("grid_n", sz)
                self:onNewGame()
            end
        end,
    }
end

function KenKenScreen:openDifficultyMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", "medium"),
        parent    = self,
        on_select = function(id)
            self.plugin:saveSetting("difficulty", id)
            if self.diff_button then
                self.diff_button:setText(self:getDiffButtonText(), self.diff_button.width)
            end
            self:onNewGame()
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Status bar
-- ---------------------------------------------------------------------------

function KenKenScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board:isShowingSolution() then
        status = _("Solution is shown; editing is disabled.")
    elseif self.board:isSolved() then
        status = _("Congratulations! Puzzle solved.")
    else
        local diff      = self.plugin:getSetting("difficulty", "medium")
        local label     = MenuHelper.DIFFICULTY_LABELS[diff] or diff
        local remaining = self.board:getRemainingCells()
        local note_str  = self.note_mode and _(" \xC2\xB7 Note ON") or ""
        -- Show cage info for selected cell
        local cage_str  = ""
        if self.selected then
            local r, c   = self.selected.r, self.selected.c
            local ci     = self.board.cage_of[r][c]
            local cage   = self.board.cages[ci]
            if cage then
                cage_str = "  [" .. self.board:getCageLabel(cage) .. "]"
            end
        end
        status = T(_("%1\xC3\x97%2 \xC2\xB7 %3 \xC2\xB7 Empty: %4%5%6"),
            self.board.n, self.board.n, label, remaining, note_str, cage_str)
    end
    ScreenBase.updateStatus(self, status)
end

-- ---------------------------------------------------------------------------
-- Button text helpers
-- ---------------------------------------------------------------------------

function KenKenScreen:getGridButtonText()
    return T(_("Grid: %1"), self.board.n .. "\xC3\x97" .. self.board.n)
end

function KenKenScreen:getDiffButtonText()
    local diff  = self.plugin:getSetting("difficulty", "medium")
    local label = MenuHelper.DIFFICULTY_LABELS[diff] or diff
    return T(_("Diff: %1"), label)
end

function KenKenScreen:getShowButtonText()
    return self.board:isShowingSolution() and _("Hide result") or _("Show result")
end

function KenKenScreen:getNoteButtonText()
    return self.note_mode and _("Note: ON") or _("Note: OFF")
end

function KenKenScreen:_updateUndoButton()
    if not self.undo_button then return end
    self.undo_button:enableDisable(self.board:canUndo())
end

return KenKenScreen
