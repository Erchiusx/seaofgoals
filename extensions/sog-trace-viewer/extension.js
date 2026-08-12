const vscode = require("vscode");

function activate(context) {
  const disposable = vscode.commands.registerCommand("sogTrace.openTrace", async (uri) => {
    try {
      const traceUri = await resolveTraceUri(uri);
      if (!traceUri) {
        return;
      }

      const trace = await readTrace(traceUri);
      const panel = vscode.window.createWebviewPanel(
        "sogTraceView",
        `SOG Trace: ${basename(traceUri.fsPath)}`,
        vscode.ViewColumn.Beside,
        { enableScripts: true }
      );

      panel.webview.html = renderTraceHtml(panel.webview, traceUri, trace);
    } catch (error) {
      vscode.window.showErrorMessage(`Could not open SOG trace: ${error.message || String(error)}`);
    }
  });

  context.subscriptions.push(disposable);
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
