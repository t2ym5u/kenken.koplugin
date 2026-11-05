# Changelog

All notable changes to this project will be documented in this file.

## [1.5.0] - 2026-11-05

### Fixed
- Every puzzle now has exactly one solution. Before, many grids (about half
  of the Hard ones) also allowed another answer, which the game then
  refused. Each new puzzle is now checked by a logic solver that never
  guesses, so it can always be solved by reasoning alone.
- A grid that keeps every rule (rows, columns and all cages) now counts as
  solved even if it differs from the stored answer, so a game saved with an
  older version can still be finished with its other answer.

### Changed
- The difficulty levels are now measured, not just set by cage size:
  Easy and Medium are solved with simple deductions only (one place left,
  cage combinations), Medium with bigger cages and fewer givens; Hard has
  the fewest givens and usually needs pairs or "this cage puts that digit
  in this row" deductions.
- More varied grids: the digits behind a puzzle are no longer always a
  shifted pattern.
- A progress bar appears if building a puzzle takes a moment.
- Today's Daily Challenge grid changes once, as puzzles are now built
  differently.

## [1.4.5] - 2026-11-04

### Fixed
- A game no longer crashes when an outdated plugin is installed alongside:
  shared modules left behind by an older plugin are replaced by this
  plugin's own copy instead of being used as they are.

## [1.4.4] - 2026-11-04

### Changed
- Uses less memory: the game loads when you open it, not when KOReader
  starts, so it no longer takes memory or startup time while unplayed.

## [1.4.3] - 2026-11-03

### Changed
- Picks up game-common 1.11.0: the shared on-screen keyboard (where used)
  gives every key the same letter size, and the no-repeat history helper.

## [1.4.2] - 2026-11-02

### Changed
- Picks up game-common 1.10.0: the shared Tools → Games menu also lists
  the games' new "· multiplayer" entries under Party & quiz.

## [1.4.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

## [1.4.0] - 2026-10-30

### Added
- "Daily Challenge" in the menu, right after "New game": today's puzzle at
  your size and difficulty, the same grid for everyone playing it today.
  Needs game-common 1.7.0.

## [1.3.0] - 2026-10-30

### Added
- "New game" once the puzzle is solved: the action bar shows it in place of
  the game's buttons, so the next puzzle no longer needs the menu. Showing
  the solution does not end the round, since it can be hidden again.
- The rules now explain how to play: tap a cell, then a digit.

### Changed
- Redesigned play screen, in line with the other games: a full-width action
  bar (on two rows in landscape, where five buttons don't fit one), the
  unified number pad, a larger board that fills the available room, and one
  frame around it. The status line reads "size · difficulty · Empty: n ·
  Cage: …" and wraps in landscape instead of being cut off.
- Title-bar menu in the same order as every other game, with the current
  values shown: "Size: …" (was "Grid: …"), "Difficulty: …" (was "Diff:
  …"), and "Show solution" / "Hide solution" (was "Show result" / "Hide
  result").
- New README screenshot.

### Fixed
- Tapping Undo crashed the game ("attempt to call method 'undo'").
- Using Hint wiped the saved game: the board was saved as nothing. And when
  a hint fills the last cell, the status now shows the win message.
- Digits overflowed their cells and cage labels came out nearly twice too
  big on high-DPI screens. Labels are now sized to the cell, and a digit in
  a cage's labelled cell gets a smaller face that fits under the label
  instead of colliding with it; notes in that cell start below the label
  too.

## [1.2.2] - 2026-10-07

### Fixed
- The Tools menu entry is translated again. `main.lua` took `_` from
  KOReader's `gettext`, which knows nothing of this plugin's strings, so the
  menu label stayed English while the game's own screen, which goes through
  `i18n`, was translated. `_` now comes from `i18n` here too.


## [1.2.1] - 2026-10-01

### Fixed
- Picks up game-common v1.5.0. Play statistics were recorded under a key no
  tool could match: `ReaderUI`/`FileManager:registerModule()` rewrite a plugin
  instance's `name` to `reader<id>` / `filemanager<id>` right after it is
  built, so this game's sessions were split across two rows and neither
  carried its plugin id. Rows written under the old keys are merged back on
  first read. The same release brings the `stopPlugin()` /
  `deletePluginSettings()` hooks KOReader 2026.07 calls when a plugin is
  deleted from the device (PR #15240).

  No change to this plugin's own code -- it inherits all of it from the
  shared library.

## [1.2.0] - 2026-09-30

### Added
- **Hint** button. Two taps, not one: the first says which cell is about to
  give, the second acts on it -- a player who is told where to look usually
  finds the rest themselves, and only pays for the full reveal if they want
  it. A cell that contradicts the solution is always reported before a fresh
  one is revealed, and on a mistake the hint empties the cell rather than
  solving it.
