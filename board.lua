local UndoStack  = require("undo_stack")
local grid_utils = require("grid_utils")
local Hint      = require("hint")

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
local SINGLE_P = { easy = 0.18, medium = 0.05, hard = 0.03 }

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
    -- opts.empty: the caller loads a save or generates right after (with
    -- the progress bar), so skip the throwaway puzzle.
    if not opts.empty then obj:generate(obj.difficulty) end
    return obj
end

-- ---------------------------------------------------------------------------
-- Random Latin square
-- ---------------------------------------------------------------------------
-- Built row by row: each new row is a perfect matching of columns to the
-- digits each column has not used yet, found with Kuhn's augmenting paths
-- over shuffled orders. A Latin rectangle always extends to a full square
-- (Hall's theorem), so this never backtracks and never fails, and it reaches
-- far more squares than a permuted cyclic one. Draws only from math.random.

local function randomLatin(n)
    local g = {}
    local col_used = {}
    for c = 1, n do col_used[c] = {} end
    for r = 1, n do
        local row, owner = {}, {}   -- row[c] = digit, owner[digit] = column
        local order = {}
        for c = 1, n do
            local ds = {}
            for d = 1, n do ds[d] = d end
            order[c] = shuffle(ds)
        end
        local function augment(c, seen)
            for _, d in ipairs(order[c]) do
                if not col_used[c][d] and not seen[d] then
                    seen[d] = true
                    if not owner[d] or augment(owner[d], seen) then
                        owner[d] = c
                        row[c]   = d
                        return true
                    end
                end
            end
            return false
        end
        local cols = {}
        for c = 1, n do cols[c] = c end
        for _, c in ipairs(shuffle(cols)) do augment(c, {}) end
        for c = 1, n do col_used[c][row[c]] = true end
        g[r] = row
    end
    return g
end

-- ---------------------------------------------------------------------------
-- Cage arithmetic
-- ---------------------------------------------------------------------------

-- Do these values (one per cage cell, in cage order) satisfy the cage?
local function cageSatisfied(cage, vals)
    local op, target = cage.op, cage.target
    if #vals == 1 then return vals[1] == target end
    if op == "+" then
        local s = 0
        for _, v in ipairs(vals) do s = s + v end
        return s == target
    elseif op == SYM_MUL then
        local p = 1
        for _, v in ipairs(vals) do p = p * v end
        return p == target
    elseif op == "-" then
        return #vals == 2 and math.abs(vals[1] - vals[2]) == target
    elseif op == SYM_DIV then
        if #vals ~= 2 then return false end
        local big, small = math.max(vals[1], vals[2]), math.min(vals[1], vals[2])
        return small > 0 and big == small * target
    end
    return false
end

-- Every value tuple (one value per cell, cage order) that satisfies the
-- cage arithmetic, with cells sharing a row or column holding different
-- values. Cached on the cage table; cages are never edited in place.
-- While generating, tuples are also shared between cages of the same shape,
-- operation and target (the repairs rebuild the same cages many times).
local tuple_cache

local function cageTuples(cage, n)
    if cage.tuples then return cage.tuples end
    local cells, op, target = cage.cells, cage.op, cage.target
    local k = #cells
    local key
    if tuple_cache then
        local parts = { n, op, target }
        for i = 1, k do
            parts[#parts+1] = (cells[i][1] - cells[1][1]) .. ":" .. (cells[i][2] - cells[1][2])
        end
        key = table.concat(parts, ",")
        local hit = tuple_cache[key]
        if hit then cage.tuples = hit; return hit end
    end
    local list = {}
    local conf = {}
    for i = 1, k do
        conf[i] = {}
        for j = 1, i - 1 do
            if cells[i][1] == cells[j][1] or cells[i][2] == cells[j][2] then
                conf[i][#conf[i] + 1] = j
            end
        end
    end
    local vals = {}
    local function rec(i, acc)
        if i > k then
            if cageSatisfied(cage, vals) then
                local t = {}
                for p = 1, k do t[p] = vals[p] end
                list[#list + 1] = t
            end
            return
        end
        for v = 1, n do
            local ok = true
            for _, j in ipairs(conf[i]) do
                if vals[j] == v then ok = false; break end
            end
            if ok then
                local nacc = acc
                if op == "+" then
                    nacc = acc + v
                    -- the cells left need at least 1 and at most n each
                    if nacc + (k - i) > target then break end
                    if nacc + (k - i) * n < target then ok = false end
                elseif op == SYM_MUL then
                    nacc = acc * v
                    if target % nacc ~= 0 then ok = false end
                end
                if ok then
                    vals[i] = v
                    rec(i + 1, nacc)
                end
            end
        end
        vals[i] = nil
    end
    rec(1, op == SYM_MUL and 1 or 0)
    cage.tuples = list
    if key then tuple_cache[key] = list end
    return list
end

-- ---------------------------------------------------------------------------
-- Logic solver (no trial and error)
-- ---------------------------------------------------------------------------
-- Candidates per cell, narrowed only by sound deductions, cheapest first:
--   singles  - a placed digit leaves its row and column; a digit with one
--              place left in a row or column goes there;
--   cage     - a digit no remaining cage combination uses in that cell goes;
--   pairs    - two cells of a line with the same two candidates take them
--              both (naked pair);            } "advanced" steps, only
--   lines    - a digit every remaining cage   } when allow_adv
--              combination puts in a given row/column of the cage leaves the
--              rest of that line.
-- Nothing is ever assumed, so a puzzle this solves completely has exactly
-- one solution. Returns solved, stats, grid (grid[r][c], 0 = unresolved).

local function logicSolve(n, cages, allow_adv)
    local N = n * n
    local cand, cnt = {}, {}
    for i = 1, N do
        local t = {}
        for v = 1, n do t[v] = true end
        cand[i], cnt[i] = t, n
    end
    local alive, cidx, cage_at = {}, {}, {}
    for k, cage in ipairs(cages) do
        local tl, a = cageTuples(cage, n), {}
        for t = 1, #tl do a[t] = tl[t] end
        alive[k] = a
        local ci = {}
        for p, cell in ipairs(cage.cells) do
            local i = (cell[1] - 1) * n + cell[2]
            ci[p], cage_at[i] = i, k
        end
        cidx[k] = ci
    end
    local stats = { singles = 0, cage = 0, pairs = 0, lines = 0 }
    local changed, broken = false, false
    -- dirty[k]: a cell of cage k lost a candidate since its last filter;
    -- line_dirty[k]: its combinations shrank since its last line check.
    local dirty, line_dirty = {}, {}
    for k = 1, #cages do dirty[k], line_dirty[k] = true, true end
    local function elim(i, v)
        if cand[i][v] then
            cand[i][v] = false
            cnt[i] = cnt[i] - 1
            if cnt[i] == 0 then broken = true end
            dirty[cage_at[i]] = true
            changed = true
        end
    end
    local done = {}

    local function singles()
        changed = false
        local progress = true
        while progress and not broken do
            progress = false
            for i = 1, N do
                if cnt[i] == 1 and not done[i] then
                    done[i], progress = true, true
                    local v
                    for x = 1, n do if cand[i][x] then v = x; break end end
                    local r = math.floor((i - 1) / n) + 1
                    local c = i - (r - 1) * n
                    for x = 1, n do
                        local j = (r - 1) * n + x
                        if j ~= i then elim(j, v) end
                        j = (x - 1) * n + c
                        if j ~= i then elim(j, v) end
                    end
                end
            end
            for line = 1, n do
                for v = 1, n do
                    local rc, rpos, cc, cpos = 0, nil, 0, nil
                    for x = 1, n do
                        local i = (line - 1) * n + x
                        if cand[i][v] then rc = rc + 1; rpos = i end
                        i = (x - 1) * n + line
                        if cand[i][v] then cc = cc + 1; cpos = i end
                    end
                    if rc == 1 and cnt[rpos] > 1 then
                        for x = 1, n do if x ~= v then elim(rpos, x) end end
                        progress = true
                    end
                    if cc == 1 and cnt[cpos] > 1 then
                        for x = 1, n do if x ~= v then elim(cpos, x) end end
                        progress = true
                    end
                end
            end
        end
        return changed
    end

    -- sup[(p-1)*n + v] == stamp: some combination still puts v in cell p
    local sup, stamp = {}, 0
    local function cageFilter()
        changed = false
        for k = 1, #cages do
          if dirty[k] then
            local a, ci = alive[k], cidx[k]
            local m, keep = #ci, 0
            stamp = stamp + 1
            for t = 1, #a do
                local tup, ok = a[t], true
                for p = 1, m do
                    if not cand[ci[p]][tup[p]] then ok = false; break end
                end
                if ok then
                    keep = keep + 1
                    a[keep] = tup
                    for p = 1, m do sup[(p - 1) * n + tup[p]] = stamp end
                end
            end
            if keep < #a then line_dirty[k] = true end
            for t = #a, keep + 1, -1 do a[t] = nil end
            for p = 1, m do
                local i, base = ci[p], (p - 1) * n
                for v = 1, n do
                    if cand[i][v] and sup[base + v] ~= stamp then elim(i, v) end
                end
            end
            -- what is left is all supported: no need to filter again yet
            dirty[k] = false
          end
        end
        return changed
    end

    local function nakedPairs()
        changed = false
        for line = 1, n do
            for dir = 1, 2 do
                local idxs = {}
                for x = 1, n do
                    idxs[x] = dir == 1 and (line - 1) * n + x or (x - 1) * n + line
                end
                for a = 1, n - 1 do
                    local ia = idxs[a]
                    if cnt[ia] == 2 then
                        for b = a + 1, n do
                            local ib = idxs[b]
                            if cnt[ib] == 2 then
                                local same = true
                                for v = 1, n do
                                    if cand[ia][v] ~= cand[ib][v] then same = false; break end
                                end
                                if same then
                                    for x = 1, n do
                                        if x ~= a and x ~= b then
                                            for v = 1, n do
                                                if cand[ia][v] then elim(idxs[x], v) end
                                            end
                                        end
                                    end
                                    if changed then return true end
                                end
                            end
                        end
                    end
                end
            end
        end
        return false
    end

    local function cageLines()
        changed = false
        for k = 1, #cages do
            local a, cells = alive[k], cages[k].cells
            local m = #cells
            if line_dirty[k] and m >= 2 and #a > 0 then
                for dir = 1, 2 do
                    local seen = {}
                    for p = 1, m do
                        local L = cells[p][dir]
                        if not seen[L] then
                            seen[L] = true
                            for v = 1, n do
                                local all = true
                                for t = 1, #a do
                                    local tup, has = a[t], false
                                    for q = 1, m do
                                        if cells[q][dir] == L and tup[q] == v then has = true; break end
                                    end
                                    if not has then all = false; break end
                                end
                                if all then
                                    for x = 1, n do
                                        local i = dir == 1 and (L - 1) * n + x or (x - 1) * n + L
                                        if cage_at[i] ~= k then elim(i, v) end
                                    end
                                    if changed then return true end
                                end
                            end
                        end
                    end
                end
                line_dirty[k] = false
            end
        end
        return false
    end

    while not broken do
        if singles() then
            stats.singles = stats.singles + 1
        elseif cageFilter() then
            stats.cage = stats.cage + 1
        elseif allow_adv and nakedPairs() then
            stats.pairs = stats.pairs + 1
        elseif allow_adv and cageLines() then
            stats.lines = stats.lines + 1
        else
            break
        end
    end

    local grid, unresolved = {}, 0
    for r = 1, n do
        grid[r] = {}
        for c = 1, n do
            local i = (r - 1) * n + c
            if cnt[i] == 1 then
                for v = 1, n do if cand[i][v] then grid[r][c] = v; break end end
            else
                grid[r][c] = 0
                unresolved = unresolved + 1
            end
        end
    end
    stats.unresolved = broken and N or unresolved
    stats.hard = stats.pairs + stats.lines
    return (not broken) and unresolved == 0, stats, grid
end

-- ---------------------------------------------------------------------------
-- Cage generation
-- ---------------------------------------------------------------------------

local DIRS = { {-1,0},{1,0},{0,-1},{0,1} }

local function newCage(cells)
    table.sort(cells, function(a, b)
        return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
    end)
    return { cells = cells, label_cell = { cells[1][1], cells[1][2] }, op = "", target = 0 }
end

local function buildCages(n, difficulty)
    local max_sz   = MAX_CAGE[difficulty]  or 3
    local single_p = SINGLE_P[difficulty] or 0.10
    local taken = emptyGrid(n)
    local cages = {}

    for r = 1, n do
        for c = 1, n do
            if taken[r][c] == 0 then
                local cells = { {r, c} }
                taken[r][c] = 1
                local target_sz = (math.random() < single_p) and 1
                    or math.random(2, max_sz)
                while #cells < target_sz do
                    local cands = {}
                    for _, cell in ipairs(cells) do
                        for _, d in ipairs(DIRS) do
                            local nr, nc = cell[1]+d[1], cell[2]+d[2]
                            if nr>=1 and nr<=n and nc>=1 and nc<=n and taken[nr][nc] == 0 then
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
                    taken[pick[1]][pick[2]] = 1
                    cells[#cells+1] = pick
                end
                cages[#cages+1] = newCage(cells)
            end
        end
    end
    return cages
end

-- ---------------------------------------------------------------------------
-- Operation and target assignment
-- ---------------------------------------------------------------------------

local function cageValues(cage, sol)
    local vals = {}
    for i, cell in ipairs(cage.cells) do vals[i] = sol[cell[1]][cell[2]] end
    return vals
end

local function targetFor(op, vals)
    if op == "+" then
        local s = 0
        for _, v in ipairs(vals) do s = s + v end
        return s
    elseif op == SYM_MUL then
        local p = 1
        for _, v in ipairs(vals) do p = p * v end
        return p
    elseif op == "-" then
        return math.abs(vals[1] - vals[2])
    else
        return math.floor(math.max(vals[1], vals[2]) / math.min(vals[1], vals[2]))
    end
end

-- The operations that fit these values: + and × always, − and ÷ only on
-- two cells (÷ when one value divides the other).
local function validOps(vals)
    local ops = { "+", SYM_MUL }
    if #vals == 2 then
        local a, b = vals[1], vals[2]
        if a ~= b then ops[#ops+1] = "-" end
        local big, small = math.max(a, b), math.min(a, b)
        if big ~= small and big % small == 0 then ops[#ops+1] = SYM_DIV end
    end
    return ops
end

local function assignOp(cage, sol, difficulty)
    local vals = cageValues(cage, sol)
    if #vals == 1 then
        cage.op, cage.target = "", vals[1]
        return
    end
    local op
    if #vals == 2 then
        local ops = validOps(vals)
        if difficulty == "easy" then
            op = (math.random() < 0.60) and "+" or ops[math.random(#ops)]
        else
            op = ops[math.random(#ops)]
        end
    else
        op = (difficulty == "hard" and math.random() < 0.35) and SYM_MUL or "+"
    end
    cage.op, cage.target = op, targetFor(op, vals)
end

local function withOp(cage, sol, op)
    local c = newCage(cage.cells)
    c.op, c.target = op, targetFor(op, cageValues(cage, sol))
    return c
end

-- Split cell `cell` out of cages[k] as a given; the rest of the cage falls
-- into its connected pieces, each a new cage with a fresh operation.
local function splitOut(cages, k, cell, sol, difficulty)
    local rest = {}
    for _, cl in ipairs(cages[k].cells) do
        if cl[1] ~= cell[1] or cl[2] ~= cell[2] then rest[#rest+1] = cl end
    end
    local given = newCage({ { cell[1], cell[2] } })
    assignOp(given, sol, difficulty)
    cages[k] = given
    local used = {}
    for s = 1, #rest do
        if not used[s] then
            used[s] = true
            local piece, q = { rest[s] }, 1
            while q <= #piece do
                local a = piece[q]
                for t = 1, #rest do
                    local b = rest[t]
                    if not used[t] and math.abs(a[1]-b[1]) + math.abs(a[2]-b[2]) == 1 then
                        used[t] = true
                        piece[#piece+1] = b
                    end
                end
                q = q + 1
            end
            local cells = {}
            for i, cl in ipairs(piece) do cells[i] = { cl[1], cl[2] } end
            -- A lone leftover cell joins a neighbouring cage that has room
            -- rather than becoming one more given.
            local host
            if #cells == 1 then
                local max_sz = MAX_CAGE[difficulty] or 3
                local r, c = cells[1][1], cells[1][2]
                for j, cg in ipairs(cages) do
                    if j ~= k and #cg.cells >= 2 and #cg.cells < max_sz then
                        for _, cl in ipairs(cg.cells) do
                            if math.abs(cl[1]-r) + math.abs(cl[2]-c) == 1 then host = j; break end
                        end
                    end
                    if host then break end
                end
            end
            if host then
                local merged = { { cells[1][1], cells[1][2] } }
                for _, cl in ipairs(cages[host].cells) do merged[#merged+1] = { cl[1], cl[2] } end
                local nc = newCage(merged)
                assignOp(nc, sol, difficulty)
                cages[host] = nc
            else
                local nc = newCage(cells)
                assignOp(nc, sol, difficulty)
                cages[#cages+1] = nc
            end
        end
    end
end

-- Repair the cages until the logic solver (with or without the advanced
-- steps) solves the puzzle: a cage around a cell the solver cannot settle
-- first tries another operation, then loses that cell as a given. Bounded;
-- the last resort turns every unsettled cell into a given, which always
-- ends (each round adds givens). Returns the final solver stats.
local MAX_REPAIRS = 24

local function makeSolvable(n, sol, cages, difficulty, allow_adv)
    local repairs = 0
    while true do
        local ok, stats, grid = logicSolve(n, cages, allow_adv)
        if ok then return stats end
        local open = {}
        for r = 1, n do
            for c = 1, n do
                if grid[r][c] == 0 then open[#open+1] = { r, c } end
            end
        end
        repairs = repairs + 1
        if repairs > MAX_REPAIRS then
            -- last resort: every unsettled cell becomes a given
            for _, cell in ipairs(open) do
                for k, cage in ipairs(cages) do
                    local inside = false
                    for _, cl in ipairs(cage.cells) do
                        if cl[1] == cell[1] and cl[2] == cell[2] then inside = true; break end
                    end
                    if inside then
                        if #cage.cells > 1 then splitOut(cages, k, cell, sol, difficulty) end
                        break
                    end
                end
            end
        else
            local cell = open[math.random(#open)]
            local k
            for i, cage in ipairs(cages) do
                for _, cl in ipairs(cage.cells) do
                    if cl[1] == cell[1] and cl[2] == cell[2] then k = i; break end
                end
                if k then break end
            end
            local cage = cages[k]
            -- the first other operation (random order) that settles more
            local best
            for _, op in ipairs(shuffle(validOps(cageValues(cage, sol)))) do
                if op ~= cage.op then
                    local alt = withOp(cage, sol, op)
                    cages[k] = alt
                    local _, st = logicSolve(n, cages, allow_adv)
                    if st.unresolved < stats.unresolved then best = alt; break end
                end
            end
            if best then
                cages[k] = best
            else
                cages[k] = cage
                splitOut(cages, k, cell, sol, difficulty)
            end
        end
    end
end

-- How many cells are givens (one-cell cages).
local function countGivens(cages)
    local g = 0
    for _, cage in ipairs(cages) do
        if #cage.cells == 1 then g = g + 1 end
    end
    return g
end

-- ---------------------------------------------------------------------------
-- generate
-- ---------------------------------------------------------------------------
-- Every puzzle is checked by the logic solver, so it has one solution and
-- needs no guessing. Easy must solve with singles and cage combinations
-- alone; Medium and Hard may need the advanced steps, and Hard keeps the
-- candidate with the most of them (bounded attempts, no clock).

-- Hard tries a few grids for one that needs an advanced step; on 8×8 one
-- try costs most (and nearly always succeeds), so it gets fewer.
local function attemptsFor(difficulty, n)
    if difficulty ~= "hard" then return 1 end
    return n >= 8 and 2 or 4
end
-- Only Hard may need (and is meant to need) the advanced steps.
local ADVANCED = { hard = true }

function KenKenBoard:generate(difficulty, on_progress)
    self.difficulty      = difficulty or self.difficulty
    self.reveal_solution = false
    self.undo:clear()
    local n    = self.n
    local diff = self.difficulty
    local allow_adv = ADVANCED[diff] or false

    local attempts = attemptsFor(diff, n)
    tuple_cache = {}
    local best_sol, best_cages, best_score
    for attempt = 1, attempts do
        local sol   = randomLatin(n)
        local cages = buildCages(n, diff)
        for _, cage in ipairs(cages) do assignOp(cage, sol, diff) end
        local stats = makeSolvable(n, sol, cages, diff, allow_adv)
        local score = stats.hard * 4 + stats.cage - countGivens(cages) * 2
        if not best_score or score > best_score then
            best_sol, best_cages, best_score = sol, cages, score
        end
        if on_progress then on_progress(attempt / attempts) end
        -- Hard is done as soon as a puzzle needs an advanced step
        if not allow_adv or stats.hard > 0 then break end
    end

    tuple_cache = nil
    self.solution = best_sol
    self.cages    = best_cages
    self.cage_of  = emptyGrid(n)
    self.given    = emptyBoolGrid(n)
    for idx, cage in ipairs(self.cages) do
        cage.tuples = nil
        for _, cell in ipairs(cage.cells) do self.cage_of[cell[1]][cell[2]] = idx end
        if #cage.cells == 1 then self.given[cage.cells[1][1]][cage.cells[1][2]] = true end
    end

    self.user        = emptyGrid(n)
    self.wrong_marks = emptyBoolGrid(n)
    self.notes       = {}
    for r = 1, n do
        self.notes[r] = {}
        for c = 1, n do self.notes[r][c] = {} end
    end
end

-- Exposed for the specs and the audit scripts.
KenKenBoard.logicSolve    = logicSolve
KenKenBoard.cageSatisfied = cageSatisfied
KenKenBoard.randomLatin   = randomLatin

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

-- Marks the filled cells that differ from the solution -- unless the grid
-- as a whole already keeps every rule (a save from before 1.5.0 may hold a
-- puzzle with a second answer), in which case nothing is wrong.
function KenKenBoard:checkConflicts()
    local n = self.n
    local solved = self:isSolved()
    for r = 1, n do
        for c = 1, n do
            local v = self:getDisplayValue(r, c)
            self.wrong_marks[r][c] = not solved and v ~= 0 and v ~= self.solution[r][c]
        end
    end
end

-- Solved = the rules hold, not "matches the stored solution": every cell
-- filled, no digit twice in a row or column, every cage's arithmetic right.
function KenKenBoard:isSolved()
    local n = self.n
    local col_seen = {}
    for c = 1, n do col_seen[c] = {} end
    for r = 1, n do
        local row_seen = {}
        for c = 1, n do
            local v = self:getDisplayValue(r, c)
            if type(v) ~= "number" or v < 1 or v > n
                or row_seen[v] or col_seen[c][v] then
                return false
            end
            row_seen[v], col_seen[c][v] = true, true
        end
    end
    for _, cage in ipairs(self.cages) do
        local vals = {}
        for i, cell in ipairs(cage.cells) do vals[i] = self:getDisplayValue(cell[1], cell[2]) end
        if not cageSatisfied(cage, vals) then return false end
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

Hint.install(KenKenBoard, {
    getUser     = function(b, r, c) return b.user[r][c] end,
    getSolution = function(b, r, c) return b.solution[r][c] end,
    isGiven     = function(b, r, c) return b:isGiven(r, c) end,
    setCell     = function(b, r, c, v) return b:setValue(r, c, v) end,
    clearCell   = function(b, r, c) return b:clearCell(r, c) end,
})

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
