#!/usr/bin/env python3
"""Memory snapshot for the Plasma memory widget.

Two modes, so the panel stays cheap:
  (no args)  /proc/meminfo summary only — sub-millisecond, polled continuously.
  --procs    additionally walks /proc and groups processes by name, for the
             popup. Only run while the popup is actually open.

Per-process memory is PSS (proportional set size) from smaps_rollup wherever
the kernel lets us read it: shared pages are divided between the processes
sharing them, so group totals actually add up instead of counting libc and the
whole Qt stack once per KDE app the way RSS does. Processes we can't read
(other users', mostly root daemons) fall back to VmRSS and are tallied in
`rss_fallback` so the UI can say so.

All memory values are emitted in kB, matching /proc.
"""
import json
import os
import pwd
import re
import shutil
import sys
import time

TICKS = os.sysconf("SC_CLK_TCK")
PAGE_KB = os.sysconf("SC_PAGE_SIZE") // 1024
TOP_GROUPS = 12          # rows in the popup table before "Other"
TOP_PROCS_PER_GROUP = 8  # per-process detail when a row is expanded
COMM_MAX = 15            # kernel truncates /proc/<pid>/comm to TASK_COMM_LEN-1


def emit(obj):
    obj["fetched_ms"] = int(time.time() * 1000)
    print(json.dumps(obj))
    raise SystemExit(0)


# ---------- summary ----------

def meminfo():
    info = {}
    with open("/proc/meminfo") as f:
        for line in f:
            key, _, val = line.partition(":")
            parts = val.split()
            if parts:
                info[key] = int(parts[0])  # kB
    return info


def summary():
    mi = meminfo()
    total = mi.get("MemTotal", 0)
    free = mi.get("MemFree", 0)
    # MemAvailable is the kernel's own estimate of what a new workload could
    # get without swapping. Deriving both "in use" and "reclaimable" from it
    # keeps the three segments summing to exactly MemTotal.
    avail = mi.get("MemAvailable", free)
    used = max(0, total - avail)
    reclaimable = max(0, avail - free)

    swap_total = mi.get("SwapTotal", 0)
    swap_free = mi.get("SwapFree", 0)

    return {
        "total_kb": total,
        "used_kb": used,
        "reclaimable_kb": reclaimable,
        "free_kb": free,
        "available_kb": avail,
        "pct": (used * 100.0 / total) if total else 0.0,
        "buffers_kb": mi.get("Buffers", 0),
        "cached_kb": mi.get("Cached", 0) + mi.get("SReclaimable", 0),
        "shmem_kb": mi.get("Shmem", 0),
        "swap_total_kb": swap_total,
        "swap_used_kb": max(0, swap_total - swap_free),
        "swap_pct": ((swap_total - swap_free) * 100.0 / swap_total) if swap_total else 0.0,
    }


# ---------- per-process ----------

def read_cmdline(pid):
    try:
        with open("/proc/%s/cmdline" % pid, "rb") as f:
            return [a.decode("utf-8", "replace") for a in f.read().split(b"\0") if a]
    except OSError:
        return []


def display_name(pid, comm):
    """Pick the label to group by.

    comm is capped at 15 chars and programs can rename themselves with
    prctl(PR_SET_NAME), so it arrives both truncated (plasma-systemmo) and
    plain wrong (clangd calls itself ion.clangd.main). argv[0] fixes both, but
    only trust it when comm looks damaged — otherwise an interpreted program
    would get grouped under `node` or `python3` instead of its own name.
    """
    if len(comm) < COMM_MAX:
        return comm
    argv = read_cmdline(pid)
    if not argv:
        return comm
    base = os.path.basename(argv[0])
    if not base:
        return comm
    return base if (base.startswith(comm) or len(comm) == COMM_MAX) else comm


def tty_of(stat_fields):
    """Decode field 7 (tty_nr) into a pts/N name — the only thing that tells
    otherwise-identical sessions of the same program apart.

    tty_nr is a dev_t packed by the kernel's new_encode_dev():
        (minor & 0xff) | (major << 8) | ((minor & ~0xff) << 12)
    so the high minor bits have to come back out of bit 12, not bit 8.
    """
    try:
        tty_nr = int(stat_fields[4])
    except (IndexError, ValueError):
        return ""
    if tty_nr == 0:
        return ""
    major = (tty_nr >> 8) & 0xFFF
    minor = (tty_nr & 0xFF) | ((tty_nr >> 12) & 0xFFFFF00)
    if major == 136:
        return "pts/%d" % minor
    if major == 4:
        return "tty%d" % minor
    return ""


def pss_kb(pid):
    try:
        with open("/proc/%s/smaps_rollup" % pid) as f:
            for line in f:
                if line.startswith("Pss:"):
                    return int(line.split()[1])
    except (OSError, ValueError, IndexError):
        return None
    return None


def rss_kb(pid):
    try:
        with open("/proc/%s/statm" % pid) as f:
            return int(f.read().split()[1]) * PAGE_KB
    except (OSError, ValueError, IndexError):
        return None


_users = {}


def user_of(path):
    try:
        uid = os.stat(path).st_uid
    except OSError:
        return ""
    if uid not in _users:
        try:
            _users[uid] = pwd.getpwuid(uid).pw_name
        except KeyError:
            _users[uid] = str(uid)
    return _users[uid]


def scan_processes():
    try:
        with open("/proc/uptime") as f:
            uptime = float(f.read().split()[0])
    except (OSError, ValueError):
        uptime = 0.0

    procs = []
    fallbacks = 0
    self_pid = str(os.getpid())

    for entry in os.scandir("/proc"):
        pid = entry.name
        if not pid.isdigit() or pid == self_pid:
            continue
        try:
            with open("/proc/%s/stat" % pid) as f:
                raw = f.read()
        except OSError:
            continue  # exited mid-scan
        close = raw.rfind(")")
        if close < 0:
            continue
        comm = raw[raw.find("(") + 1:close]
        fields = raw[close + 2:].split()

        kb = pss_kb(pid)
        measured = "pss"
        if kb is None:
            kb = rss_kb(pid)
            measured = "rss"
            if kb is None:
                continue
        if kb <= 0:
            continue  # kernel threads and the already-dead
        # Count the fallback only once we know the process is actually being
        # reported — kernel threads have no smaps_rollup either, and counting
        # them would claim hundreds of degraded readings that never show up.
        if measured == "rss":
            fallbacks += 1

        # field 22 (starttime) is fields[19]: fields[0] is field 3.
        try:
            age = max(0.0, uptime - float(fields[19]) / TICKS)
        except (IndexError, ValueError):
            age = 0.0

        procs.append({
            "pid": int(pid),
            "name": display_name(pid, comm),
            "kb": kb,
            "measured": measured,
            "age_s": int(age),
            "tty": tty_of(fields),
            "user": user_of(entry.path),
        })

    return procs, fallbacks


def group(procs):
    groups = {}
    for p in procs:
        g = groups.get(p["name"])
        if g is None:
            g = groups[p["name"]] = {"name": p["name"], "kb": 0, "procs": 0, "items": []}
        g["kb"] += p["kb"]
        g["procs"] += 1
        g["items"].append(p)

    ordered = sorted(groups.values(), key=lambda g: g["kb"], reverse=True)
    for g in ordered:
        g["items"].sort(key=lambda p: p["kb"], reverse=True)
        g["items"] = g["items"][:TOP_PROCS_PER_GROUP]

    top = ordered[:TOP_GROUPS]
    rest = ordered[TOP_GROUPS:]
    if rest:
        top.append({
            "name": "Other",
            "kb": sum(g["kb"] for g in rest),
            "procs": sum(g["procs"] for g in rest),
            "items": [],
            "is_other": True,
        })
    return top


# ---------- Claude Code temp files ----------
#
# Claude Code keeps per-session scratch dirs in /tmp/claude-<uid>/<project>/<session-id>/.
# /tmp is tmpfs, so those files are RAM (or swap) — but they belong to no
# process, so PSS can never see them, and they outlive the session that wrote
# them. A dead session once held 5.9 GB here, invisible to the table.

CLAUDE_SESSIONS = os.path.expanduser("~/.claude/sessions")
RECENT_S = 600   # unmatched dir written this recently → "recent", not "ended"


def tree_usage(path):
    """(kB allocated, newest mtime) for a directory tree. st_blocks counts a
    tmpfs page whether it's resident or swapped out, which is what we want:
    either way it's memory the file is holding."""
    kb, newest = 0, 0.0
    for dirpath, dirnames, filenames in os.walk(path):
        for name in filenames + dirnames:
            try:
                st = os.lstat(os.path.join(dirpath, name))
            except OSError:
                continue
            kb += st.st_blocks // 2           # 512-byte blocks → kB
            newest = max(newest, st.st_mtime)
    return kb, newest


def live_claude_sessions():
    """sessionId → (pid, cwd, tty) for sessions whose process is still alive,
    from Claude Code's own ~/.claude/sessions/<pid>.json registry."""
    live = {}
    try:
        entries = list(os.scandir(CLAUDE_SESSIONS))
    except OSError:
        return live
    for e in entries:
        if not e.name.endswith(".json"):
            continue
        try:
            with open(e.path) as f:
                s = json.load(f)
            pid = int(s["pid"])
            with open("/proc/%d/stat" % pid) as f:
                raw = f.read()
        except (OSError, ValueError, KeyError, TypeError):
            continue                          # stale registry entry
        fields = raw[raw.rfind(")") + 2:].split()
        live[s.get("sessionId", "")] = (pid, s.get("cwd", ""), tty_of(fields))
    return live


def slug_to_path(slug):
    """Best-effort reverse of Claude's project slug (every '/' became '-', so
    dashes inside names are ambiguous). Only used for ended sessions — live
    ones report their real cwd."""
    home = os.path.expanduser("~")
    path = slug.replace("-", "/")
    return "~" + path[len(home):] if path.startswith(home) else path


CLAUDE_TMP = "/tmp/claude-%d" % os.getuid()
SESSION_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def scan_claude_tmp():
    """One item per session dir (plus one 'shared' item), each carrying its
    path in "_path" — stripped before anything is emitted."""
    try:
        projects = list(os.scandir(CLAUDE_TMP))
    except OSError:
        return []
    live = live_claude_sessions()
    home = os.path.expanduser("~")
    now = time.time()
    items, shared_kb, shared_mtime = [], 0, 0.0

    for proj in projects:
        if not proj.is_dir(follow_symlinks=False) or not proj.name.startswith("-"):
            # bundled-skills, bash-edit-diff, loose files: shared, not per-session
            kb, mt = tree_usage(proj.path) if proj.is_dir(follow_symlinks=False) else (0, 0.0)
            if not proj.is_dir(follow_symlinks=False):
                try:
                    st = os.lstat(proj.path)
                    kb, mt = st.st_blocks // 2, st.st_mtime
                except OSError:
                    pass
            shared_kb += kb
            shared_mtime = max(shared_mtime, mt)
            continue
        try:
            sessions = [s for s in os.scandir(proj.path) if s.is_dir(follow_symlinks=False)]
        except OSError:
            continue
        for sess in sessions:
            kb, mt = tree_usage(sess.path)
            if kb <= 0:
                continue
            pid, cwd, tty = live.get(sess.name, (0, "", ""))
            if cwd:
                label = "~" + cwd[len(home):] if cwd.startswith(home) else cwd
            else:
                label = slug_to_path(proj.name)
            items.append({
                "pid": pid,
                "name": "claude-tmp",
                "kb": kb,
                "measured": "tmpfs",
                "age_s": int(max(0, now - mt)) if mt else 0,
                "tty": tty,
                "user": "",
                "label": label or "~",
                "session": sess.name[:8],
                "live": pid > 0,
                # Unmatched but freshly written usually means a background job
                # of another session is still using it — don't call it dead.
                "status": "live" if pid > 0 else ("recent" if mt and now - mt < RECENT_S else "ended"),
                "_path": sess.path,
            })

    if shared_kb > 0:
        items.append({
            "pid": 0, "name": "claude-tmp", "kb": shared_kb, "measured": "tmpfs",
            "age_s": int(max(0, now - shared_mtime)) if shared_mtime else 0,
            "tty": "", "user": "", "label": "shared (skills, diffs)",
            "session": "", "live": True, "status": "shared",
        })
    return items


def claude_tmp_group():
    items = [{k: v for k, v in p.items() if k != "_path"} for p in scan_claude_tmp()]
    if not items:
        return None

    items.sort(key=lambda p: p["kb"], reverse=True)
    return {
        "name": "Claude temp files",
        "kb": sum(p["kb"] for p in items),
        "procs": len(items),
        "ended": sum(1 for p in items if p["status"] == "ended"),
        "ended_kb": sum(p["kb"] for p in items if p["status"] == "ended"),
        "items": items[:TOP_PROCS_PER_GROUP],
        "is_tmp": True,
    }


def clean_claude_tmp():
    """Delete the session dirs that are 'ended' *right now* — re-scanned here
    rather than trusting what the popup showed seconds ago. Only UUID-named
    dirs directly under /tmp/claude-<uid>/<project>/ are ever touched."""
    freed, count = 0, 0
    for p in scan_claude_tmp():
        path = p.get("_path", "")
        if p["status"] != "ended" or not path:
            continue
        parent = os.path.dirname(path)
        if (not SESSION_RE.match(os.path.basename(path))
                or os.path.dirname(parent) != CLAUDE_TMP
                or not os.path.basename(parent).startswith("-")
                or os.path.islink(path)):
            continue
        shutil.rmtree(path, ignore_errors=True)
        if not os.path.exists(path):
            freed += p["kb"]
            count += 1
            try:
                os.rmdir(parent)          # drop the project dir if now empty
            except OSError:
                pass
    return {"freed_kb": freed, "count": count}


def merge_tmp(groups, tmp):
    """Rank the tmp row by size among the process groups, keeping Other last."""
    if not tmp:
        return groups
    other = [g for g in groups if g.get("is_other")]
    rest = [g for g in groups if not g.get("is_other")] + [tmp]
    rest.sort(key=lambda g: g["kb"], reverse=True)
    return rest + other


# ---------- main ----------

out = {"ok": True}
try:
    out.update(summary())
except Exception as e:
    emit({"error": "meminfo", "detail": str(e)})

if "--clean-claude-tmp" in sys.argv:
    try:
        out["cleaned"] = clean_claude_tmp()
    except Exception as e:
        out["cleaned"] = {"error": str(e), "freed_kb": 0, "count": 0}
    try:
        out.update(summary())                 # reflect what was just freed
    except Exception:
        pass

if "--procs" in sys.argv:
    try:
        procs, fallbacks = scan_processes()
        try:
            tmp = claude_tmp_group()
        except Exception:
            tmp = None                         # never let this break the table
        out["groups"] = merge_tmp(group(procs), tmp)
        out["tmp_kb"] = tmp["kb"] if tmp else 0
        out["proc_total_kb"] = sum(p["kb"] for p in procs)
        out["proc_count"] = len(procs)
        out["rss_fallback"] = fallbacks
    except Exception as e:
        out["proc_error"] = str(e)

emit(out)
