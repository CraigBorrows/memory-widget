# CLAUDE.md — memory-widget

KDE Plasma 6 (Plasma 6.6, Qt6/KF6) panel widget showing RAM usage as a
percentage, with a grouped per-application breakdown in the popup. Built for
Craig's Fedora 43 / KDE Wayland workstation. Sibling project to
`claude-usage-widget`, same structure and conventions.

## Working on this

- Source of truth is this project. `package/` is **symlinked** into
  `~/.local/share/plasma/plasmoids/com.cbo.memusage`. The helper lives inside
  the package at `contents/code/mem-usage.py` (resolved at runtime via
  `Qt.resolvedUrl`), so there's no separate `~/.local/bin` install. Run
  `./install.sh` to (re)create the symlink, clear the QML cache, and restart
  plasmashell. `./build.sh` produces a distributable `.plasmoid`.
- **Always clear `~/.cache/plasmashell/qmlcache/` after editing `main.qml`** —
  Plasma runs the *compiled* cache, not your source, so a plain restart shows
  no change. This is the single biggest footgun here. `install.sh` handles it.
- Validate QML without disturbing the live panel:
  `plasmoidviewer -a com.cbo.memusage` (needs `plasma-sdk`, already installed).
  It exits non-zero only on a real failure — a clean run just sits there until
  you kill it. `plasmoidviewer -f vertical -a com.cbo.memusage` renders the
  in-panel form.
- The helper is standalone and testable: `python3
  package/contents/code/mem-usage.py --procs | python3 -m json.tool`.

## Data source

Everything comes from `/proc` — no external deps, no root.

- **Summary** (`/proc/meminfo`, ~20 ms): the three popup segments are derived
  as `used = MemTotal - MemAvailable`, `reclaimable = MemAvailable - MemFree`,
  `free = MemFree`, so they sum to exactly MemTotal with no rounding gap. The
  headline percentage is `used / total`. MemAvailable is the kernel's own
  estimate of what a new workload could claim without swapping, which is why
  it — not `free`'s `used` column — anchors the arithmetic.
- **Per-process** (`--procs`, ~400 ms): PSS from `/proc/<pid>/smaps_rollup`,
  not RSS. This matters a lot here: RSS double-counts every shared page in
  every process sharing it, which on this machine overstated `claude` by
  745 MB across 9 sessions, `dolphin` by 73%, and `cef_server` by 52%.
  Processes whose smaps_rollup we can't read (root daemons) fall back to
  VmRSS and are counted in `rss_fallback` so the popup footnote can say so.
  All the large consumers are readable, so the top of the table is pure PSS.

### /proc parsing gotchas, all of which bit once

- `comm` is capped at 15 chars **and** programs rename themselves via
  `prctl(PR_SET_NAME)` — clangd reports `ion.clangd.main`. `display_name()`
  falls back to `basename(argv[0])` only when comm is a full 15 chars, so
  interpreted programs don't all collapse into `node`/`python3`.
- `tty_nr` (stat field 7) is a `dev_t` packed by `new_encode_dev()`:
  `(minor & 0xff) | (major << 8) | ((minor & ~0xff) << 12)`. The high minor
  bits come back out of **bit 12**, not bit 8 — decoding it as `>> 8` turns
  `pts/1` into `pts/2049`.
- Kernel threads have no `smaps_rollup` and zero RSS. Count the RSS fallback
  *after* the zero-memory skip, or you report hundreds of degraded readings
  that never appear in the table.
- stat field 22 (starttime) is `fields[19]` once you split after the last
  `)` — `fields[0]` is field 3, because the comm field can itself contain
  spaces and parens.

## Conventions

- Panel: percentage on top, absolute used below (`42%` / `20.9G`), matching
  the two-line layout of `claude-usage-widget`.
- Colour thresholds: >=90 negative (red), >=75 neutral (orange), else the
  ordinary text colour — deliberately *not* green at rest, since a permanently
  coloured panel number is just noise.
- Two `DataSource`s on purpose: the panel polls the cheap summary every 3 s,
  and the 400 ms process scan runs every 5 s **only while the popup is open**
  (`running: root.expanded`). Don't merge them.
- Every run appends `" # <seq>"` to the command so it is a distinct DataSource
  source — without that, reconnecting the same source name is a no-op and a
  forced refresh silently does nothing. **`seq` wraps at 8 — never make it
  unbounded.** Plasma5Support keeps source names in a `QQmlPropertyMap` backed
  by an append-only `QQmlOpenMetaObject`: every name ever used stays a property
  forever (and *removing* a source adds one — `removeSource` → `clear()` →
  `setValue` → `createProperty`), while both connect and disconnect rebuild the
  whole metaobject via `QMetaObjectBuilder::toMetaObject()`. Unbounded, the 3 s
  poll costs O(polls so far); after ~23 h this widget plus `cpu-widget` had
  ~28k names each and plasmashell's main thread was pinned at 100% with 1.3 GB
  RSS, lagging the panel while the rest of the machine was fine. Wrapping keeps
  it constant, and 8 × 3 s still leaves 24 s before a name is reused.
- Clicking a table row expands it to individual PIDs with tty and uptime;
  middle-click on the panel opens System Monitor.
