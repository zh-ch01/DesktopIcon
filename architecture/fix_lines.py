import io, json, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

P = "evidence.json"
with io.open(P, encoding="utf-8") as fh:
    m = json.load(fh)

FIX = [("e.desktop-hittest-detail", "Desktop.cs", 166, 165),
       ("e.ipc-identity", "IpcWindow.cs", 51, 52)]

hits = 0
for e in m["edges"]:
    for eid, file, old, new in FIX:
        if e["id"] != eid:
            continue
        for ref in e["sourceRefs"]:
            if ref["file"] == file and ref["line"] == old:
                ref["line"] = new
                hits += 1

if hits != len(FIX):
    print("ABORT: patched %d of %d expected fixes" % (hits, len(FIX)))
    sys.exit(1)

with io.open(P, "w", encoding="utf-8") as fh:
    json.dump(m, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
print("relocated %d mis-cited line numbers" % hits)
