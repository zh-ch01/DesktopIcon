#!/usr/bin/env python
"""Cross-artifact consistency gate.

verify_refs.py proves that evidence.json cites real lines. This gate proves that
the two human-facing artifacts (dependencies.dot, system-model.structurizr.dsl)
do not cite anything evidence.json has not verified, and that the DOT has not
drifted from the JSON graph (same node set, same edge set).

Independent re-computation: this script re-reads the source files itself instead
of trusting verify_refs' bookkeeping, so a stale pass cannot hide here.

Exit 0 only if every check passes AND every negative control is caught.
"""
import copy, io, json, os, re, sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ARTIFACTS = ["dependencies.dot", "system-model.structurizr.dsl"]
CITE = re.compile(r"\b([A-Za-z0-9_.-]+\.(?:cs|md|manifest|csproj|json)):(\d+)\b")
EDGE_LINE = re.compile(r'^  "([^"]+)" -> "([^"]+)" \[(.*)\];\s*$', re.M)
LABEL = re.compile(r'label="(?P<label>(?:[^"\\]|\\.)*)"')

_cache = {}


def verified_pairs(model):
    """(file, line) pairs whose anchor really is on that line, re-read now."""
    ok = set()
    bad = []
    items = [("node", n) for n in model["nodes"]] + [("edge", e) for e in model["edges"]]
    items += [("prose", {"id": "prose[%d]" % i, "sourceRefs": [p]})
              for i, p in enumerate(model.get("prose", []) or [])]
    for kind, item in items:
        for r in item.get("sourceRefs", []) or []:
            f, ln, anc = r["file"], r["line"], r["anchor"]
            if f not in _cache:
                p = os.path.join(ROOT, f.replace("/", os.sep))
                _cache[f] = io.open(p, encoding="utf-8-sig").read().split("\n") if os.path.isfile(p) else None
            lines = _cache[f]
            if lines is None:
                bad.append("%s %s: %s missing" % (kind, item["id"], f))
                continue
            if ln < 1 or ln > len(lines):
                bad.append("%s %s: %s:%d out of range" % (kind, item["id"], f, ln))
                continue
            if anc not in lines[ln - 1]:
                bad.append("%s %s: %s:%d has no anchor %r" % (kind, item["id"], f, ln, anc))
                continue
            ok.add((f, ln))
    return ok, bad


def check(model, dot_text, dsl_text):
    fails = []
    ok_pairs, ref_bad = verified_pairs(model)
    for b in ref_bad:
        fails.append("evidence.json: " + b)

    stats = {"dot_cites": 0, "dsl_cites": 0, "md_cites": 0, "dot_nodes": 0, "dot_edges": 0}

    # 1. citations in artifacts must be verified.
    #    DOT labels carry the two-character escape \n; restore it to a newline first,
    #    otherwise the trailing "n" glues onto the filename and every citation mis-parses.
    def scan(text):
        return set(CITE.findall(text.replace("\\n", "\n")))

    for name, text in (("dependencies.dot", dot_text), ("system-model.structurizr.dsl", dsl_text)):
        found = scan(text)
        stats["dot_cites" if name.endswith("dot") else "dsl_cites"] = len(found)
        for f, ln in sorted(found):
            if (f, int(ln)) not in ok_pairs:
                fails.append("%s cites unverified %s:%s" % (name, f, ln))

    md_files = sorted(f for f in os.listdir(HERE) if f.endswith(".md"))
    if not md_files:
        fails.append("no markdown artifact found next to the gate; nothing to scan")
        stats["md_cites"] = 0
    else:
        for MD_NAME in md_files:
            found = scan(io.open(os.path.join(HERE, MD_NAME), encoding="utf-8").read())
            stats["md_cites"] += len(found)
            for f, ln in sorted(found):
                if (f, int(ln)) not in ok_pairs:
                    fails.append("%s cites unverified %s:%s" % (MD_NAME, f, ln))

    # 2. DOT node set == evidence node set
    dot_nodes = set(re.findall(r'^\s{4}"([^"]+)" \[shape=', dot_text, re.M))
    stats["dot_nodes"] = len(dot_nodes)
    ev_nodes = {n["id"] for n in model["nodes"]}
    for missing in sorted(ev_nodes - dot_nodes):
        fails.append("DOT omits evidence node: %s" % missing)
    for extra in sorted(dot_nodes - ev_nodes):
        fails.append("DOT declares unknown node: %s" % extra)

    # 3. DOT edge set == evidence edge set, endpoints agree, and each edge's own
    #    citations belong to that edge in evidence.json (not just to the model)
    dot_edges = {}
    per_edge_cites = {}
    for src, dst, attrs in EDGE_LINE.findall(dot_text):
        lm = LABEL.search(attrs)
        if not lm:
            fails.append("DOT edge %s -> %s has no label" % (src, dst))
            continue
        label = lm.group("label")
        parts = label.split("\\n")
        eid = parts[0].strip()
        dot_edges[eid] = (src, dst)
        per_edge_cites[eid] = set(CITE.findall(label.replace("\\n", "\n")))
    stats["dot_edges"] = len(dot_edges)
    ev_edges = {e["id"]: (e["from"], e["to"]) for e in model["edges"]}
    ev_own = {e["id"]: {(r["file"], r["line"]) for r in e.get("sourceRefs", []) or []}
              for e in model["edges"]}
    for missing in sorted(set(ev_edges) - set(dot_edges)):
        fails.append("DOT omits evidence edge: %s" % missing)
    for extra in sorted(set(dot_edges) - set(ev_edges)):
        fails.append("DOT declares unknown edge: %s" % extra)
    for eid, (src, dst) in sorted(dot_edges.items()):
        if eid in ev_edges and ev_edges[eid] != (src, dst):
            fails.append("DOT edge %s endpoints %s != evidence %s"
                         % (eid, (src, dst), ev_edges[eid]))
        for f, ln in per_edge_cites.get(eid, ()):
            if (f, int(ln)) not in ev_own.get(eid, set()):
                fails.append("DOT edge %s cites %s:%s which is not in that edge's own sourceRefs"
                             % (eid, f, ln))

    # 5. every component in the evidence model must appear in the DSL
    for n in model["nodes"]:
        if n["type"] in ("module",):
            if '"%s"' % n["label"] not in dsl_text:
                fails.append("DSL omits component: %s" % n["label"])

    return fails, stats


def main():
    with io.open(os.path.join(HERE, "evidence.json"), encoding="utf-8") as fh:
        model = json.load(fh)
    texts = {}
    for a in ARTIFACTS:
        p = os.path.join(HERE, a)
        if not os.path.isfile(p):
            print("GATE FAIL: artifact missing: %s" % a)
            return 2
        texts[a] = io.open(p, encoding="utf-8").read()

    fails, stats = check(model, texts["dependencies.dot"], texts["system-model.structurizr.dsl"])

    print("== denominator receipt ==")
    print("evidence nodes / edges      : %d / %d" % (len(model["nodes"]), len(model["edges"])))
    print("verified (file,line) pairs  : %d" % len(verified_pairs(model)[0]))
    print("citations in .dot           : %d" % stats["dot_cites"])
    print("citations in .dsl           : %d" % stats["dsl_cites"])
    print("citations in prose .md      : %d" % stats["md_cites"])
    print("DOT nodes / edges declared  : %d / %d" % (stats["dot_nodes"], stats["dot_edges"]))

    if min(stats.values()) == 0:
        print("GATE FAIL: scanned nothing in an artifact; zero denominator is not a pass")
        return 1

    print()
    print("== consistency ==")
    if fails:
        seen = set()
        for f in fails:
            if f not in seen:
                seen.add(f)
                print("  FAIL " + f)
        print("  (%d distinct failures)" % len(seen))
    else:
        print("  artifacts agree with the evidence model")

    print()
    print("== negative controls (each MUST be caught) ==")
    dot_t = texts["dependencies.dot"]
    dsl_t = texts["system-model.structurizr.dsl"]
    modules = [n for n in model["nodes"] if n["type"] == "module"]
    if len(modules) < 3:
        print("GATE FAIL: too few module nodes to build meaningful controls")
        return 1

    missed = []

    def expect(name, result, needle):
        mf = result[0]
        hit = [x for x in mf if needle in x]
        if hit:
            print("  OK caught  %s  [%s]" % (name, hit[0][:82]))
        else:
            missed.append(name)
            print("  MISSED     %s  (looked for %r in %d failures)" % (name, needle, len(mf)))

    m1 = copy.deepcopy(model)
    m1["edges"][0]["sourceRefs"][0]["line"] = 888888
    expect("evidence ref no longer resolves", check(m1, dot_t, dsl_t), "out of range")

    m2 = copy.deepcopy(model)
    m2["edges"].pop(0)
    expect("evidence edge dropped but still drawn", check(m2, dot_t, dsl_t), "unknown edge")

    m3 = copy.deepcopy(model)
    m3["nodes"] = [n for n in m3["nodes"] if n["id"] != modules[0]["id"]]
    expect("evidence module node dropped but still drawn", check(m3, dot_t, dsl_t), "unknown node")

    m4 = copy.deepcopy(model)
    m4["edges"][3]["from"] = m4["edges"][3]["to"]
    expect("edge endpoints edited in evidence but not in the DOT", check(m4, dot_t, dsl_t), "endpoints")

    expect("a component is renamed away in the DSL",
           check(model, dot_t, dsl_t.replace('component "%s"' % modules[0]["label"], 'component "Whatever"')),
           "DSL omits component")

    m5 = copy.deepcopy(model)
    if m5.get("prose"):
        dropped = m5["prose"].pop(0)
        expect("prose citation dropped from the model", check(m5, dot_t, dsl_t),
               "cites unverified %s:%d" % (dropped["file"], dropped["line"]))
    else:
        missed.append("prose control")
        print("  MISSED     prose list is empty, so the prose gate cannot be tested")

    expect("artifact cites a file:line that does not exist",
           check(model, dot_t + '\n  "a" -> "b" [label="x\\nNoSuch.cs:12"];\n', dsl_t),
           "unverified NoSuch.cs:12")

    if missed:
        print()
        print("GATE FAIL: %d negative control(s) not caught" % len(missed))
        return 1
    if fails:
        return 1
    print()
    print("GATE PASS: DOT and DSL trace to the evidence model, which traces to the code")
    return 0


if __name__ == "__main__":
    sys.exit(main())
