local UndoStack  = require("undo_stack")
local grid_utils = require("grid_utils")

local emptyGrid     = grid_utils.emptyGrid
local emptyBoolGrid = grid_utils.emptyBoolGrid
local copyGrid      = grid_utils.copyGrid
local shuffle       = grid_utils.shuffle

local DEFAULT_N          = 6
local DEFAULT_DIFFICULTY = "medium"

-- UTF-8 arithmetic symbols
local SYM_MUL = "\195\151"   -- ×
local SYM_DIV = "\195\183"   -- ÷

-- Max cage cell count by difficulty
local MAX_CAGE = { easy = 2, medium = 3, hard = 4 }
-- Probability that a newly started cage remains a single cell (i.e. a given)
local SINGLE_P = { easy = 0.18, medium = 0.10, hard = 0.05 }

-- ---------------------------------------------------------------------------
-- KenKenBoard
-- ---------------------------------------------------------------------------

local KenKenBoard = {}
KenKenBoard.__index = KenKenBoard

function KenKenBoard:new(opts)
    opts = opts or {}
    local n = opts.n or DEFAULT_N
    local obj = setmetatable({
        n               = n,
        difficulty      = opts.difficulty or DEFAULT_DIFFICULTY,
        solution        = emptyGrid(n),
        given           = emptyBoolGrid(n),
        user            = emptyGrid(n),
        notes           = {},
        cages           = {},
        cage_of         = emptyGrid(n),   -- cage_of[r][c] = 1-based cage index
        wrong_marks     = emptyBoolGrid(n),
        reveal_solution = false,
        undo            = UndoStack:new{ max_size = 200 },
    }, self)
    for r = 1, n do
        obj.notes[r] = {}
        for c = 1, n do obj.notes[r][c] = {} end
    end
    obj:generate(obj.difficulty)
    return obj
end

-- ---------------------------------------------------------------------------
-- Latin-square generation (identical to Futoshiki)
-- ---------------------------------------------------------------------------

local function makeBaseLatin(n)
    local g = {}
    for r = 1, n do
        g[r] = {}
        for c = 1, n do g[r][c] = (r + c - 2) % n + 1 end
    end
    return g
end

local function permuteLatin(g, n)
    local row_ord, col_ord = {}, {}
    for i = 1, n do row_ord[i] = i; col_ord[i] = i end
    shuffle(row_ord); shuffle(col_ord)
    local dmap = {}
    local digits = {}
    for i = 1, n do digits[i] = i end
    shuffle(digits)
    for i = 1, n do dmap[i] = digits[i] end
    local out = {}
    for r = 1, n do
        out[r] = {}
        for c = 1, n do out[r][c] = dmap[g[row_ord[r]][col_ord[c]]] end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Cage generation
-- ---------------------------------------------------------------------------

local function buildCages(n, sol, difficulty)
    local max_sz  = MAX_CAGE[difficulty]  or 3
    local single_p = SINGLE_P[difficulty] or 0.10
    local cage_of = emptyGrid(n)
    local cages   = {}

    for r = 1, n do
        for c = 1, n do
            if cage_of[r][c] == 0 then
                local idx   = #cages + 1
                local cells = { {r, c} }
                cage_of[r][c] = idx

                local target_sz = (math.random() < single_p) and 1
                    or math.random(2, max_sz)

                while #cells < target_sz do
                    local cands = {}
                    for _, cell in ipairs(cells) do
                        for _, d in ipairs({ {-1,0},{1,0},{0,-1},{0,1} }) do
                            local nr, nc = cell[1]+d[1], cell[2]+d[2]
                            if nr>=1 and nr<=n and nc>=1 and nc<=n
                                and cage_of[nr][nc] == 0 then
                                local dup = false
                                for _, nb in ipairs(cands) do
                                    if nb[1]==nr and nb[2]==nc then dup=true; break end
                                end
                                if not dup then cands[#cands+1] = {nr, nc} end
                            end
                        end
                    end
                    if #cands == 0 then break end
                    local pick = cands[math.random(#cands)]
                    cage_of[pick[1]][pick[2]] = idx
                    cells[#cells+1] = pick
                end

                -- Sort to reading order so label_cell is top-left
                table.sort(cells, function(a, b)
                    return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
                end)
                cages[idx] = {
                    cells      = cells,
                    label_cell = { cells[1][1], cells[1][2] },
                    op         = "",
                    target     = 0,
                }
            end
        end
    end

    return cages, cage_of
end

-- ---------------------------------------------------------------------------
-- Operation and target assignment
-- ---------------------------------------------------------------------------

local function assignOps(cages, sol, difficulty)
    for _, cage in ipairs(cages) do
        local cells = cage.cells
        local size  = #cells
        local vals  = {}
        for _, cell in ipairs(cells) do
            vals[#vals+1] = sol[cell[1]][cell[2]]
        end

        if size == 1 then
            cage.op     = ""
            cage.target = vals[1]

        elseif size == 2 then
            local a, b = vals[1], vals[2]
            local ops  = { "+" }
            ops[#ops+1] = SYM_MUL
            if math.abs(a - b) > 0 then ops[#ops+1] = "-" end
            local big, small = math.max(a,b), math.min(a,b)
            if small > 0 and big % small == 0 and big ~= small then
                ops[#ops+1] = SYM_DIV
            end

            local op
            if difficulty == "easy" then
                op = (math.random() < 0.60) and "+" or ops[math.random(#ops)]
            else
                op = ops[math.random(#ops)]
            end
            cage.op = op

            if op == "+" then
                cage.target = a + b
            elseif op == "-" then
                cage.target = math.abs(a - b)
            elseif op == SYM_MUL then
                cage.target = a * b
            else   -- ÷
                cage.target = math.floor(big / small)
            end

        else
            -- size >= 3: + or × only
            local use_mul = (difficulty == "hard") and (math.random() < 0.35)
            if use_mul then
                local prod = 1
                for _, v in ipairs(vals) do prod = prod * v end
                cage.op     = SYM_MUL
                cage.target = prod
            else
                local sum = 0
                for _, v in ipairs(vals) do sum = sum + v end
                cage.op     = "+"
                cage.target = sum
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- generate
-- ---------------------------------------------------------------------------

function KenKenBoard:generate(difficulty)
    self.difficulty      = difficulty or self.difficulty
    self.reveal_solution = false
    self.undo:clear()
    local n = self.n

    self.solution = permuteLatin(makeBaseLatin(n), n)
    self.cages, self.cage_of = buildCages(n, self.solution, self.difficulty)
    assignOps(self.cages, self.solution, self.difficulty)

    -- Single-cell cages become givens
    self.given = emptyBoolGrid(n)
    for _, cage in ipairs(self.cages) do
        if #cage.cells == 1 then
            local r, c = cage.cells[1][1], cage.cells[1][2]
            self.given[r][c] = true
        end
    end

    self.user        = emptyGrid(n)
    self.wrong_marks = emptyBoolGrid(n)
    self.notes       = {}
    for r = 1, n do
        self.notes[r] = {}
        for c = 1, n do self.notes[r][c] = {} end
    end
end

-- ---------------------------------------------------------------------------
-- Cell access
-- ---------------------------------------------------------------------------

function KenKenBoard:isGiven(r, c)
    return self.given[r] and self.given[r][c] == true
end

function KenKenBoard:getDisplayValue(r, c)
    if self.reveal_solution then return self.solution[r][c] end
    if self:isGiven(r, c)   then return self.solution[r][c] end
    return self.user[r][c]
end

-- Returns the cage label string for a given cage (e.g. "12+", "6×", "3-", "5").
function KenKenBoard:getCageLabel(cage)
    return tostring(cage.target) .. cage.op
end

-- ---------------------------------------------------------------------------
-- Editing
-- ---------------------------------------------------------------------------

local function cloneNotes(cell)
    local out = {}
    for k, v in pairs(cell) do out[k] = v end
    return out
end

function KenKenBoard:setValue(r, c, v)
    if self:isGiven(r, c)     then return false, "given" end
    if self.reveal_solution   then return false, "solution_shown" end
    local prev_val   = self.user[r][c]
    local prev_notes = cloneNotes(self.notes[r][c])
    self.undo:push{ r=r, c=c, prev_value=prev_val, prev_notes=prev_notes }
    self.user[r][c]  = v
    self.notes[r][c] = {}
    self.wrong_marks[r][c] = false
    return true
end

function KenKenBoard:clearCell(r, c)
    if self:isGiven(r, c)   then return false, "given" end
    if self.reveal_solution then return false, "solution_shown" end
    local prev_val   = self.user[r][c]
    local prev_notes = cloneNotes(self.notes[r][c])
    self.undo:push{ r=r, c=c, prev_value=prev_val, prev_notes=prev_notes }
    self.user[r][c]  = 0
    self.notes[r][c] = {}
    self.wrong_marks[r][c] = false
    return true
end

function KenKenBoard:toggleNote(r, c, d)
    if self:isGiven(r, c)   then return false, "given" end
    if self.reveal_solution then return false, "solution_shown" end
    local prev_notes = cloneNotes(self.notes[r][c])
    self.undo:push{ r=r, c=c, prev_notes=prev_notes }
    self.notes[r][c][d] = not self.notes[r][c][d] or nil
    return true
end

-- ---------------------------------------------------------------------------
-- Undo
-- ---------------------------------------------------------------------------

function KenKenBoard:canUndo() return self.undo:canUndo() end

function KenKenBoard:undo()
    local entry = self.undo:pop()
    if not entry then return false, UndoStack.NOTHING_TO_UNDO end
    local r, c = entry.r, entry.c
    if entry.prev_value ~= nil then self.user[r][c] = entry.prev_value end
    if entry.prev_notes        then self.notes[r][c] = cloneNotes(entry.prev_notes) end
    self.wrong_marks[r][c] = false
    return true
end

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

function KenKenBoard:checkConflicts()
    local n = self.n
    for r = 1, n do
        for c = 1, n do
            local v = self:getDisplayValue(r, c)
            self.wrong_marks[r][c] = v ~= 0 and v ~= self.solution[r][c]
        end
    end
end

function KenKenBoard:isSolved()
    local n = self.n
    for r = 1, n do
        for c = 1, n do
            local v = self:getDisplayValue(r, c)
            if v == 0 or v ~= self.solution[r][c] then return false end
        end
    end
    return true
end

function KenKenBoard:getRemainingCells()
    local n, count = self.n, 0
    for r = 1, n do
        for c = 1, n do
            if self:getDisplayValue(r, c) == 0 then count = count + 1 end
        end
    end
    return count
end

-- ---------------------------------------------------------------------------
-- Solution reveal
-- ---------------------------------------------------------------------------

function KenKenBoard:toggleSolution()   self.reveal_solution = not self.reveal_solution end
function KenKenBoard:isShowingSolution() return self.reveal_solution end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

function KenKenBoard:serialize()
    local n = self.n
    local notes_out = {}
    for r = 1, n do
        notes_out[r] = {}
        for c = 1, n do
            local cell = {}
            for d, v in pairs(self.notes[r][c]) do if v then cell[d] = true end end
            notes_out[r][c] = cell
        end
    end
    local cages_out = {}
    for i, cage in ipairs(self.cages) do
        local cells_out = {}
        for j, cell in ipairs(cage.cells) do cells_out[j] = {cell[1], cell[2]} end
        cages_out[i] = {
            cells      = cells_out,
            label_cell = { cage.label_cell[1], cage.label_cell[2] },
            op         = cage.op,
            target     = cage.target,
        }
    end
    return {
        n               = n,
        difficulty      = self.difficulty,
        solution        = copyGrid(self.solution, n),
        given           = copyGrid(self.given, n),
        user            = copyGrid(self.user, n),
        notes           = notes_out,
        cage_of         = copyGrid(self.cage_of, n),
        cages           = cages_out,
        wrong_marks     = copyGrid(self.wrong_marks, n),
        reveal_solution = self.reveal_solution,
        undo            = self.undo:serialize(),
    }
end

function KenKenBoard:load(data)
    if type(data) ~= "table" or not data.solution or not data.cages then return false end
    local n = data.n or DEFAULT_N
    self.n          = n
    self.difficulty = data.difficulty or DEFAULT_DIFFICULTY
    self.solution   = copyGrid(data.solution, n)
    self.user       = copyGrid(data.user or {}, n)
    self.cage_of    = copyGrid(data.cage_of or {}, n)

    self.given = emptyBoolGrid(n)
    if data.given then
        for r = 1, n do for c = 1, n do
            local v = data.given[r] and data.given[r][c]
            self.given[r][c] = (v == true or v == 1)
        end end
    end

    self.notes = {}
    for r = 1, n do
        self.notes[r] = {}
        for c = 1, n do
            self.notes[r][c] = {}
            local saved = data.notes and data.notes[r] and data.notes[r][c]
            if type(saved) == "table" then
                for d, v in pairs(saved) do if v then self.notes[r][c][d] = true end end
            end
        end
    end

    self.cages = {}
    for i, cdata in ipairs(data.cages) do
        local cells = {}
        for j, cell in ipairs(cdata.cells) do cells[j] = {cell[1], cell[2]} end
        self.cages[i] = {
            cells      = cells,
            label_cell = { cdata.label_cell[1], cdata.label_cell[2] },
            op         = cdata.op,
            target     = cdata.target,
        }
    end

    self.wrong_marks = emptyBoolGrid(n)
    if data.wrong_marks then
        for r = 1, n do for c = 1, n do
            local v = data.wrong_marks[r] and data.wrong_marks[r][c]
            self.wrong_marks[r][c] = (v == true or v == 1)
        end end
    end

    self.reveal_solution = data.reveal_solution or false
    self.undo = UndoStack:new{ max_size = 200 }
    if data.undo then self.undo:load(data.undo) end
    return true
end

return KenKenBoard
