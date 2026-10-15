import io, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

# (file, old, new, expected_occurrences)
PAIRS = [
    ("system-model.architecture-understanding.md",
     "python verify_refs.py     # 142 \u6761 sourceRef \u9010\u6761\u56de\u8bfb\u771f\u6587\u4ef6\u771f\u884c + anchor \u547d\u4e2d\uff1b4 \u4e2a\u8d1f\u63a7\u5236",
     "python verify_refs.py     # 170 \u6761 sourceRef \u9010\u6761\u56de\u8bfb\u771f\u6587\u4ef6\u771f\u884c + anchor \u547d\u4e2d\uff1b4 \u4e2a\u8d1f\u63a7\u5236", 1),
    ("system-model.architecture-understanding.md",
     "python cross_check.py     # .dot \u4e0e .dsl \u7684\u6bcf\u4e2a\u5f15\u7528\u5fc5\u987b\u5728 evidence.json \u91cc\u5df2\u9a8c\uff1b\u8282\u70b9\u8fb9\u96c6\u5408\u53cc\u5411\u76f8\u7b49\uff1b6 \u4e2a\u8d1f\u63a7\u5236",
     "python cross_check.py     # .dot / .dsl / \u5168\u90e8 4 \u4efd .md \u7684\u6bcf\u4e2a\u5f15\u7528\u5fc5\u987b\u5728 evidence.json \u91cc\u5df2\u9a8c\uff1b\u8282\u70b9\u8fb9\u96c6\u5408\u53cc\u5411\u76f8\u7b49\uff1b7 \u4e2a\u8d1f\u63a7\u5236", 1),

    ("scenario-route.md",
     "\uff08`evidence.json` \u7684 `prose` \u6bb5\uff0c27 \u6761\uff09",
     "\uff08`evidence.json` \u7684 `prose` \u6bb5\uff0c28 \u6761\uff0c\u8986\u76d6\u5168\u90e8 4 \u4efd markdown\uff09", 1),
    ("scenario-route.md",
     "**169 / 169 \u901a\u8fc7**\uff0824 \u8282\u70b9\u300152 \u8fb9\u300127 \u6761\u6b63\u6587\u5f15\u7528\uff0c\u8bfb 11 \u4e2a\u6587\u4ef6\uff09",
     "**170 / 170 \u901a\u8fc7**\uff0824 \u8282\u70b9\u300152 \u8fb9\u300128 \u6761\u6b63\u6587\u5f15\u7528\uff0c\u8bfb 11 \u4e2a\u6587\u4ef6\uff09", 1),
    ("scenario-route.md",
     "**143 \u4e2a\u5df2\u9a8c pair\uff0cdot 102 / dsl 68 / prose 101 \u6761\u5f15\u7528\u5168\u90e8\u53ef\u53cd\u67e5**",
     "**144 \u4e2a\u5df2\u9a8c pair\uff1bdot 102\u3001dsl 68\u30014 \u4efd markdown \u5408\u8ba1 146 \u6761\u5f15\u7528\u5168\u90e8\u53ef\u53cd\u67e5**", 1),
    ("scenario-route.md",
     "DOT / DSL / \u6b63\u6587\u4e09\u65b9\u5f15\u7528\u7684\u6bcf\u4e2a `file:line`",
     "DOT / DSL / \u5168\u90e8 markdown \u91cc\u6bcf\u4e2a `file:line`", 1),
    ("scenario-route.md",
     "`cross_check.py` \u518d\u628a DOT/DSL/\u6b63\u6587\u4e09\u65b9\u7684\u6bcf\u4e2a `file:line` \u53cd\u67e5\u56de `evidence.json`",
     "`cross_check.py` \u518d\u628a DOT\u3001DSL\u3001\u56db\u4efd markdown \u7684\u6bcf\u4e2a `file:line` \u53cd\u67e5\u56de `evidence.json`", 1),

    ("system-model.summary.md",
     "| `evidence.json` | 1,757 | \u673a\u5668\u53ef\u8bfb\u8bc1\u636e\u6a21\u578b\uff1a24 \u8282\u70b9\u300152 \u8fb9\u300127 \u6761\u6b63\u6587\u5f15\u7528",
     "| `evidence.json` | 1,763 | \u673a\u5668\u53ef\u8bfb\u8bc1\u636e\u6a21\u578b\uff1a24 \u8282\u70b9\u300152 \u8fb9\u300128 \u6761\u6b63\u6587\u5f15\u7528", 1),
    ("system-model.summary.md",
     "\u56fe\u7684\u5224\u8bfb\u3001\u989c\u8272\u8bed\u4e49\u3001\u8fc7\u6ee4\u65b9\u5f0f\u3001\u4e94\u6761\u7ed3\u8bba\u3001\u540e\u7eed\u52a8\u4f5c | \u90e8\u5206\uff08\u5f15\u7528\u4e0d\u9010\u6761\u6821\uff09 |",
     "\u56fe\u7684\u5224\u8bfb\u3001\u989c\u8272\u8bed\u4e49\u3001\u8fc7\u6ee4\u65b9\u5f0f\u3001\u4e94\u6761\u7ed3\u8bba\u3001\u540e\u7eed\u52a8\u4f5c | \u2705 `cross_check.py` |", 1),
    ("system-model.summary.md",
     "\u4e3a\u4ec0\u4e48\u662f\u8fd9\u4e09\u4ef6\u6280\u80fd\u3001\u95e8\u7981\u52a0\u8f7d\u3001\u53d6\u8bc1\u65b9\u5f0f\u3001\u4ea4\u4ed8\u5f62\u72b6\u504f\u5dee\u5bf9\u7167 | \u274c |",
     "\u4e3a\u4ec0\u4e48\u662f\u8fd9\u4e09\u4ef6\u6280\u80fd\u3001\u95e8\u7981\u52a0\u8f7d\u3001\u53d6\u8bc1\u65b9\u5f0f\u3001\u4ea4\u4ed8\u5f62\u72b6\u504f\u5dee\u5bf9\u7167 | \u2705 `cross_check.py` |", 1),
    ("system-model.summary.md",
     "| \u5f15\u7528\u9010\u6761\u56de\u8bfb\u771f\u6587\u4ef6\u771f\u884c + anchor \u5b50\u4e32\u547d\u4e2d | **169 / 169**\uff0824 \u8282\u70b9 + 52 \u8fb9 + 27 \u6b63\u6587\u5f15\u7528",
     "| \u5f15\u7528\u9010\u6761\u56de\u8bfb\u771f\u6587\u4ef6\u771f\u884c + anchor \u5b50\u4e32\u547d\u4e2d | **170 / 170**\uff0824 \u8282\u70b9 + 52 \u8fb9 + 28 \u6b63\u6587\u5f15\u7528", 1),
    ("system-model.summary.md",
     "| \u4ea7\u7269\u5f15\u7528\u53ef\u53cd\u67e5\u56de\u8bc1\u636e\u6a21\u578b | dot **102**\u3001dsl **68**\u3001prose **101** \u6761\uff1b\u5df2\u9a8c `(file,line)` \u7ec4\u5408 **143** \u4e2a |",
     "| \u4ea7\u7269\u5f15\u7528\u53ef\u53cd\u67e5\u56de\u8bc1\u636e\u6a21\u578b | dot **102**\u3001dsl **68**\u30014 \u4efd markdown \u5408\u8ba1 **146** \u6761\uff1b\u5df2\u9a8c `(file,line)` \u7ec4\u5408 **144** \u4e2a |", 1),
    ("system-model.summary.md",
     "| `cross_check.py` | 239 | \u95f8\u95e8\u4e8c\uff1a\u4e09\u4efd\u4ea7\u7269\u662f\u5426\u4e0e\u8bc1\u636e\u6a21\u578b\u4e00\u81f4",
     "| `cross_check.py` | 239 | \u95f8\u95e8\u4e8c\uff1a\u4e03\u4efd\u4ea7\u7269\uff08dot\u3001dsl\u30014 \u4efd md\uff09\u662f\u5426\u4e0e\u8bc1\u636e\u6a21\u578b\u4e00\u81f4", 1),
    ("system-model.summary.md",
     "- `patch_refs.py`(53 \u884c)\u3001`fix_lines.py`(28 \u884c)\u3001`extend_evidence.py`(109 \u884c)\u3001`add_prose_refs.py`(85 \u884c)",
     "- `patch_refs.py`(53)\u3001`fix_lines.py`(28)\u3001`extend_evidence.py`(109)\u3001`add_prose_refs.py`(101)\u3001`patch_gate.py`(38)", 1),
    ("system-model.summary.md",
     "```bash\ncd DesktopIconToggle/architecture\npython verify_refs.py",
     "```bash\ncd DesktopIconToggle/architecture\npython verify_refs.py", 0),
]

by_file = {}
for f, old, new, want in PAIRS:
    if want == 0:
        continue
    by_file.setdefault(f, []).append((old, new, want))

aborted = False
for f, edits in by_file.items():
    raw = io.open(f, encoding="utf-8").read()
    for old, new, want in edits:
        n = raw.count(old)
        if n != want:
            print("ABORT %s: count %d (want %d) for: %s" % (f, n, want, old[:60]))
            aborted = True
    if aborted:
        continue
    for old, new, want in edits:
        raw = raw.replace(old, new)
    io.open(f, "w", encoding="utf-8", newline="\n").write(raw)
    print("patched %s (%d edits)" % (f, len(edits)))

if aborted:
    sys.exit(1)
