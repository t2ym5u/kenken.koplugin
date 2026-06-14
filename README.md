# kenken.koplugin

A KenKen plugin for [KOReader](https://github.com/koreader/koreader).


## Screenshot

*(Screenshot to be added.)*

## Rules

Fill the N×N grid with 1–N (no repeats in rows or columns). Cells are grouped into cages labelled with a target and an arithmetic operation (+, −, ×, ÷). The numbers in each cage must produce the target using that operation.

## Concept

KenKen combines Sudoku-style uniqueness constraints with arithmetic.
Fill the grid with digits 1–N (N = grid size) so that each digit appears
exactly once in every row and column. Within each outlined "cage", the digits
must produce the given target value using the indicated operation (+, −, ×, ÷).

## Features

- **Multiple grid sizes** — 3×3, 4×4, 5×5, 6×6, 8×8
- **Three difficulty levels** — Easy (only + and ×), Medium, Hard (all operations)
- **Operation-free mode** — only the target is shown, no operation hint
- **Note mode** — pencil in candidate digits
- **Cage highlighting** — tap a cage to highlight all its cells simultaneously
- **Check** — highlights cells violating row, column or cage constraints
- **Reveal solution** — shows the full solution
- **Undo** — step back through your moves
- **Auto-save** — game state saved and restored on next launch

## Controls

| Action | How |
|--------|-----|
| Select a cell | Tap it |
| Enter a digit | Tap the digit button |
| Erase a cell | Tap **Erase** |
| Toggle note mode | Tap **Note: Off / On** |
| Undo last move | Tap **Undo** |
| Check progress | Tap **Check** |
| New game | Tap **New game** |
| Change grid size | Tap **Grid** |
| Change difficulty | Tap **Diff** |
| Show rules | Tap **Rules** |

## Why e-ink friendly?

Like Sudoku, KenKen is a pure logic puzzle with static grid rendering and
discrete tap interactions — well-suited to e-ink refresh characteristics.

## License

GPL-3.0
