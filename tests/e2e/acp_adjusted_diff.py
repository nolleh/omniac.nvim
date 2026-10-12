"""Live codex-acp probe for prompt -> rejected edit -> follow-up prompt -> end_turn.

Run manually with `python3 tests/e2e/acp_adjusted_diff.py`. This starts a real
agent and may consume model quota. Test files live in a temporary sibling of
this repository so workspace-write mode requests approval. They are removed
when the process exits normally.
"""

import json
import os
import select
import subprocess
import tempfile
import time
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]

with tempfile.TemporaryDirectory(
    prefix=".omniac-acp-flow-",
    dir=REPO.parent,
) as test_root:
    workdir = str(REPO)
    targets = os.path.join(test_root, "targets")
    os.mkdir(targets)
    first = os.path.join(targets, "first.txt")
    second = os.path.join(targets, "second.txt")
    with open(first, "w") as out:
        out.write("first=old\n")
    with open(second, "w") as out:
        out.write("second=old\n")

    proc = subprocess.Popen(
        ["codex-acp"], cwd=workdir, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, bufsize=0,
    )
    buffer = b""
    proposals = {}
    rejected_batch = False
    approved_followup = 0
    turn = 0
    agent_text = []
    reviewed = {first: "first=reviewed\n", second: "second=proposed\n"}

    def send(message):
        proc.stdin.write((json.dumps(message) + "\n").encode())
        proc.stdin.flush()

    def receive(deadline):
        global buffer
        while time.monotonic() < deadline:
            if b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                return json.loads(line)
            ready, _, _ = select.select([proc.stdout], [], [], min(1, deadline - time.monotonic()))
            if ready:
                chunk = os.read(proc.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError(f"agent stdout closed, exit={proc.poll()}")
                buffer += chunk
        raise TimeoutError("ACP response timed out")

    def request(request_id, method, params, timeout=120):
        global rejected_batch, approved_followup
        send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        while True:
            message = receive(deadline)
            if message.get("id") == request_id and ("result" in message or "error" in message):
                result = message.get("result") or {}
                print(json.dumps({"event": "prompt_response" if method == "session/prompt" else method,
                                  "turn": turn, "stopReason": result.get("stopReason"),
                                  "error": message.get("error")}, ensure_ascii=False), flush=True)
                return message
            if message.get("method") == "session/update":
                update = message.get("params", {}).get("update", {})
                if update.get("sessionUpdate") == "agent_message_chunk":
                    content = update.get("content") or {}
                    if isinstance(content, dict):
                        agent_text.append(content.get("text", ""))
                if update.get("sessionUpdate") in ("tool_call", "tool_call_update"):
                    if update.get("sessionUpdate") == "tool_call":
                        print(json.dumps({"event": "tool_call", "kind": update.get("kind"), "title": update.get("title"),
                                          "status": update.get("status"), "toolCallId": update.get("toolCallId")}, ensure_ascii=False), flush=True)
                    if update.get("status") == "failed":
                        print(json.dumps({"event": "tool_failed", "update": str(update)[:1400]}, ensure_ascii=False), flush=True)
                    content = update.get("content") or []
                    if isinstance(content, list):
                        diffs = [part for part in content if isinstance(part, dict) and part.get("type") == "diff"]
                        if diffs:
                            proposals[update.get("toolCallId")] = diffs
                continue
            if message.get("method") == "session/request_permission":
                params = message.get("params", {})
                call = params.get("toolCall") or {}
                diffs = proposals.get(call.get("toolCallId"), [])
                paths = sorted({part.get("path") for part in diffs if part.get("path")})
                options = params.get("options") or []
                reject = next((x.get("optionId") for x in options if x.get("kind") == "reject_once"), None)
                allow = next((x.get("optionId") for x in options if x.get("kind") == "allow_once"), None)
                if turn == 1 and len(paths) == 2 and reject:
                    option = reject
                    rejected_batch = True
                    decision = "cancel_original_batch"
                elif (
                    turn == 2
                    and len(diffs) == 2
                    and {part.get("path") for part in diffs} == set(reviewed)
                    and all(part.get("newText") == reviewed[part["path"]] for part in diffs)
                    and allow
                ):
                    option = allow
                    approved_followup += 1
                    decision = "approve_followup"
                else:
                    option = reject
                    decision = "reject_unexpected"
                print(json.dumps({"event": "permission", "turn": turn, "kind": call.get("kind"),
                                  "paths": [os.path.basename(p) for p in paths], "decision": decision},
                                 ensure_ascii=False), flush=True)
                outcome = {"outcome": "selected", "optionId": option} if option else {"outcome": "cancelled"}
                send({"jsonrpc": "2.0", "id": message["id"], "result": {"outcome": outcome}})
                continue
            if message.get("id") is not None and message.get("method"):
                print(json.dumps({"event": "unhandled_request", "method": message.get("method")}, ensure_ascii=False), flush=True)
                send({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": "unsupported test request"}})

    try:
        initialized = request(1, "initialize", {
            "protocolVersion": 1,
            "clientInfo": {"name": "omniac-flow-probe", "title": "omniac-flow-probe", "version": "0.1.0"},
            "clientCapabilities": {"fs": {"readTextFile": True, "writeTextFile": True}, "terminal": False},
        })
        if initialized.get("error"):
            raise RuntimeError("initialize failed")
        session = request(2, "session/new", {"cwd": workdir, "mcpServers": []})
        session_id = (session.get("result") or {}).get("sessionId")
        if not session_id:
            raise RuntimeError("session/new failed")
        mode = request(3, "session/set_mode", {"sessionId": session_id, "modeId": "workspace-write"})
        if mode.get("error"):
            raise RuntimeError("session/set_mode failed")

        turn = 1
        original = request(4, "session/prompt", {
            "sessionId": session_id,
            "prompt": [{"type": "text", "text": f"Use one apply_patch call to edit both existing files. In {first}, replace first=old with first=proposed. In {second}, replace second=old with second=proposed. Both files must be in the same edit call. If permission is rejected, stop without retrying. Do not use shell commands."}],
        })
        print(json.dumps({"event": "first_agent_text", "text": "".join(agent_text)[-1000:]}, ensure_ascii=False), flush=True)
        with open(first) as source:
            first_after = source.read()
        with open(second) as source:
            second_after = source.read()
        print(json.dumps({"event": "first_file_state", "first": first_after, "second": second_after}, ensure_ascii=False), flush=True)
        if not rejected_batch:
            raise RuntimeError("did not observe a two-file edit permission")
        if (original.get("result") or {}).get("stopReason") != "cancelled":
            raise AssertionError("rejected original prompt did not end with cancelled")
        if first_after != "first=old\n" or second_after != "second=old\n":
            raise AssertionError("rejected edit changed a file before the follow-up")

        turn = 2
        followup = request(5, "session/prompt", {
            "sessionId": session_id,
            "prompt": [{"type": "text", "text": f"The user adjusted one diff in the approval batch. The original edit batch was rejected. Apply the reviewed contents: in {first}, replace first=old with first=reviewed; in {second}, replace second=old with second=proposed. Use one apply_patch call. Do not use shell commands."}],
        })
        with open(first) as source:
            first_content = source.read()
        with open(second) as source:
            second_content = source.read()
        print(json.dumps({"event": "final", "approved_followup": approved_followup,
                          "first": first_content, "second": second_content}, ensure_ascii=False), flush=True)
        if (followup.get("result") or {}).get("stopReason") != "end_turn":
            raise AssertionError("follow-up prompt did not end with end_turn")
        if approved_followup == 0:
            raise AssertionError("no follow-up edit was approved")
        if first_content != "first=reviewed\n" or second_content != "second=proposed\n":
            raise AssertionError("final files differ from reviewed content")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
