import io, json, os, re, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
P = os.path.join(HERE, "evidence.json")
CITE = re.compile(r"\b([A-Za-z0-9_.-]+\.(?:cs|md|manifest|csproj)):(\d+)\b")

MD_FILES = sorted(f for f in os.listdir(HERE) if f.endswith(".md"))

ANCHORS = {
    "Desktop.cs:15": "ProgmanClass",
    "Desktop.cs:88": "foreach",
    "Native.cs:41": "DllImport",
    "Native.cs:289": "DllImport",
    "Native.cs:368": "shell32.dll",
    "Native.cs:378": "kernel32.dll",
    "Native.cs:436": "advapi32.dll",
    "Program.cs:168": "便宜的保险",
    "Program.cs:177": "800",
    "Program.cs:343": "onIcon = true",
    "Settings.cs:23": "RespondToInjectedDoubleClickDefault",
    "Autostart.cs:70": "/// <summary>",
    "Autostart.cs:74": "里取出可执行文件路径",
    "DesktopIconToggle.csproj:28": "ServerGarbageCollection",
    "README.md:7": "6.3",
    "README.md:8": "239",
    "README.md:13": "后台实例自己执行",
    "README.md:39": "两份 exe 是两个身份",
    "README.md:49": "一次堆内存都不分配",
    "README.md:53": "状态不落缓存",
    "README.md:57": "溢出区",
    "README.md:61": "隐藏的是图标层",
    "README.md:65": "LVM_SUBITEMHITTEST",
    "README.md:73": "TrackPopupMenuEx",
    "README.md:77": "状态自证是分级的",
    "README.md:81": "窗口类名",
    "README.md:84": "两处未实测",
    "README.md:88": "100ms",
}

with io.open(P, encoding="utf-8") as fh:
    m = json.load(fh)

tokens = set()
per_file = {}
for f in MD_FILES:
    text = io.open(os.path.join(HERE, f), encoding="utf-8").read()
    found = sorted(set("%s:%s" % (a, b) for a, b in CITE.findall(text)))
    per_file[f] = found
    tokens.update(found)

# model-verified pairs are nodes + edges only; prose is rebuilt fresh on every run
verified = set()
for item in m["nodes"] + m["edges"]:
    for r in item.get("sourceRefs", []) or []:
        verified.add("%s:%d" % (r["file"], r["line"]))

delta = sorted(t for t in tokens if t not in verified)

missing = [t for t in delta if t not in ANCHORS]
if missing:
    print("ABORT: %d prose citation(s) have no anchor supplied:" % len(missing))
    for t in missing:
        print("   " + t)
    sys.exit(1)

stale = [t for t in ANCHORS if t not in delta]
if stale:
    print("ABORT: anchor supplied but unused by any markdown: %s" % ", ".join(sorted(stale)))
    sys.exit(1)

_cache = {}
for t in delta:
    f, ln = t.rsplit(":", 1)
    ln = int(ln)
    if f not in _cache:
        fp = os.path.join(ROOT, f)
        if not os.path.isfile(fp):
            print("ABORT: %s cites a file that does not exist: %s" % (t, f)); sys.exit(1)
        _cache[f] = io.open(fp, encoding="utf-8-sig").read().split("\n")
    lines = _cache[f]
    if ln < 1 or ln > len(lines):
        print("ABORT: %s out of range (%d lines)" % (t, len(lines))); sys.exit(1)
    if ANCHORS[t] not in lines[ln - 1]:
        print("ABORT: %s has no %r | actual: %s" % (t, ANCHORS[t], lines[ln - 1].strip()[:80]))
        sys.exit(1)

sources = ", ".join(MD_FILES)
m["prose"] = [{"claim": "cited by markdown artifact(s): " + sources,
               "file": t.rsplit(":", 1)[0],
               "line": int(t.rsplit(":", 1)[1]),
               "anchor": ANCHORS[t]} for t in delta]

with io.open(P, "w", encoding="utf-8") as fh:
    json.dump(m, fh, indent=2, ensure_ascii=False)
    fh.write("\n")

print("markdown scanned : %s" % ", ".join("%s(%d)" % (k, len(v)) for k, v in per_file.items()))
print("distinct citations: %d  model-verified: %d  newly anchored as prose: %d"
      % (len(tokens), len(tokens) - len(delta), len(delta)))
