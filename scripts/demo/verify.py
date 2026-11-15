#!/usr/bin/env python3
"""Check the real file after the reviewed edit has been applied."""

import argparse
import importlib.util
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path, help="The disposable taskboard directory")
    args = parser.parse_args()
    project = args.project.resolve()
    subprocess.run([sys.executable, "-B", "-m", "unittest", "-v"], cwd=project, check=True)
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("demo_task_summary", project / "task_summary.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    summarize = module.summarize_tasks
    cases = [
        ([], "Nothing pending."),
        (["Write docs"], "1 task: Write docs"),
        (["Write docs", "Fix tests"], "2 tasks: Write docs, Fix tests"),
        (["Write docs", "Fix tests", "Review changes", "Ship release"],
         "4 tasks: Write docs, Fix tests, +2 more"),
    ]
    for tasks, expected in cases:
        original = tasks.copy()
        actual = summarize(tasks)
        if actual != expected or tasks != original:
            raise SystemExit(f"FAIL: {original!r}: got {actual!r}; expected {expected!r}; input now {tasks!r}")
        print(f"PASS: {actual}")
    print("Reviewed content is on disk; order and input are preserved.")


if __name__ == "__main__":
    main()
