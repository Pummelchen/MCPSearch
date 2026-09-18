#!/usr/bin/env python3
"""Tests for the harnesses that no Swift test can reach.

The Swift suite covers the server; the Python harnesses drive it, and two of them had no
test anywhere. `soak.py`'s run verdicts are asserted by a CI step, but
nothing exercised its argument parsing, its dotenv parser or its credential-leak scan, and
`searxng_health.py` had no test at all — it was reachable only by pointing it at a live
instance. This module drives both, and additionally asserts the one contract that crosses
the two languages: the provider environment scrub list in `mcp_smoke.py` must be the same
list as `ServerTestSupport.providerEnvironmentVariables` in the Swift tests, because a
drift leaves a developer's exported API key visible to the child process the smoke test
believes it scrubbed.

The stub SearXNG server is a real loopback HTTP server on an ephemeral port, so the
classification path (`probe` -> exit code) is exercised end to end rather than around.

Usage:
    python3 scripts/harness_tests.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = REPOSITORY_ROOT / "scripts"


def load_script(name: str) -> types.ModuleType:
    """Import a sibling script by path, since `scripts/` is not a package."""
    path = SCRIPTS / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


searxng_health = load_script("searxng_health")
# One stub, shared with `dual_client_contract.py`: that harness needs the same scripted
# instance to point both executables at, and a test module is the wrong place for a server
# to live.
StubSearXNG = load_script("searxng_stub").StubSearXNG


def run_main(module: types.ModuleType, argv: list[str]) -> tuple[int, str]:
    """Call `module.main()` with `argv` and return its status and stdout.

    `main` writes to stdout through `print`, so stdout is captured rather than the
    process's; `main` is the seam the CLI itself uses, which keeps the test on the
    argument parsing rather than on the process boundary.
    """
    original = sys.argv
    sys.argv = [f"{module.__name__}.py", *argv]
    buffer = io.StringIO()
    try:
        with contextlib.redirect_stdout(buffer):
            status = module.main()
    finally:
        sys.argv = original
    return status, buffer.getvalue()


class SearXNGHealthTests(unittest.TestCase):
    """`searxng_health.py`, whose classification logic had no test before this."""

    def test_healthy_instance_is_reporting_zero(self) -> None:
        stub = StubSearXNG(
            payload=json.dumps(
                {
                    "results": [
                        {"engine": "google", "title": "a"},
                        {"engines": ["brave", "google"], "title": "b"},
                    ],
                    "unresponsive_engines": [["duckduckgo", "CAPTCHA"]],
                }
            )
        )
        try:
            status, output = run_main(searxng_health, [stub.base_url, "--json"])
        finally:
            stub.close()
        self.assertEqual(status, 0, output)
        report = json.loads(output)
        self.assertTrue(report["healthy"])
        self.assertEqual(report["result_count"], 2)
        # `engines` and `engine` are both counted, and google appears in both results.
        self.assertEqual(report["engines"], {"google": 2, "brave": 1})
        self.assertEqual(report["unresponsive_engines"], [["duckduckgo", "CAPTCHA"]])

    def test_403_is_json_disabled_and_exit_one(self) -> None:
        stub = StubSearXNG(status=403, payload="Forbidden")
        try:
            status, output = run_main(searxng_health, [stub.base_url, "--json"])
        finally:
            stub.close()
        self.assertEqual(status, 1, output)
        self.assertEqual(json.loads(output)["reason"], "json_disabled")

    def test_200_with_no_results_is_unhealthy_but_reachable(self) -> None:
        stub = StubSearXNG(payload=json.dumps({"results": [], "unresponsive_engines": []}))
        try:
            status, output = run_main(searxng_health, [stub.base_url, "--json"])
        finally:
            stub.close()
        # The instance answered, so the run reached the classification and the verdict is
        # "unhealthy", not "unreachable": exit 1 rather than 2.
        self.assertEqual(status, 1, output)
        report = json.loads(output)
        self.assertFalse(report["healthy"])
        self.assertEqual(report["result_count"], 0)

    def test_non_json_200_is_an_unexpected_response(self) -> None:
        stub = StubSearXNG(payload="<html>not searxng</html>")
        try:
            status, output = run_main(searxng_health, [stub.base_url, "--json"])
        finally:
            stub.close()
        self.assertEqual(status, 1, output)
        report = json.loads(output)
        self.assertEqual(report["reason"], "unexpected_response")
        self.assertEqual(report["status"], 200)

    def test_closed_port_is_unreachable_and_exit_two(self) -> None:
        # Bind and release a port so the address is certainly not listening.
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            host, port = probe.getsockname()
        status, output = run_main(searxng_health, [f"http://{host}:{port}", "--json"])
        self.assertEqual(status, 2, output)
        self.assertEqual(json.loads(output)["reason"], "unreachable")

    def test_a_non_http_url_is_refused_rather_than_opened(self) -> None:
        # `urlopen` supports `file://`, so the scheme is asserted before anything is opened.
        # The refusal is a usage error: exit 2, not a traceback.
        status, output = run_main(searxng_health, ["file:///etc/passwd", "--json"])
        self.assertEqual(status, 2, output)
        self.assertEqual(json.loads(output)["reason"], "invalid_url")

    def test_human_output_names_the_unavailable_engine(self) -> None:
        stub = StubSearXNG(
            payload=json.dumps(
                {
                    "results": [{"engine": "google"}],
                    "unresponsive_engines": [["duckduckgo", "CAPTCHA"], ["only-one"]],
                }
            )
        )
        try:
            status, output = run_main(searxng_health, [stub.base_url])
        finally:
            stub.close()
        self.assertEqual(status, 0, output)
        self.assertIn("HEALTHY", output)
        self.assertIn("duckduckgo: CAPTCHA", output)
        # A one-element pair has no reason to print and must not crash the report.
        self.assertNotIn("only-one", output)


class SoakArgumentTests(unittest.TestCase):
    """`soak.py`'s argument parsing and credential scan, which nothing drove before this."""

    def setUp(self) -> None:
        self.soak = load_script("soak")

    def test_help_documents_every_flag(self) -> None:
        finished = subprocess.run(
            [sys.executable, str(SCRIPTS / "soak.py"), "--help"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(finished.returncode, 0, finished.stderr)
        for flag in ("--queries", "--mode", "--pause", "--providers", "--max-results"):
            self.assertIn(flag, finished.stdout)

    def test_a_non_positive_query_count_is_a_usage_error(self) -> None:
        # `QUERIES[:0]` starts nothing and `QUERIES[:-3]` silently runs 47 of 50, so both are
        # refused before the run rather than run as a soak nobody asked for.
        for value in ("0", "-3"):
            finished = subprocess.run(
                [sys.executable, str(SCRIPTS / "soak.py"), "--queries", value, "/nonexistent"],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(finished.returncode, 2, value)
            self.assertIn("--queries must be positive", finished.stderr)

    def test_a_missing_binary_is_reported_not_crashed(self) -> None:
        finished = subprocess.run(
            [sys.executable, str(SCRIPTS / "soak.py"), "--queries", "1", "/nonexistent/binary"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(finished.returncode, 2)
        self.assertIn("binary not found", finished.stderr)

    def test_dotenv_parser_matches_the_server(self) -> None:
        contents = """
            # a comment
            export TAVILY_API_KEY=tvly-value

            QUOTED="a b"
            SINGLE='c d'
            EMPTY=
            MALFORMED
        """
        parsed = self.soak.parse_dotenv(contents)
        self.assertEqual(parsed["TAVILY_API_KEY"], "tvly-value")
        self.assertEqual(parsed["QUOTED"], "a b")
        self.assertEqual(parsed["SINGLE"], "c d")
        self.assertNotIn("EMPTY", parsed, "a key with no value is not a setting")
        self.assertNotIn("MALFORMED", parsed)

    def test_the_credential_scan_finds_markers_and_values(self) -> None:
        secrets = {"TAVILY_API_KEY": "tvly-abcdefghijklmnop", "SHORT": "abc"}
        found = self.soak.find_credential_leaks(
            "request failed: Bearer tvly-abcdefghijklmnop", secrets
        )
        self.assertIn("Bearer ", found)
        self.assertIn("TAVILY_API_KEY value", found)
        # A short value is a false-positive machine and is deliberately not matched.
        self.assertEqual(self.soak.find_credential_leaks("abc", secrets), [])

    def test_clean_stderr_reports_no_leak(self) -> None:
        self.assertEqual(
            self.soak.find_credential_leaks("server started, 0 providers configured", {}),
            [],
        )

    def test_load_secret_values_reads_a_config_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "named" / "config.env"
            config.parent.mkdir()
            config.write_text("TAVILY_API_KEY=tvly-fromfile\nBRAVE_SEARCH_API_KEY=b-fromfile\n")
            # The repository-root fallback is pointed at an empty directory. `load_secret_values`
            # reads the developer's own config.env by design, so without this the assertion below
            # about an absent key passes in CI and fails on any machine that has one (ledger A0025).
            empty_root = Path(directory) / "no-config-here"
            empty_root.mkdir()
            # A credential already exported must not win over the file for a variable the file
            # does define, and a variable neither names must stay absent. `patch.dict` is used
            # rather than assigning `os.environ`, which Ruff correctly flags as a non-clearing
            # replacement of the process environment.
            with mock.patch.dict(
                os.environ,
                {"SEARCH_CONFIG_FILE": str(config)},
                clear=False,
            ):
                for name in self.soak.SECRET_VARIABLES:
                    os.environ.pop(name, None)
                values = self.soak.load_secret_values(repository_root=str(empty_root))
            self.assertEqual(values["TAVILY_API_KEY"], "tvly-fromfile")
            self.assertEqual(values["BRAVE_SEARCH_API_KEY"], "b-fromfile")
            self.assertNotIn("MOJEEK_API_KEY", values)


class SoakSemanticsTests(unittest.TestCase):
    """`soak.py`'s own provider selection and verdicts.

    These were two heredocs inside `ci.yml`, asserting the harness's behaviour in the job that
    happened to have the file to hand. That made them invisible to `tools/release.sh`, which runs
    this module and does not read CI's steps — so the release gate checked less than CI did. They
    are tests of a harness, which is what this module is for, and moving them here means both run
    them.
    """

    def test_provider_selection_is_authoritative(self) -> None:
        # An ambient SEARCH_DISABLED_PROVIDERS must not keep a requested provider switched off,
        # and requesting everything must clear the ambient list rather than leave it in place.
        soak = load_script("soak")
        # Patched rather than assigned: this runs in the test process, unlike the heredoc it
        # replaces, so the ambient environment has to be put back afterwards.
        with mock.patch.dict(os.environ, {"SEARCH_DISABLED_PROVIDERS": "tavily"}):
            environment = soak.build_environment({"tavily", "brave"})
            disabled = environment["SEARCH_DISABLED_PROVIDERS"].split(",")
            self.assertNotIn("tavily", disabled)
            self.assertIn("mojeek", disabled)

            every = soak.build_environment(set(soak.ALL_PROVIDERS))
            self.assertEqual(every["SEARCH_DISABLED_PROVIDERS"], "")

            only_brave = soak.build_environment({"brave"})
            self.assertIn("tavily", only_brave["SEARCH_DISABLED_PROVIDERS"].split(","))

    def test_run_verdicts_are_enforced(self) -> None:
        # A requested provider that never contributed makes the soak describe a different run from
        # the one in its header, which the harness treats as a failure.
        soak = load_script("soak")
        self.assertEqual(soak.silent_providers({"tavily", "brave"}, {"tavily": 5, "brave": 3}), [])
        self.assertEqual(soak.silent_providers({"tavily", "brave"}, {"tavily": 5}), ["brave"])
        self.assertEqual(soak.silent_providers({"tavily", "brave"}, {}), ["brave", "tavily"])

        clean = {"tavily": 5, "brave": 3}
        self.assertIsNone(soak.run_verdict(5, 0, {"tavily", "brave"}, clean))
        self.assertEqual(soak.run_verdict(5, 5, {"tavily", "brave"}, clean), "every query errored")
        silent = soak.run_verdict(5, 0, {"tavily", "brave"}, {"tavily": 5})
        self.assertIsNotNone(silent)
        self.assertIn("brave", silent or "")


class ScrubListContractTests(unittest.TestCase):
    """The one contract that crosses the two languages."""

    def test_the_python_and_swift_scrub_lists_are_the_same_set(self) -> None:
        smoke = load_script("mcp_smoke")
        swift = (REPOSITORY_ROOT / "Tests" / "WebSearchCoreTests" / "TestSupport.swift").read_text(
            encoding="utf-8"
        )
        start = swift.index("static let providerEnvironmentVariables")
        end = swift.index("]", start)
        in_swift = set(re.findall(r'"([A-Z][A-Z0-9_]*)"', swift[start:end]))
        # `swift` here is the source of truth, so a missing marker is a broken test rather
        # than a passing one.
        self.assertGreaterEqual(len(in_swift), 10, sorted(in_swift))
        in_python = set(smoke.SCRUBBED_VARIABLES)

        self.assertEqual(
            in_python - in_swift,
            set(),
            "scripts/mcp_smoke.py scrubs variables the Swift harnesses do not: "
            "update ServerTestSupport.providerEnvironmentVariables in the same commit",
        )
        self.assertEqual(
            in_swift - in_python,
            set(),
            "ServerTestSupport.providerEnvironmentVariables names variables "
            "scripts/mcp_smoke.py does not scrub: the smoke test would then pass a "
            "developer's exported key through to the child it believes it scrubbed",
        )

    def test_the_swift_side_is_reachable_at_all(self) -> None:
        # Guard the parser above: if the file is renamed or the declaration becomes a
        # `let` with a different name, the two `index()` calls raise and the contract
        # errors instead of silently comparing empty sets.
        smoke = load_script("mcp_smoke")
        self.assertTrue(smoke.SCRUBBED_VARIABLES, "the Python scrub list is empty")


class DualClientContractTests(unittest.TestCase):
    """The runtime contract, seen from outside: it must not pass or crash vacuously.

    What it *asserts* is exercised by whether it can fail — it runs against real binaries in CI
    and in the release gate, where a regression surfaces as a failure. What is checked here is the
    shape of its own failure when the build it needs is not there.
    """

    def test_a_missing_binary_directory_is_reported_not_crashed(self) -> None:
        finished = subprocess.run(
            [sys.executable, str(SCRIPTS / "dual_client_contract.py"), "/nonexistent/bin"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(finished.returncode, 1)
        self.assertIn("no binary at", finished.stderr)


def main() -> int:
    suite = unittest.TestSuite()
    loader = unittest.TestLoader()
    for case in (
        SearXNGHealthTests,
        SoakArgumentTests,
        ScrubListContractTests,
        SoakSemanticsTests,
        DualClientContractTests,
    ):
        suite.addTests(loader.loadTestsFromTestCase(case))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if result.wasSuccessful():
        print("harness tests passed")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
