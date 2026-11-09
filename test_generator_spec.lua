-- Generator regressions (1.5.0): varied Latin squares, solving is judged by
-- the rules, and old saves -- whose puzzle may have had a second answer --
-- still load and can be finished. The difficulty guarantees (uniqueness,
-- no trial, ordered levels, determinism) live in test_difficulty_spec.lua.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

local MUL = "\195\151"

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
