#!/usr/bin/env python3
import argparse
import json
import mimetypes
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description="Serve SeaOfGoals experiment traces.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=19161)
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"serving SeaOfGoals traces at http://{args.host}:{args.port}/")
    server.serve_forever()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/":
            self.send_text(INDEX_HTML, "text/html; charset=utf-8")
        elif parsed.path == "/api/runs":
            self.send_json(list_runs())
        elif parsed.path == "/api/trace":
            params = parse_qs(parsed.query)
            run_id = single_param(params, "id")
            try:
                self.send_json(read_trace(run_id))
            except ValueError as exc:
                self.send_error(404, str(exc))
        else:
            self.send_error(404, "not found")

    def log_message(self, fmt, *args):
        print("%s - - [%s] %s" % (self.address_string(), self.log_date_time_string(), fmt % args))

    def send_json(self, value):
        body = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_text(self, text, content_type):
        body = text.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", content_type or mimetypes.types_map.get(".html", "text/html"))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def single_param(params, name):
    values = params.get(name)
    if not values or not values[0]:
        raise ValueError(f"missing {name}")
    return values[0]


def list_runs():
    runs = []
    for trace_path in ROOT.glob("*/runs/control/*/sog-trace.jsonl"):
        run_dir = trace_path.parent
        experiment = trace_path.relative_to(ROOT).parts[0]
        events, parse_errors = load_events(trace_path)
        first_ts = events[0].get("timestamp", "") if events else ""
        last_ts = events[-1].get("timestamp", "") if events else ""
        event_objs = [item.get("event", {}) for item in events]
        finished = last_event(event_objs, "harness_finished")
        started_goals = [event for event in event_objs if event.get("type") == "subgoal_started"]
        ended_goals = [event for event in event_objs if event.get("type") == "subgoal_ended"]
        runs.append(
            {
                "id": str(trace_path.relative_to(ROOT)),
                "experiment": experiment,
                "run": run_dir.name,
                "trace": str(trace_path),
                "firstTimestamp": first_ts,
                "lastTimestamp": last_ts,
                "mtime": trace_path.stat().st_mtime,
                "events": len(events),
                "parseErrors": len(parse_errors),
                "goalsStarted": len(started_goals),
                "goalsEnded": len(ended_goals),
                "reason": (finished or {}).get("reason", "running"),
            }
        )
    runs.sort(key=lambda item: (item["lastTimestamp"], item["mtime"], item["id"]), reverse=True)
    return {"root": str(ROOT), "runs": runs}


def read_trace(run_id):
    trace_path = (ROOT / run_id).resolve()
    if ROOT not in trace_path.parents or trace_path.name != "sog-trace.jsonl" or not trace_path.is_file():
        raise ValueError("unknown trace")
    events, parse_errors = load_events(trace_path)
    return {
        "id": str(trace_path.relative_to(ROOT)),
        "path": str(trace_path),
        "events": events,
        "parseErrors": parse_errors,
    }


def load_events(path):
    events = []
    parse_errors = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            line = line.rstrip("\n")
            if not line.strip():
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError as exc:
                parse_errors.append({"line": line_number, "message": str(exc), "text": line[:300]})
    return events, parse_errors


def last_event(events, event_type):
    for event in reversed(events):
        if event.get("type") == event_type:
            return event
    return None


INDEX_HTML = r"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SeaOfGoals Experiments</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #111315;
      --panel: #181b1f;
      --panel-2: #20242a;
      --text: #e6e8eb;
      --muted: #9aa4af;
      --line: #343a43;
      --accent: #4aa3ff;
      --ok: #46c37b;
      --warn: #d6a23f;
      --bad: #e06c75;
      --assistant: #8db8ff;
      --tool: #c792ea;
      --harness: #77d4c8;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font: 13px/1.45 ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    header {
      position: sticky;
      top: 0;
      z-index: 5;
      display: flex;
      gap: 16px;
      align-items: center;
      padding: 12px 16px;
      border-bottom: 1px solid var(--line);
      background: var(--bg);
    }
    h1 {
      margin: 0;
      font-size: 16px;
      font-weight: 650;
    }
    button, select, input {
      color: var(--text);
      background: var(--panel-2);
      border: 1px solid var(--line);
      border-radius: 5px;
      padding: 6px 8px;
      font: inherit;
    }
    button { cursor: pointer; }
    .layout {
      display: grid;
      grid-template-columns: 390px minmax(0, 1fr);
      min-height: calc(100vh - 53px);
    }
    aside {
      border-right: 1px solid var(--line);
      overflow: auto;
      max-height: calc(100vh - 53px);
    }
    main {
      overflow: auto;
      max-height: calc(100vh - 53px);
    }
    .run {
      display: block;
      width: 100%;
      text-align: left;
      border: 0;
      border-bottom: 1px solid var(--line);
      border-radius: 0;
      background: transparent;
      padding: 11px 13px;
    }
    .run:hover, .run.active { background: var(--panel); }
    .run-title {
      display: flex;
      justify-content: space-between;
      gap: 8px;
      font-weight: 650;
    }
    .run-meta, .run-path, .muted {
      color: var(--muted);
    }
    .run-path {
      margin-top: 4px;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: 12px;
    }
    .status-ok { color: var(--ok); }
    .status-warn { color: var(--warn); }
    .status-bad { color: var(--bad); }
    .trace-head {
      padding: 14px 18px;
      border-bottom: 1px solid var(--line);
      background: var(--panel);
    }
    .trace-title {
      font-size: 15px;
      font-weight: 700;
    }
    .trace-meta {
      margin-top: 5px;
      color: var(--muted);
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .goals {
      display: grid;
      grid-auto-flow: column;
      grid-auto-columns: minmax(360px, 430px);
      gap: 12px;
      align-items: start;
      padding: 14px;
      min-width: max-content;
    }
    .goal {
      border: 1px solid var(--line);
      border-radius: 6px;
      background: var(--panel);
      overflow: hidden;
    }
    .goal-head {
      position: sticky;
      top: 0;
      z-index: 2;
      padding: 10px;
      border-bottom: 1px solid var(--line);
      background: var(--panel-2);
    }
    .goal-id {
      color: var(--accent);
      font-weight: 750;
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    }
    .goal-name {
      margin-top: 2px;
      font-weight: 650;
    }
    .messages {
      padding: 8px;
    }
    .message {
      border: 1px solid var(--line);
      border-left: 3px solid var(--muted);
      border-radius: 5px;
      margin-bottom: 8px;
      background: #14171a;
      overflow: hidden;
    }
    .message.assistant { border-left-color: var(--assistant); }
    .message.tool { border-left-color: var(--tool); }
    .message.harness { border-left-color: var(--harness); }
    .message.effect { border-left-color: var(--warn); }
    .message.error { border-left-color: var(--bad); }
    .message-top {
      display: flex;
      justify-content: space-between;
      gap: 8px;
      padding: 7px 8px;
      border-bottom: 1px solid var(--line);
      color: var(--muted);
      font-size: 12px;
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    }
    .role {
      color: var(--text);
      font-weight: 700;
    }
    .message-body {
      padding: 8px;
    }
    pre {
      margin: 0;
      white-space: pre-wrap;
      word-break: break-word;
      font: 12px/1.42 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      max-height: 360px;
      overflow: auto;
    }
    .empty {
      padding: 28px;
      color: var(--muted);
    }
  </style>
</head>
<body>
  <header>
    <h1>SeaOfGoals Experiments</h1>
    <button id="refresh">Refresh</button>
    <input id="filter" placeholder="Filter experiment/run">
    <span id="count" class="muted"></span>
  </header>
  <div class="layout">
    <aside id="runs"></aside>
    <main id="detail"><div class="empty">Select a run.</div></main>
  </div>
  <script>
    const state = { runs: [], selected: null };

    document.getElementById("refresh").addEventListener("click", loadRuns);
    document.getElementById("filter").addEventListener("input", renderRuns);

    loadRuns();

    async function loadRuns() {
      const response = await fetch("/api/runs");
      const payload = await response.json();
      state.runs = payload.runs || [];
      document.getElementById("count").textContent = `${state.runs.length} runs`;
      renderRuns();
      if (!state.selected && state.runs[0]) {
        await selectRun(state.runs[0].id);
      }
    }

    function renderRuns() {
      const filter = document.getElementById("filter").value.toLowerCase();
      const runs = state.runs.filter((run) => {
        return `${run.experiment} ${run.run} ${run.reason}`.toLowerCase().includes(filter);
      });
      document.getElementById("runs").innerHTML = runs.map(renderRunButton).join("") || `<div class="empty">No runs found.</div>`;
      for (const button of document.querySelectorAll("[data-run-id]")) {
        button.addEventListener("click", () => selectRun(button.dataset.runId));
      }
    }

    function renderRunButton(run) {
      const active = run.id === state.selected ? " active" : "";
      return `<button class="run${active}" data-run-id="${escapeAttr(run.id)}">
        <div class="run-title">
          <span>${escapeHtml(run.experiment)}</span>
          <span class="${statusClass(run.reason)}">${escapeHtml(run.reason)}</span>
        </div>
        <div class="run-meta">${escapeHtml(compactTime(run.lastTimestamp))} · goals ${run.goalsEnded}/${run.goalsStarted} · events ${run.events}</div>
        <div class="run-path">${escapeHtml(run.run)}</div>
      </button>`;
    }

    async function selectRun(id) {
      state.selected = id;
      renderRuns();
      document.getElementById("detail").innerHTML = `<div class="empty">Loading ${escapeHtml(id)}...</div>`;
      const response = await fetch(`/api/trace?id=${encodeURIComponent(id)}`);
      const trace = await response.json();
      renderTrace(trace);
    }

    function renderTrace(trace) {
      const model = buildGoalHistory(trace.events || []);
      const parseErrors = (trace.parseErrors || []).map((error) => {
        return `<div class="message error"><div class="message-top"><span class="role">parse-error</span><span>line ${error.line}</span></div><div class="message-body"><pre>${escapeHtml(error.message + "\\n" + error.text)}</pre></div></div>`;
      }).join("");
      document.getElementById("detail").innerHTML = `
        <section class="trace-head">
          <div class="trace-title">${escapeHtml(trace.id)}</div>
          <div class="trace-meta">${escapeHtml(trace.path)}</div>
        </section>
        ${parseErrors}
        <section class="goals">${model.goals.map(renderGoal).join("")}</section>`;
    }

    function buildGoalHistory(records) {
      const goals = new Map();
      const run = ensureGoal(goals, "__run", "Run / scheduler");
      for (const record of records) {
        const event = record.event || {};
        const goalId = goalIdForEvent(event);
        const goal = goalId ? ensureGoal(goals, goalId, "") : run;
        if (event.type === "subgoal_started") {
          goal.name = event.subgoal_name || goal.name;
          goal.status = "running";
        }
        if (event.type === "subgoal_ended") {
          goal.status = event.status || goal.status;
          goal.summary = event.summary || goal.summary;
        }
        const message = eventToMessage(record.timestamp || "", event);
        if (message) goal.messages.push(message);
      }
      return { goals: Array.from(goals.values()) };
    }

    function ensureGoal(goals, id, name) {
      if (!goals.has(id)) {
        goals.set(id, { id, name: name || "", status: "", summary: "", messages: [] });
      }
      return goals.get(id);
    }

    function goalIdForEvent(event) {
      if (event.active_subgoal) return event.active_subgoal;
      if (event.subgoal_id) return event.subgoal_id;
      const prompt = event.prompt || "";
      const match = prompt.match(/Goal:\\s*([A-Za-z0-9_.:-]+)/);
      return match ? match[1] : "";
    }

    function eventToMessage(timestamp, event) {
      const type = event.type || "unknown";
      if (type === "assistant_message") {
        return { role: "assistant", kind: type, timestamp, title: "assistant", body: event.content || "(empty)" };
      }
      if (type === "reasoning_observed") {
        return { role: "harness", kind: type, timestamp, title: "reasoning observed", body: stringify({
          reasoning_id: event.reasoning_id || null,
          encrypted_content_chars: event.encrypted_content_chars || 0,
          summary_items: event.summary_items || 0,
        }) };
      }
      if (type === "tool_call") {
        return { role: "assistant", kind: type, timestamp, title: `tool call · ${event.tool_name || "?"}`, body: stringify(event.arguments) };
      }
      if (type === "tool_result") {
        return { role: "tool", kind: type, timestamp, title: `tool result · ${event.tool_name || "?"}`, body: event.result || "" };
      }
      if (type === "effect_recorded") {
        const effect = event.effect || {};
        return { role: "harness", kind: "effect", timestamp, title: `effect · ${effect.kind || "?"}`, body: `${effect.resource || ""}\\n${effect.detail || ""}`.trim() };
      }
      if (type === "subgoal_started") {
        return { role: "harness", kind: type, timestamp, title: `begin · ${event.subgoal_id || "?"}`, body: event.subgoal_name || "" };
      }
      if (type === "subgoal_ended") {
        return { role: "harness", kind: type, timestamp, title: `end · ${event.status || ""}`, body: event.summary || "" };
      }
      if (type === "workflow_status") {
        return { role: "harness", kind: type, timestamp, title: "workflow status", body: stringify(event) };
      }
      if (type === "harness_started" || type === "harness_finished") {
        return { role: "harness", kind: type, timestamp, title: type, body: stringify(event) };
      }
      return { role: "harness", kind: type, timestamp, title: type, body: stringify(event) };
    }

    function renderGoal(goal) {
      return `<article class="goal">
        <div class="goal-head">
          <div><span class="goal-id">${escapeHtml(goal.id)}</span> <span class="${statusClass(goal.status)}">${escapeHtml(goal.status || "")}</span></div>
          <div class="goal-name">${escapeHtml(goal.name || "(unnamed)")}</div>
          <div class="muted">${goal.messages.length} history entries</div>
        </div>
        <div class="messages">${goal.messages.map(renderMessage).join("") || `<div class="empty">No history.</div>`}</div>
      </article>`;
    }

    function renderMessage(message) {
      return `<div class="message ${escapeAttr(message.role)} ${escapeAttr(message.kind)}">
        <div class="message-top">
          <span><span class="role">${escapeHtml(message.role)}</span> ${escapeHtml(message.title)}</span>
          <span>${escapeHtml(compactTime(message.timestamp))}</span>
        </div>
        <div class="message-body"><pre>${escapeHtml(truncate(message.body || "", 8000))}</pre></div>
      </div>`;
    }

    function stringify(value) {
      if (value === undefined || value === null) return "";
      if (typeof value === "string") return value;
      return JSON.stringify(value, null, 2);
    }

    function truncate(value, limit) {
      const text = String(value);
      if (text.length <= limit) return text;
      return text.slice(0, limit) + "\\n... truncated ...";
    }

    function compactTime(value) {
      if (!value) return "";
      const date = new Date(value);
      if (Number.isNaN(date.getTime())) return value;
      return date.toISOString().replace("T", " ").replace(/\\.\\d{3}Z$/, "Z");
    }

    function statusClass(value) {
      const text = String(value || "");
      if (text === "success" || text === "stop" || text === "assistant_finished") return "status-ok";
      if (text.includes("fail") || text.includes("error")) return "status-bad";
      return "status-warn";
    }

    function escapeHtml(value) {
      return String(value).replace(/[&<>"']/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
    }

    function escapeAttr(value) {
      return escapeHtml(value).replace(/`/g, "&#96;");
    }
  </script>
</body>
</html>
"""


if __name__ == "__main__":
    main()
