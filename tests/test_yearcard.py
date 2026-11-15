"""tests/test_yearcard.py -- checks for tools/yearcard.py. Standard library only: python3 -m unittest tests.test_yearcard

Every log line below is invented. The canary strings are put together while the tests run, so this file holds no path, address or key shape.
Run on macOS or Linux (the tests set the time zone with time.tzset).
"""
import ast
import contextlib
import hashlib
import io
import json
import os
import pathlib
import socket
import stat
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools" / "yearcard.py"
sys.path.insert(0, str(ROOT / "tools"))
os.environ["TZ"] = "UTC"
time.tzset()

import yearcard  # noqa: E402


def canaries():
    """Strings that must never reach the card, built here so the source holds none of them."""
    return {
        "path": "/" + "Us" + "ers/" + "zq" + "carol/" + "secret" + "-project",
        "project": "zq" + "-roadmap-" + "alpha",
        "prompt": "please " + "rotate the " + "zqvault " + "passphrase",
        "prurl": "https" + "://" + "git" + "hub.com/" + "zq-org/zq-repo/pull/7",
        "email": "zq.carol" + "@" + "example" + ".org",
        "keyshape": "s" + "k-" + "zq" + "A1b2C3d4E5f6G7h8I9j0",
        "arn": "arn:" + "aws:bedrock:us-west-2:" + "123456789012:" + "inference-profile/zq-custom",
        "title": "zq " + "quarterly " + "numbers chat",
        "branch": "feature/" + "zq-hidden-branch",
        "session": "zq5e55i0n-" + "0000-4000-8000-" + "00000000beef",
    }


def line(**kw):
    return json.dumps(kw)


def user(ts, sid, text=True, extra=None):
    content = "hello there" if text else None
    msg = {"role": "user", "content": content if text else [{"type": "tool_result", "content": "ok"}]}
    d = {"type": "user", "timestamp": ts, "sessionId": sid, "message": msg, "isSidechain": False}
    d.update(extra or {})
    return line(**d)


def asst(ts, sid, mid, rid, model, out, inp=100, extra=None):
    d = {"type": "assistant", "timestamp": ts, "sessionId": sid, "requestId": rid, "isSidechain": False,
         "message": {"id": mid, "role": "assistant", "model": model, "content": [{"type": "text", "text": "hi"}],
                     "usage": {"input_tokens": inp, "output_tokens": out}}}
    d.update(extra or {})
    return line(**d)


def standard_fixture(root, junk=None):
    """Two projects, two sessions, one message written three times, one custom model id, one synthetic record."""
    c = canaries()
    junk = junk or {}
    a = pathlib.Path(root) / ("-" + c["path"].strip("/").replace("/", "-"))
    b = pathlib.Path(root) / ("-" + c["project"])
    a.mkdir(parents=True)
    b.mkdir(parents=True)
    s1, s2 = "sess-one", "sess-two"
    leak = dict(cwd=c["path"], gitBranch=c["branch"], slug=c["project"], aiTitle=c["title"], lastPrompt=c["prompt"],
                prUrl=c["prurl"], prRepository=c["project"], email=c["email"], toolUseResult=c["keyshape"])
    leak.update(junk)
    rows1 = [
        user("2026-03-02T10:00:00.000Z", s1, extra=leak),
        asst("2026-03-02T10:00:30.000Z", s1, "m1", "r1", "claude-sample-large", 5, extra=leak),
        asst("2026-03-02T10:00:30.000Z", s1, "m1", "r1", "claude-sample-large", 10, extra=leak),
        asst("2026-03-02T10:00:31.000Z", s1, "m1", "r1", "claude-sample-large", 40, extra=leak),
        user("2026-03-02T10:01:00.000Z", s1, text=False, extra=leak),
        asst("2026-03-02T10:01:10.000Z", s1, "m2", "r2", "claude-sample-large", 20, extra=leak),
        user("2026-03-02T10:30:00.000Z", s1, extra=leak),
        asst("2026-03-02T10:30:20.000Z", s1, "m3", "r3", c["arn"], 7, extra=leak),
        line(type="ai-title", aiTitle=c["title"], sessionId=s1),
        line(type="pr-link", prUrl=c["prurl"], sessionId=s1),
    ]
    rows2 = [
        user("2026-03-03T14:00:00.000Z", s2, extra=leak),
        asst("2026-03-03T14:00:10.000Z", s2, "m4", "r4", "claude-sample-mid", 30, extra=leak),
        asst("2026-03-03T14:00:50.000Z", s2, "m5", "r5", "claude-sample-mid", 30, extra=leak),
        asst("2026-03-03T14:01:00.000Z", s2, "m6", "r6", "<synthetic>", 0, extra=leak),
    ]
    (a / (c["session"] + ".jsonl")).write_text("\n".join(rows1) + "\n")
    (b / "second.jsonl").write_text("\n".join(rows2) + "\n")
    return c


def run_tool(argv, env=None):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        env_patch = mock.patch.dict(os.environ, env or {}, clear=False)
        with env_patch:
            try:
                code = yearcard.main(argv)
            except SystemExit as e:
                code = e.code
    return code, out.getvalue(), err.getvalue()


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.logs = pathlib.Path(self.tmp.name) / "projects"
        self.logs.mkdir()
        self.work = pathlib.Path(self.tmp.name) / "work"
        self.work.mkdir()
        self.card = self.work / "card.html"


class TestFindLogs(Base):
    def test_the_default_folder_is_under_the_home_folder(self):
        home = pathlib.Path(self.tmp.name) / "home"
        (home / ".claude" / "projects").mkdir(parents=True)
        self.assertEqual(yearcard.find_logs(None, {}, home), home / ".claude" / "projects")

    def test_the_config_folder_variable_wins_over_the_home_folder(self):
        cfg = pathlib.Path(self.tmp.name) / "cfg"
        (cfg / "projects").mkdir(parents=True)
        self.assertEqual(yearcard.find_logs(None, {"CLAUDE_CONFIG_DIR": str(cfg)}, pathlib.Path("/nonexistent")), cfg / "projects")

    def test_an_explicit_folder_wins_over_both(self):
        self.assertEqual(yearcard.find_logs(str(self.logs), {"CLAUDE_CONFIG_DIR": "/elsewhere"}, pathlib.Path("/nonexistent")), self.logs)

    def test_a_missing_folder_exits_2_names_where_it_looked_and_writes_no_card(self):
        code, out, err = run_tool(["--logs", str(self.work / "nope"), "--out", str(self.card)])
        self.assertEqual(code, 2)
        self.assertIn("looked", out + err)
        self.assertFalse(self.card.exists())


class TestNumbers(Base):
    def setUp(self):
        super().setUp()
        standard_fixture(self.logs)
        self.stats = yearcard.summarize(yearcard.read_logs(self.logs))

    def test_sessions_are_the_distinct_session_ids(self):
        self.assertEqual(self.stats["sessions"], 2)

    def test_a_message_written_three_times_counts_once_with_its_largest_token_count(self):
        self.assertEqual(self.stats["messages"], 5)
        self.assertEqual(self.stats["output_tokens"], 40 + 20 + 7 + 30 + 30)

    def test_a_prompt_is_a_user_line_with_text_and_a_tool_result_is_not(self):
        self.assertEqual(self.stats["prompts"], 3)

    def test_the_busiest_day_is_the_local_date_with_most_messages(self):
        self.assertEqual((self.stats["busiest_day"], self.stats["busiest_count"]), ("2026-03-02", 3))

    def test_active_time_caps_each_gap_at_five_minutes(self):
        self.assertEqual(self.stats["active_seconds"], 440)

    def test_models_keep_claude_ids_and_fold_everything_else_into_other(self):
        self.assertEqual(dict(self.stats["models"]), {"claude-sample-large": 2, "claude-sample-mid": 2, "other": 1})

    def test_a_synthetic_record_is_not_counted(self):
        self.assertEqual(self.stats["messages"], 5)

    def test_the_span_runs_from_the_first_to_the_last_day_inclusive(self):
        self.assertEqual((self.stats["first"], self.stats["last"], self.stats["span_days"]), ("2026-03-02", "2026-03-03", 2))

    def test_the_hour_strip_counts_messages_by_weekday_and_hour(self):
        self.assertEqual(self.stats["strip"][0][10], 3)   # Monday 10:00
        self.assertEqual(self.stats["strip"][1][14], 2)   # Tuesday 14:00
        self.assertEqual(sum(sum(r) for r in self.stats["strip"]), 5)


class TestTitle(Base):
    def card_for(self, extra_rows):
        d = self.logs / "p"
        d.mkdir(exist_ok=True)
        (d / "x.jsonl").write_text("\n".join(extra_rows) + "\n")
        stats = yearcard.summarize(yearcard.read_logs(self.logs))
        return yearcard.render_card(stats)

    def test_a_span_of_300_days_or_more_says_the_year(self):
        html = self.card_for([user("2025-04-01T10:00:00Z", "a"), asst("2026-03-02T10:00:00Z", "a", "m", "r", "claude-sample-large", 1)])
        self.assertIn("YOUR 2026 IN CLAUDE CODE", html)

    def test_a_shorter_span_says_how_many_days_it_found(self):
        html = self.card_for([user("2026-02-01T10:00:00Z", "a"), asst("2026-03-06T10:00:00Z", "a", "m", "r", "claude-sample-large", 1)])
        self.assertIn("YOUR LAST 34 DAYS IN CLAUDE CODE", html)
        self.assertNotIn("YOUR 2026", html)


class TestPrivacy(Base):
    def setUp(self):
        super().setUp()
        self.c = standard_fixture(self.logs)

    def leaks(self, text):
        return [k for k, v in self.c.items() if v in text]

    def test_the_detector_can_fail(self):
        # a deliberately leaking text is caught, so a pass below means something
        self.assertEqual(self.leaks("x " + self.c["email"] + " y"), ["email"])

    def test_no_canary_reaches_the_card_the_terminal_or_the_error_stream(self):
        code, out, err = run_tool(["--logs", str(self.logs), "--out", str(self.card)])
        self.assertEqual(code, 0)
        everything = self.card.read_text() + out + err
        self.assertEqual(self.leaks(everything), [])

    def test_unknown_fields_with_canaries_do_not_reach_the_card(self):
        junk = {"zqExtra": self.c["keyshape"], "message_note": self.c["prompt"]}
        shutil_logs = pathlib.Path(self.tmp.name) / "p2"
        shutil_logs.mkdir()
        c2 = standard_fixture(shutil_logs, junk=junk)
        code, out, err = run_tool(["--logs", str(shutil_logs), "--out", str(self.card)])
        self.assertEqual(code, 0)
        text = self.card.read_text() + out + err
        self.assertEqual([k for k, v in c2.items() if v in text], [])

    def test_a_custom_model_id_is_shown_as_other(self):
        run_tool(["--logs", str(self.logs), "--out", str(self.card)])
        text = self.card.read_text()
        self.assertIn("other", text)
        self.assertNotIn(self.c["arn"], text)


class TestCardIsInert(Base):
    def setUp(self):
        super().setUp()
        standard_fixture(self.logs)
        run_tool(["--logs", str(self.logs), "--out", str(self.card)])
        self.html = self.card.read_text()

    def test_no_script_no_external_load_no_link(self):
        low = self.html.lower()
        for bad in ("<script", " src=", "url(", "@import", "<link", "<iframe", "<a ", "<img", "http://", "https://", "<form", "onload", "onclick"):
            self.assertNotIn(bad, low, bad)

    def test_a_content_security_policy_forbids_everything(self):
        self.assertIn("Content-Security-Policy", self.html)
        self.assertIn("default-src 'none'", self.html)

    def test_the_footer_has_the_address_once_as_text_and_the_not_by_anthropic_line(self):
        self.assertEqual(self.html.count("sunglasses.dev/warroom"), 1)
        self.assertIn("Made with Warroom, a free tool. Not made or endorsed by Anthropic.", self.html)

    def test_the_card_is_one_block_of_a_fixed_size(self):
        self.assertEqual(self.html.count('class="card"'), 1)
        self.assertIn("width:", self.html)

    def test_the_card_is_dark(self):
        self.assertIn("#0f1115", self.html)

    def test_the_card_does_not_use_another_apps_recap_name(self):
        self.assertNotIn("wrapped", self.html.lower())


class TestNothingLeavesTheMachine(Base):
    def test_the_tool_imports_only_what_the_list_allows(self):
        allowed = {"argparse", "collections", "datetime", "html", "json", "os", "pathlib", "re", "sys", "time"}
        tree = ast.parse(TOOL.read_text())
        seen = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                seen |= {a.name.split(".")[0] for a in node.names}
            elif isinstance(node, ast.ImportFrom):
                seen.add((node.module or "").split(".")[0])
        self.assertEqual(seen - allowed, set(), seen - allowed)

    def test_the_tool_has_no_dynamic_import_no_eval_no_exec(self):
        tree = ast.parse(TOOL.read_text())
        names = {n.func.id for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)}
        self.assertEqual(names & {"__import__", "eval", "exec", "compile"}, set())

    def test_the_tool_makes_one_file_and_only_through_the_one_call(self):
        tree = ast.parse(TOOL.read_text())
        opens = [n for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == "open"]
        attrs = {n.attr for n in ast.walk(tree) if isinstance(n, ast.Attribute)}
        self.assertEqual(len(opens), 1)          # the card; log files are read with Path.open
        self.assertEqual(attrs & {"write_text", "write_bytes", "mkdir", "touch", "unlink", "rename", "remove", "rmdir"}, set())
        os_uses = {n.attr for n in ast.walk(tree) if isinstance(n, ast.Attribute) and isinstance(n.value, ast.Name) and n.value.id == "os"}
        self.assertEqual(os_uses, {"environ"})

    def test_the_tool_finishes_with_every_network_call_refusing(self):
        standard_fixture(self.logs)

        def refuse(*a, **k):
            raise AssertionError("network call attempted")
        with mock.patch.object(socket.socket, "connect", refuse), mock.patch.object(socket, "getaddrinfo", refuse), \
                mock.patch.object(socket, "create_connection", refuse), mock.patch.object(socket.socket, "sendto", refuse):
            code, out, err = run_tool(["--logs", str(self.logs), "--out", str(self.card)])
        self.assertEqual(code, 0)
        self.assertTrue(self.card.exists())

    def test_the_network_refusal_works_on_a_deliberate_attempt(self):
        def refuse(*a, **k):
            raise AssertionError("network call attempted")
        with mock.patch.object(socket, "getaddrinfo", refuse):
            with self.assertRaises(AssertionError):
                socket.getaddrinfo("localhost", 80)


class TestWrites(Base):
    def tree(self, root):
        return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.rglob("*")) if p.is_file()}

    def test_the_run_writes_the_card_and_nothing_else_and_leaves_the_logs_as_they_were(self):
        standard_fixture(self.logs)
        before_logs, before_work = self.tree(self.logs), self.tree(self.work)
        code, _, _ = run_tool(["--logs", str(self.logs), "--out", str(self.card)])
        self.assertEqual(code, 0)
        self.assertEqual(self.tree(self.logs), before_logs)
        after = self.tree(self.work)
        self.assertEqual(set(after) - set(before_work), {"card.html"})

    def test_the_run_works_when_the_log_folder_cannot_be_written(self):
        standard_fixture(self.logs)
        dirs = [self.logs] + [p for p in self.logs.rglob("*") if p.is_dir()]
        for d in dirs:
            d.chmod(stat.S_IRUSR | stat.S_IXUSR)
        try:
            code, _, _ = run_tool(["--logs", str(self.logs), "--out", str(self.card)])
        finally:
            for d in dirs:
                d.chmod(stat.S_IRWXU)
        self.assertEqual(code, 0)

    def test_an_existing_card_is_not_replaced_without_the_flag(self):
        standard_fixture(self.logs)
        self.card.write_text("mine")
        code, _, err = run_tool(["--logs", str(self.logs), "--out", str(self.card)])
        self.assertEqual(code, 2)
        self.assertEqual(self.card.read_text(), "mine")
        code, _, _ = run_tool(["--logs", str(self.logs), "--out", str(self.card), "--force"])
        self.assertEqual(code, 0)
        self.assertIn("card", self.card.read_text())


class TestFormatDrift(Base):
    def test_garbage_lines_are_skipped_counted_and_the_card_still_builds(self):
        standard_fixture(self.logs)
        p = next(self.logs.rglob("second.jsonl"))
        p.write_text(p.read_text() + "not json at all\n{broken\n[1,2]\n" + line(type="user", timestamp="not a time", sessionId="x") + "\n")
        code, out, err = run_tool(["--logs", str(self.logs), "--out", str(self.card)])
        self.assertEqual(code, 0)
        self.assertIn("skipped 4", out + err)
        self.assertTrue(self.card.exists())

    def test_an_unknown_record_type_is_not_an_error(self):
        standard_fixture(self.logs)
        p = next(self.logs.rglob("second.jsonl"))
        p.write_text(p.read_text() + line(type="some-new-kind", timestamp="2026-03-04T10:00:00Z", sessionId="n") + "\n")
        code, out, err = run_tool(["--logs", str(self.logs), "--out", str(self.card)])
        self.assertEqual(code, 0)

    def test_no_usable_record_exits_2_says_the_format_may_have_changed_and_writes_no_card(self):
        d = self.logs / "p"
        d.mkdir()
        (d / "x.jsonl").write_text("garbage\n" + line(type="pr-link", prUrl="x") + "\n")
        code, out, err = run_tool(["--logs", str(self.logs), "--out", str(self.card)])
        self.assertEqual(code, 2)
        self.assertIn("format may have changed", out + err)
        self.assertFalse(self.card.exists())

    def test_a_line_over_the_size_limit_is_skipped_counted_and_the_lines_after_it_are_still_read(self):
        standard_fixture(self.logs)
        p = next(self.logs.rglob("second.jsonl"))
        huge = line(type="user", timestamp="2026-03-03T15:00:00Z", sessionId="big", message={"role": "user", "content": "x" * (yearcard.MAX_LINE + 10)})
        p.write_text(p.read_text() + huge + "\n" + asst("2026-03-03T15:00:10Z", "sess-two", "m9", "r9", "claude-sample-mid", 9) + "\n")
        code, out, err = run_tool(["--logs", str(self.logs), "--out", str(self.card)])
        self.assertEqual(code, 0)
        self.assertIn("skipped 1", out + err)
        self.assertIn("replies 6", out + err)


class TestHints(Base):
    def test_a_short_span_prints_the_retention_hint_and_a_long_one_does_not(self):
        standard_fixture(self.logs)
        _, out, err = run_tool(["--logs", str(self.logs), "--out", str(self.card)])
        self.assertIn("cleanupPeriodDays", out + err)
        longp = self.logs / "long"
        longp.mkdir()
        (longp / "y.jsonl").write_text("\n".join([user("2025-01-02T10:00:00Z", "z"), asst("2026-03-02T10:00:00Z", "z", "m", "r", "claude-sample-large", 1)]) + "\n")
        self.card.unlink()
        _, out2, err2 = run_tool(["--logs", str(longp), "--out", str(self.card)])
        self.assertNotIn("cleanupPeriodDays", out2 + err2)


class TestSpeed(Base):
    def test_a_large_tree_is_read_in_bounded_time_and_memory_free_of_the_content(self):
        d = self.logs / "big"
        d.mkdir()
        rows = []
        for i in range(20000):
            rows.append(asst("2026-03-02T10:%02d:%02dZ" % (i // 60 % 60, i % 60), "s%d" % (i % 50), "m%d" % i, "r%d" % i, "claude-sample-large", 3,
                             extra={"cwd": "x" * 400}))
        (d / "big.jsonl").write_text("\n".join(rows) + "\n")
        t = time.perf_counter()
        code, _, _ = run_tool(["--logs", str(self.logs), "--out", str(self.card)])
        self.assertEqual(code, 0)
        self.assertLess(time.perf_counter() - t, 30)


if __name__ == "__main__":
    unittest.main()
