#!/usr/bin/env python3
"""A scripted stand-in for `claude` speaking the stream-json stdio protocol.

The prompt text picks the scenario. Anything the test needs to observe about
what the SDK wrote comes back as a `system` message with subtype `test_*`.

Live-session scenarios (the app's store tests drive these)
----------------------------------------------------------
Control requests, picked by their argument:

* `set_model` — `model: "slow"` acks after 0.4 s (the CLI's entitlement check
  takes about 1.5 s); `model: "refuse:<code>"` answers an error with
  `error_code: <code>` (`restricted_by_org`, `catalog_unknown`, ...);
  `model: "echo"` acks and then sends a `/model` local-command output
  (`Set model to echo`) as a replayed user line; anything else just acks.
  (The real CLI 2.1.286 did not stream that output while idle, only
  `LiveControlsSmoke`'s ack and error; the echo is here for a store that
  must cope with it arriving.)
* `set_permission_mode` — acks `{mode}` and sends `system/status` carrying
  `permissionMode`. `bypassPermissions` without `--allow-dangerously-skip-permissions`
  on the command line is refused with `error_code: bypass_not_launched`;
  `mode: "auto"` is refused with `auto_mode_unavailable`.
* `cancel_async_message` — `{cancelled: true}` and a `command_lifecycle`
  `cancelled` for a uuid held by the `hold` prompt; `{cancelled: false}` for
  any other uuid.
* `list_models` — two rows, one `disabled`.
* `get_context_usage` — a minimal usage (`totalTokens` 12 000 of 200 000).
* `apply_flag_settings` — merged into the settings layer as before; no echo
  (a host's own change is never echoed).

Prompts, picked by their text (each is also replayed with its uuid and, except
for `hold`, ends in a `result`):

* `lifecycle` — `queued`, `started`, replay, an assistant reply, `result`,
  `completed`.
* `hold` — `queued` only; the prompt waits in the queue (no replay, no
  result) until `cancel_async_message` takes it out.
* `lifecycle-cancel` — `queued`, `started`, then `cancelled` (an interrupt
  swept it) and a `result`.
* `title` — `system/session_title_changed` with `Renamed`.
* `flag` — a top-level `apply_flag_settings` line `{effortLevel: "high"}`, as
  the CLI sends a typed `/effort high` to the host.
* `flag-request` — the same patch as an inbound `apply_flag_settings`
  control request; the SDK answers success and yields the event.
* `mode-status` — a `system/status` `compacting` line, then the same with a
  null status and `permissionMode: plan`.
"""
import json
import sys
import time

SESSION = "fake-session"

# The session settings layer, as the CLI keeps it: `--settings` values with
# `apply_flag_settings` values on top. A null withdraws a runtime value.
LAUNCH_SETTINGS = {}
RUNTIME_SETTINGS = {}
if "--settings" in sys.argv:
    LAUNCH_SETTINGS.update(json.loads(sys.argv[sys.argv.index("--settings") + 1]))


def session_layer():
    return {**LAUNCH_SETTINGS, **RUNTIME_SETTINGS}


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def emit_raw(text):
    sys.stdout.write(text + "\n")
    sys.stdout.flush()


def result(uuid):
    emit({"type": "result", "subtype": "success", "is_error": False, "result": "done", "num_turns": 1,
          "session_id": SESSION, "uuid": "r-" + uuid, "user_message_uuids": [uuid]})


QUEUED = set()


def lifecycle(uuid, state):
    emit({"type": "command_lifecycle", "command_uuid": uuid, "state": state, "session_id": SESSION,
          "uuid": "lc-" + uuid + "-" + state})


def status(mode=None, state=None):
    line = {"type": "system", "subtype": "status", "status": state, "session_id": SESSION,
            "uuid": "st-" + str(mode) + "-" + str(state)}
    if mode is not None:
        line["permissionMode"] = mode
    emit(line)


def model_echo(model):
    emit({"type": "user", "message": {"role": "user", "content":
          "<local-command-stdout>Set model to " + model + "</local-command-stdout>"},
          "session_id": SESSION, "parent_tool_use_id": None, "uuid": "model-" + model, "isReplay": True})


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
    elif subtype == "set_model":
        model = request.get("model")
        if isinstance(model, str) and model.startswith("refuse:"):
            time.sleep(0.2)
            emit({"type": "control_response", "response": {
                "subtype": "error", "request_id": request_id, "error": "Cannot set model " + model,
                "error_code": model[len("refuse:"):]}})
            return
        if model == "slow":
            time.sleep(0.4)
        respond(request_id)
        if model == "echo":
            model_echo(model)
    elif subtype == "set_permission_mode":
        mode = request.get("mode")
        if mode == "bypassPermissions" and "--allow-dangerously-skip-permissions" not in sys.argv:
            emit({"type": "control_response", "response": {
                "subtype": "error", "request_id": request_id,
                "error": "Cannot set permission mode to bypassPermissions because the session was not launched "
                         "with --dangerously-skip-permissions",
                "error_code": "bypass_not_launched"}})
        elif mode == "auto":
            emit({"type": "control_response", "response": {
                "subtype": "error", "request_id": request_id, "error": "Cannot set permission mode to auto",
                "error_code": "auto_mode_unavailable"}})
        else:
            respond(request_id, {"mode": mode})
            status(mode=mode)
    elif subtype == "cancel_async_message":
        uuid = request.get("message_uuid")
        held = uuid in QUEUED
        QUEUED.discard(uuid)
        respond(request_id, {"cancelled": held})
        if held:
            lifecycle(uuid, "cancelled")
    elif subtype == "list_models":
        respond(request_id, {"models": [
            {"value": "default", "resolvedModel": "claude-fake-1", "displayName": "Default",
             "description": "Fake", "supportsEffort": True, "supportedEffortLevels": ["low", "high"],
             "supportsFastMode": True},
            {"value": "locked", "displayName": "Locked", "description": "Not for this org", "disabled": True},
        ]})
    elif subtype == "get_context_usage":
        respond(request_id, {
            "categories": [{"name": "Messages", "tokens": 12000}], "totalTokens": 12000, "maxTokens": 200000,
            "rawMaxTokens": 200000, "percentage": 6, "model": "claude-fake-1", "isAutoCompactEnabled": True,
            "memoryFiles": [], "mcpTools": [], "agents": []})
    elif subtype == "hang":
        # Never answered; the test withdraws it once it knows it arrived.
        emit({"type": "system", "subtype": "test_hanging", "request_id": request_id, "session_id": SESSION})
    elif subtype == "apply_flag_settings":
        for key, value in request.get("settings", {}).items():
            if value is None:
                RUNTIME_SETTINGS.pop(key, None)
            else:
                RUNTIME_SETTINGS[key] = value
        respond(request_id)
    elif subtype == "get_settings":
        layer = session_layer()
        respond(request_id, {
            "effective": {"theme": "dark", **layer},
            "sources": [{"source": "userSettings", "settings": {"theme": "dark"}}]
            + ([{"source": "flagSettings", "settings": layer}] if layer else []),
            "applied": {"model": "claude-test", "effort": layer.get("effortLevel"), "advisor": None,
                        "ultracode": layer.get("ultracode", False)},
        })
    elif subtype == "side_question":
        respond(request_id, {"response": "Answer: " + request.get("question", ""), "synthetic": False})
    elif subtype == "rewind_conversation":
        # A target named "busy" stands for a turn still winding down.
        if request.get("target_message_uuid") == "busy":
            respond(request_id, {"rewound": False, "reason": "turn_running"})
        else:
            respond(request_id, {"rewound": True})
    else:
        respond(request_id, {"echo": request})


def scenario(msg):
    uuid = msg.get("uuid", "")
    content = msg["message"]["content"]
    text = content if isinstance(content, str) else "".join(b.get("text", "") for b in content)
    if text == "hold":
        # Waits in the CLI's queue: no replay, no result, until cancelled.
        QUEUED.add(uuid)
        lifecycle(uuid, "queued")
        return
    emit({"type": "system", "subtype": "init", "cwd": "/tmp", "session_id": SESSION, "model": "fake",
          "permissionMode": "default", "tools": ["Bash"], "uuid": "init-" + uuid})
    if text in ("lifecycle", "lifecycle-cancel"):
        lifecycle(uuid, "queued")
        lifecycle(uuid, "started")
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
    elif text in ("lifecycle", "lifecycle-cancel"):
        emit({"type": "assistant", "message": {"id": "msg-1", "model": "fake", "role": "assistant",
              "content": [{"type": "text", "text": "ok"}]}, "session_id": SESSION, "uuid": "a-" + uuid,
              "parent_tool_use_id": None})
        result(uuid)
        lifecycle(uuid, "completed" if text == "lifecycle" else "cancelled")
    elif text == "title":
        emit({"type": "system", "subtype": "session_title_changed", "title": "Renamed", "session_id": SESSION,
              "uuid": "title-" + uuid})
        result(uuid)
    elif text == "flag":
        emit({"type": "apply_flag_settings", "settings": {"effortLevel": "high"}, "session_id": SESSION,
              "uuid": "flag-" + uuid})
        result(uuid)
    elif text == "flag-request":
        emit({"type": "control_request", "request_id": "flag-1", "request": {
            "subtype": "apply_flag_settings", "settings": {"fastMode": True}}})
        reply = read()
        emit({"type": "system", "subtype": "test_flag_reply", "reply": reply, "session_id": SESSION})
        result(uuid)
    elif text == "mode-status":
        status(state="compacting")
        status(mode="plan")
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
