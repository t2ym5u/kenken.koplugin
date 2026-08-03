local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("KenKenBoard", function()
    local Board

    setup(function()
        Board = require("board")
    end)


    local function newBoard(n)
        math.randomseed(42)
        return Board:new({ n = n or 6 })
    end

    describe("construction", function()
        it("creates an n×n grid", function()
            local b = newBoard(6)
            assert.are.equal(6, b.n)
        end)

        it("cages cover every cell exactly once", function()
            local b = newBoard(6)
            local n = b.n
            local count = 0
            for _, cage in ipairs(b.cages) do
                count = count + #cage.cells
            end
            assert.are.equal(n * n, count)
        end)

        it("solution is a valid latin square", function()
            local b = newBoard(6)
            local n = b.n
            for r = 1, n do
                local seen = {}
                for c = 1, n do
                    local v = b.solution[r][c]
                    assert.is_nil(seen[v], "row " .. r .. " duplicate " .. v)
                    seen[v] = true
                end
            end
            for c = 1, n do
                local seen = {}
                for r = 1, n do
                    local v = b.solution[r][c]
                    assert.is_nil(seen[v], "col " .. c .. " duplicate " .. v)
                    seen[v] = true
                end
            end
        end)

        it("each cage has a valid target and op", function()
            local b = newBoard(6)
            for _, cage in ipairs(b.cages) do
                assert.is_true(cage.target > 0, "cage target must be positive")
                assert.is_string(cage.op)
            end
        end)
    end)

    describe("isGiven", function()
        it("single-cell cages are marked as given", function()
            local b = newBoard(6)
            local n = b.n
            for _, cage in ipairs(b.cages) do
                if #cage.cells == 1 then
                    local r, c = cage.cells[1][1], cage.cells[1][2]
                    assert.is_true(b:isGiven(r, c))
                    return
                end
            end
        end)

        it("multi-cell cage cells are not given", function()
            local b = newBoard(6)
            for _, cage in ipairs(b.cages) do
                if #cage.cells > 1 then
                    for _, cell in ipairs(cage.cells) do
                        assert.is_false(b:isGiven(cell[1], cell[2]))
                    end
                    return
                end
            end
        end)
    end)

    describe("getCageLabel", function()
        it("single-cell cage label is just the number", function()
            local b = newBoard(6)
            for _, cage in ipairs(b.cages) do
                if #cage.cells == 1 then
                    local label = b:getCageLabel(cage)
                    assert.are.equal(tostring(cage.target), label)
                    return
                end
            end
        end)

        it("multi-cell cage label ends with an operator", function()
            local b = newBoard(6)
            for _, cage in ipairs(b.cages) do
                if #cage.cells > 1 then
                    local label = b:getCageLabel(cage)
                    assert.is_true(#label > 1, "label should have operator suffix")
                    return
                end
            end
        end)
    end)

    describe("setValue / clearCell", function()
        local function firstFreeCell(b)
            local n = b.n
            for r = 1, n do
                for c = 1, n do
                    if not b:isGiven(r, c) then return r, c end
                end
            end
        end

        it("setValue writes to a free cell", function()
            local b = newBoard(6)
            local r, c = firstFreeCell(b)
            local ok = b:setValue(r, c, 3)
            assert.is_true(ok)
            assert.are.equal(3, b.user[r][c])
        end)

        it("setValue rejects given cells", function()
            local b = newBoard(6)
            local n = b.n
            for r = 1, n do
                for c = 1, n do
                    if b:isGiven(r, c) then
                        local ok, reason = b:setValue(r, c, 1)
                        assert.is_false(ok)
                        assert.are.equal("given", reason)
                        return
                    end
                end
            end
        end)

        it("clearCell zeroes a free cell", function()
            local b = newBoard(6)
            local r, c = firstFreeCell(b)
            b:setValue(r, c, 4)
            local ok = b:clearCell(r, c)
            assert.is_true(ok)
            assert.are.equal(0, b.user[r][c])
        end)
    end)

    describe("undo", function()
        it("canUndo is false on a fresh board", function()
            local b = newBoard(6)
            assert.is_false(b:canUndo())
        end)

        it("restores value after setValue", function()
            local b = newBoard(6)
            local r, c
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if not b:isGiven(rr, cc) then r, c = rr, cc; goto done end
                end
            end
            ::done::
            b:setValue(r, c, 2)
            Board.undo(b)  -- b.undo field (UndoStack) shadows the :undo() method
            assert.are.equal(0, b.user[r][c])
        end)
    end)

    describe("isSolved", function()
        it("returns false for a fresh board", function()
            local b = newBoard(6)
            assert.is_false(b:isSolved())
        end)

        it("returns true when all cells match the solution", function()
            local b = newBoard(6)
            local n = b.n
            for r = 1, n do
                for c = 1, n do
                    if not b:isGiven(r, c) then
                        b.user[r][c] = b.solution[r][c]
                    end
                end
            end
            assert.is_true(b:isSolved())
        end)
    end)

    describe("serialize / load", function()
        it("round-trips board state", function()
            local b = newBoard(6)
            local n = b.n
            -- Write a value into the first free cell
            for r = 1, n do
                for c = 1, n do
                    if not b:isGiven(r, c) then
                        b:setValue(r, c, 1)
                        goto done
                    end
                end
            end
            ::done::
            local data = b:serialize()

            local b2 = Board:new({ n = n })
            local ok = b2:load(data)
            assert.is_true(ok)
            assert.are.equal(b.n, b2.n)
            assert.are.equal(#b.cages, #b2.cages)
            for r = 1, n do
                for c = 1, n do
                    assert.are.equal(b.solution[r][c], b2.solution[r][c])
                    assert.are.equal(b.user[r][c],     b2.user[r][c])
                end
            end
        end)

        it("load returns false for invalid data", function()
            local b = newBoard(6)
            assert.is_false(b:load(nil))
            assert.is_false(b:load({}))
        end)
    end)
end)
