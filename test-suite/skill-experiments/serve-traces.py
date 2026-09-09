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
        elif parsed.path == "/goals":
            self.send_text(GOALS_HTML, "text/html; charset=utf-8")
        elif parsed.path == "/timeline":
            self.send_text(TIMELINE_HTML, "text/html; charset=utf-8")
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
      if (type === "user_message") {
        return { role: "user", kind: type, timestamp, title: "user", body: event.content || "" };
      }
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
      if (type === "model_usage") {
        return { role: "harness", kind: type, timestamp, title: "model usage", body: stringify({
          input_tokens: event.input_tokens || 0,
          cached_input_tokens: event.cached_input_tokens || 0,
          output_tokens: event.output_tokens || 0,
          reasoning_output_tokens: event.reasoning_output_tokens || 0,
          total_tokens: event.total_tokens || 0,
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


GOALS_HTML = r"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SeaOfGoals Goal Comparison</title>
  <style>
    :root { color-scheme: dark; --bg:#111315; --panel:#1b1f24; --panel2:#232830; --line:#39414b; --text:#e6e8eb; --muted:#9aa4af; --serial:#d6a23f; --preload:#64cdb4; --assistant:#9bbcff; --tool:#d4a1ef; --result:#b8c4cf; }
    * { box-sizing:border-box; }
    body { margin:0; background:var(--bg); color:var(--text); font:13px/1.45 ui-sans-serif,system-ui,sans-serif; }
    header { position:sticky; top:0; z-index:3; display:flex; gap:14px; align-items:center; padding:11px 16px; background:var(--bg); border-bottom:1px solid var(--line); }
    h1 { margin:0; font-size:17px; } button,select { color:var(--text); background:var(--panel2); border:1px solid var(--line); border-radius:4px; padding:6px 8px; font:inherit; }
    button { cursor:pointer; } .controls { display:flex; gap:10px; flex-wrap:wrap; padding:10px 16px; border-bottom:1px solid var(--line); }
    .controls label { display:flex; gap:7px; align-items:center; color:var(--muted); } .muted { color:var(--muted); }
    main { padding:14px 16px 40px; } .goal { margin:0 auto 18px; max-width:1800px; border:1px solid var(--line); background:var(--panel); }
    .goal-head { padding:10px 13px; border-bottom:1px solid var(--line); display:flex; gap:12px; align-items:baseline; }
    .goal-id { font-weight:700; color:#fff; } .goal-name { font-weight:650; } .goal-desc { margin-left:auto; color:var(--muted); max-width:55%; text-align:right; }
    .columns { display:grid; grid-template-columns:minmax(0,1fr) minmax(0,1fr); gap:1px; background:var(--line); }
    .column { min-width:0; background:var(--bg); padding:10px; } .column-head { display:flex; justify-content:space-between; align-items:baseline; border-bottom:2px solid; padding:0 2px 7px; margin-bottom:8px; font-weight:700; }
    .serial .column-head { color:var(--serial); border-color:var(--serial); } .preload .column-head { color:var(--preload); border-color:var(--preload); }
    .event { border-left:3px solid var(--line); margin:0 0 8px; padding:7px 9px; background:var(--panel); min-width:0; }
    .event.assistant_message { border-color:var(--assistant); } .event.tool_call { border-color:var(--tool); } .event.tool_result { border-color:var(--result); }
    .event-top { display:flex; gap:8px; justify-content:space-between; color:var(--muted); font-size:12px; } .event-title { color:var(--text); font-weight:650; }
    pre { margin:6px 0 0; white-space:pre-wrap; overflow-wrap:anywhere; font:11px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace; color:#d8dde3; max-height:420px; overflow:auto; }
    details > summary { cursor:pointer; color:var(--muted); margin-top:5px; } .empty { color:var(--muted); padding:12px 2px; }
    @media (max-width:800px) { .columns { grid-template-columns:1fr; } .goal-desc { display:none; } }
  </style>
</head>
<body>
  <header><h1>Goal comparison</h1><button id="refresh">Refresh</button><a href="/timeline" class="muted">timeline</a><a href="/" class="muted">history view</a></header>
  <div class="controls">
    <label>Serial <select id="serial"></select></label>
    <label>Preload <select id="preload"></select></label>
    <span id="status" class="muted"></span>
  </div>
  <main id="content"><div class="empty">Loading runs...</div></main>
  <script>
    const state = { runs: [], traces: {}, selected: {} };
    document.getElementById("refresh").addEventListener("click", () => { state.traces = {}; loadRuns(); });
    document.getElementById("serial").addEventListener("change", loadSelected);
    document.getElementById("preload").addEventListener("change", loadSelected);
    loadRuns();

    async function loadRuns() {
      const response = await fetch("/api/runs"); const payload = await response.json();
      state.runs = (payload.runs || []).filter((run) => run.experiment === "port-widget");
      const serial = state.runs.filter((run) => run.run.includes("serial-sog"));
      const preload = state.runs.filter((run) => run.run.includes("preload-context"));
      fill("serial", serial, state.selected.serial || (serial[0] && serial[0].id));
      fill("preload", preload, state.selected.preload || (preload[0] && preload[0].id));
      await loadSelected();
    }
    function fill(id, runs, selected) {
      document.getElementById(id).innerHTML = runs.map((run) => `<option value="${attr(run.id)}">${html(run.run)}</option>`).join("");
      if (selected) document.getElementById(id).value = selected;
    }
    async function loadSelected() {
      state.selected.serial = document.getElementById("serial").value; state.selected.preload = document.getElementById("preload").value;
      await Promise.all([load(state.selected.serial), load(state.selected.preload)]); render();
    }
    async function load(id) { if (!id || state.traces[id]) return; state.traces[id] = await (await fetch(`/api/trace?id=${encodeURIComponent(id)}`)).json(); }
    function render() {
      const serial = state.traces[state.selected.serial], preload = state.traces[state.selected.preload]; if (!serial || !preload) return;
      const left = groupSerial(serial.events || []), right = groupGoals(preload.events || []); const ids = [...new Set([...Object.keys(left), ...Object.keys(right)])].filter((x) => /^G\d+$/.test(x)).sort((a,b) => Number(a.slice(1))-Number(b.slice(1)));
      document.getElementById("status").textContent = `${ids.length} goals · serial ${short(serial.id)} · preload ${short(preload.id)}`;
      document.getElementById("content").innerHTML = ids.map((id) => renderGoal(id, left[id] || [], right[id] || [])).join("");
    }
    function groupGoals(records) {
      const groups = {}; let active = "";
      for (const record of records) { const e = record.event || {}; const id = e.active_subgoal || e.subgoal_id || active; if (e.type === "subgoal_started") active = e.subgoal_id; if (e.type === "subgoal_ended") active = e.subgoal_id; if (/^G\d+$/.test(id || "")) (groups[id] ||= []).push(record); }
      return groups;
    }
    function groupSerial(records) {
      const groups = {}; const usage = records.map((r,i) => [i,r]).filter(([,r]) => (r.event || {}).type === "model_usage");
      const mapping = {1:"G000",2:"G000",3:"G000",4:"G000",5:"G002",6:"shared",7:"G003",8:"G003",9:"G004",10:"G006",11:"G007",12:"G007",13:"G007",14:"G007"};
      usage.forEach(([i], n) => { const id = mapping[n+1] || "shared"; const end = usage[n+1] ? usage[n+1][0] : records.length; (groups[id] ||= []).push(...records.slice(n ? usage[n-1][0] : 0, end)); });
      return groups;
    }
    function renderGoal(id, serial, preload) {
      const name = goalName(id, preload.concat(serial));
      return `<section class="goal"><div class="goal-head"><span class="goal-id">${html(id)}</span><span class="goal-name">${html(name)}</span><span class="goal-desc">serial rounds ${roundCount(serial)} · preload rounds ${roundCount(preload)}</span></div><div class="columns">${column("serial", serial, "Serial baseline")}${column("preload", preload, "Preload")}</div></section>`;
    }
    function column(kind, records, title) { return `<div class="column ${kind}"><div class="column-head"><span>${title}</span><span>${records.length} events</span></div>${records.length ? records.map(renderEvent).join("") : `<div class="empty">No mapped events.</div>`}</div>`; }
    function renderEvent(record) { const e=record.event||{}; const type=e.type||"unknown"; return `<article class="event ${attr(type)}"><div class="event-top"><span class="event-title">${html(label(e))}</span><span>${html(time(record.timestamp))}</span></div>${body(e)}</article>`; }
    function body(e) { const value=eventBody(e); if (!value) return ""; return `<details><summary>View details</summary><pre>${html(value)}</pre></details>`; }
    function label(e) { if(e.type==="assistant_message") return "agent text"; if(e.type==="tool_call") return e.tool_name==="shell" ? `shell · ${shellCommand(e)}` : `tool call · ${e.tool_name||"?"}`; if(e.type==="tool_result") return `tool result · ${e.tool_name||"?"}`; if(e.type==="harness_started") return "system / goal prompt"; if(e.type==="subgoal_started") return `begin · ${e.subgoal_id||""}`; if(e.type==="subgoal_ended") return `end · ${e.status||""}`; return e.type||"event"; }
    function shellCommand(e) { return String((e.arguments||{}).command||"").split("\\n")[0]; }
    function eventBody(e) { if(e.type==="assistant_message"||e.type==="user_message"||e.type==="harness_started") return e.content||e.prompt||e.system_prompt||""; if(e.type==="tool_call") { const a=e.arguments||{}; return e.tool_name==="shell" ? `$ ${a.command||""}` : JSON.stringify(a,null,2); } if(e.type==="tool_result") return e.result||""; if(e.type==="subgoal_ended") return e.summary||""; return ""; }
    function goalName(id, records) { const e=records.find((r)=>(r.event||{}).type==="subgoal_started" && (r.event||{}).subgoal_id===id); return e ? e.event.subgoal_name : ""; }
    function roundCount(records) { return new Set(records.filter((r)=>(r.event||{}).type==="model_usage").map((r)=>r.timestamp)).size; }
    function short(id) { return String(id||"").split("/").slice(-2,-1)[0] || id; }
    function time(v) { return new Date(v).toISOString().replace(/.*T/,"").replace(/\\..*/,""); }
    function html(v) { return String(v??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"}[c])); }
    function attr(v) { return html(v).replace(/`/g,"&#96;"); }
  </script>
</body>
</html>
"""

TIMELINE_HTML = r"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SeaOfGoals Timeline</title>
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
      --serial: #d6a23f;
      --concurrent: #61c7a8;
      --tool: #c792ea;
      --bad: #e06c75;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font: 13px/1.4 ui-sans-serif, system-ui, sans-serif;
    }
    header {
      position: sticky;
      top: 0;
      z-index: 4;
      display: flex;
      align-items: center;
      gap: 12px;
      padding: 11px 16px;
      border-bottom: 1px solid var(--line);
      background: rgba(17, 19, 21, .96);
    }
    h1 { margin: 0; font-size: 16px; }
    select, button {
      color: var(--text);
      background: var(--panel-2);
      border: 1px solid var(--line);
      border-radius: 5px;
      padding: 6px 8px;
      font: inherit;
    }
    button { cursor: pointer; }
    .muted { color: var(--muted); }
    .legend { margin-left: auto; display: flex; gap: 14px; color: var(--muted); }
    .legend span::before {
      content: "";
      display: inline-block;
      width: 9px;
      height: 9px;
      margin-right: 5px;
      border-radius: 50%;
      background: var(--accent);
    }
    .legend .serial::before { background: var(--serial); }
    .legend .concurrent::before { background: var(--concurrent); }
    .controls { padding: 10px 16px; border-bottom: 1px solid var(--line); background: var(--panel); }
    .controls {
      display: grid;
      grid-template-columns: minmax(0, 1fr) minmax(0, 1fr) auto;
      gap: 8px 14px;
      align-items: center;
    }
    .controls label { display: flex; min-width: 0; align-items: center; gap: 8px; color: var(--muted); }
    .controls select { width: 100%; min-width: 0; max-width: none; }
    .controls label:last-of-type { white-space: nowrap; }
    .controls #status { white-space: nowrap; }
    .timeline-scroll { overflow: auto; }
    .timeline {
      position: relative;
      min-width: 1040px;
      padding: 18px 26px 60px;
    }
    .axis {
      display: none;
    }
    .lane {
      position: absolute;
      top: 18px;
      bottom: 60px;
      width: calc(50% - 32px);
      overflow: visible;
    }
    .lane.serial { left: 26px; padding-right: 24px; }
    .lane.concurrent { right: 26px; padding-left: 24px; }
    .lane-head {
      position: absolute;
      top: -12px;
      left: 24px;
      right: 0;
      z-index: 2;
      padding: 8px 10px;
      border: 1px solid var(--line);
      border-top: 3px solid var(--accent);
      background: var(--panel-2);
      font-weight: 700;
    }
    .lane-head .muted {
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .lane.serial .lane-head { left: 0; right: 24px; border-top-color: var(--serial); }
    .lane.concurrent .lane-head { border-top-color: var(--concurrent); }
    .connections {
      position: absolute;
      inset: 0;
      width: 100%;
      height: 100%;
      pointer-events: none;
      overflow: visible;
    }
    .connection {
      stroke: var(--line);
      stroke-width: 1;
    }
    .connection-point {
      fill: var(--panel-2);
      stroke: var(--accent);
      stroke-width: 2;
    }
    .serial .connection-point { stroke: var(--serial); }
    .concurrent .connection-point { stroke: var(--concurrent); }
    .event-list {
      position: absolute;
      top: 48px;
      left: 54px;
      right: 0;
      bottom: 0;
    }
    .serial .event-list {
      left: 0;
      right: 54px;
    }
    .event-card {
      position: absolute;
      left: 0;
      right: 0;
      height: 28px;
      padding: 4px 8px;
      border: 1px solid var(--line);
      border-left: 3px solid var(--accent);
      border-radius: 3px;
      background: var(--panel-2);
      color: var(--muted);
      text-align: left;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      cursor: pointer;
    }
    .serial .event-card { border-left-color: var(--serial); }
    .serial .event-card { border-left: 0; border-right: 3px solid var(--serial); }
    .concurrent .event-card { border-left-color: var(--concurrent); }
    .event-card.tool_call { border-left-color: var(--tool); }
    .event-card.subgoal_started, .event-card.subgoal_ended { border-left-color: var(--concurrent); }
    .event-card.dag_snapshot { opacity: .72; }
    .event-card:hover, .event-card.selected { z-index: 3; color: var(--text); background: #2a3038; }
    .event-label {
      display: inline-block;
      max-width: calc(100% - 54px);
      overflow: hidden;
      text-overflow: ellipsis;
      font: 10px ui-monospace, monospace;
      pointer-events: none;
    }
    .event-time {
      float: right;
      color: var(--muted);
      font: 10px ui-monospace, monospace;
    }
    .inspector {
      position: fixed;
      z-index: 5;
      display: none;
      width: min(620px, calc(100vw - 36px));
      max-height: 38vh;
      padding: 10px 12px;
      border: 1px solid var(--accent);
      border-radius: 6px;
      background: #20242af2;
      box-shadow: 0 8px 24px #0008;
    }
    .inspector.visible { display: block; }
    .inspector-head { display: flex; gap: 8px; font-weight: 700; }
    .inspector-time { color: var(--muted); font: 11px ui-monospace, monospace; }
    .inspector pre { max-height: 28vh; margin-top: 7px; white-space: pre-wrap; overflow: auto; font: 11px/1.4 ui-monospace, monospace; }
    .empty { padding: 28px; color: var(--muted); }
    @media (max-width: 800px) {
      .controls { grid-template-columns: 1fr; }
      .legend { display: none; }
    }
  </style>
</head>
<body>
  <header>
    <h1>port-widget timeline</h1>
    <button id="refresh">Refresh</button>
    <a href="/" class="muted">history view</a>
    <a href="/goals" class="muted">goal comparison</a>
    <div class="legend"><span class="serial">serial baseline</span><span class="concurrent">SoG concurrent</span></div>
  </header>
  <div class="controls">
    <label>Serial <select id="serial"></select></label>
    <label>Concurrent <select id="concurrent"></select></label>
    <label><input id="internals" type="checkbox"> show model usage / reasoning</label>
    <span id="status" class="muted"></span>
  </div>
  <div id="inspector" class="inspector"></div>
  <div id="content" class="empty">Loading runs...</div>
  <script>
    const state = { runs: [], traces: {}, selected: {}, zoom: 1, pointers: new Map(), pinchDistance: null };
    const content = document.getElementById("content");
    document.getElementById("refresh").addEventListener("click", loadRuns);
    document.getElementById("serial").addEventListener("change", loadSelected);
    document.getElementById("concurrent").addEventListener("change", loadSelected);
    document.getElementById("internals").addEventListener("change", render);
    content.addEventListener("wheel", handleTrackpadZoom, { passive: false });
    content.addEventListener("pointerdown", handlePointerDown);
    content.addEventListener("pointermove", handlePointerMove);
    content.addEventListener("pointerup", handlePointerEnd);
    content.addEventListener("pointercancel", handlePointerEnd);
    loadRuns();

    async function loadRuns() {
      const response = await fetch("/api/runs");
      const payload = await response.json();
      state.runs = (payload.runs || []).filter((run) => run.experiment === "port-widget");
      const serial = state.runs.filter((run) => run.run.includes("serial-sog"));
      const concurrent = state.runs.filter((run) => run.run.includes("concurrent-sog"));
      fillSelect("serial", serial, state.selected.serial || (serial[0] && serial[0].id));
      fillSelect("concurrent", concurrent, state.selected.concurrent || (concurrent[0] && concurrent[0].id));
      state.selected.serial = document.getElementById("serial").value;
      state.selected.concurrent = document.getElementById("concurrent").value;
      await loadSelected();
    }

    function fillSelect(id, runs, selected) {
      document.getElementById(id).innerHTML = runs.map((run) => `<option value="${escapeAttr(run.id)}">${escapeHtml(run.run)}</option>`).join("");
      if (selected) document.getElementById(id).value = selected;
    }

    async function loadSelected() {
      state.selected.serial = document.getElementById("serial").value;
      state.selected.concurrent = document.getElementById("concurrent").value;
      await Promise.all([loadTrace(state.selected.serial), loadTrace(state.selected.concurrent)]);
      render();
    }

    async function loadTrace(id) {
      if (!id || state.traces[id]) return;
      const response = await fetch(`/api/trace?id=${encodeURIComponent(id)}`);
      state.traces[id] = await response.json();
    }

    function render() {
      const serial = state.traces[state.selected.serial];
      const concurrent = state.traces[state.selected.concurrent];
      if (!serial || !concurrent) return;
      const serialEvents = visibleEvents(serial.events || []);
      const concurrentEvents = visibleEvents(concurrent.events || []);
      const normalizedSerial = normalizeEvents(serialEvents);
      const normalizedConcurrent = normalizeEvents(concurrentEvents);
      const all = normalizedSerial.concat(normalizedConcurrent);
      const duration = Math.max(...all.map((item) => item.elapsed));
      const scale = state.zoom;
      const rowHeight = 34;
      const height = Math.max(720, duration / 1000 * scale + 120, Math.max(normalizedSerial.length, normalizedConcurrent.length) * rowHeight + 100);
      document.getElementById("status").textContent = `${formatDuration(duration)} normalized time range`;
      document.getElementById("content").innerHTML = `<div class="timeline-scroll"><div class="timeline" style="height:${height}px"><div class="axis"></div>${renderLane("serial", serial, normalizedSerial, scale, rowHeight)}${renderLane("concurrent", concurrent, normalizedConcurrent, scale, rowHeight)}</div></div>`;
      document.querySelectorAll(".event-card").forEach((marker) => {
        marker.addEventListener("mouseenter", (event) => showInspector(marker.dataset.event, event));
        marker.addEventListener("mousemove", (event) => positionInspector(event.clientX, event.clientY));
        marker.addEventListener("mouseleave", hideInspector);
      });
    }

    function normalizeEvents(records) {
      if (!records.length) return [];
      const start = Date.parse(records[0].timestamp);
      return records.map((record) => ({ ...record, elapsed: Date.parse(record.timestamp) - start }));
    }

    function visibleEvents(records) {
      const internals = document.getElementById("internals").checked;
      const hidden = new Set(internals ? [] : ["model_usage", "reasoning_observed"]);
      return records.filter((record) => !hidden.has((record.event || {}).type));
    }

    function renderLane(kind, trace, records, scale, rowHeight) {
      const axisX = kind === "serial" ? "96%" : "4%";
      const eventX = kind === "serial" ? "88%" : "12%";
      let previousEventTop = -rowHeight;
      const positions = records.map((record, index) => {
        const timeTop = Math.max(0, record.elapsed / 1000 * scale);
        const eventTop = Math.max(index * rowHeight, timeTop, previousEventTop + rowHeight);
        previousEventTop = eventTop;
        return { record, eventTop };
      });
      const points = positions.map(({ record, eventTop }) => {
        const event = record.event || {};
        const y = Math.max(48, record.elapsed / 1000 * scale + 48);
        return `<line class="connection" x1="${axisX}" y1="${y}" x2="${eventX}" y2="${48 + eventTop + 14}"/><circle class="connection-point" cx="${axisX}" cy="${y}" r="4"/>`;
      }).join("");
      const events = positions.map(({ record, eventTop }) => {
        const event = record.event || {};
        const goal = event.active_subgoal || event.subgoal_id || "";
        const title = `${goal ? `${goal} · ` : ""}${eventLabel(event)}`;
        return `<button class="event-card ${escapeAttr(event.type || "unknown")}" style="top:${eventTop}px" data-event="${escapeAttr(JSON.stringify({ record, lane: kind }))}" title="${escapeAttr(title)}"><span class="event-label">${escapeHtml(title)}</span><span class="event-time">+${escapeHtml(formatDuration(record.elapsed))}</span></button>`;
      }).join("");
      const run = shortRunName(trace.id || "");
      return `<section class="lane ${kind}"><svg class="connections" aria-hidden="true">${points}</svg><div class="lane-head">${kind === "serial" ? "Serial baseline" : "SoG concurrent"}<div class="muted">${escapeHtml(run)}</div></div><div class="event-list">${events}</div></section>`;
    }

    function shortRunName(id) {
      const directory = String(id).split("/").slice(-2, -1)[0] || id;
      return directory.split("--").slice(-3).join(" · ");
    }

    function showInspector(encoded, pointer) {
      const data = JSON.parse(encoded);
      const event = data.record.event || {};
      const inspector = document.getElementById("inspector");
      inspector.classList.add("visible");
      inspector.innerHTML = `<div class="inspector-head"><span>${escapeHtml(data.lane)} · ${escapeHtml(eventLabel(event))}</span><span class="inspector-time">+${formatDuration(data.record.elapsed)}</span></div><pre>${escapeHtml(eventBody(event))}</pre>`;
      positionInspector(pointer.clientX, pointer.clientY);
    }

    function positionInspector(x, y) {
      const inspector = document.getElementById("inspector");
      if (!inspector.classList.contains("visible")) return;
      const margin = 14;
      const bounds = inspector.getBoundingClientRect();
      const left = Math.min(x + margin, window.innerWidth - bounds.width - margin);
      const top = Math.min(y + margin, window.innerHeight - bounds.height - margin);
      inspector.style.left = `${Math.max(margin, left)}px`;
      inspector.style.top = `${Math.max(margin, top)}px`;
    }

    function hideInspector() {
      document.getElementById("inspector").classList.remove("visible");
    }

    function handleTrackpadZoom(event) {
      if (!event.ctrlKey) return;
      event.preventDefault();
      state.zoom *= Math.exp(-event.deltaY * 0.01);
      render();
    }

    function handlePointerDown(event) {
      state.pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
      if (state.pointers.size === 2) state.pinchDistance = currentPinchDistance();
    }

    function handlePointerMove(event) {
      if (!state.pointers.has(event.pointerId)) return;
      state.pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
      if (state.pointers.size !== 2 || !state.pinchDistance) return;
      const distance = currentPinchDistance();
      state.zoom *= distance / state.pinchDistance;
      state.pinchDistance = distance;
      event.preventDefault();
      render();
    }

    function handlePointerEnd(event) {
      state.pointers.delete(event.pointerId);
      state.pinchDistance = state.pointers.size === 2 ? currentPinchDistance() : null;
    }

    function currentPinchDistance() {
      const points = Array.from(state.pointers.values());
      return Math.hypot(points[0].x - points[1].x, points[0].y - points[1].y);
    }

    function eventLabel(event) {
      if (event.type === "assistant_message") return "agent text";
      if (event.type === "harness_started") return "system prompt";
      if (event.type === "tool_call") return toolCallLabel(event);
      if (event.type === "tool_result") return `result · ${event.tool_name || "?"}`;
      if (event.type === "subgoal_started") return `begin · ${event.subgoal_id || "?"}`;
      if (event.type === "subgoal_ended") return `end · ${event.status || ""}`;
      if (event.type === "dag_snapshot") return `DAG · ${event.phase || ""}`;
      return event.type || "unknown";
    }

    function toolCallLabel(event) {
      const name = event.tool_name || "?";
      const args = event.arguments || {};
      if (name === "shell" && args.command) return `shell · ${args.command.split("\\n")[0]}`;
      if (name === "write_file" && args.path) return `write_file · ${args.path}`;
      return `tool · ${name}`;
    }

    function eventBody(event) {
      if (event.type === "assistant_message" || event.type === "user_message") return event.content || "";
      if (event.type === "tool_call") {
        const args = event.arguments || {};
        if (event.tool_name === "shell" && args.command) return `$ ${args.command}`;
        if (event.tool_name === "write_file" && args.path) return `path: ${args.path}\n\ncontent:\n${args.content || ""}`;
        return JSON.stringify(args, null, 2);
      }
      if (event.type === "tool_result") return event.result || "";
      if (event.type === "subgoal_ended") return event.summary || "";
      if (event.type === "effect_recorded") return JSON.stringify(event.effect || {});
      if (event.type === "dag_snapshot") return `${(event.running || []).join(", ")} | completed: ${(event.completed || []).join(", ")}`;
      return JSON.stringify(event);
    }

    function shortTime(value) { return new Date(value).toISOString().slice(11, 19); }
    function formatDuration(ms) { return `${(ms / 1000).toFixed(1)}s`; }
    function escapeHtml(value) { return String(value).replace(/[&<>"']/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch])); }
    function escapeAttr(value) { return escapeHtml(value).replace(/`/g, "&#96;"); }
  </script>
</body>
</html>
"""


if __name__ == "__main__":
    main()
