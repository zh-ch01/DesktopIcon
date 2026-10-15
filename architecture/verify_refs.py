#!/usr/bin/env python
"""Evidence gate for the DesktopIconToggle architecture model.

Every sourceRef must resolve: the file exists, the line number is in range, and
the anchor token literally appears on that line. A citation that merely points at
a valid line number is not evidence.

Exit 0 only if all refs pass AND all built-in negative controls fail as expected.
"""
import copy
import io
import json
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL = os.path.join(HERE, "evidence.json")
CONFIDENCE = {"high", "medium", "low", "unknown"}
STATES = {"current", "target", "deprecated", "proposed", "unknown"}


def read_lines(root, rel):
    path = os.path.join(root, rel.replace("/", os.sep))
    if not os.path.isfile(path):
        return None, "missing file"
    try:
        with io.open(path, encoding="utf-8-sig") as fh:
            return fh.read().split("\n"), None
    except UnicodeDecodeError:
        return None, "not utf-8"


_cache = {}


def lines_of(root, rel):
    key = rel
    if key not in _cache:
        _cache[key] = read_lines(root, rel)
    return _cache[key]


def check(model, root):
    fails = []
    ref_count = 0
    files_seen = set()

    node_ids = []
    for n in model.get("nodes", []):
        node_ids.append(n.get("id"))
    dup_nodes = [i for i in set(node_ids) if node_ids.count(i) > 1]
    for d in dup_nodes:
        fails.append("duplicate node id: %s" % d)

    edge_ids = [e.get("id") for e in model.get("edges", [])]
    dup_edges = [i for i in set(edge_ids) if edge_ids.count(i) > 1]
    for d in dup_edges:
        fails.append("duplicate edge id: %s" % d)

    known = set(node_ids)

    def refs_of(item, kind):
        nonlocal ref_count
        iid = item.get("id", "?")
        for ref in item.get("sourceRefs", []) or []:
            rel = ref.get("file")
            line = ref.get("line")
            anchor = ref.get("anchor")
            if not rel or not isinstance(line, int) or not anchor:
                fails.append("%s %s: malformed ref %r" % (kind, iid, ref))
                continue
            files_seen.add(rel)
            lines, err = lines_of(root, rel)
            if err:
                fails.append("%s %s: %s -> %s" % (kind, iid, rel, err))
                continue
            if line < 1 or line > len(lines):
                fails.append("%s %s: %s:%d out of range (file has %d lines)"
                             % (kind, iid, rel, line, len(lines)))
                continue
            body = lines[line - 1]
            if anchor not in body:
                fails.append("%s %s: %s:%d has no %r | actual: %s"
                             % (kind, iid, rel, line, anchor, body.strip()[:90]))
                continue
            ref_count += 1

    for n in model.get("nodes", []):
        if n.get("confidence") not in CONFIDENCE:
            fails.append("node %s: bad confidence %r" % (n.get("id"), n.get("confidence")))
        if n.get("state") not in STATES:
            fails.append("node %s: bad state %r" % (n.get("id"), n.get("state")))
        if n.get("state") == "current" and n.get("confidence") not in ("high", "medium"):
            fails.append("node %s: current-state needs high/medium confidence" % n.get("id"))
        refs_of(n, "node")

    for e in model.get("edges", []):
        for side in ("from", "to"):
            if e.get(side) not in known:
                fails.append("edge %s: %s=%r is not a declared node"
                             % (e.get("id"), side, e.get(side)))
        refs_of(e, "edge")

    # prose citations: claims made only in the human-facing document
    for i, p in enumerate(model.get("prose", []) or []):
        item = {"id": "prose[%d] %s:%s" % (i, p.get("file"), p.get("line")), "sourceRefs": [p]}
        refs_of(item, "prose")

    return fails, ref_count, files_seen


NEGATIVE_CONTROLS = [
    ("anchor not present on cited line",
     lambda m: m["edges"][0]["sourceRefs"][0].__setitem__("anchor", "ZZZ_not_a_real_token_ZZZ")),
    ("cited line number beyond end of file",
     lambda m: m["edges"][0]["sourceRefs"][0].__setitem__("line", 999999)),
    ("edge references an undeclared node",
     lambda m: m["edges"][0].__setitem__("to", "node.that.does.not.exist")),
    ("cited file does not exist",
     lambda m: m["nodes"][0]["sourceRefs"][0].__setitem__("file", "NoSuchFile.cs")),
]


def main():
    if not os.path.isfile(MODEL):
        print("GATE FAIL: model not found at %s" % MODEL)
        return 2
    with io.open(MODEL, encoding="utf-8") as fh:
        model = json.load(fh)

    root = os.path.dirname(HERE)
    fails, refs, files_seen = check(model, root)

    nodes = len(model.get("nodes", []))
    edges = len(model.get("edges", []))
    prose = len(model.get("prose", []) or [])
    declared_refs = sum(len(n.get("sourceRefs", []) or []) for n in model.get("nodes", []))
    declared_refs += sum(len(e.get("sourceRefs", []) or []) for e in model.get("edges", []))
    declared_refs += prose

    print("== denominator receipt ==")
    print("nodes scanned        : %d" % nodes)
    print("edges scanned        : %d" % edges)
    print("prose citations      : %d" % prose)
    print("sourceRefs declared  : %d" % declared_refs)
    print("sourceRefs verified  : %d" % refs)
    print("distinct files read  : %d (%s)" % (len(files_seen), ", ".join(sorted(files_seen))))

    if nodes == 0 or edges == 0 or refs == 0:
        print("GATE FAIL: scanned nothing; a zero denominator is not a pass")
        return 1
    if refs != declared_refs:
        print("GATE FAIL: %d of %d refs did not resolve" % (declared_refs - refs, declared_refs))

    print()
    print("== real model ==")
    if fails:
        for f in fails:
            print("  FAIL " + f)
    else:
        print("  all %d refs resolve to file:line + anchor token" % refs)

    print()
    print("== negative controls (each MUST fail) ==")
    blind = []
    for name, mutate in NEGATIVE_CONTROLS:
        mutant = copy.deepcopy(model)
        try:
            mutate(mutant)
        except Exception as exc:
            blind.append("%s (mutation itself broke: %s)" % (name, exc))
            print("  BROKEN  %s" % name)
            continue
        mfails, mrefs, _ = check(mutant, root)
        if mfails:
            print("  OK caught  %s  [%s]" % (name, mfails[0][:80]))
        else:
            blind.append(name)
            print("  MISSED     %s  <- gate is blind to this class of error" % name)

    if blind:
        print()
        print("GATE FAIL: %d negative control(s) not caught" % len(blind))
        return 1
    if fails or refs != declared_refs:
        return 1
    print()
    print("GATE PASS: %d refs across %d nodes / %d edges / %d files, %d negative controls caught"
          % (refs, nodes, edges, len(files_seen), len(NEGATIVE_CONTROLS)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
