-- Difficulty guarantees for KenKen (see docs/dev/TESTING.md, "Difficulty
-- specs"), moved here from test_generator_spec.lua: every size x level has
-- one solution found by the game's own logic solver without trial (Easy and
-- Medium with singles and cage combinations only), the levels are ordered
-- on givens and advanced steps, a seed gives the same puzzle, generation
-- never reads the clock and stays within a generous time bound.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

local SIZES  = { 3, 4, 5, 6, 8 }
local LEVELS = { "easy", "medium", "hard" }
local SEEDS  = 10

-- Runs fn with os.clock/os.time/os.date counted; returns how many times
-- they were read. The play timer (game-common timer.lua, started when a new
-- round begins) is not part of the generator and is left out.
local function clockReads(fn)
    local oc, ot, od = os.clock, os.time, os.date
    local reads = 0
    local function count()
        local src = debug.getinfo(3, "S").source
        if not src:find("timer%.lua$") then reads = reads + 1 end
    end
    os.clock = function(...) count(); return oc(...) end
    os.time  = function(...) count(); return ot(...) end
    os.date  = function(...) count(); return od(...) end
    local ok, err = pcall(fn)
    os.clock, os.time, os.date = oc, ot, od
    if not ok then error(err, 0) end
    return reads
end

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
describe("KenKen difficulty", function()
    local Board

    setup(function()
        Board = require("board")
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

    it("generation never reads the clock", function()
        for _, n in ipairs(SIZES) do
            for _, d in ipairs(LEVELS) do
                local b = Board:new{ n = n, empty = true }
                local reads = clockReads(function()
                    math.randomseed(4242 + n)
                    b:generate(d)
                end)
                assert.are.equal(0, reads, ("%dx%d %s read the clock"):format(n, n, d))
            end
        end
    end)
end)
