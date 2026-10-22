#!/usr/bin/env python3
"""Fail-closed source/test transformations and targeted mutation verdict."""
import unittest

from compare_fairness import (BARRIER, COMPARATOR, mutant_killed, private_test,
                              replace_once, source_mutation)


class ComparisonTests(unittest.TestCase):
    def test_fifo_changes_only_last_comparator_return(self):
        self.assertEqual(source_mutation("fifo", "before\n" + COMPARATOR + "\nafter"),
                         "before\n    return 1;\nafter")

    def test_incremental_preserves_id_order_for_non_incremental_peers(self):
        self.assertEqual(source_mutation("incremental", COMPARATOR),
                         "    return a->incremental || s->node->id <= stream->node->id;")

    def test_mutant_changes_only_posted_barrier_term(self):
        self.assertEqual(source_mutation("without-posted-barrier", "prefix " + BARRIER + " suffix"),
                         "prefix stream->queued suffix")

    def test_replacement_rejects_missing_or_multiple_matches(self):
        for text in ("missing", BARRIER + BARRIER):
            with self.subTest(text=text), self.assertRaises(ValueError):
                replace_once(text, BARRIER, "stream->queued")

    def test_baseline_strips_only_literal_directives_and_adds_diagnostics(self):
        original = ("http2_fair_scheduling on;\n  http2_fair_scheduling off;\n"
                    "\thttp2_fair_scheduling off;\n# http2_fair_scheduling on;\n"
                    "\tmy @bytes = sort { $a <=> $b } map { $bytes{$_} || 0 } @$ids;")
        result = private_test(original, "h2_fair_scheduling.t", True)
        self.assertIn("# http2_fair_scheduling on;", result)
        self.assertNotIn("\n  http2_fair_scheduling", result)
        self.assertIn("FAIRNESS_BYTES static label=$name budget=$budget", result)

    def test_changed_directive_shape_is_rejected(self):
        with self.assertRaises(ValueError):
            private_test("http2_fair_scheduling on;\n", "h2_fair_scheduling.t", True)

    def test_targeted_proxy_assertion_failure_kills_mutant(self):
        for number, kind in ((4, "length"), (10, "chunked")):
            self.assertTrue(mutant_killed(
                f"not ok {number} - {kind} synchronous producer bounded service\n"))

    def test_other_failures_or_passing_targets_do_not_kill_mutant(self):
        for text in ("not ok 5 - length complete payload integrity\n",
                     "ok 4 - length synchronous producer bounded service\n",
                     "not ok 4 - different assertion\n"):
            self.assertFalse(mutant_killed(text))


if __name__ == "__main__":
    unittest.main()
