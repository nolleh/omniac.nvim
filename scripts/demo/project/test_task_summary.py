"""Existing behavior to preserve during the demo."""

import unittest

from task_summary import summarize_tasks


class TaskSummaryTests(unittest.TestCase):
    def test_two_tasks(self):
        self.assertEqual(
            summarize_tasks(["Write docs", "Fix tests"]),
            "2 tasks: Write docs, Fix tests",
        )

    def test_preserves_order(self):
        self.assertEqual(
            summarize_tasks(["Ship release", "Review changes"]),
            "2 tasks: Ship release, Review changes",
        )

    def test_does_not_modify_input(self):
        tasks = ["Write docs", "Fix tests"]
        summarize_tasks(tasks)
        self.assertEqual(tasks, ["Write docs", "Fix tests"])


if __name__ == "__main__":
    unittest.main()
