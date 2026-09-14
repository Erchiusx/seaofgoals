#!/usr/bin/env python3
"""Render comparable wall-time distributions from trace manifests."""

import argparse
import datetime
import html
import json
import statistics
from pathlib import Path


def timestamp(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def read_run(root, entry):
    trace = root / "runs" / "control" / entry["trace"]
    records = [json.loads(line) for line in trace.open(encoding="utf-8") if line.strip()]
    times = [timestamp(record["timestamp"]) for record in records]
    if not times:
        raise ValueError(f"empty trace: {trace}")
    events = [record.get("event", {}) for record in records]
    finished = [event for event in events if event.get("type") == "process_finished"]
    failed = [
        event
        for event in finished
        if event.get("exit_code") not in (None, 0) or event.get("timed_out") is True
    ]
    if failed:
        raise ValueError(f"failed process in trace: {trace}")
    return {
        "id": entry["id"],
        "trace": entry["trace"],
        "wall": (max(times) - min(times)).total_seconds(),
        "processes": len(finished),
    }


def summary(runs):
    values = [run["wall"] for run in runs]
    return {
        "mean": statistics.mean(values),
        "median": statistics.median(values),
        "minimum": min(values),
        "maximum": max(values),
    }


def percent(value, lower, upper):
    return 100 * (value - lower) / (upper - lower)


def distribution(name, css_class, runs, stats, lower, upper):
    ordered = sorted(runs, key=lambda run: run["wall"])
    dots = []
    for index, run in enumerate(ordered):
        left = percent(run["wall"], lower, upper)
        level = index % 3
        title = html.escape(f'{name}: {run["wall"]:.1f}s; {run["id"]}')
        dots.append(
            f'<a class="dot {css_class}" style="left:{left:.4f}%;top:{12 + level * 18}px" '
            f'href="../runs/control/{html.escape(run["trace"])}" title="{title}">'
            f'<span>{run["wall"]:.1f}s</span></a>'
        )
    median = percent(stats["median"], lower, upper)
    mean = percent(stats["mean"], lower, upper)
    return f"""
    <div class="distribution-row">
      <div class="row-label"><strong>{html.escape(name)}</strong><span>mean {stats['mean']:.1f}s · median {stats['median']:.1f}s</span></div>
      <div class="plot">
        <i class="marker median" style="left:{median:.4f}%" title="median {stats['median']:.1f}s"></i>
        <i class="marker mean" style="left:{mean:.4f}%" title="mean {stats['mean']:.1f}s"></i>
        {''.join(dots)}
      </div>
    </div>"""


def ranked_rows(baseline, concurrent, lower, upper):
    baseline = sorted(baseline, key=lambda run: run["wall"])
    concurrent = sorted(concurrent, key=lambda run: run["wall"])
    rows = []
    for rank, (base, sog) in enumerate(zip(baseline, concurrent), 1):
        base_left = percent(base["wall"], lower, upper)
        sog_left = percent(sog["wall"], lower, upper)
        left = min(base_left, sog_left)
        width = abs(sog_left - base_left)
        delta = sog["wall"] - base["wall"]
        rows.append(
            f"""<div class="rank-row">
              <strong>{rank}</strong>
              <div class="rank-plot">
                <i class="connector" style="left:{left:.4f}%;width:{width:.4f}%"></i>
                <a class="rank-dot baseline" style="left:{base_left:.4f}%" href="../runs/control/{html.escape(base['trace'])}" title="Single Pi: {base['wall']:.1f}s; {html.escape(base['id'])}"></a>
                <a class="rank-dot concurrent" style="left:{sog_left:.4f}%" href="../runs/control/{html.escape(sog['trace'])}" title="SoG concurrent: {sog['wall']:.1f}s; {html.escape(sog['id'])}"></a>
              </div>
              <span>{base['wall']:.1f}s / {sog['wall']:.1f}s</span>
              <em class="{'slower' if delta > 0 else 'faster'}">{delta:+.1f}s</em>
            </div>"""
        )
    return "".join(rows)


def render(manifest_path, output):
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    root = manifest_path.parent
    baseline = [read_run(root, entry) for entry in manifest["baseline"]]
    concurrent = [read_run(root, entry) for entry in manifest["concurrent"]]
    if len(baseline) != len(concurrent):
        raise ValueError("baseline and concurrent sample counts differ")

    baseline_stats = summary(baseline)
    concurrent_stats = summary(concurrent)
    all_values = [run["wall"] for run in baseline + concurrent]
    lower = 20 * int((min(all_values) - 1) // 20)
    upper = 20 * int((max(all_values) + 20) // 20)
    ticks = range(int(lower), int(upper) + 1, 20)
    tick_html = "".join(
        f'<span style="left:{percent(value, lower, upper):.4f}%">{value}s</span>'
        for value in ticks
    )
    mean_delta = concurrent_stats["mean"] - baseline_stats["mean"]
    median_delta = concurrent_stats["median"] - baseline_stats["median"]

    document = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(manifest['title'])}</title>
<style>
:root{{--bg:#fafbfc;--surface:#fff;--text:#202428;--muted:#657180;--line:#dce2e8;--baseline:#d8a43d;--concurrent:#42b99a;--danger:#b4463d}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 system-ui,sans-serif;letter-spacing:0}}
main{{width:min(1380px,calc(100% - 32px));margin:28px auto 56px}}h1{{font-size:24px;margin:0}}header p,.note{{color:var(--muted);margin:4px 0 0}}.summary{{display:grid;grid-template-columns:repeat(4,minmax(150px,1fr));gap:1px;background:var(--line);border:1px solid var(--line);margin:22px 0 28px}}.stat{{background:var(--surface);padding:15px}}.stat span{{display:block;color:var(--muted);font-size:12px}}.stat strong{{font-size:22px}}section{{background:var(--surface);border:1px solid var(--line);padding:20px;margin-top:18px}}h2{{font-size:17px;margin:0 0 4px}}.axis{{height:30px;position:relative;margin-left:220px;border-bottom:1px solid #8993a0}}.axis span{{position:absolute;bottom:5px;transform:translateX(-50%);font-size:11px;color:var(--muted)}}.axis span:first-child{{transform:none}}.axis span:last-child{{transform:translateX(-100%)}}.distribution-row{{display:grid;grid-template-columns:220px 1fr;align-items:center;margin-top:12px}}.row-label strong,.row-label span{{display:block}}.row-label span{{font-size:12px;color:var(--muted)}}.plot{{height:68px;position:relative;background:repeating-linear-gradient(to right,transparent 0,transparent calc(10% - 1px),#edf0f3 calc(10% - 1px),#edf0f3 10%)}}.dot{{position:absolute;width:13px;height:13px;border-radius:50%;transform:translateX(-50%);border:2px solid #fff;box-shadow:0 0 0 1px #0003;z-index:2}}.dot span{{display:none;position:absolute;left:50%;top:-30px;transform:translateX(-50%);white-space:nowrap;background:#202428;color:#fff;padding:3px 6px;font-size:11px}}.dot:hover{{z-index:5;scale:1.2}}.dot:hover span{{display:block}}.baseline{{background:var(--baseline)}}.concurrent{{background:var(--concurrent)}}.marker{{position:absolute;top:0;bottom:0;width:0;border-left:2px solid #4d5966}}.marker.mean{{border-left-style:dashed;opacity:.6}}.rank-row{{display:grid;grid-template-columns:34px 1fr 150px 70px;align-items:center;min-height:34px}}.rank-plot{{height:22px;position:relative;border-bottom:1px solid var(--line)}}.connector{{position:absolute;top:10px;height:2px;background:#9ba5af}}.rank-dot{{position:absolute;top:5px;width:12px;height:12px;border-radius:50%;transform:translateX(-50%);z-index:2}}.rank-row>span{{padding-left:15px;font-variant-numeric:tabular-nums}}.rank-row em{{font-style:normal;font-weight:600;text-align:right}}.slower{{color:var(--danger)}}.faster{{color:#148267}}.legend{{display:flex;gap:18px;margin:12px 0 0;color:var(--muted)}}.legend i{{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:6px}}.rank-axis{{margin-left:34px;margin-right:220px}}code{{font-size:12px}}@media(max-width:760px){{.summary{{grid-template-columns:1fr 1fr}}.axis{{margin-left:120px}}.distribution-row{{grid-template-columns:120px 1fr}}.rank-row{{grid-template-columns:25px 1fr 105px 55px}}.rank-axis{{margin-left:25px;margin-right:160px}}}}
</style></head><body><main>
<header><h1>{html.escape(manifest['title'])}</h1><p>{len(baseline)} complete runs per configuration · gpt-5.6 · fresh UUID workspace per run</p></header>
<div class="summary">
  <div class="stat"><span>Single Pi mean</span><strong>{baseline_stats['mean']:.1f}s</strong></div>
  <div class="stat"><span>SoG concurrent mean</span><strong>{concurrent_stats['mean']:.1f}s</strong></div>
  <div class="stat"><span>Mean difference</span><strong>{mean_delta:+.1f}s</strong></div>
  <div class="stat"><span>Median difference</span><strong>{median_delta:+.1f}s</strong></div>
</div>
<section><h2>Wall-time distributions</h2><p class="note">Solid marker: median. Dashed marker: mean. Hover a point for its run ID; click to open the trace.</p>
  <div class="legend"><span><i class="baseline"></i>Single Pi</span><span><i class="concurrent"></i>SoG concurrent</span></div>
  <div class="axis">{tick_html}</div>
  {distribution('Single Pi baseline', 'baseline', baseline, baseline_stats, lower, upper)}
  {distribution('SoG concurrent', 'concurrent', concurrent, concurrent_stats, lower, upper)}
</section>
<section><h2>Sorted wall times</h2><p class="note">Each row compares equal ranks in two independent distributions; it does not imply paired executions. Values are Single Pi / SoG concurrent.</p>
  <div class="axis rank-axis">{tick_html}</div>
  {ranked_rows(baseline, concurrent, lower, upper)}
</section>
</main></body></html>"""
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(document, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    render(args.manifest, args.output)
    print(f"wrote {args.output}")


if __name__ == "__main__":
    main()
