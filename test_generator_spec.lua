-- Generator regressions (1.5.0): every puzzle has one solution and is
-- solved by pure logic (no trial), the levels really differ, a seed gives
-- the same puzzle, solving is judged by the rules, and old saves -- whose
-- puzzle may have had a second answer -- still load and can be finished.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

local MUL = "\195\151"
local SIZES  = { 3, 4, 5, 6, 8 }
local LEVELS = { "easy", "medium", "hard" }
local SEEDS  = 10

-- Independent of the board's solver: plain backtracking, counts up to `limit`.
local function countSolutions(b, limit)
    local n = b.n
    local g = {}
    for r = 1, n do g[r] = {} for c = 1, n do g[r][c] = 0 end end
    local filled = {}
    for k = 1, #b.cages do filled[k] = 0 end
    local found = 0
    local function rec(i)
        if found >= limit then return end
        if i > n * n then found = found + 1; return end
        local r, c = math.floor((i - 1) / n) + 1, (i - 1) % n + 1
        local k = b.cage_of[r][c]
        for v = 1, n do
            local ok = true
            for x = 1, n do
                if (x < c and g[r][x] == v) or (x < r and g[x][c] == v) then ok = false; break end
            end
            if ok then
                g[r][c] = v
                filled[k] = filled[k] + 1
                local pass = true
                if filled[k] == #b.cages[k].cells then
                    local vals = {}
                    for j, cl in ipairs(b.cages[k].cells) do vals[j] = g[cl[1]][cl[2]] end
                    pass = b.cageSatisfied(b.cages[k], vals)
                end
                if pass then rec(i + 1) end
                filled[k] = filled[k] - 1
                g[r][c] = 0
            end
        end
    end
    rec(1)
    return found
end

local function givens(b)
    local g = 0
    for r = 1, b.n do for c = 1, b.n do if b.given[r][c] then g = g + 1 end end end
    return g
end

-- A 4×4 Hard save from 1.4.x (seed 3001): its cages allow a second answer.
local function oldSave()
    local cages = {
        { cells = { {1,1},{1,2},{2,1},{2,2} }, label_cell = {1,1}, op = "+",  target = 10 },
        { cells = { {1,3},{1,4},{2,3},{2,4} }, label_cell = {1,3}, op = MUL,  target = 24 },
        { cells = { {3,1},{3,2} },             label_cell = {3,1}, op = MUL,  target = 6 },
        { cells = { {3,3},{4,3} },             label_cell = {3,3}, op = "+",  target = 7 },
        { cells = { {3,4},{4,4} },             label_cell = {3,4}, op = "-",  target = 1 },
        { cells = { {4,1},{4,2} },             label_cell = {4,1}, op = MUL,  target = 4 },
    }
    local cage_of = {}
    for r = 1, 4 do cage_of[r] = {} end
    for k, cg in ipairs(cages) do
        for _, cl in ipairs(cg.cells) do cage_of[cl[1]][cl[2]] = k end
    end
    local zeros, falses = {}, {}
    for r = 1, 4 do zeros[r] = { 0, 0, 0, 0 }; falses[r] = { false, false, false, false } end
    return {
        n = 4, difficulty = "hard",
        solution = { {1,4,2,3}, {3,2,1,4}, {2,3,4,1}, {4,1,3,2} },
        given = falses, user = zeros, notes = {}, cage_of = cage_of,
        cages = cages, wrong_marks = falses, reveal_solution = false,
    }
end
local OLD_ALT = { {1,3,2,4}, {2,4,1,3}, {3,2,4,1}, {4,1,3,2} }

describe("KenKen generator", function()
    local Board

    setup(function()
        Board = require("board")
    end)

    it("builds varied Latin squares, not only permuted cyclic ones", function()
        -- Valid every time, and (almost) never the same square twice.
        local seen = {}
        local distinct = 0
        for s = 1, 40 do
            math.randomseed(s)
            local g = Board.randomLatin(5)
            for i = 1, 5 do
                local rs, cs = {}, {}
                for j = 1, 5 do
                    assert.is_nil(rs[g[i][j]]); rs[g[i][j]] = true
                    assert.is_nil(cs[g[j][i]]); cs[g[j][i]] = true
                end
            end
            local key = {}
            for i = 1, 5 do key[i] = table.concat(g[i]) end
            key = table.concat(key, "/")
            if not seen[key] then seen[key] = true; distinct = distinct + 1 end
        end
        assert.is_true(distinct >= 35)
    end)

    for _, n in ipairs(SIZES) do
        for _, d in ipairs(LEVELS) do
            it(("%dx%d %s: one solution, found by logic alone"):format(n, n, d), function()
                local b = Board:new{ n = n, empty = true }
                for s = 1, SEEDS do
                    math.randomseed(7000 + s)
                    b:generate(d)
                    -- Easy and Medium: singles and cage combinations only.
                    local ok, stats, grid = Board.logicSolve(n, b.cages, d == "hard")
                    assert.is_true(ok, ("seed %d not solved by logic"):format(7000 + s))
                    if d ~= "hard" then assert.are.equal(0, stats.hard) end
                    for r = 1, n do
                        for c = 1, n do
                            assert.are.equal(b.solution[r][c], grid[r][c])
                        end
                    end
                    -- cross-check uniqueness with plain backtracking
                    if n <= 5 then
                        assert.are.equal(1, countSolutions(b, 2), ("seed %d"):format(7000 + s))
                    end
                    -- givens are the one-cell cages, and nothing else
                    for _, cg in ipairs(b.cages) do
                        for _, cl in ipairs(cg.cells) do
                            assert.are.equal(#cg.cells == 1, b.given[cl[1]][cl[2]])
                            assert.is_true(b.cage_of[cl[1]][cl[2]] > 0)
                        end
                    end
                end
            end)
        end
    end

    it("levels are distinct: fewer givens and harder steps as the level rises", function()
        for _, n in ipairs({ 5, 6, 8 }) do
            local g, adv = {}, {}
            for _, d in ipairs(LEVELS) do
                g[d], adv[d] = 0, 0
                local b = Board:new{ n = n, empty = true }
                for s = 1, SEEDS do
                    math.randomseed(8000 + s)
                    b:generate(d)
                    g[d] = g[d] + givens(b)
                    local _, stats = Board.logicSolve(n, b.cages, true)
                    adv[d] = adv[d] + stats.hard
                end
            end
            assert.is_true(g.easy > g.medium and g.medium > g.hard,
                ("%d: givens %d/%d/%d"):format(n, g.easy, g.medium, g.hard))
            assert.are.equal(0, adv.easy)
            assert.is_true(adv.hard > adv.medium, ("%d: advanced steps %d/%d"):format(n, adv.medium, adv.hard))
        end
    end)

    it("the same seed gives the same puzzle", function()
        for _, d in ipairs(LEVELS) do
            local a = Board:new{ n = 6, empty = true }
            local b = Board:new{ n = 6, empty = true }
            math.randomseed(1234); a:generate(d)
            math.randomseed(1234); b:generate(d)
            assert.are.same(a.solution, b.solution)
            assert.are.equal(#a.cages, #b.cages)
            for k, cg in ipairs(a.cages) do
                assert.are.same(cg.cells, b.cages[k].cells)
                assert.are.equal(cg.op, b.cages[k].op)
                assert.are.equal(cg.target, b.cages[k].target)
            end
        end
    end)

    it("generates within a generous time bound", function()
        local b = Board:new{ n = 8, empty = true }
        local worst = 0
        for s = 1, 5 do
            math.randomseed(9000 + s)
            local t = os.clock()
            b:generate("hard")
            worst = math.max(worst, os.clock() - t)
        end
        assert.is_true(worst < 2, ("8x8 hard took %.2f s"):format(worst))
    end)
end)

describe("KenKen solving by the rules", function()
    local Board

    setup(function()
        Board = require("board")
    end)

    it("an old save with a second answer loads and accepts that answer", function()
        local b = Board:new{ n = 4, empty = true }
        assert.is_true(b:load(oldSave()))
        assert.is_false(b:isSolved())
        for r = 1, 4 do for c = 1, 4 do b.user[r][c] = OLD_ALT[r][c] end end
        assert.is_true(b:isSolved())
        b:checkConflicts()
        for r = 1, 4 do for c = 1, 4 do assert.is_false(b.wrong_marks[r][c]) end end
        -- the stored answer is accepted too
        for r = 1, 4 do for c = 1, 4 do b.user[r][c] = b.solution[r][c] end end
        assert.is_true(b:isSolved())
    end)

    it("rejects a Latin square that breaks a cage", function()
        local b = Board:new{ n = 4, empty = true }
        assert.is_true(b:load(oldSave()))
        -- a valid Latin square, but 1+2+... breaks the 10+ cage
        local g = { {1,2,3,4}, {2,1,4,3}, {3,4,1,2}, {4,3,2,1} }
        for r = 1, 4 do for c = 1, 4 do b.user[r][c] = g[r][c] end end
        assert.is_false(b:isSolved())
    end)

    it("rejects a repeated digit in a row even when cages add up", function()
        local b = Board:new{ n = 4, empty = true }
        assert.is_true(b:load(oldSave()))
        for r = 1, 4 do for c = 1, 4 do b.user[r][c] = OLD_ALT[r][c] end end
        b.user[4][1], b.user[4][2] = 2, 2   -- 4× still holds, row 4 does not
        assert.is_false(b:isSolved())
    end)

    it("a new puzzle round-trips through serialize/load and solves", function()
        math.randomseed(31)
        local b = Board:new{ n = 6, empty = true }
        b:generate("hard")
        local data = b:serialize()
        assert.is_nil(data.cages[1].tuples)
        local b2 = Board:new{ n = 6, empty = true }
        assert.is_true(b2:load(data))
        assert.are.same(b.solution, b2.solution)
        assert.are.same(b.cage_of, b2.cage_of)
        local ok = Board.logicSolve(6, b2.cages, true)
        assert.is_true(ok)
        for r = 1, 6 do for c = 1, 6 do
            if not b2:isGiven(r, c) then b2.user[r][c] = b2.solution[r][c] end
        end end
        assert.is_true(b2:isSolved())
    end)
end)
