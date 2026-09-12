import fs from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { Presentation, PresentationFile } from "@oai/artifact-tool";

const workspaceDir = "/home/erchius/development/scfg/SeaOfGoals";
const SKILL_DIR = "/home/erchius/.codex/plugins/cache/openai-primary-runtime/presentations/26.905.11957/skills/presentations";
const TMP_DIR = path.join(workspaceDir, ".pptx-build", "seaofgoals-progress");
const FINAL_PPTX = path.join(workspaceDir, "docs", "slides", "seaofgoals-progress-v2.pptx");
const RUNTIME_PYTHON = "/home/erchius/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python";

const { applyPresentationChartFont, finalizePresentation } = await import(
  pathToFileURL(path.join(SKILL_DIR, "container_tools/artifact_tool_utils.mjs")).href,
);

const W = 1280;
const H = 720;
const FONT = "Noto Sans";
const MONO = "Noto Sans Mono";
const C = {
  ink: "#17212B",
  muted: "#5F6B76",
  faint: "#E7EBEE",
  paper: "#F7F8F8",
  white: "#FFFFFF",
  teal: "#147D78",
  tealLight: "#D8EEEB",
  blue: "#356DA5",
  blueLight: "#DCE8F4",
  orange: "#D77A24",
  orangeLight: "#F6E4D2",
  purple: "#7256D8",
  red: "#B4473A",
  gray: "#A6AFB7",
};

await fs.mkdir(TMP_DIR, { recursive: true });
await fs.mkdir(path.dirname(FINAL_PPTX), { recursive: true });

const deck = Presentation.create({ slideSize: { width: W, height: H } });

function addText(slide, text, left, top, width, height, opts = {}) {
  const shape = slide.shapes.add({
    geometry: "textbox",
    position: { left, top, width, height },
    fill: "none",
    line: { fill: "none", width: 0 },
  });
  shape.text = text;
  shape.text.style = {
    typeface: opts.typeface ?? FONT,
    fontSize: opts.fontSize ?? 20,
    bold: opts.bold ?? false,
    color: opts.color ?? C.ink,
    autoFit: opts.autoFit ?? "shrinkText",
    verticalAlignment: opts.verticalAlignment ?? "top",
  };
  return shape;
}

function addBox(slide, left, top, width, height, fill, line = fill, radius = "rounded-sm") {
  return slide.shapes.add({
    geometry: "roundRect",
    position: { left, top, width, height },
    fill,
    line: { style: "solid", fill: line, width: 1 },
    borderRadius: radius,
  });
}

function addLine(slide, left, top, width, height, fill = C.faint, lineWidth = 1) {
  return slide.shapes.add({
    geometry: "line",
    position: { left, top, width, height },
    fill: "none",
    line: { style: "solid", fill, width: lineWidth },
  });
}

function addHeader(slide, title, number) {
  slide.background.fill = C.paper;
  addText(slide, title, 68, 42, 1030, 54, { fontSize: 34, bold: true });
  addText(slide, String(number).padStart(2, "0"), 1150, 49, 62, 28, {
    fontSize: 15,
    bold: true,
    color: C.muted,
  });
  addLine(slide, 68, 104, 1144, 0, C.faint, 1);
}

function addLabel(slide, text, left, top, width, color = C.teal) {
  addText(slide, text.toUpperCase(), left, top, width, 24, {
    fontSize: 13,
    bold: true,
    color,
  });
}

function addNode(slide, text, left, top, width, height, fill = C.white, line = C.gray, fontSize = 16) {
  const node = addBox(slide, left, top, width, height, fill, line);
  addText(slide, text, left + 10, top + 8, width - 20, height - 16, {
    fontSize,
    bold: true,
    verticalAlignment: "middle",
  });
  return node;
}

function connect(slide, from, to, opts = {}) {
  return slide.shapes.connect(from, to, {
    kind: opts.kind ?? "elbow",
    fromSide: opts.fromSide ?? "right",
    toSide: opts.toSide ?? "left",
    line: { style: opts.style ?? "solid", fill: opts.color ?? C.gray, width: opts.width ?? 2 },
    tail: { type: "arrow", width: "sm", length: "sm" },
  });
}

// 1. Cover
{
  const slide = deck.slides.add();
  slide.background.fill = C.paper;
  addText(slide, "SeaOfGoals", 72, 94, 730, 92, { fontSize: 58, bold: true });
  addText(slide, "Speculative parallelism for agent skills", 74, 197, 730, 42, {
    fontSize: 25,
    color: C.teal,
    bold: true,
  });
  addText(
    slide,
    "Compile a written workflow into a task DAG, execute independent goals in isolated workspaces, and recover when runtime effects reveal a missing dependency.",
    74,
    270,
    710,
    120,
    { fontSize: 23, color: C.muted },
  );

  const y = 498;
  const labels = ["skill", "compile", "schedule", "merge"];
  const fills = [C.blueLight, C.tealLight, C.orangeLight, C.white];
  const lines = [C.blue, C.teal, C.orange, C.gray];
  const nodes = labels.map((label, i) => addNode(slide, label, 74 + i * 213, y, 155, 62, fills[i], lines[i], 17));
  for (let i = 0; i < nodes.length - 1; i += 1) connect(slide, nodes[i], nodes[i + 1], { color: C.muted });

  addText(slide, "September 2026", 1000, 626, 210, 28, { fontSize: 15, color: C.muted });
  slide.speakerNotes.textFrame.setText("Source: SeaOfGoals repository development notes and experiment traces.");
}

// 2. Research question
{
  const slide = deck.slides.add();
  addHeader(slide, "Research question", 2);
  addText(
    slide,
    "Agent skills often describe a reliable serial workflow even when some steps could run concurrently.",
    70,
    142,
    1120,
    76,
    { fontSize: 27, bold: true },
  );

  const items = [
    ["Compile", "Infer goal boundaries and real dependencies from the skill text."],
    ["Execute", "Run ready goals concurrently in isolated workspaces."],
    ["Observe", "Track filesystem reads and writes as runtime effects."],
    ["Recover", "Add a missing dependency and rerun the later goal after a conflict."],
  ];
  items.forEach(([verb, body], i) => {
    const y = 260 + i * 82;
    addText(slide, String(i + 1).padStart(2, "0"), 82, y + 2, 46, 28, { fontSize: 14, bold: true, color: C.teal });
    addText(slide, verb, 148, y, 145, 34, { fontSize: 22, bold: true });
    addText(slide, body, 312, y, 820, 42, { fontSize: 20, color: C.muted });
    if (i < items.length - 1) addLine(slide, 148, y + 57, 984, 0, C.faint, 1);
  });
  addText(slide, "Current scope: filesystem effects and end-to-end wall time", 70, 640, 700, 28, {
    fontSize: 16,
    color: C.muted,
  });
}

// 3. Execution model
{
  const slide = deck.slides.add();
  addHeader(slide, "Execution model", 3);
  addLabel(slide, "Compile time", 72, 134, 260, C.blue);
  addLabel(slide, "Run time", 500, 134, 260, C.teal);

  const raw = addNode(slide, "Raw skill", 72, 190, 150, 68, C.blueLight, C.blue);
  const compiler = addNode(slide, "Compiler", 270, 190, 150, 68, C.white, C.blue);
  const dag = addNode(slide, "Ordered goal DAG", 468, 190, 180, 68, C.tealLight, C.teal);
  const planner = addNode(slide, "G000 planner", 696, 190, 170, 68, C.white, C.teal);
  const ready = addNode(slide, "Ready goals", 914, 190, 150, 68, C.white, C.teal);
  const merge = addNode(slide, "Merge", 1112, 190, 100, 68, C.orangeLight, C.orange);
  [raw, compiler, dag, planner, ready, merge].reduce((a, b) => {
    if (a) connect(slide, a, b, { color: C.muted });
    return b;
  }, null);

  addLine(slide, 72, 322, 1140, 0, C.faint, 1);
  addText(slide, "Host harness", 72, 354, 225, 38, { fontSize: 24, bold: true });
  addText(
    slide,
    "Owns the DAG, scheduling state, goal prompts, traces, snapshots, conflict detection, and merge decisions.",
    72,
    404,
    470,
    104,
    { fontSize: 20, color: C.muted },
  );

  addText(slide, "Goal agents", 666, 354, 225, 38, { fontSize: 24, bold: true });
  addText(
    slide,
    "Pi executes one goal per agent through bwrap. Every agent sees the stable path /workspace while the host manages separate snapshots.",
    666,
    404,
    500,
    104,
    { fontSize: 20, color: C.muted },
  );
  addBox(slide, 666, 540, 500, 70, C.white, C.faint);
  addText(slide, "/workspace", 694, 558, 170, 32, { fontSize: 19, bold: true, typeface: MONO, color: C.teal });
  addText(slide, "stable agent-visible path", 875, 558, 250, 32, { fontSize: 18, color: C.muted });
}

// 4. Conservative merge
{
  const slide = deck.slides.add();
  addHeader(slide, "Conservative merge baseline", 4);

  addLabel(slide, "Conflict rule", 72, 138, 240, C.orange);
  addText(slide, "A(Si) = R(Si) ∪ W(Si)", 72, 185, 520, 46, { fontSize: 27, bold: true, typeface: MONO });
  addText(
    slide,
    "conflict(Si,Sj) iff W(Si) ∩ A(Sj) ≠ ∅\nor W(Sj) ∩ A(Si) ≠ ∅",
    72,
    248,
    560,
    86,
    { fontSize: 22, typeface: MONO },
  );
  addText(slide, "Read/read overlap is allowed. Any overlap involving a write creates a conflict.", 72, 354, 540, 70, {
    fontSize: 19,
    color: C.muted,
  });

  const earlier = addNode(slide, "Earlier goal Si", 700, 168, 190, 70, C.tealLight, C.teal);
  const later = addNode(slide, "Later goal Sj", 988, 168, 190, 70, C.orangeLight, C.orange);
  connect(slide, earlier, later, { color: C.orange, width: 3 });
  addText(slide, "conflict", 909, 183, 74, 24, { fontSize: 14, bold: true, color: C.orange });

  const actions = [
    ["Keep Si", "Accept the earlier result."],
    ["Add Si → Sj", "Turn the observed conflict into a dependency."],
    ["Invalidate", "Discard Sj and completed descendants."],
    ["Rerun", "Resume from the merged workspace."],
  ];
  actions.forEach(([head, body], i) => {
    const y = 294 + i * 76;
    addText(slide, String(i + 1), 710, y + 1, 30, 30, { fontSize: 15, bold: true, color: C.orange });
    addText(slide, head, 756, y, 170, 30, { fontSize: 20, bold: true });
    addText(slide, body, 932, y, 280, 38, { fontSize: 17, color: C.muted });
  });
  addBox(slide, 72, 554, 540, 76, C.white, C.faint);
  addText(slide, "Fallback invariant", 94, 570, 165, 25, { fontSize: 16, bold: true, color: C.teal });
  addText(slide, "Failed speculation degrades toward the trusted serial workflow.", 264, 568, 320, 42, {
    fontSize: 18,
    color: C.muted,
  });
}

// 5. Preload and context
{
  const slide = deck.slides.add();
  addHeader(slide, "Reducing repeated exploration", 5);

  const columns = [72, 458, 844];
  const widths = [326, 326, 368];
  const labels = ["Preload", "Incremental planning", "Context boundary"];
  const bodies = [
    "G000 inspects the workspace and predicts files or read-only actions. The harness executes them and injects ordinary tool-call results into the goal history.",
    "G000 can publish several independent goal plans in one response. A goal waits for its own plan rather than the complete planning pass.",
    "Each goal starts with a fresh agent context. It receives explicit predecessor state and planned observations instead of ambient conversation history.",
  ];
  labels.forEach((label, i) => {
    addText(slide, String(i + 1).padStart(2, "0"), columns[i], 154, 42, 26, { fontSize: 14, bold: true, color: C.teal });
    addText(slide, label, columns[i], 198, widths[i], 44, { fontSize: 24, bold: true });
    addLine(slide, columns[i], 258, widths[i] - 24, 0, i === 0 ? C.blue : i === 1 ? C.teal : C.orange, 4);
    addText(slide, bodies[i], columns[i], 292, widths[i] - 12, 180, { fontSize: 19, color: C.muted });
  });

  addBox(slide, 72, 528, 1140, 92, C.ink, C.ink);
  addText(slide, "Model-visible history", 98, 550, 240, 30, { fontSize: 17, bold: true, color: C.white });
  addText(
    slide,
    "assistant tool call  +  real tool result  +  goal instruction",
    356,
    548,
    790,
    34,
    { fontSize: 19, typeface: MONO, color: "#E8F5F3" },
  );
  addText(slide, "Preload is represented as normal history, not a privileged context channel.", 356, 585, 790, 23, {
    fontSize: 15,
    color: "#B9C5CB",
  });
}

// 6. Port-widget experiment
{
  const slide = deck.slides.add();
  addHeader(slide, "Port-widget experiment", 6);
  addText(
    slide,
    "Port connectColorMenu across InstantSearch.js, React, Vue, common fixtures, and final validation.",
    72,
    128,
    1110,
    50,
    { fontSize: 21, color: C.muted },
  );

  const positions = {
    G000: [76, 224], G001: [212, 224], G002: [348, 224],
    G003: [518, 178], G004: [518, 250], G005: [518, 322],
    G006: [710, 250], G007: [862, 250], G008: [1014, 250],
  };
  const nodes = {};
  Object.entries(positions).forEach(([id, [x, y]]) => {
    const branch = ["G003", "G004", "G005"].includes(id);
    nodes[id] = addNode(slide, id, x, y, 92, 48, branch ? C.tealLight : C.white, branch ? C.teal : C.gray, 15);
  });
  [["G000", "G001"], ["G001", "G002"], ["G002", "G003"], ["G002", "G004"], ["G002", "G005"],
    ["G003", "G006"], ["G004", "G006"], ["G005", "G006"], ["G006", "G007"], ["G007", "G008"]]
    .forEach(([a, b]) => connect(slide, nodes[a], nodes[b], { color: C.gray, width: 1.5 }));

  addText(slide, "parallel branch", 534, 386, 150, 24, { fontSize: 14, bold: true, color: C.teal });

  addLabel(slide, "Single Pi baseline", 72, 468, 290, C.blue);
  addText(slide, "One Pi receives the full skill and follows its workflow. Parallel tool calls remain allowed within a turn.", 72, 500, 490, 92, {
    fontSize: 18,
    color: C.muted,
  });
  addLabel(slide, "SeaOfGoals concurrent", 664, 468, 320, C.teal);
  addText(slide, "One Pi per goal. Ready goals run concurrently. G000 incremental planning and preload are enabled.", 664, 500, 500, 92, {
    fontSize: 18,
    color: C.muted,
  });
  addText(slide, "Model: gpt-5.6    Fresh UUID workspace for every run", 72, 635, 700, 24, {
    fontSize: 15,
    typeface: MONO,
    color: C.muted,
  });
}

// 7. Ten-run results
{
  const slide = deck.slides.add();
  addHeader(slide, "Wall time across ten runs", 7);
  const serial = [169.8, 174.0, 181.4, 189.7, 201.1, 212.4, 219.8, 222.9, 229.4, 357.8];
  const concurrent = [196.3, 201.6, 202.3, 208.1, 215.4, 215.8, 232.7, 232.7, 236.5, 276.4];
  const chart = slide.charts.add("line", {
    position: { left: 68, top: 142, width: 810, height: 446 },
    categories: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10"],
    series: [
      { name: "Single Pi", values: serial, line: { style: "solid", fill: C.blue, width: 3 } },
      { name: "SoG concurrent", values: concurrent, line: { style: "solid", fill: C.teal, width: 3 } },
    ],
    legend: { position: "bottom", overlay: false },
    xAxis: { title: { text: "Run rank, fastest to slowest" } },
    yAxis: {
      title: { text: "Wall time, seconds" },
      minimumScale: 150,
      maximumScale: 380,
      majorGridlines: { style: "solid", fill: C.faint, width: 1 },
    },
  });
  applyPresentationChartFont(chart, { fontFamily: FONT });

  addLabel(slide, "Median", 930, 152, 180, C.teal);
  addText(slide, "206.8s", 930, 184, 180, 46, { fontSize: 30, bold: true, color: C.blue });
  addText(slide, "Single Pi", 930, 230, 180, 25, { fontSize: 16, color: C.muted });
  addText(slide, "215.6s", 930, 280, 180, 46, { fontSize: 30, bold: true, color: C.teal });
  addText(slide, "SoG concurrent", 930, 326, 220, 25, { fontSize: 16, color: C.muted });
  addLine(slide, 930, 382, 250, 0, C.faint, 1);
  addText(slide, "+8.8s", 930, 410, 180, 42, { fontSize: 27, bold: true, color: C.orange });
  addText(slide, "median difference", 930, 454, 220, 25, { fontSize: 16, color: C.muted });

  addBox(slide, 68, 614, 1112, 52, C.white, C.faint);
  addText(slide, "Current result", 90, 628, 150, 24, { fontSize: 15, bold: true, color: C.teal });
  addText(slide, "No stable speedup yet. Concurrent runs vary less, but their median is slower.", 252, 626, 900, 28, {
    fontSize: 18,
    color: C.ink,
  });
  slide.speakerNotes.textFrame.setText("Source: ten fresh-workspace runs recorded in the SeaOfGoals port-widget experiment directories.");
}

// 8. Timing and next steps
{
  const slide = deck.slides.add();
  addHeader(slide, "Model execution dominates the current runtime", 8);
  addText(slide, "Summed phase time by goal in the latest instrumented concurrent run", 72, 124, 760, 28, {
    fontSize: 17,
    color: C.muted,
  });
  const categories = ["G000", "G001", "G002", "G003", "G004", "G005", "G006", "G007", "G008"];
  const wait = [25.1, 8.7, 9.3, 26.9, 35.9, 16.7, 12.7, 8.8, 10.6];
  const reasoning = [0.2, 0, 0, 0.2, 0.3, 1.5, 0.4, 0, 0];
  const generation = [7.0, 12.2, 0.1, 33.9, 35.9, 44.2, 17.6, 3.7, 11.2];
  const chart = slide.charts.add("bar", {
    position: { left: 60, top: 168, width: 770, height: 424 },
    categories,
    series: [
      { name: "Model wait", values: wait, fill: C.gray },
      { name: "Reasoning", values: reasoning, fill: C.purple },
      { name: "Generation", values: generation, fill: C.teal },
    ],
    barOptions: { direction: "bar", grouping: "stacked", gapWidth: 38 },
    legend: { position: "bottom", overlay: false },
    xAxis: { title: { text: "Seconds; goal intervals overlap" }, majorGridlines: { style: "solid", fill: C.faint, width: 1 } },
    yAxis: { reverseOrder: true },
  });
  applyPresentationChartFont(chart, { fontFamily: FONT });

  addLabel(slide, "Interpretation", 884, 152, 250, C.teal);
  const points = [
    "Separate goal agents repeat some generation and exploration.",
    "G000 adds model calls before downstream work becomes ready.",
    "Provider latency dominates local filesystem tool execution.",
  ];
  points.forEach((text, i) => {
    addText(slide, String(i + 1), 884, 202 + i * 78, 28, 28, { fontSize: 15, bold: true, color: C.teal });
    addText(slide, text, 926, 198 + i * 78, 278, 58, { fontSize: 18, color: C.muted });
  });
  addLine(slide, 884, 450, 310, 0, C.faint, 1);
  addLabel(slide, "Next experiments", 884, 480, 250, C.orange);
  addText(
    slide,
    "Predict commands beyond file preload. Stream plans as each tool call completes. Test workflows with larger independent branches.",
    884,
    520,
    320,
    112,
    { fontSize: 18, color: C.ink },
  );
  addText(slide, "Latest run wall time: 190.7s", 72, 634, 360, 24, { fontSize: 15, color: C.muted, typeface: MONO });
  slide.speakerNotes.textFrame.setText("Source: trace 3b63930a-0802-4315-b158-18ae269e1ed3. Phase totals overlap because goals execute concurrently.");
}

const requirements = {
  explicitTotalSlideCount: 8,
  requiredNativeTableOwnerSlides: [],
  requiredNativeChartOwnerSlides: [7, 8],
  materializeLiteralChartWorkbooks: true,
};
const fontPolicy = { basis: "design", families: [FONT, MONO] };
const expectedSlideSizeEmu = "12192000,6858000";

const stagingDir = path.join(workspaceDir, ".codex-finalizer");
await fs.mkdir(stagingDir, { recursive: true });
const candidatePath = path.join(stagingDir, "seaofgoals-progress-v2-candidate.pptx");
await (await PresentationFile.exportPptx(deck)).save(candidatePath);

await finalizePresentation({
  ...requirements,
  workspaceDir,
  candidatePath,
  finalPath: FINAL_PPTX,
  pythonExecutable: RUNTIME_PYTHON,
  integrityValidatorPath: path.join(SKILL_DIR, "container_tools/inspect_presentation_package_integrity.py"),
  layoutValidatorPath: path.join(SKILL_DIR, "container_tools/inspect_presentation_layout_geometry.py"),
  layoutArgs: [
    "--expected-slide-size-emu", expectedSlideSizeEmu,
    "--validate-bullet-geometry",
    "--validate-heading-fit",
  ],
  requiredNativeTableOwnerSlides: [],
  fontPolicy,
  verifyArtifactToolImport: true,
  receiptPath: path.join(TMP_DIR, "seaofgoals-progress-v2.validation.json"),
});

for (const [index, slide] of deck.slides.items.entries()) {
  const png = await deck.export({ slide, format: "png", scale: 1 });
  await fs.writeFile(path.join(TMP_DIR, `slide-${String(index + 1).padStart(2, "0")}.png`), new Uint8Array(await png.arrayBuffer()));
}

console.log(FINAL_PPTX);
