#!/usr/bin/env python3
import argparse
import html
import json
import shutil
import subprocess
from collections import defaultdict, deque
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description="Render SeaOfGoals sog.json DAGs as standalone HTML.")
    parser.add_argument("sog_json", nargs="+", help="Path(s) to sog.json files.")
    parser.add_argument("--out", help="Output path. Only valid for one input; defaults to sog.html next to input.")
    args = parser.parse_args()

    if args.out and len(args.sog_json) != 1:
        parser.error("--out can only be used with a single input")

    for raw_path in args.sog_json:
        path = Path(raw_path)
        out = Path(args.out) if args.out else path.with_name("sog.html")
        render_file(path, out)
        print(f"wrote {out}")


def render_file(path, out):
    graph = json.loads(path.read_text(encoding="utf-8"))
    goals = graph["goals"]
    goal_by_id = {goal["id"]: goal for goal in goals}
    levels = topo_levels(goals)
    matrix = dependency_matrix(goals)
    mermaid = mermaid_graph(goals)
    dot = graphviz_dot(goals)
    svg = render_graphviz_svg(dot)

    out.write_text(
        page(
            title=f"{graph.get('skill', path.parent.name)} workflow",
            source_path=str(path),
            levels=levels,
            goals=goals,
            matrix=matrix,
            mermaid=mermaid,
            dot=dot,
            svg=svg,
            goal_by_id=goal_by_id,
        ),
        encoding="utf-8",
    )


def topo_levels(goals):
    successors = defaultdict(list)
    indegree = {goal["id"]: 0 for goal in goals}
    for goal in goals:
        for pred in goal.get("predecessors", []):
            successors[pred].append(goal["id"])
            indegree[goal["id"]] += 1

    ready = deque([goal["id"] for goal in goals if indegree[goal["id"]] == 0])
    level_by_id = {}
    while ready:
        current = ready.popleft()
        preds = next(goal for goal in goals if goal["id"] == current).get("predecessors", [])
        level_by_id[current] = 0 if not preds else 1 + max(level_by_id[pred] for pred in preds)
        for nxt in successors[current]:
            indegree[nxt] -= 1
            if indegree[nxt] == 0:
                ready.append(nxt)

    levels = defaultdict(list)
    for goal in goals:
        levels[level_by_id[goal["id"]]].append(goal)
    return [levels[index] for index in sorted(levels)]


def dependency_matrix(goals):
    ids = [goal["id"] for goal in goals]
    predecessors = {goal["id"]: set(goal.get("predecessors", [])) for goal in goals}
    return {
        "ids": ids,
        "rows": [[1 if src in predecessors[dst] else 0 for dst in ids] for src in ids],
    }


def mermaid_graph(goals):
    lines = ["graph LR"]
    for goal in goals:
        lines.append(f'  {goal["id"]}["{escape_mermaid(goal["id"] + ": " + goal["name"])}"]')
    for goal in goals:
        for pred in goal.get("predecessors", []):
            lines.append(f"  {pred} --> {goal['id']}")
    return "\n".join(lines)


def graphviz_dot(goals):
    lines = [
        "digraph sog {",
        "  graph [rankdir=LR, bgcolor=\"transparent\", pad=\"0.2\", nodesep=\"0.45\", ranksep=\"0.65\"];",
        "  node [shape=box, style=\"rounded,filled\", fillcolor=\"white\", color=\"#bcccdc\", penwidth=1.2, fontname=\"Inter,Arial,sans-serif\", fontsize=11, margin=\"0.10,0.08\"];",
        "  edge [color=\"#486581\", arrowsize=0.7, penwidth=1.2];",
    ]
    for goal in goals:
        label = f"{goal['id']}\n{goal['name']}"
        lines.append(f'  "{escape_dot(goal["id"])}" [label="{escape_dot(label)}"];')
    for goal in goals:
        for pred in goal.get("predecessors", []):
            lines.append(f'  "{escape_dot(pred)}" -> "{escape_dot(goal["id"])}";')
    lines.append("}")
    return "\n".join(lines)


def render_graphviz_svg(dot):
    if shutil.which("dot") is None:
        return None
    result = subprocess.run(
        ["dot", "-Tsvg"],
        input=dot,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    return result.stdout


def page(title, source_path, levels, goals, matrix, mermaid, dot, svg, goal_by_id):
    return f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>{html.escape(title)}</title>
  <style>
    body {{ margin: 0; font: 14px/1.45 system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: #1f2933; background: #f7f8fa; }}
    header {{ padding: 20px 28px; background: #102a43; color: white; }}
    header h1 {{ margin: 0 0 4px; font-size: 22px; font-weight: 650; }}
    header div {{ color: #cbd5e1; font-size: 13px; }}
    main {{ padding: 24px 28px 40px; }}
    h2 {{ margin: 28px 0 12px; font-size: 16px; }}
    .graphviz {{ background: white; border: 1px solid #d9e2ec; border-radius: 8px; padding: 16px; overflow-x: auto; }}
    .graphviz svg {{ max-width: none; height: auto; }}
    .levels {{ display: flex; gap: 16px; align-items: flex-start; overflow-x: auto; padding-bottom: 10px; }}
    .level {{ min-width: 260px; max-width: 320px; }}
    .level-title {{ font-weight: 650; color: #52606d; margin-bottom: 8px; }}
    .goal {{ background: white; border: 1px solid #d9e2ec; border-radius: 8px; padding: 12px; margin-bottom: 10px; box-shadow: 0 1px 2px rgba(16, 42, 67, 0.05); }}
    .goal-id {{ font-weight: 700; color: #0b69a3; }}
    .goal-name {{ font-weight: 650; margin-top: 2px; }}
    .goal-desc {{ margin-top: 8px; color: #52606d; font-size: 13px; }}
    .preds {{ margin-top: 8px; color: #7b8794; font-size: 12px; }}
    table {{ border-collapse: collapse; background: white; }}
    th, td {{ border: 1px solid #d9e2ec; padding: 6px 8px; text-align: center; }}
    th {{ background: #edf2f7; font-weight: 650; }}
    td.one {{ background: #bee3f8; color: #0b69a3; font-weight: 700; }}
    pre {{ background: #102a43; color: #d9e2ec; padding: 14px; border-radius: 8px; overflow-x: auto; }}
    .edge-list {{ columns: 2; column-gap: 28px; }}
    .edge-list div {{ break-inside: avoid; margin-bottom: 4px; }}
  </style>
</head>
<body>
  <header>
    <h1>{html.escape(title)}</h1>
    <div>{html.escape(source_path)}</div>
  </header>
  <main>
    <h2>Graph</h2>
    <section class="graphviz">
      {render_graphviz(svg, dot)}
    </section>
    <h2>Topological Levels</h2>
    <section class="levels">
      {render_levels(levels)}
    </section>
    <h2>Edges</h2>
    <section class="edge-list">
      {render_edges(goals, goal_by_id)}
    </section>
    <h2>Dependency Matrix</h2>
    {render_matrix(matrix)}
    <h2>Mermaid</h2>
    <pre>{html.escape(mermaid)}</pre>
    <h2>Graphviz DOT</h2>
    <pre>{html.escape(dot)}</pre>
  </main>
</body>
</html>
"""


def render_graphviz(svg, dot):
    if svg:
        return svg
    return f"<pre>{html.escape(dot)}</pre>"


def render_levels(levels):
    chunks = []
    for index, goals in enumerate(levels):
        cards = []
        for goal in goals:
            preds = ", ".join(goal.get("predecessors", [])) or "none"
            cards.append(
                f"""<article class="goal">
  <div class="goal-id">{html.escape(goal["id"])}</div>
  <div class="goal-name">{html.escape(goal["name"])}</div>
  <div class="goal-desc">{html.escape(goal["description"])}</div>
  <div class="preds">predecessors: {html.escape(preds)}</div>
</article>"""
            )
        chunks.append(
            f"""<div class="level">
  <div class="level-title">Level {index}</div>
  {''.join(cards)}
</div>"""
        )
    return "\n".join(chunks)


def render_edges(goals, goal_by_id):
    edges = []
    for goal in goals:
        for pred in goal.get("predecessors", []):
            edges.append(
                f"<div><strong>{html.escape(pred)}</strong> {html.escape(goal_by_id[pred]['name'])} &rarr; "
                f"<strong>{html.escape(goal['id'])}</strong> {html.escape(goal['name'])}</div>"
            )
    if not edges:
        return "<div>No edges.</div>"
    return "\n".join(edges)


def render_matrix(matrix):
    ids = matrix["ids"]
    head = "".join(f"<th>{html.escape(goal_id)}</th>" for goal_id in ids)
    rows = []
    for src, values in zip(ids, matrix["rows"]):
        cells = "".join(f'<td class="{"one" if value else "zero"}">{value}</td>' for value in values)
        rows.append(f"<tr><th>{html.escape(src)}</th>{cells}</tr>")
    return f"<table><tr><th>src \\ dst</th>{head}</tr>{''.join(rows)}</table>"


def escape_mermaid(text):
    return text.replace('"', '\\"')


def escape_dot(text):
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", r"\n")


if __name__ == "__main__":
    main()
