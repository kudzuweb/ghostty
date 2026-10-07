# Mauria's Ghostty fork

This file lists everything in this fork that differs from stock Ghostty, how to use each difference, and how to maintain the fork. Every change that adds, removes or alters a deviation, setting, theme, build step or gotcha updates this file in the same commit. Facts were checked against the code and git history on 2026-10-07 unless marked unverified.

## What this fork is

The fork is `kudzuweb/ghostty` on GitHub, a public fork of `ghostty-org/ghostty`. Locally `origin` is the fork and `upstream` is Ghostty's repository. `main` is Mauria's build. It follows Ghostty's releases, not upstream's development branch, and today it is based on the tag `v1.3.1`. Work happens on topic branches that merge into `main`. Only the macOS app has been changed or tested; the Linux GTK app is untouched and unused.

## Install and update

| Step | What to do |
|---|---|
| Toolchain | Install Zig 0.15.2 at `~/.local/opt/zig-aarch64-macos-0.15.2`, linked from `~/.local/bin/zig`, and Xcode 26 with the iOS SDK and the Metal toolchain. |
| Core library, after any change outside `macos/` | Run `zig build -Demit-macos-app=false` from the repo root. |
| Debug app | Run `env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -project macos/Ghostty.xcodeproj -scheme Ghostty -configuration Debug SYMROOT="$PWD/macos/build" build`. This replaces `macos/build.nu`, because Nushell is not installed. The output is `macos/build/Debug/Ghostty.app` with bundle id `com.mitchellh.ghostty.debug`, which keeps its own preferences and saved window state. |
| Daily app | Run `zig build -Doptimize=ReleaseFast`, then replace `/Applications/Ghostty.app` with `zig-out/Ghostty.app`. Replacing it closes the open tabs, and they come back resumed. |
| Work machine or any other Mac | Clone the fork, build the daily app as above, then copy `fork/config.ghostty` to `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty` and the files in `fork/themes/` to `~/.config/ghostty/themes/`. |
| Lint Swift | Run `swiftlint lint --strict` in `macos/`. |

The built-in updater is off, because `SUEnableAutomaticChecks` is `false` in `macos/Ghostty-Info.plist` (this is upstream's value at `v1.3.1`, not a fork change). That matters because a stock Ghostty update would replace the fork's changes. The app reports version `0.1` because `MARKETING_VERSION` is `0.1` in `macos/Ghostty.xcodeproj/project.pbxproj`; this is cosmetic for source builds.

## Deviations in the code

Each row is a commit on `main` after `v1.3.1`, listed with its hash. Find the full set with `git log --oneline v1.3.1..main`.

### AppleScript additions

| Addition | How to use it |
|---|---|
| The `tab color` property on a tab (`7452aee75`) | Read or set it with one of ten values: `no color`, `blue`, `purple`, `pink`, `red`, `orange`, `yellow`, `green`, `teal` or `graphite`. It is the same setter the tab's context menu uses, so the color redraws and persists with window state. |
| The `group name` and `group color` properties on a tab (`447a1e979`) | `group name` reads or sets the tab's sidebar group, and `group color` reads or sets the color shared by every tab in that group. `group color` is ignored for a tab that is in no group. |
| The `pid` and `tty` properties on a terminal (`452171c48`) | Both are read-only: `pid` is the foreground process id and `tty` is the terminal's device path. They also appear on the App Intents terminal entity. |

### Vertical tab sidebar and tab groups

| Feature | How it works |
|---|---|
| Vertical tab sidebar (`f64c71e7d` through `3662e40eb`, then `5739a5365`) | The sidebar was cherry-picked from upstream pull request 14562, which is open and unreviewed upstream, and adapted to `v1.3.1` with conflict fixes. Mauria does not track that pull request. Turn it on with `macos-titlebar-style = vertical-tabs`. The same range adds a collapsed mode that lists numbered tiles, and the native tab context menu on sidebar tabs. |
| Config key history (`3b3919477`, `5739a5365`) | The pull request's separate `macos-vertical-tabs` key was replaced by the `vertical-tabs` value of `macos-titlebar-style`, so only the latter exists now. |
| Tab groups (`447a1e979`) | A tab belongs to a named group, shown as one tinted, collapsible, flat block with a header. Right-click a tab for Move to Group or New Group, and right-click a group header to rename, recolor or ungroup it. Membership is saved with window state and in close-tab undo. Each group's color and collapsed state are stored per group name in `UserDefaults` (`TerminalTabGroupColors` and `TerminalTabGroupsCollapsed`). A tab opened beside a grouped tab joins that group, and joining a group moves the tab next to the group's other tabs. |
| Flat, square sidebar (`447a1e979`) | The same commit restyled the whole sidebar from the pull request: full-width square rows, hairline separators and a solid highlight for the selected tab in place of the glass capsule. This was Mauria's choice. |
| Theme-colored sidebar (`3a96d5c16`) | Group colors and tab dots take the active theme's 16 ANSI colors, so the sidebar changes with the theme. Orange mixes the theme's red and yellow because palettes have no orange. Without a palette the colors fall back to system colors. |

### Session resume

The change is `93ca93c65`, in `macos/Sources/Features/Terminal/AgentSessionResume.swift`.

| Part | Detail |
|---|---|
| What it does | When window state is saved, each terminal records the command that resumes the Claude Code or Codex session in its foreground. When the window is restored, that command is typed into the terminal's shell. Quitting marks every terminal window's state as changed so the saved state is current. |
| Where the session id comes from | For Claude Code it is `sessionId` in `~/.claude/sessions/<pid>.json`. For Codex it is the id at the end of the `rollout-<timestamp>-<uuid>.jsonl` file the process holds open under `~/.codex/sessions/`. |
| Failure mode | Both sources are undocumented files of those tools. When either changes, nothing is found and the terminal restores as a plain shell. |
| Required setting | `window-save-state = always` must be set. The default follows the macOS "close windows when quitting" setting, which is on for Mauria, so a normal quit would save nothing. |

### Sleep guard

The change is `04dc7d039` plus `122dbdc44`, in `macos/Sources/Features/SleepGuard/SleepGuard.swift`. It ports Mauria's retired NoDoz app.

| Part | Detail |
|---|---|
| The control | A button in the sidebar header shows whether the Mac may sleep with the lid closed, by reading `pmset -g` for the `disablesleep` flag. Its menu has the current state, a manual toggle and a Mode submenu. |
| Manual and Auto modes | The mode is stored in `UserDefaults` as `SleepGuardMode`. Manual leaves the flag to the toggle. Auto blocks sleep while any terminal has a foreground program that is not an idle shell, or any process named `claude` or `codex` on a terminal's TTY, and allows sleep after a grace period. |
| Grace period | It defaults to 120 seconds and is read from `UserDefaults` as `SleepGuardGraceSeconds`. |
| Failed flips | A floating Sleep Guard panel states the error. It closes itself after 30 seconds and is reused rather than stacked. Auto retries after 30 seconds. |
| Quitting | Quitting Ghostty in Auto mode undoes a block that Auto set, so a forgotten block does not drain a laptop in a bag. |
| Requirement | An existing `NOPASSWD` sudoers rule must allow exactly `/usr/bin/pmset -a disablesleep 1` and `/usr/bin/pmset -a disablesleep 0`. Without it Auto fails every retry and the panel appears. The rule is outside this repo; on `home-laptop` it was confirmed with `sudo -n -l` on 2026-10-07. |
| Menu bar icon | The icon is switched off. The code that creates the menu bar status item is commented out in `SleepGuard.swift`, with a note, so it can be restored by uncommenting it. |
| NoDoz leftovers | NoDoz's unported code (commented out) and its icon are in `macos/Sources/Features/SleepGuard/NoDoz/`. |

### Backports from upstream

These came in so the foreground process id and tty could exist. Each is in upstream's development branch and will arrive in a later release, where a merge may show them as already applied.

| Backport | Detail |
|---|---|
| Foreground pid and tty name in the C API and core (`eb8b7dcd3`, `a67002713`) | The core surface can report the foreground process id and the pty name. Both return null when the platform cannot supply them. |
| Process-info macro fixes (`9a3ffd27a`, `328bfe9a6`) | These fix C macro comparisons and simplify the macro use in `src/pty.zig`. |
| Build fix (`80362ef21`) | `src/build/SharedDeps.zig` translates `pty.c` only for platforms that have PTYs, because the backported version also translated it for the iOS library and failed. Upstream later restored the same per-OS switch. |

## Mauria's config and themes

The live config is `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`. A copy is `fork/config.ghostty`; update the copy whenever the live file changes.

| Line | What it does and why |
|---|---|
| `macos-titlebar-style = vertical-tabs` | Turns on the vertical tab sidebar. |
| `theme = Nu Disco` | Selects the custom theme below. A `background`, `foreground` or `palette` line in the config would override any theme, so the config has none. |
| `working-directory = ~/Documents/Projects` | The first window opens in the projects folder. It applies to the first window only, and new tabs inherit the current tab's folder. |
| `window-save-state = always` | Restores windows after a normal quit, which session resume depends on. |

Custom themes live in `~/.config/ghostty/themes/`, and copies are in `fork/themes/`. Install them on another machine by copying those files to that folder.

| Theme | Detail |
|---|---|
| `Black` | Black background with white text, matching Mauria's Warp setup. |
| `Nu Disco` | Adapted from the MIT-licensed VS Code theme by dbanksdesign (`dbanksdesign/nu-disco-vscode-theme`). Translucent colors are flattened onto the background because Ghostty palettes have no alpha, and the normal and bright ANSI sets are swapped so terminal output matches the editor's look. |
| `Solarized Dark Higher Contrast` | This is a built-in theme, not a file in the fork, and it is Mauria's Solarized option. |

## Integrations elsewhere

| Integration | Detail |
|---|---|
| Handoff launcher, `skills/handoff/launch.sh` in `claudemonorepo` | Opens a new Claude session in a Ghostty tab through AppleScript and pins the tab title with `perform action "set_tab_title:<name>"`. |
| Quipu keeper launcher, `my-quipu/.claude/launch-keeper.sh` | Does the same for the resident quipu keeper session. |
| Smithy Ghostty module, `skills/smithy/references/ghostty/guide.md` in `claudemonorepo` | Holds the design and evaluation guidance for changing Ghostty, and points here for facts. |

Both launchers address `/Applications/Ghostty.app` by absolute path.

## Maintenance

### Upgrading from upstream

1. Fetch tags with `git fetch upstream --tags`.
2. On a topic branch from `main`, merge the new release tag, for example `git merge v1.4.0`. Sessions may resolve the conflicts.
3. Build the core library and the debug app, run `swiftlint lint --strict` in `macos/`, and launch the debug build.
4. Merge the topic branch into `main`, rebuild the daily app, and update the base version named in "What this fork is" and, once it exists, the recorded base version for the release check.

### Conflict hot spots

| File | Why it conflicts |
|---|---|
| `macos/Sources/Features/Terminal/TerminalTabSidebar.swift` | The sidebar came from an unmerged upstream pull request and was restyled and extended with groups, theme colors and the sleep guard button. This is the main hot spot. |
| `include/ghostty.h` | Upstream renamed every C API declaration with a `GHOSTTY_API` prefix after 1.3, so backports touching it conflict. Keep the release's style and add the new declarations. |
| `src/pty.zig`, `src/build/SharedDeps.zig` and `src/termio/` | These hold the backported process-info code and may already be applied upstream. |
| `macos/Ghostty.sdef` | The fork adds properties here, and `macos/AGENTS.md` fixes the order of top-level definitions: classes, records, enums, commands. |

### Gotchas

| Gotcha | What to do |
|---|---|
| A test Ghostty launched from inside a Claude Code session inherits the `CLAUDE*` environment variables, and a `claude` started in it never registers its session. | Strip every `CLAUDE*` variable when launching a test build. |
| An interrupted `zig build` leaves `macos/GhosttyKit.xcframework`, which breaks the next build with code 70. | Delete that folder and rebuild. |
| The clone is a blob-less partial clone, and a stale commit graph broke history searches. | Delete `.git/objects/info/commit-graph*`. |
| AppleScript `input text` pastes without running the line. | Follow it with `send key "enter"`, or use a surface configuration's `initial input`. |
| The live app and a debug build both have the process name `ghostty`. | Address a debug build by its absolute path in AppleScript, and never touch a process you did not start. |

## Planned work

These are Mauria's decisions and none is built yet.

| Item | Decision |
|---|---|
| Settings panel | A gear in the sidebar header opens a panel that edits the same `config.ghostty` file, with conflicts handled as they arise. The fork's settings become real Ghostty config keys. It includes a theme picker that writes `theme =`. Agents can edit the same file. |
| Keep alive | It replaces the watchdog daemon at `scripts/watchdog` in `claudemonorepo`, and each tab has a right-click toggle. A crashed session is relaunched with `--resume` in the same tab, at most 3 crashes in any 60 minutes, then the tab is marked "gave up". On a session-limit `rate_limit` error it nudges "continue" just after the reset time printed in the message, otherwise every 15 minutes. Out of credits notifies and checks every 15 minutes. `server_error` nudges every 5 minutes. `authentication_failed`, `model_not_found` and other errors are not retried and only notify. Background sessions are watched through `claude agents --json --all` and restarted with `claude respawn <id>`. A launchd job relaunches Ghostty if it crashes. |
| Keep alive events | Events go to an events file. A Claude Code Mod in each session submits events about that session's own workers as prompts, through `$.prompt.submit` and gated on the session being idle, as the likethis Mod does, so an orchestrator can handle them unattended. Ghostty also shows a macOS notification unless the overnight switch is on. |
| Usage cutoff | Ported from the watchdog. It rebuilds 5-hour usage windows from transcript timestamps and winds work down so the workday starts in a window that is at most about half used and resets within 2 hours. The constants (workday start 10:00, usable 2 hours, margin 15 minutes, warning 25 minutes) become settings. |
| Overnight switch | Until the workday start it turns on keep alive and the usage cutoff for every tab running an agent and sets the sleep guard to Auto. It turns itself off in the morning. |
| Weekly release check | It checks GitHub releases of `ghostty-org/ghostty` and reports only minor releases such as 1.4.0, not patches. It shows a notice that reuses Ghostty's update pill (`macos/Sources/Features/Update/UpdatePill.swift`) and a macOS notification, both linking to the release. It compares against the fork's recorded base version, which is `v1.3.1` today and is updated on each upstream merge. |
| Retire the watchdog | Archive the script in git history, then remove it. |
