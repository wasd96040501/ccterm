#!/usr/bin/env python3
"""A scripted stand-in for `claude` speaking the stream-json stdio protocol.

The prompt text picks the scenario. Anything the test needs to observe about
what the SDK wrote comes back as a `system` message with subtype `test_*`.
"""
import json
import sys

SESSION = "fake-session"


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def emit_raw(text):
    sys.stdout.write(text + "\n")
    sys.stdout.flush()


def result(uuid):
    emit({"type": "result", "subtype": "success", "is_error": False, "result": "done", "num_turns": 1,
          "session_id": SESSION, "uuid": "r-" + uuid, "user_message_uuids": [uuid]})


def read():
    line = sys.stdin.readline()
    if not line:
        sys.exit(0)
    return json.loads(line)


def respond(request_id, payload=None, error=None):
    if error is not None:
        emit({"type": "control_response",
              "response": {"subtype": "error", "request_id": request_id, "error": error}})
    else:
        body = {"subtype": "success", "request_id": request_id}
        if payload is not None:
            body["response"] = payload
        emit({"type": "control_response", "response": body})


def handle_control(msg):
    request_id = msg["request_id"]
    request = msg["request"]
    subtype = request.get("subtype")
    if subtype == "initialize":
        respond(request_id, {
            "commands": [{"name": "review", "description": "Review code", "argumentHint": "<pr>"}],
            "agents": [{"name": "Explore", "description": "Search"}],
            "models": [{"value": "default", "displayName": "Default", "supportsEffort": True}],
            "account": {"email": "dev@example.com"},
            "output_style": "default",
            "available_output_styles": ["default"],
        })
        emit({"type": "system", "subtype": "test_initialize", "request": request, "session_id": SESSION})
    elif subtype == "fail":
        respond(request_id, error="nope")
    elif subtype == "hang":
        # Never answered; the test withdraws it once it knows it arrived.
        emit({"type": "system", "subtype": "test_hanging", "request_id": request_id, "session_id": SESSION})
    elif subtype == "side_question":
        respond(request_id, {"response": "Answer: " + request.get("question", ""), "synthetic": False})
    else:
        respond(request_id, {"echo": request})


def scenario(msg):
    uuid = msg.get("uuid", "")
    content = msg["message"]["content"]
    text = content if isinstance(content, str) else "".join(b.get("text", "") for b in content)
    emit({"type": "system", "subtype": "init", "cwd": "/tmp", "session_id": SESSION, "model": "fake",
          "permissionMode": "default", "tools": ["Bash"], "uuid": "init-" + uuid})
    emit({"type": "user", "message": {"role": "user", "content": content}, "session_id": SESSION,
          "parent_tool_use_id": None, "uuid": uuid, "isReplay": True})

    if text == "echo":
        emit({"type": "system", "subtype": "test_user_line", "line": msg, "session_id": SESSION})
        emit({"type": "assistant", "message": {"id": "msg-1", "model": "fake", "role": "assistant",
              "content": [{"type": "text", "text": "hello"}]}, "session_id": SESSION, "uuid": "a-" + uuid,
              "parent_tool_use_id": None})
        result(uuid)
    elif text == "permission":
        emit({"type": "control_request", "request_id": "perm-1", "request": {
            "subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": "ls"}, "tool_use_id": "toolu_1",
            "permission_suggestions": [
                {"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "ls:*"}], "behavior": "allow",
                 "destination": "session"},
                {"type": "someFutureKind", "x": 1},
            ],
            "decision_reason": "needs approval"}})
        while True:
            reply = read()
            if reply.get("type") == "control_response":
                break
            if reply.get("type") == "control_request":
                handle_control(reply)
        # Like --replay-user-messages: our own answer is echoed back.
        emit(reply)
        emit({"type": "system", "subtype": "test_permission_reply", "reply": reply, "session_id": SESSION})
        result(uuid)
    elif text == "withdraw":
        emit({"type": "control_request", "request_id": "perm-2", "request": {
            "subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": "sleep 99"},
            "tool_use_id": "toolu_2"}})
        emit({"type": "control_cancel_request", "request_id": "perm-2"})
        result(uuid)
    elif text == "garbage":
        emit_raw("this is not json")
        emit_raw("[1, 2, 3]")
        emit_raw('{"type": "assistant", "uuid": "broken"}')
        emit({"type": "brand_new_kind", "payload": {"x": 1}})
        emit({"type": "keep_alive"})
        emit({"type": "control_request", "request_id": "hook-1",
              "request": {"subtype": "hook_callback", "callback_id": "c", "input": {}}})
        emit({"type": "control_request", "request_id": "odd-1", "request": {"subtype": "made_up"}})
        reply1 = read()
        reply2 = read()
        emit({"type": "system", "subtype": "test_auto_replies", "replies": [reply1, reply2], "session_id": SESSION})
        result(uuid)
    elif text == "crash":
        sys.stderr.write("fatal: boom\n")
        sys.stderr.flush()
        sys.exit(3)
    else:
        result(uuid)


def main():
    while True:
        msg = read()
        kind = msg.get("type")
        if kind == "control_request":
            handle_control(msg)
        elif kind == "control_cancel_request":
            emit({"type": "system", "subtype": "test_cancelled", "request_id": msg["request_id"],
                  "session_id": SESSION})
        elif kind == "user":
            scenario(msg)


if __name__ == "__main__":
    main()
