import io, json, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

P = "evidence.json"
raw = io.open(P, encoding="utf-8").read()

PAIRS = [
    ('{ "file": "README.md", "line": 3, "anchor": "DesktopIconToggle" }',
     '{ "file": "README.md", "line": 3, "anchor": "\u6258\u76d8\u5e38\u9a7b" }', 1),
    ('{ "file": "README.md", "line": 24, "anchor": "--toggle" }',
     '{ "file": "README.md", "line": 28, "anchor": "--toggle" }', 1),
    ('{ "file": "README.md", "line": 35, "anchor": "DesktopIconToggle" }',
     '{ "file": "README.md", "line": 35, "anchor": "ShowWindowAsync" }', 1),
    ('{ "file": "Native.cs", "line": 289, "anchor": "SetWindowsHookExW" }',
     '{ "file": "Native.cs", "line": 290, "anchor": "SetWindowsHookExW" }', 2),
    ('{ "file": "Native.cs", "line": 41, "anchor": "RegisterWindowMessageW" }',
     '{ "file": "Native.cs", "line": 42, "anchor": "RegisterWindowMessageW" }', 2),
    ('{ "file": "Native.cs", "line": 368, "anchor": "Shell_NotifyIconW" }',
     '{ "file": "Native.cs", "line": 370, "anchor": "Shell_NotifyIconW" }', 2),
    ('{ "file": "Native.cs", "line": 378, "anchor": "CreateMutexW" }',
     '{ "file": "Native.cs", "line": 379, "anchor": "CreateMutexW" }', 2),
    ('{ "file": "Native.cs", "line": 436, "anchor": "RegGetValueW" }',
     '{ "file": "Native.cs", "line": 437, "anchor": "RegGetValueW" }', 2),
    ('{ "file": "Desktop.cs", "line": 61, "anchor": "SysListView32" }',
     '{ "file": "Desktop.cs", "line": 18, "anchor": "SysListView32" }, { "file": "Desktop.cs", "line": 61, "anchor": "ListViewClass" }', 1),
    ('{ "file": "Autostart.cs", "line": 58, "anchor": "Native.RegDeleteValueW" }',
     '{ "file": "Autostart.cs", "line": 57, "anchor": "Native.RegDeleteValueW" }', 1),
    ('{ "file": "TrayIcon.cs", "line": 44, "anchor": "NIM_SETVERSION" }',
     '{ "file": "TrayIcon.cs", "line": 46, "anchor": "NIM_SETVERSION" }', 1),
]

bad = []
for old, new, want in PAIRS:
    n = raw.count(old)
    if n != want:
        bad.append("count %d (expected %d) for: %s" % (n, want, old[:70]))
        continue
    raw = raw.replace(old, new)

if bad:
    print("ABORT, no write performed:")
    for b in bad:
        print("  " + b)
    sys.exit(1)

try:
    json.loads(raw)
except Exception as e:
    print("ABORT, result is not valid JSON: %s" % e)
    sys.exit(1)

io.open(P, "w", encoding="utf-8").write(raw)
print("patched %d distinct refs, JSON valid" % len(PAIRS))
