#!/usr/bin/env python3
"""yearcard.py -- one dark card of your own Claude Code activity, made from the log files on your computer.

    python3 tools/yearcard.py                     read the default log folder, write claude-code-card.html here
    python3 tools/yearcard.py --logs PATH         read a different folder of *.jsonl files
    python3 tools/yearcard.py --out FILE --force  write the card to FILE, replacing it if it exists

What it reads: the *.jsonl session logs Claude Code keeps under ~/.claude/projects (or $CLAUDE_CONFIG_DIR/projects).
From each line it keeps only: the line type, the time, the session id, a message id and request id (to count a
message once), the model id, two token counts, and whether a user line carries text. Everything else on the line
(paths, project names, prompts, replies, titles, links, branch names) is dropped as soon as the line is read.
What it writes: one HTML file. The page loads nothing, runs nothing and links to nothing. The tool opens no network
connection and writes no other file. It is not made or endorsed by Anthropic.

The log format is not a public contract. A line this tool does not understand is skipped and counted.
Exit 0 = card written. Exit 2 = no card (no folder, no usable line, file exists, bad option).
"""
import argparse
import collections
import datetime
import html
import json
import os
import pathlib
import re
import sys
import time

MAX_LINE = 8 * 1024 * 1024     # a longer line is skipped without being held in memory (a pasted image can make one)
GAP_CAP_SECONDS = 300          # a pause longer than this counts as five minutes
YEAR_SPAN_DAYS = 300           # below this the card says how many days it found, not the year
MODEL_ID = re.compile(r"^claude-[a-z0-9.\-]{1,60}$")
FOOTER = "Made with Warroom, a free tool. Not made or endorsed by Anthropic."
ADDRESS = "sunglasses.dev/warroom"
HINT = ("Claude Code deletes session logs older than about 30 days unless the cleanupPeriodDays setting is raised, "
        "so this card covers the span found above, not a full year.")


def find_logs(explicit, env, home):
    """The folder to read: --logs, else $CLAUDE_CONFIG_DIR/projects, else ~/.claude/projects."""
    if explicit:
        return pathlib.Path(explicit)
    cfg = (env or {}).get("CLAUDE_CONFIG_DIR")
    if cfg:
        return pathlib.Path(cfg) / "projects"
    return pathlib.Path(home) / ".claude" / "projects"


def _epoch(value):
    if not isinstance(value, str) or len(value) < 10 or len(value) > 40:
        return None
    try:
        dt = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt.timestamp()


def _int(value):
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0


def _has_text(content):
    if isinstance(content, str):
        return bool(content.strip())
    if isinstance(content, list):
        return any(isinstance(x, dict) and x.get("type") == "text" for x in content)
    return False


def read_logs(root):
    """Read every *.jsonl under root. Returns only counts and small values, never any text from a line."""
    seen = {}                                   # (message id, request id) -> [time, session, model, tokens]
    stamps = collections.defaultdict(set)       # session -> set of whole-second times
    prompts = 0
    skipped = 0
    files = 0
    unreadable = 0
    anon = 0
    for path in sorted(pathlib.Path(root).rglob("*.jsonl")):
        try:
            fh = path.open("r", encoding="utf-8", errors="replace")
        except OSError:
            unreadable += 1
            continue
        files += 1
        with fh:
            while True:
                raw = fh.readline(MAX_LINE + 1)
                if not raw:
                    break
                if len(raw) > MAX_LINE:
                    skipped += 1
                    while raw and not raw.endswith("\n"):
                        raw = fh.readline(1 << 20)       # drain the rest of the line a piece at a time
                    continue
                raw = raw.strip()
                if not raw:
                    continue
                if raw[0] == "{" and raw[-1] == "}" and "user" not in raw and "assistant" not in raw:
                    continue                    # another kind of line: nothing here is used
                try:
                    d = json.loads(raw)
                except ValueError:
                    skipped += 1
                    continue
                if not isinstance(d, dict):
                    skipped += 1
                    continue
                kind = d.get("type")
                if kind not in ("user", "assistant"):
                    continue
                t = _epoch(d.get("timestamp"))
                sid = d.get("sessionId")
                msg = d.get("message")
                if t is None or not isinstance(msg, dict):
                    skipped += 1
                    continue
                sid = sys.intern(sid) if isinstance(sid, str) and sid else "unknown"
                if kind == "user":
                    stamps[sid].add(int(t))
                    if d.get("isSidechain") is not True and d.get("isMeta") is not True and _has_text(msg.get("content")):
                        prompts += 1
                    continue
                model = msg.get("model")
                if not isinstance(model, str) or model.startswith("<"):
                    continue                    # a record that carries no model is not a reply
                model = sys.intern(model)
                usage = msg.get("usage") if isinstance(msg.get("usage"), dict) else {}
                out = _int(usage.get("output_tokens"))
                mid, rid = msg.get("id"), d.get("requestId")
                if isinstance(mid, str) and isinstance(rid, str):
                    key = (mid, rid)
                else:
                    anon += 1
                    key = ("line", anon)
                stamps[sid].add(int(t))
                row = seen.get(key)
                if row is None:
                    seen[key] = [t, sid, model, out]
                elif out > row[3]:
                    row[2], row[3] = model, out
    return {"messages": list(seen.values()), "stamps": stamps, "prompts": prompts, "skipped": skipped,
            "files": files, "unreadable": unreadable}


def _local(epoch):
    return datetime.datetime.fromtimestamp(epoch)


def summarize(read):
    """Turn what read_logs kept into the numbers on the card."""
    msgs = read["messages"]
    stamps = read["stamps"]
    all_times = [t for s in stamps.values() for t in s]
    if not all_times:
        return None
    first, last = _local(min(all_times)).date(), _local(max(all_times)).date()
    days = collections.Counter()
    strip = [[0] * 24 for _ in range(7)]
    models = collections.Counter()
    tokens = 0
    for t, _sid, model, out in msgs:
        dt = _local(t)
        days[dt.date().isoformat()] += 1
        strip[dt.weekday()][dt.hour] += 1
        models[model if MODEL_ID.match(model) else "other"] += 1
        tokens += out
    active = 0
    for s in stamps.values():
        ordered = sorted(s)
        active += sum(min(b - a, GAP_CAP_SECONDS) for a, b in zip(ordered, ordered[1:]))
    busiest = sorted(days.items(), key=lambda kv: (-kv[1], kv[0]))[:1]
    return {
        "sessions": len(stamps), "messages": len(msgs), "prompts": read["prompts"], "output_tokens": tokens,
        "busiest_day": busiest[0][0] if busiest else "", "busiest_count": busiest[0][1] if busiest else 0,
        "active_seconds": active,
        "models": sorted(models.items(), key=lambda kv: (kv[0] == "other", -kv[1], kv[0])),
        "first": first.isoformat(), "last": last.isoformat(), "span_days": (last - first).days + 1,
        "strip": strip, "skipped": read["skipped"],
    }


def title_for(stats):
    if stats["span_days"] >= YEAR_SPAN_DAYS:
        return "YOUR %s IN CLAUDE CODE" % stats["last"][:4]
    n = stats["span_days"]
    return "YOUR LAST %d %s IN CLAUDE CODE" % (n, "DAY" if n == 1 else "DAYS")


def _date_words(iso):
    d = datetime.date.fromisoformat(iso)
    return "%d %s %d" % (d.day, d.strftime("%b"), d.year)


def render_card(stats):
    """One self-contained page: inline style, inline SVG, no script, no link, no image, no font file."""
    e = html.escape
    hours = stats["active_seconds"] / 3600.0
    peak = max((c for row in stats["strip"] for c in row), default=0) or 1
    cells = []
    for r, row in enumerate(stats["strip"]):
        for h, c in enumerate(row):
            op = 0.08 + 0.92 * (c / peak) if c else 0.06
            cells.append('<rect x="%d" y="%d" width="11" height="11" rx="2" fill="#7c9cff" fill-opacity="%.2f"/>' % (h * 14, r * 14, op))
    strip_svg = '<svg width="332" height="96" viewBox="0 0 332 96" role="img" aria-label="messages by weekday and hour">%s</svg>' % "".join(cells)
    top = stats["models"][:4]
    mmax = max((c for _, c in top), default=1) or 1
    model_rows = "".join(
        '<div class="m"><span>%s</span><i style="width:%dpx"></i><b>%s</b></div>' % (e(n), max(4, int(160 * c / mmax)), format(c, ","))
        for n, c in top)
    tiles = [
        ("Sessions", format(stats["sessions"], ",")),
        ("Replies", format(stats["messages"], ",")),
        ("Prompts", format(stats["prompts"], ",")),
        ("Active hours, about", format(hours, ",.1f")),
        ("Output tokens", format(stats["output_tokens"], ",")),
        ("Busiest day", "%s (%s)" % (_date_words(stats["busiest_day"]), format(stats["busiest_count"], ","))),
    ]
    tile_html = "".join('<div class="t"><small>%s</small><strong>%s</strong></div>' % (e(a), e(b)) for a, b in tiles)
    span = "%s to %s, %d day%s" % (_date_words(stats["first"]), _date_words(stats["last"]), stats["span_days"], "" if stats["span_days"] == 1 else "s")
    return (
        '<!doctype html>\n<html lang="en"><head><meta charset="utf-8">\n'
        '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'">\n'
        '<meta name="viewport" content="width=device-width,initial-scale=1">\n<title>%s</title>\n<style>\n'
        'body{margin:0;background:#0f1115;color:#e8eaf0;font:15px/1.4 -apple-system,Segoe UI,Helvetica,Arial,sans-serif;display:flex;justify-content:center;padding:24px}\n'
        '.card{width:640px;box-sizing:border-box;padding:32px;background:#161a22;border:1px solid #262c38;border-radius:16px}\n'
        'h1{margin:0 0 4px;font-size:22px;letter-spacing:.04em}\n.span{color:#8d96a8;margin-bottom:22px}\n'
        '.g{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:22px}\n'
        '.t{background:#0f1115;border:1px solid #262c38;border-radius:10px;padding:12px 14px}\n'
        '.t small{display:block;color:#8d96a8;margin-bottom:2px}\n.t strong{font-size:20px}\n'
        '.m{display:flex;align-items:center;gap:10px;margin:6px 0}\n.m span{width:200px;color:#c4cad8;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}\n'
        '.m i{display:block;height:8px;background:#7c9cff;border-radius:4px}\n.m b{color:#8d96a8;font-weight:500}\n'
        'h2{font-size:13px;color:#8d96a8;margin:18px 0 8px;font-weight:500;text-transform:uppercase;letter-spacing:.08em}\n'
        '.f{margin-top:24px;padding-top:14px;border-top:1px solid #262c38;color:#8d96a8;font-size:13px}\n.f div{margin-top:4px;color:#c4cad8}\n'
        '</style></head><body>\n<div class="card">\n<h1>%s</h1>\n<div class="span">%s</div>\n<div class="g">%s</div>\n'
        '<h2>Models</h2>\n%s\n<h2>When you work (weekday by hour)</h2>\n%s\n'
        '<div class="f">%s<div>%s</div></div>\n</div>\n</body></html>\n'
    ) % (e(title_for(stats)), e(title_for(stats)), e(span), tile_html, model_rows, strip_svg, e(FOOTER), e(ADDRESS))


def _summary_lines(stats, wrote):
    hours = stats["active_seconds"] / 3600.0
    lines = [
        title_for(stats),
        "span: %s to %s (%d days)" % (stats["first"], stats["last"], stats["span_days"]),
        "sessions %s, replies %s, prompts %s" % (format(stats["sessions"], ","), format(stats["messages"], ","), format(stats["prompts"], ",")),
        "active hours about %.1f, output tokens %s" % (hours, format(stats["output_tokens"], ",")),
        "busiest day %s (%s replies)" % (stats["busiest_day"], format(stats["busiest_count"], ",")),
    ]
    if stats["skipped"]:
        lines.append("skipped %d lines this tool does not understand" % stats["skipped"])
    if stats["span_days"] < YEAR_SPAN_DAYS:
        lines.append(HINT)
    lines.append("wrote %s" % wrote)
    return lines


def main(argv=None):
    ap = argparse.ArgumentParser(prog="yearcard.py", description="A card of your own Claude Code activity, from local logs. Nothing is sent anywhere.")
    ap.add_argument("--logs", help="folder of *.jsonl session logs (default: $CLAUDE_CONFIG_DIR/projects or ~/.claude/projects)")
    ap.add_argument("--out", default="claude-code-card.html", help="file to write (default: claude-code-card.html)")
    ap.add_argument("--force", action="store_true", help="replace the output file if it exists")
    args = ap.parse_args(argv)
    root = find_logs(args.logs, os.environ, pathlib.Path.home())
    if not root.is_dir():
        print("no log folder: looked in %s. Pass --logs PATH to point at your session logs." % root, file=sys.stderr)
        return 2
    stats = summarize(read_logs(root))
    if stats is None:
        print("found no usable line in %s: the log format may have changed. No card written." % root, file=sys.stderr)
        return 2
    out = pathlib.Path(args.out)
    if out.exists() and not args.force:
        print("%s already exists. Use --force to replace it." % out, file=sys.stderr)
        return 2
    try:
        with open(out, "w" if args.force else "x", encoding="utf-8") as fh:
            fh.write(render_card(stats))
    except OSError as err:
        print("could not write %s: %s" % (out, err.strerror), file=sys.stderr)
        return 2
    print("\n".join(_summary_lines(stats, out)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
