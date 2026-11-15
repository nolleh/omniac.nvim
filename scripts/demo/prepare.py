#!/usr/bin/env python3
"""Create a fresh demo take, or launch it in the current terminal."""

import argparse
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--launch", action="store_true", help="Open Neovim after preparation")
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    if args.launch:
        for command in ("nvim", "codex-acp"):
            if not shutil.which(command):
                parser.error(f"{command} is missing from PATH")

    take = Path(tempfile.mkdtemp(prefix="omniac-main-demo-")).resolve()
    project = take / "taskboard"
    agent_cwd = take / "agent-workspace"
    agent_cwd.mkdir()
    shutil.copytree(here / "project", project)
    subprocess.run([sys.executable, "-B", "-m", "unittest", "-v"], cwd=project, check=True)
    command = ["nvim", "-n", "-i", "NONE", "-u", str(here / "init.lua"), "task_summary.py"]
    print(f"\nFresh take: {take}", flush=True)
    print("\nLaunch from a kitty terminal:", flush=True)
    print(f"cd {shlex.quote(str(project))}", flush=True)
    print(
        f"OMNIAC_DEMO_AGENT_CWD={shlex.quote(str(agent_cwd))} {shlex.join(command)}",
        flush=True,
    )
    print("\nAfter the demo, verify the reviewed result:", flush=True)
    print(shlex.join([sys.executable, "-B", str(here / "verify.py"), str(project)]), flush=True)
    if args.launch:
        os.chdir(project)
        env = dict(os.environ, OMNIAC_DEMO_AGENT_CWD=str(agent_cwd))
        os.execvpe(command[0], command, env)


if __name__ == "__main__":
    main()
