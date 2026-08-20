const vscode = require("vscode");

function activate(context) {
  context.subscriptions.push(registerTraceCommand("sogTrace.openTrace", "sogTraceView", "SOG Trace", renderTraceHtml));
  context.subscriptions.push(registerTraceCommand("sogTrace.openGoalColumns", "sogTraceGoalColumns", "SOG Goals", renderGoalColumnsHtml));
}

function registerTraceCommand(command, viewType, titlePrefix, render) {
  return vscode.commands.registerCommand(command, async (uri) => {
    try {
      const traceUri = await resolveTraceUri(uri);
      if (!traceUri) {
        return;
      }

      const trace = await readTrace(traceUri);
      const panel = vscode.window.createWebviewPanel(
        viewType,
        `${titlePrefix}: ${basename(traceUri.fsPath)}`,
        vscode.ViewColumn.Beside,
        { enableScripts: true }
      );

      panel.webview.html = render(panel.webview, traceUri, trace);
    } catch (error) {
      vscode.window.showErrorMessage(`Could not open SOG trace: ${error.message || String(error)}`);
    }
  });
}

function deactivate() {}

async function resolveTraceUri(uri) {
  if (uri && uri.scheme) {
    return uri;
  }

  const activeUri = vscode.window.activeTextEditor && vscode.window.activeTextEditor.document.uri;
  if (activeUri && activeUri.fsPath.endsWith("sog-trace.jsonl")) {
    return activeUri;
  }

  const picked = await vscode.window.showOpenDialog({
    canSelectFiles: true,
    canSelectFolders: false,
    canSelectMany: false,
    filters: { "SeaOfGoals traces": ["jsonl"], "All files": ["*"] },
    title: "Open sog-trace.jsonl",
  });

  return picked && picked[0];
}

async function readTrace(uri) {
  const bytes = await vscode.workspace.fs.readFile(uri);
  const text = Buffer.from(bytes).toString("utf8");
  const events = [];
  const parseErrors = [];

  text.split(/\r?\n/).forEach((line, index) => {
    if (!line.trim()) {
      return;
    }
    try {
      events.push({ line: index + 1, record: JSON.parse(line) });
    } catch (error) {
      parseErrors.push({ line: index + 1, message: error.message, text: line.slice(0, 200) });
    }
  });

  return { events, parseErrors };
}

function renderTraceHtml(webview, uri, trace) {
  const nonce = String(Date.now()) + String(Math.random()).slice(2);
  const cells = trace.events.map((event, index) => renderCell(event, index)).join("\n");
  const summary = summarizeTrace(trace);
  const parseErrors = trace.parseErrors.map(renderParseError).join("\n");
  const cspSource = webview.cspSource;

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src ${cspSource} 'unsafe-inline'; script-src 'nonce-${nonce}';">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>SeaOfGoals Trace</title>
  <style>
    :root {
      --bg: var(--vscode-editor-background);
      --fg: var(--vscode-editor-foreground);
      --muted: var(--vscode-descriptionForeground);
      --border: var(--vscode-panel-border);
      --cell: var(--vscode-sideBar-background);
      --code: var(--vscode-textCodeBlock-background);
      --accent: var(--vscode-focusBorder);
      --error: var(--vscode-errorForeground);
      --ok: #3fb950;
      --warn: #d29922;
    }
    body {
      margin: 0;
      padding: 0;
      background: var(--bg);
      color: var(--fg);
      font: 13px/1.45 var(--vscode-font-family);
    }
    header {
      position: sticky;
      top: 0;
      z-index: 2;
      padding: 12px 18px;
      background: var(--bg);
      border-bottom: 1px solid var(--border);
    }
    h1 {
      margin: 0 0 8px;
      font-size: 16px;
      font-weight: 600;
    }
    .path, .meta {
      color: var(--muted);
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .toolbar {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      margin-top: 10px;
    }
    button {
      color: var(--fg);
      background: var(--cell);
      border: 1px solid var(--border);
      border-radius: 4px;
      padding: 4px 8px;
      cursor: pointer;
    }
    button.active {
      outline: 1px solid var(--accent);
    }
    main {
      padding: 16px 18px 32px;
      max-width: 1180px;
    }
    .cell {
      display: grid;
      grid-template-columns: 56px 1fr;
      gap: 10px;
      margin: 0 0 10px;
    }
    .gutter {
      color: var(--muted);
      text-align: right;
      padding-top: 9px;
      font-variant-numeric: tabular-nums;
    }
    .card {
      border: 1px solid var(--border);
      border-radius: 6px;
      background: var(--cell);
      overflow: hidden;
    }
    .card-head {
      display: flex;
      justify-content: space-between;
      gap: 12px;
      padding: 8px 10px;
      border-bottom: 1px solid var(--border);
    }
    .kind {
      font-weight: 600;
    }
    .subgoal {
      color: var(--muted);
    }
    .time {
      color: var(--muted);
      font-variant-numeric: tabular-nums;
      white-space: nowrap;
    }
    .body {
      padding: 10px;
    }
    pre {
      margin: 0;
      padding: 10px;
      overflow: auto;
      background: var(--code);
      border-radius: 4px;
      white-space: pre-wrap;
      word-break: break-word;
    }
    .harness_started .card { border-left: 3px solid var(--accent); }
    .assistant_message .card { border-left: 3px solid #8b949e; }
    .tool_call .card { border-left: 3px solid #58a6ff; }
    .tool_result .card { border-left: 3px solid #a371f7; }
    .subgoal_started .card { border-left: 3px solid var(--ok); }
    .subgoal_ended .card { border-left: 3px solid var(--warn); }
    .effect_recorded .card { border-left: 3px solid #f778ba; }
    .workflow_status .card { border-left: 3px solid #79c0ff; }
    .harness_finished .card { border-left: 3px solid var(--ok); }
    .parse-error {
      border: 1px solid var(--error);
      color: var(--error);
      border-radius: 6px;
      padding: 10px;
      margin-bottom: 10px;
    }
    .hidden {
      display: none;
    }
  </style>
</head>
<body>
  <header>
    <h1>SeaOfGoals Trace</h1>
    <div class="path">${escapeHtml(uri.fsPath)}</div>
    <div class="meta">${escapeHtml(summary)}</div>
    <div class="toolbar">
      ${filterButton("all", "All")}
      ${filterButton("subgoal", "Subgoals")}
      ${filterButton("tool", "Tools")}
      ${filterButton("effect", "Effects")}
      ${filterButton("workflow", "Workflow")}
      ${filterButton("message", "Messages")}
    </div>
  </header>
  <main>
    ${parseErrors}
    ${cells || "<p>No events found.</p>"}
  </main>
  <script nonce="${nonce}">
    const buttons = Array.from(document.querySelectorAll("[data-filter]"));
    const cells = Array.from(document.querySelectorAll(".cell"));
    buttons.forEach((button) => {
      button.addEventListener("click", () => {
        const filter = button.dataset.filter;
        buttons.forEach((item) => item.classList.toggle("active", item === button));
        cells.forEach((cell) => {
          cell.classList.toggle("hidden", filter !== "all" && !cell.dataset.groups.split(" ").includes(filter));
        });
      });
    });
  </script>
</body>
</html>`;
}

function filterButton(filter, label) {
  const active = filter === "all" ? " active" : "";
  return `<button class="${active}" data-filter="${filter}">${label}</button>`;
}

function renderGoalColumnsHtml(webview, uri, trace) {
  const summary = summarizeTrace(trace);
  const timeline = buildTimelineModel(trace.events);
  const parseErrors = trace.parseErrors.map(renderParseError).join("\n");
  const cspSource = webview.cspSource;
  const board = renderTimelineBoard(timeline);

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src ${cspSource} 'unsafe-inline';">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>SeaOfGoals Goal Timeline</title>
  <style>
    :root {
      --bg: var(--vscode-editor-background);
      --fg: var(--vscode-editor-foreground);
      --muted: var(--vscode-descriptionForeground);
      --border: var(--vscode-panel-border);
      --cell: var(--vscode-sideBar-background);
      --code: var(--vscode-textCodeBlock-background);
      --accent: var(--vscode-focusBorder);
      --ok: #3fb950;
      --warn: #d29922;
      --bad: var(--vscode-errorForeground);
      --tool: #58a6ff;
      --result: #a371f7;
      --effect: #f778ba;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      padding: 0;
      background: var(--bg);
      color: var(--fg);
      font: 13px/1.45 var(--vscode-font-family);
    }
    header {
      position: sticky;
      top: 0;
      z-index: 3;
      padding: 12px 18px;
      background: var(--bg);
      border-bottom: 1px solid var(--border);
    }
    h1 {
      margin: 0 0 8px;
      font-size: 16px;
      font-weight: 600;
    }
    .path, .meta {
      color: var(--muted);
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .timeline-wrap {
      height: calc(100vh - 82px);
      overflow: auto;
      padding: 0 0 28px;
    }
    .timeline {
      display: grid;
      grid-auto-rows: minmax(44px, auto);
      gap: 0;
      min-width: max-content;
      padding: 0 18px 18px;
    }
    .corner,
    .goal-head,
    .time-cell,
    .slot {
      border-right: 1px solid var(--border);
      border-bottom: 1px solid var(--border);
    }
    .corner {
      position: sticky;
      top: 0;
      left: 0;
      z-index: 4;
      min-width: 150px;
      padding: 10px;
      background: var(--bg);
      color: var(--muted);
      font-weight: 600;
    }
    .goal-head {
      position: sticky;
      top: 0;
      z-index: 3;
      width: 330px;
      min-width: 330px;
      padding: 10px;
      background: var(--cell);
    }
    .goal-id {
      font-weight: 700;
      color: var(--accent);
    }
    .goal-name {
      margin-top: 2px;
      font-size: 13px;
    }
    .status {
      display: inline-block;
      margin-top: 7px;
      padding: 2px 7px;
      border-radius: 999px;
      font-size: 11px;
      border: 1px solid var(--border);
    }
    .status.success { color: var(--ok); }
    .status.failed, .status.blocked { color: var(--bad); }
    .status.unknown { color: var(--warn); }
    .counts {
      margin-top: 7px;
      color: var(--muted);
      font-size: 12px;
    }
    .time-cell {
      position: sticky;
      left: 0;
      z-index: 2;
      width: 150px;
      min-width: 150px;
      padding: 8px 10px;
      background: var(--bg);
      color: var(--muted);
      font-size: 12px;
      font-variant-numeric: tabular-nums;
    }
    .slot {
      width: 330px;
      min-width: 330px;
      padding: 6px;
      background: color-mix(in srgb, var(--bg) 85%, var(--cell));
    }
    .slot.empty {
      background: var(--bg);
    }
    .event {
      padding: 8px;
      border: 1px solid var(--border);
      border-left: 3px solid var(--muted);
      border-radius: 5px;
      background: var(--bg);
    }
    .event.tool_call { border-left-color: var(--tool); }
    .event.tool_result { border-left-color: var(--result); }
    .event.effect_recorded { border-left-color: var(--effect); }
    .event.subgoal_started { border-left-color: var(--ok); }
    .event.subgoal_ended { border-left-color: var(--warn); }
    .event.harness_finished { border-left-color: var(--ok); }
    .event.merge,
    .event.conflict,
    .event.replan { border-left-color: var(--bad); }
    .event.llm-error { border-left-color: var(--bad); }
    .event-top {
      display: flex;
      justify-content: space-between;
      gap: 8px;
      color: var(--muted);
      font-size: 11px;
      font-variant-numeric: tabular-nums;
    }
    .event-title {
      margin-top: 4px;
      font-weight: 600;
    }
    pre {
      margin: 7px 0 0;
      padding: 8px;
      overflow: auto;
      background: var(--code);
      border-radius: 4px;
      white-space: pre-wrap;
      word-break: break-word;
      max-height: 260px;
    }
    .parse-error {
      border: 1px solid var(--bad);
      color: var(--bad);
      border-radius: 6px;
      padding: 10px;
      margin: 16px 18px 0;
    }
  </style>
</head>
<body>
  <header>
    <h1>SeaOfGoals Goal Timeline</h1>
    <div class="path">${escapeHtml(uri.fsPath)}</div>
    <div class="meta">${escapeHtml(summary)} · timeline rows: ${timeline.rows.length}</div>
  </header>
  ${parseErrors}
  <main class="timeline-wrap">
    ${board || "<p>No goal events found.</p>"}
  </main>
</body>
</html>`;
}

function buildTimelineModel(items) {
  const goals = collectGoalMetadata(items);
  const rows = [];
  let hasRunColumn = false;

  items.forEach((item, index) => {
    const event = (item.record && item.record.event) || {};
    let goalId = goalIdForEvent(event);
    if (!goalId) {
      if (!isTimelineRunEvent(event)) {
        return;
      }
      goalId = "__run";
      hasRunColumn = true;
    }
    if (goalId !== "__run") {
      ensureGoal(goals, goalId);
    }
    rows.push({
      index: index + 1,
      goalId,
      timestamp: item.record.timestamp || "",
      compactTime: compactTimestamp(item.record.timestamp || ""),
      type: event.type || "unknown",
      title: eventTitle(event),
      body: compactEventBody(event),
      llmError: event.type === "harness_finished" && String(event.reason || "").includes("llm_error"),
      mergeLike: isMergeLikeEvent(event),
    });
  });

  const columns = [];
  if (hasRunColumn) {
    columns.push({
      id: "__run",
      name: "Run / scheduler",
      status: "meta",
      summary: "",
      tools: 0,
      effects: 0,
      events: [],
    });
  }
  columns.push(...Array.from(goals.values()));
  countGoalEvents(columns, rows);
  return { columns, rows };
}

function collectGoalMetadata(items) {
  const goals = new Map();
  for (const item of items) {
    const event = (item.record && item.record.event) || {};
    if (event.type === "harness_started") {
      const promptGoal = goalIdFromPrompt(event.prompt || "");
      if (promptGoal) {
        ensureGoal(goals, promptGoal);
      }
    } else if (event.type === "subgoal_started") {
      const goal = ensureGoal(goals, event.subgoal_id || "unknown");
      goal.name = event.subgoal_name || goal.name;
    } else if (event.type === "subgoal_ended") {
      const goal = ensureGoal(goals, event.subgoal_id || "unknown");
      goal.status = event.status || goal.status;
      goal.summary = event.summary || goal.summary;
    }
  }
  return goals;
}

function countGoalEvents(columns, rows) {
  const byId = new Map(columns.map((column) => [column.id, column]));
  for (const row of rows) {
    const column = byId.get(row.goalId);
    if (!column) continue;
    column.events.push(row);
    if (row.type === "tool_call") column.tools += 1;
    if (row.type === "effect_recorded") column.effects += 1;
  }
}

function renderTimelineBoard(timeline) {
  if (timeline.columns.length === 0) {
    return "";
  }
  const template = `150px repeat(${timeline.columns.length}, 330px)`;
  const heads = timeline.columns.map((column, index) => renderTimelineHead(column, index + 2)).join("\n");
  const rows = timeline.rows.map((row, index) => renderTimelineRow(timeline.columns, row, index + 2)).join("\n");
  return `<div class="timeline" style="grid-template-columns: ${template}">
    <div class="corner" style="grid-column: 1; grid-row: 1;">time</div>
    ${heads}
    ${rows}
  </div>`;
}

function renderTimelineHead(column, gridColumn) {
  const statusClass = column.status || "unknown";
  return `<div class="goal-head" style="grid-column: ${gridColumn}; grid-row: 1;">
    <div class="goal-id">${escapeHtml(column.id === "__run" ? "Run" : column.id)}</div>
    <div class="goal-name">${escapeHtml(column.name || "(unnamed)")}</div>
    <span class="status ${escapeAttr(statusClass)}">${escapeHtml(column.status || "unknown")}</span>
    <div class="counts">tools ${column.tools} · effects ${column.effects} · events ${column.events.length}</div>
  </div>`;
}

function renderTimelineRow(columns, row, gridRow) {
  const time = `<div class="time-cell" style="grid-column: 1; grid-row: ${gridRow};">
    <div>#${String(row.index).padStart(4, "0")}</div>
    <div>${escapeHtml(row.compactTime)}</div>
  </div>`;
  const cells = columns
    .map((column, index) => {
      const gridColumn = index + 2;
      if (column.id !== row.goalId) {
        return `<div class="slot empty" style="grid-column: ${gridColumn}; grid-row: ${gridRow};"></div>`;
      }
      return `<div class="slot" style="grid-column: ${gridColumn}; grid-row: ${gridRow};">${renderGoalEvent(row)}</div>`;
    })
    .join("\n");
  return time + "\n" + cells;
}

function buildGoalColumns(items) {
  const goals = new Map();

  for (const item of items) {
    const event = (item.record && item.record.event) || {};
    if (event.type === "harness_started") {
      const promptGoal = goalIdFromPrompt(event.prompt || "");
      if (promptGoal) {
        ensureGoal(goals, promptGoal);
      }
    } else if (event.type === "subgoal_started") {
      const goal = ensureGoal(goals, event.subgoal_id || "unknown");
      goal.name = event.subgoal_name || goal.name;
    } else if (event.type === "subgoal_ended") {
      const goal = ensureGoal(goals, event.subgoal_id || "unknown");
      goal.status = event.status || goal.status;
      goal.summary = event.summary || goal.summary;
    }
  }

  items.forEach((item, index) => {
    const event = (item.record && item.record.event) || {};
    const goalId = goalIdForEvent(event);
    if (!goalId) {
      return;
    }
    const goal = ensureGoal(goals, goalId);
    if (event.type === "tool_call") goal.tools += 1;
    if (event.type === "effect_recorded") goal.effects += 1;
    goal.events.push({
      index: index + 1,
      timestamp: item.record.timestamp || "",
      type: event.type || "unknown",
      title: eventTitle(event),
      body: compactEventBody(event),
      llmError: event.type === "harness_finished" && String(event.reason || "").includes("llm_error"),
    });
  });

  return Array.from(goals.values());
}

function ensureGoal(goals, goalId) {
  if (!goals.has(goalId)) {
    goals.set(goalId, {
      id: goalId,
      name: "",
      status: "unknown",
      summary: "",
      tools: 0,
      effects: 0,
      events: [],
    });
  }
  return goals.get(goalId);
}

function goalIdForEvent(event) {
  if (event.type === "subgoal_started" || event.type === "subgoal_ended") {
    return event.subgoal_id || "";
  }
  if (event.active_subgoal) {
    return event.active_subgoal;
  }
  if (event.active_node) {
    return event.active_node;
  }
  if (event.type === "harness_started") {
    return goalIdFromPrompt(event.prompt || "");
  }
  return "";
}

function goalIdFromPrompt(prompt) {
  const match = String(prompt).match(/Goal id:\s*([A-Za-z0-9_.:-]+)/);
  return match ? match[1] : "";
}

function compactEventBody(event) {
  switch (event.type) {
    case "harness_started":
      return firstPromptLines(event.prompt || "");
    case "assistant_message":
      return truncate(event.content || "(empty)", 800);
    case "tool_call":
      return truncate(JSON.stringify(event.arguments || {}, null, 2), 1200);
    case "tool_result":
      return truncate(event.result || "", 900);
    case "effect_recorded":
      return truncate(JSON.stringify(event.effect || {}, null, 2), 800);
    case "subgoal_started":
      return event.subgoal_name || "";
    case "subgoal_ended":
      return event.summary || "";
    case "workflow_status":
      return truncate(JSON.stringify({
        active_node: event.active_node,
        last_node: event.last_node,
        completed_nodes: event.completed_nodes || [],
        failed_nodes: event.failed_nodes || [],
        skipped_nodes: event.skipped_nodes || [],
        transition_warnings: event.transition_warnings || []
      }, null, 2), 800);
    case "harness_finished":
      return truncate(event.reason || "", 900);
    default:
      return truncate(JSON.stringify(event, null, 2), 900);
  }
}

function firstPromptLines(prompt) {
  const lines = String(prompt).split(/\r?\n/);
  const important = [];
  for (const line of lines) {
    if (
      line.startsWith("Goal id:") ||
      line.startsWith("Goal name:") ||
      line.startsWith("Execute exactly") ||
      line.startsWith("Focus ")
    ) {
      important.push(line);
    }
  }
  return important.join("\n") || truncate(prompt, 700);
}

function renderGoalColumn(goal) {
  const events = goal.events.map(renderGoalEvent).join("\n");
  const statusClass = goal.status || "unknown";
  return `<section class="goal">
    <div class="goal-head">
      <div class="goal-id">${escapeHtml(goal.id)}</div>
      <div class="goal-name">${escapeHtml(goal.name || "(unnamed)")}</div>
      <span class="status ${escapeAttr(statusClass)}">${escapeHtml(goal.status || "unknown")}</span>
      <div class="counts">tools ${goal.tools} · effects ${goal.effects} · events ${goal.events.length}</div>
    </div>
    ${goal.summary ? `<div class="summary">${escapeHtml(goal.summary)}</div>` : ""}
    <div class="events">${events}</div>
  </section>`;
}

function renderGoalEvent(event) {
  const body = event.body ? `<pre>${escapeHtml(event.body)}</pre>` : "";
  const classes = [
    event.type,
    event.llmError ? "llm-error" : "",
    event.mergeLike ? "merge" : "",
  ].filter(Boolean).join(" ");
  return `<article class="event ${escapeAttr(classes)}">
    <div class="event-top">
      <span>#${String(event.index).padStart(4, "0")}</span>
      <span>${escapeHtml(event.timestamp)}</span>
    </div>
    <div class="event-title">${escapeHtml(event.title)}</div>
    ${body}
  </article>`;
}

function renderCell(item, index) {
  const record = item.record || {};
  const event = record.event || {};
  const type = event.type || "unknown";
  const groups = eventGroups(type);
  const title = eventTitle(event);
  const subgoal = activeSubgoal(event);
  const body = eventBody(event);
  const time = record.timestamp || "";

  return `<section class="cell ${escapeAttr(type)}" data-groups="${escapeAttr(groups.join(" "))}">
    <div class="gutter">${String(index + 1).padStart(4, "0")}</div>
    <article class="card">
      <div class="card-head">
        <div>
          <span class="kind">${escapeHtml(title)}</span>
          ${subgoal ? `<span class="subgoal"> · ${escapeHtml(subgoal)}</span>` : ""}
        </div>
        <div class="time">${escapeHtml(time)}</div>
      </div>
      <div class="body">${body}</div>
    </article>
  </section>`;
}

function eventGroups(type) {
  if (type === "tool_call" || type === "tool_result") return ["tool"];
  if (type === "subgoal_started" || type === "subgoal_ended") return ["subgoal"];
  if (type === "effect_recorded") return ["effect"];
  if (type === "workflow_status") return ["workflow"];
  if (type === "assistant_message" || type === "harness_started") return ["message"];
  return ["message"];
}

function isTimelineRunEvent(event) {
  return event.type === "harness_finished" || isMergeLikeEvent(event);
}

function isMergeLikeEvent(event) {
  const type = String(event.type || "").toLowerCase();
  const reason = String(event.reason || "").toLowerCase();
  const effect = event.effect || {};
  const effectKind = String(effect.kind || "").toLowerCase();
  const effectDetail = String(effect.detail || "").toLowerCase();
  return (
    type.includes("merge") ||
    type.includes("conflict") ||
    type.includes("replan") ||
    reason.includes("merge") ||
    reason.includes("conflict") ||
    reason.includes("replan") ||
    effectKind.includes("merge") ||
    effectKind.includes("conflict") ||
    effectDetail.includes("merge conflict") ||
    effectDetail.includes("replan")
  );
}

function compactTimestamp(timestamp) {
  const text = String(timestamp || "");
  if (!text) {
    return "";
  }
  if (text.includes("T")) {
    return text.split("T", 2)[1].replace("Z", "").slice(0, 12);
  }
  return text.slice(0, 12);
}

function eventTitle(event) {
  switch (event.type) {
    case "harness_started":
      return "Prompt";
    case "assistant_message":
      return "Assistant";
    case "tool_call":
      return `Tool call: ${event.tool_name || ""}`;
    case "tool_result":
      return `Tool result: ${event.tool_name || ""}`;
    case "subgoal_started":
      return `Begin ${event.subgoal_id || ""}`;
    case "subgoal_ended":
      return `End ${event.subgoal_id || ""} (${event.status || "unknown"})`;
    case "effect_recorded":
      return "Effect";
    case "workflow_status":
      return "Workflow status";
    case "harness_finished":
      return `Finished: ${event.reason || ""}`;
    default:
      return event.type || "Unknown";
  }
}

function activeSubgoal(event) {
  if (event.active_subgoal) return `active ${event.active_subgoal}`;
  if (event.subgoal_name) return event.subgoal_name;
  if (event.arguments && event.arguments.id) return event.arguments.id;
  return "";
}

function eventBody(event) {
  switch (event.type) {
    case "harness_started":
      return `<pre>${escapeHtml(event.prompt || "")}</pre>`;
    case "assistant_message":
      return `<pre>${escapeHtml(event.content || "(empty)")}</pre>`;
    case "tool_call":
      return `<pre>${escapeHtml(JSON.stringify(event.arguments || {}, null, 2))}</pre>`;
    case "tool_result":
      return `<pre>${escapeHtml(event.result || "")}</pre>`;
    case "subgoal_started":
      return `<pre>${escapeHtml(event.subgoal_name || "")}</pre>`;
    case "subgoal_ended":
      return `<pre>${escapeHtml(event.summary || "")}</pre>`;
    case "effect_recorded":
      return `<pre>${escapeHtml(JSON.stringify(event.effect || {}, null, 2))}</pre>`;
    case "workflow_status":
      return `<pre>${escapeHtml(JSON.stringify({
        active_node: event.active_node,
        last_node: event.last_node,
        completed_nodes: event.completed_nodes || [],
        failed_nodes: event.failed_nodes || [],
        skipped_nodes: event.skipped_nodes || [],
        transition_warnings: event.transition_warnings || []
      }, null, 2))}</pre>`;
    case "harness_finished":
      return `<pre>${escapeHtml(event.reason || "")}</pre>`;
    default:
      return `<pre>${escapeHtml(JSON.stringify(event, null, 2))}</pre>`;
  }
}

function renderParseError(error) {
  return `<div class="parse-error">
    <strong>Parse error on line ${error.line}:</strong> ${escapeHtml(error.message)}
    <pre>${escapeHtml(error.text)}</pre>
  </div>`;
}

function summarizeTrace(trace) {
  const counts = new Map();
  let first = "";
  let last = "";
  for (const item of trace.events) {
    const event = item.record.event || {};
    counts.set(event.type || "unknown", (counts.get(event.type || "unknown") || 0) + 1);
    first = first || item.record.timestamp || "";
    last = item.record.timestamp || last;
  }
  const summary = Array.from(counts.entries())
    .map(([key, value]) => `${key}: ${value}`)
    .join(" · ");
  return `${trace.events.length} events${first ? ` · ${first} -> ${last}` : ""}${summary ? ` · ${summary}` : ""}`;
}

function basename(path) {
  return path.split(/[\\/]/).pop() || path;
}

function truncate(value, limit) {
  const text = String(value || "");
  if (text.length <= limit) {
    return text;
  }
  return `${text.slice(0, limit)}\n... truncated ...`;
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function escapeAttr(value) {
  return escapeHtml(value).replace(/\s+/g, " ");
}

module.exports = { activate, deactivate };
