<div align="center">

# O

**A native macOS disk cleaner that never deletes — everything goes to the Trash.**

[English](README.md) · [简体中文](README.zh-CN.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-black.svg)](#)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](#)
[![Tests](https://img.shields.io/badge/tests-78%20XCTest%20%C2%B7%20204%20SelfTest-brightgreen.svg)](#build--test)

</div>

---

O is a disk cleanup and system utility for macOS, built with SwiftUI. It shows what is eating your disk, finds what can be safely freed, and **only ever moves files to the Trash** — no permanent deletion, no shell commands, no silent privilege escalation.

| Home (light) | Home (dark) |
| --- | --- |
| ![Home light](Docs/01-home-light.png) | ![Home dark](Docs/01-home-dark.png) |

| Cleanup | Rules |
| --- | --- |
| ![Cleanup](Docs/02-clean-light.png) | ![Rules](Docs/09-rules-light.png) |

## Features

- **Top-bar navigation** — six pages (Home · Clean · Space · Apps · System · Rules) in a compact 46 pt bar with ⌘1–⌘6 shortcuts; never wraps at the 860×600 minimum window.
- **Home dashboard** — chip, cores, memory, GPU, display resolution and scale, last four digits of the serial number; macOS build, uptime, boot volume, battery health and cycle count, thermal pressure, local network interfaces and IP. Live charts (CPU sparkline, segmented memory meter, disk usage ring, network rates) sampled every 2 s, throttled to 10 s when the window is hidden. Every value comes from real system APIs (sysctl / IOKit / Metal / getifaddrs) — unreadable data is shown as *unavailable* with a reason, never faked.
- **Rule-driven cleanup** — scans follow user-editable rules, not hardcoded categories. 14 source categories: user caches, app logs, Xcode derived data, Trash, app leftovers (Application Support / Containers / Group Containers / Saved Application State / HTTPStorages), diagnostic reports, developer artifacts, package manager caches (npm / yarn / pnpm / pip / Homebrew / Go / Cargo / Gradle / Maven / CocoaPods), Docker, iOS backups, mail attachments, personal large files, system caches.
- **Rules page** — three presets (Conservative 5 / Standard 26 / Aggressive 33), full CRUD per rule, protected path list, per-rule estimated reclaimable space and hit counts back-filled after a real scan. Caution-grade rules require explicit confirmation.
- **First-launch onboarding** — four steps: why permissions are needed, current real probe status, how to grant, and how the rule engine works. Can be skipped and reopened from System › Permissions.
- **Menu bar companion** — template icon (system-tinted), compact panel with disk / CPU / memory / network / battery, synced scan state.
- **M2 design system** — warm paper `#F5F4ED` / warm black `#141318`, ink blue `#144A74` as the only accent, serif headings + SF Pro body + monospaced tabular figures, 1 px hairlines, restrained motion, automatic light/dark.

## Menu bar

![Menu bar panel](Docs/10-menubar-light.png)

The menu bar panel shows disk, CPU, memory, network and battery at a glance, keeps the scan state in sync with the main window, and links straight to scanning, the main window, settings, permissions and the overview.

## Rule engine

| Capability | Detail |
| --- | --- |
| Rule model | name, category, path (with `~` expansion), min age (days), min size (MB), safety grade (safe / suggested / caution), enabled, note, scan mode |
| Validation | every save passes `PathSafety` + rule validation: empty / relative paths, home root, system prefixes, paths outside home, `~/Library` root, symlink escapes and protected paths are rejected **with a reason**; duplicate paths within a configuration are rejected |
| Presets | Conservative · Standard · Aggressive, one click, then still fully editable; Aggressive asks twice |
| Import / export | JSON with a metadata envelope (format version, app version, export date); file name carries a timestamp. Import asks **Merge or Replace**: merge keeps existing rules and skips duplicate paths, replace swaps the whole configuration; invalid entries are skipped and reported individually, never silently dropped |
| Protected list | paths you add here are never cleaned; import merges lists as a union |
| Estimates | per-rule reclaimable bytes and hit counts come from a real rule scan; nested rule roots are deduplicated so nothing is counted twice |

Scanning is streaming and cancellable: background tasks, 150 ms throttled progress callbacks merged to 100 ms UI updates, ETA estimates, symlink loops and repeated traversal avoided, permission-blocked paths recorded as skip reasons instead of errors.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘1 … ⌘6` | Home / Clean / Space / Apps / System / Rules |
| `⇧⌘R` | Start scan |
| `⌘⌫` | Clean selected items |
| `⇧⌘E` | Export report |
| `⌘F` | Focus search |
| `⌘R` | Refresh current page |
| `⌘,` | Open settings |

## Install

**From DMG** — build it locally, then open and drag **O** into Applications:

```bash
bash build_dmg.sh     # → dist/O-<version>.dmg
```

**From source** — open `Package.swift` in Xcode (scheme `O`, ⌘R to run, ⌘U to test), or:

```bash
bash build_app.sh
open .build/app/O.app
```

> The DMG is ad-hoc signed: the first launch requires *System Settings › Privacy & Security › Allow*. For wide distribution, sign with Developer ID and notarize.

## Build & test

Requires macOS 13+, Xcode 16.2 (or Swift 6.0 toolchain).

```bash
bash build_app.sh     # release build, 0 warnings, packages .app + icons
bash run_tests.sh     # both suites, reported separately
```

- **XCTest**: 78 test cases, 0 failures — path safety, scanner behavior, trash service, rules (presets, validation, persistence, JSON round-trip, lenient import, merge dedupe, scanner filters), duplicates, launch items, window close behavior, single instance.
- **SelfTest**: 204 assertions, 0 failures — a XCTest-free mirror including a **real** trash round-trip (create a temp file → trash it → verify → remove the test artifact).

Built-in diagnostics, no screen-recording permission needed:

```bash
.build/app/O.app/Contents/MacOS/O --ui-audit        # offscreen 2x PNG of every page, light & dark
.build/app/O.app/Contents/MacOS/O --lifecycle-audit  # close-window residency & window reuse
```

## Safety model

- **Trash only.** Every clean action calls `trashItem`. No `rm`, no shell, no bypass.
- **Path whitelist.** System prefixes are rejected before anything is scanned or cleaned; symlink escapes are detected.
- **No silent privilege escalation.** The app requests nothing; permission gaps degrade features with an explanation instead of erroring.
- **No data leaves the machine.** Device info is read-only and local; no network calls, no telemetry.
- **Reversible by design.** Nothing is ever deleted permanently; the Trash is your undo.

## Limitations

- Without Full Disk Access, `~/.Trash`, `~/Library/Mail`, Safari data and similar protected locations are reported as restricted rather than counted.
- The disk trend chart needs multiple days of samples to become meaningful.
- Duplicate detection is SHA-256 based; it does not find visually similar media.
- The app icon is warm-paper light; macOS icons do not auto-switch in dark mode.
- Chinese UI only for now; localization files are on the roadmap.
- Ad-hoc signed: suitable for personal use; public distribution needs Developer ID + notarization.

## License

[MIT](LICENSE) © O Project

**Disclaimer** — O is a disk utility. Despite the trash-only model, review the confirmation dialog before cleaning. The authors are not responsible for data loss.
