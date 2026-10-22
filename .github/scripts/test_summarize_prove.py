#!/usr/bin/env python3
"""Regression checks for the serial prove-log summary boundary."""
import os
from pathlib import Path
import unittest

from summarize_prove import summarize


class ProveSummaryTests(unittest.TestCase):
    def test_collapsed_file_skip_preserves_reason_and_zero_counts(self):
        result = summarize(
            "grpc_early_hints.t ............ skipped: no http_v3 available\n"
            "Files=1, Tests=0, 0 wallclock secs\nResult: NOTESTS\n")
        row = result["results"][0]
        self.assertEqual((row["result"], row["planned"], row["seen"]),
                         ("SKIP", 0, 0))
        self.assertTrue(row["skip_all"])
        self.assertEqual(row["skip_reason"], "no http_v3 available")

    def test_collapsed_skip_does_not_reuse_previous_record(self):
        result = summarize(
            "grpc.t ..\n1..1\nok 1 - response\nok\n"
            "grpc_trailers.t ............... skipped: no http_v3 available\n"
            "Dubious, ignored formatter noise after the completed skip\n"
            "proxy_h2.t ..\n1..1\nok 1 - response\nok\n"
            "Files=3, Tests=2, 0 wallclock secs\nResult: PASS\n")
        self.assertEqual([row["result"] for row in result["results"]],
                         ["PASS", "SKIP", "PASS"])
        self.assertEqual([row["seen"] for row in result["results"]], [1, 0, 1])

    def test_bare_formatter_ok_is_not_an_assertion(self):
        result = summarize("a.t ..\n1..1\nok 1 - works\nok\n"
                           "Files=1, Tests=1, 0 wallclock secs\nResult: PASS\n")
        self.assertEqual(result["results"][0]["seen"], 1)

    def test_counts_assertion_skips_separately_from_skipped_files(self):
        result = summarize(
            "a.t ..\n1..2\nok 1 - works\nok 2 # skip long test\nok\n"
            "b.t ........ skipped: no module\n"
            "Files=2, Tests=2, 0 wallclock secs\nResult: PASS\n")
        self.assertEqual((result["skipped_assertions"], result["skipped_files"]),
                         (1, 1))

    def test_todo_failure_is_not_a_real_failure(self):
        result = summarize("a.t ..\n1..1\nnot ok 1 # TODO pending\nok\n"
                           "Files=1, Tests=1, 0 wallclock secs\nResult: PASS\n")
        row = result["results"][0]
        self.assertEqual((row["failed"], row["todo"], row["result"]), (0, 1, "PASS"))

    def test_failed_assertion_marks_file_failed(self):
        result = summarize("a.t ..\n1..1\nnot ok 1 - broken\n"
                           "Files=1, Tests=1, 0 wallclock secs\nResult: FAIL\n")
        self.assertEqual(result["results"][0]["result"], "FAIL")

    def test_harness_failure_after_successful_assertions_marks_file_failed(self):
        result = summarize("a.t ..\n1..1\nok 1\nDubious, test returned 1\n"
                           "Files=1, Tests=1, 0 wallclock secs\nResult: FAIL\n")
        self.assertEqual(result["results"][0]["result"], "FAIL")

    def test_expanded_skip_plan_retains_reason(self):
        result = summarize("a.t ..\n1..0 # SKIP no module\nskipped: no module\n"
                           "Files=1, Tests=0, 0 wallclock secs\nResult: NOTESTS\n")
        self.assertEqual(result["results"][0]["skip_reason"], "no module")
        self.assertEqual(result["skipped_files"], 1)

    def test_skip_plan_with_assertion_is_not_reported_as_skipped(self):
        result = summarize("a.t ..\n1..0 # SKIP no module\nok 1\n"
                           "Files=1, Tests=1, 0 wallclock secs\nResult: FAIL\n")
        self.assertEqual(result["results"][0]["result"], "FAIL")
        self.assertEqual(result["skipped_files"], 0)

    def test_missing_assertion_marks_file_failed(self):
        result = summarize("a.t ..\n1..2\nok 1\n"
                           "Files=1, Tests=1, 0 wallclock secs\nResult: FAIL\n")
        self.assertEqual(result["results"][0]["result"], "FAIL")

    def test_file_count_mismatch_rejects_partial_summary(self):
        with self.assertRaisesRegex(ValueError, "file count"):
            summarize("a.t ..\n1..1\nok 1\n"
                      "Files=2, Tests=1, 0 wallclock secs\nResult: PASS\n")

    def test_assertion_count_mismatch_rejects_partial_summary(self):
        with self.assertRaisesRegex(ValueError, "test count"):
            summarize("a.t ..\n1..1\nok 1\n"
                      "Files=1, Tests=2, 0 wallclock secs\nResult: PASS\n")

    def test_missing_totals_rejects_partial_log(self):
        with self.assertRaises(ValueError):
            summarize("a.t ..\n1..1\nok 1\n")


@unittest.skipUnless(os.environ.get("FAIRNESS_NATIVE_LOG_DIR"),
                     "Optional native logs were not provided")
class NativeLogTests(unittest.TestCase):
    def test_actual_h2_log(self):
        self.check_log("native-h2-suite.log", 36, 942, 26, 0)

    def test_actual_related_log(self):
        self.check_log("native-h2-related-suite.log", 22, 455, 1, 2)

    def check_log(self, filename, files, tests, assertion_skips, file_skips):
        text = (Path(os.environ["FAIRNESS_NATIVE_LOG_DIR"]) / filename).read_text(
            errors="replace")
        result = summarize(text)
        self.assertEqual((result["files"], result["tests"]), (files, tests))
        self.assertEqual(result["skipped_assertions"], assertion_skips)
        self.assertEqual(result["skipped_files"], file_skips)
        self.assertFalse(any(row["result"] == "FAIL" for row in result["results"]))


if __name__ == "__main__":
    unittest.main()
