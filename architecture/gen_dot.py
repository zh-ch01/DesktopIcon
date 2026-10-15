#!/usr/bin/env python
"""Generate dependencies.dot from evidence.json.

The DOT file is derived so it cannot drift from the evidence model: citations are
copied from each edge's own verified sourceRefs rather than retyped.
"""
import io, json, os, sys
from collections import OrderedDict

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
with io.open(os.path.join(HERE, "evidence.json"), encoding="utf-8") as fh:
    m = json.load(fh)

CLUSTER = OrderedDict([
    ("actors", ("Actors", "people and things outside the system that drive it",
                ["actor.user", "actor.script", "actor.injected"])),
    ("scope", ("System boundary", "DesktopIconToggle.exe, run in one of two roles",
               ["sys.dit", "container.exe", "proc.server", "proc.cli"])),
    ("app", ("In-process components", "the eight source files of the one assembly",
             ["comp.program", "comp.ipcwindow", "comp.gesturehook", "comp.trayicon",
              "comp.desktop", "comp.remoteblock", "comp.settings", "comp.autostart",
              "comp.native"])),
    ("os", ("Win32 subsystem", "reached only through the Native declaration surface",
            ["ext.user32", "ext.shell32", "ext.kernel32", "ext.advapi32"])),
    ("shell", ("Explorer (foreign process)", "the app reaches into these windows",
               ["ext.explorer.desktop", "ext.explorer.tray"])),
    ("store", ("HKCU registry", "the only persistence the app owns",
               ["store.hkcu.settings", "store.hkcu.run"])),
])

STYLE = {
    "actor": 'shape=ellipse, style="filled,bold", fillcolor="#cfe1f5", color="#2b2d42"',
    "system": 'shape=box3d, style=filled, fillcolor="#f2cc8f", color="#7f5539"',
    "container": 'shape=box, style="rounded,filled,dashed", fillcolor="#fff3d6", color="#7f5539"',
    "module": 'shape=component, style=filled, fillcolor="#ffffff", color="#33415c"',
    "external-system": 'shape=hexagon, style=filled, fillcolor="#ccd5ae", color="#3a5a40"',
    "database": 'shape=cylinder, style=filled, fillcolor="#eab676", color="#9d0208"',
}

CONF_STYLE = {
    "high": 'color="#33415c", penwidth=1.0',
    "medium": 'color="#9d7a00", penwidth=1.4, style=dashed',
    "low": 'color="#d62828", penwidth=1.6, style=dashed',
    "unknown": 'color="#d62828", style="dotted,bold"',
}

# a couple of relationships are architecturally load-bearing; make them visible
BOLD = {
    "e.desktop-showhide": 'color="#d62828", penwidth=2.6',
    "e.desktop-hittest-detail": 'color="#d62828", penwidth=2.6',
    "e.desktop-hittest": 'color="#d62828", penwidth=2.2',
    "e.desktop-remoteblock": 'color="#d62828", penwidth=2.2',
    "e.cli-server-discover": 'color="#9d0208", penwidth=2.2, style=dashed',
    "e.status-diag": 'color="#9d0208", penwidth=2.0, style=dashed',
    "e.taskbarcreated": 'color="#3a5a40", penwidth=2.0, style=dashed',
    "e.hook-ipcwindow": 'color="#3a5a40", penwidth=2.0',
    "e.gesture-throttle": 'color="#588157", penwidth=1.8',
    "e.gesture-inflight": 'color="#588157", penwidth=1.8',
    "e.bootrestore-timer": 'color="#588157", penwidth=1.8',
    "e.desktop-settings": 'color="#588157", penwidth=1.8',
    "e.endsession-persist": 'color="#588157", penwidth=1.8',
}

ASSIGN = {}
for cname, (_, _, ids) in CLUSTER.items():
    for i in ids:
        ASSIGN[i] = cname

nodes = {n["id"]: n for n in m["nodes"]}
missing = [n["id"] for n in m["nodes"] if n["id"] not in ASSIGN]
if missing:
    print("ABORT: nodes not assigned to any cluster: %s" % ", ".join(missing))
    sys.exit(1)


def cites(e):
    seen, out = set(), []
    for r in e.get("sourceRefs", []) or []:
        tok = "%s:%d" % (r["file"], r["line"])
        if tok not in seen:
            seen.add(tok)
            out.append(tok)
    lines = []
    for i in range(0, len(out), 3):
        lines.append("  ".join(out[i:i + 3]))
    return "\\n".join(lines)


def esc(s):
    return s.replace('"', '\\"')


out = []
out.append("// dependencies.dot - GENERATED from evidence.json by gen_dot.py; do not hand-edit.")
out.append("// Gate: verify_refs.py (resolves every citation against the real files),")
out.append("//      cross_check.py (this file must agree with evidence.json and the DSL).")
out.append("// Question this graph answers: what does each part of DesktopIconToggle.exe depend on,")
out.append("//      and which of those edges leave the process?")
out.append("// Reading order: cluster In-process components -> edge colour. Red = crosses into explorer's")
out.append("//      process. Green = a guard/timer that exists to protect the 300 ms hook timeout.")
out.append("//      Dashed = not an ordinary call (async, broadcast, or a read-only diagnostic).")
out.append("// Edge labels carry the evidence.json edge id, then the relationship type, then the citations,")
out.append("//      so any claim in this graph is checkable without opening the JSON.")
out.append("digraph DesktopIconToggle_Dependencies {")
out.append("  rankdir=TB;")
out.append('  graph [fontname="Segoe UI", fontsize=10, nodesep=0.42, ranksep=1.05,')
out.append('         compound=true, labelloc=t, pagesize="", dpi=110,')
out.append('         label="DesktopIconToggle - component dependency graph (current state, 2026-09-30)\\n'
           'generated: system-modeler + graphviz  |  edges=%d  nodes=%d  verified citations=%d"];'
           % (len(m["edges"]), len(m["nodes"]),
              sum(len(n.get("sourceRefs", []) or []) for n in m["nodes"])
              + sum(len(e.get("sourceRefs", []) or []) for e in m["edges"])))
out.append('  node [fontname="Segoe UI", fontsize=9];')
out.append('  edge [fontname="Consolas", fontsize=7, labeldistance=1.6, fontsize=7];')

total_refs = 0
for cname, (title, note, ids) in CLUSTER.items():
    out.append("")
    out.append('  subgraph cluster_%s {' % cname)
    out.append('    label="%s\\n%s";' % (esc(title), esc(note)))
    out.append("    style=rounded; color=#adb5bd; fontsize=11; margin=14;")
    for nid in ids:
        n = nodes[nid]
        st = STYLE.get(n["type"])
        if st is None:
            print("ABORT: no style for node type %r (node %s)" % (n["type"], nid))
            sys.exit(1)
        label = "%s\\n%s" % (esc(n["label"]), n["type"])
        if n["confidence"] != "high":
            label += "\\n[confidence: %s]" % n["confidence"]
        out.append('    "%s" [%s, label="%s"];' % (nid, st, label))
        total_refs += len(n.get("sourceRefs", []) or [])
    out.append("  }")

out.append("")
emitted = 0
for e in m["edges"]:
    conf = e.get("confidence", "unknown")
    attrs = [CONF_STYLE.get(conf, 'color="#d62828", style=dotted'),
             'label="%s\\n%s | %s\\n%s"' % (esc(e["id"]), esc(e["type"]),
                                            esc(e.get("protocol", "n/a")), cites(e)),
             'labeltooltip="%s"' % esc(e.get("description", "")[:300]),
             'arrowsize=0.75, constraint=%s' % ('false' if e["from"] == e["to"] else 'true')]
    if e["id"] in BOLD:
        attrs[0] = BOLD[e["id"]]
    out.append('  "%s" -> "%s" [%s];' % (e["from"], e["to"], ", ".join(attrs)))
    emitted += 1
    total_refs += len(e.get("sourceRefs", []) or [])

out.append("}")

dst = os.path.join(HERE, "dependencies.dot")
with io.open(dst, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("\n".join(out) + "\n")

print("wrote dependencies.dot: %d nodes, %d edges, %d sourceRefs carried into labels"
      % (len(m["nodes"]), emitted, total_refs))
