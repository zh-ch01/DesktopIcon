import io, json, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

P = "evidence.json"
with io.open(P, encoding="utf-8") as fh:
    m = json.load(fh)

def R(file, line, anchor):
    return {"file": file, "line": line, "anchor": anchor}

NEW_EDGES = [
    {"id": "e.wmapp-protocol", "from": "comp.native", "to": "comp.program",
     "type": "supplies", "sync": "n/a", "protocol": "constant declarations", "confidence": "high",
     "description": "The WM_APP protocol the two roles speak: ping, gesture hand-off, icon-test return, two stat channels, quit. Values are fixed, not runtime-allocated, except TaskbarCreated which is dynamic by design.",
     "sourceRefs": [R("Native.cs", 21, "WM_TRAY"), R("Native.cs", 24, "WM_APP_GESTURE"),
                    R("Native.cs", 27, "WM_APP_ICON_TEST"), R("Native.cs", 30, "WM_APP_PING"),
                    R("Native.cs", 33, "WM_APP_MENU_STATS"), R("Native.cs", 35, "WM_APP_GESTURE_STATS"),
                    R("Native.cs", 36, "WM_APP_QUIT")]},

    {"id": "e.gesture-throttle", "from": "comp.program", "to": "comp.program",
     "type": "self-loop", "sync": "sync", "protocol": "in-process guard", "confidence": "high",
     "description": "100 ms floor on the decision path. Not politeness: a queued backlog pushes the hook past LowLevelHooksTimeout (300 ms), which makes the whole system's mouse stutter and silently removes the hook while hook_set still reports 1.",
     "sourceRefs": [R("Program.cs", 312, "GestureThrottleMs"), R("Program.cs", 350, "GestureThrottleMs = 100")]},

    {"id": "e.gesture-inflight", "from": "comp.program", "to": "comp.program",
     "type": "self-loop", "sync": "sync", "protocol": "Interlocked", "confidence": "high",
     "description": "Exactly one hit test may be outstanding. The only concurrency primitive in the app, and drops are counted rather than silently swallowed.",
     "sourceRefs": [R("Program.cs", 332, "Interlocked.CompareExchange")]},

    {"id": "e.gesture-worker", "from": "comp.program", "to": "comp.desktop",
     "type": "calls", "sync": "async", "protocol": "ThreadPool work item, result posted back as WM_APP_ICON_TEST", "confidence": "high",
     "description": "Deliberate offload: the message thread does cheap checks only (point classification, style bit); anything that sends to explorer moves off it.",
     "sourceRefs": [R("Program.cs", 341, "ThreadPool.QueueUserWorkItem"),
                    R("Program.cs", 346, "WM_APP_ICON_TEST"),
                    R("Program.cs", 325, "Desktop.ClicksThrough")]},

    {"id": "e.desktop-point", "from": "comp.desktop", "to": "ext.explorer.desktop",
     "type": "reads", "sync": "sync", "protocol": "WindowFromPoint / GetAncestor / GetParent / style bit", "confidence": "high",
     "description": "Decides whether a screen point is the desktop itself, and returns the icon list under it. Read from the message thread, so no cross-process send here.",
     "sourceRefs": [R("Desktop.cs", 119, "WindowFromPoint"), R("Desktop.cs", 128, "GetParent"),
                    R("Desktop.cs", 138, "GetWindowLongPtr")]},

    {"id": "e.desktop-hittest-detail", "from": "comp.desktop", "to": "ext.explorer.desktop",
     "type": "calls", "sync": "sync", "protocol": "LVM_SUBITEMHITTEST via SendMessageTimeoutW, 150 ms, abort-if-hung", "confidence": "high",
     "description": "Asks explorer's list view for the item at a client point. Client coordinates are converted first; the pid check exists because a DefView can belong to a different process than expected.",
     "sourceRefs": [R("Desktop.cs", 149, "IsWindowVisible"), R("Desktop.cs", 152, "ScreenToClient"),
                    R("Desktop.cs", 154, "GetWindowThreadProcessId"), R("Desktop.cs", 166, "LVM_SUBITEMHITTEST")]},

    {"id": "e.hook-chains", "from": "comp.gesturehook", "to": "ext.user32",
     "type": "calls", "sync": "sync", "protocol": "CallNextHookEx", "confidence": "high",
     "description": "Every event is chained on. The gesture never consumes the click, so double-clicking an icon still launches the program normally.",
     "sourceRefs": [R("DesktopGestureHook.cs", 99, "CallNextHookEx"),
                    R("DesktopGestureHook.cs", 46, "GetSystemMetrics")]},

    {"id": "e.hook-uninstall", "from": "comp.program", "to": "comp.gesturehook",
     "type": "depends-on", "sync": "sync", "protocol": "in-process call", "confidence": "high",
     "description": "Loop exit disposes hook, window, tray in that order; a leaked global hook would outlive the intent.",
     "sourceRefs": [R("Program.cs", 107, "_hook?.Dispose"), R("DesktopGestureHook.cs", 105, "UnhookWindowsHookEx")]},

    {"id": "e.endsession-persist", "from": "comp.program", "to": "comp.desktop",
     "type": "writes", "sync": "sync", "protocol": "in-process call at WM_QUERYENDSESSION", "confidence": "high",
     "description": "Re-reads the REAL visibility at session end and stores it, so a change made through explorer's own right-click menu is not lost at reboot.",
     "sourceRefs": [R("Program.cs", 234, "RememberCurrentState")]},

    {"id": "e.menu-blocks", "from": "comp.program", "to": "ext.user32",
     "type": "calls", "sync": "sync", "protocol": "TrackPopupMenuEx (blocking)", "confidence": "high",
     "description": "Menu tracking blocks the message thread by design; this is also why WM_CLOSE is ignored - the system sends it to the menu owner while tracking.",
     "sourceRefs": [R("Program.cs", 474, "TrackPopupMenuEx")]},

    {"id": "e.status-diag", "from": "proc.cli", "to": "proc.server",
     "type": "reads", "sync": "sync", "protocol": "three read-only WM_APP stat channels", "confidence": "high",
     "description": "Graded self-report instead of one health boolean: hook installed vs callback actually fired vs a double click was paired vs ShowWindow actually ran vs dropped. Two outages this session were 'looks fine, does nothing' and only the graded counters localised them.",
     "sourceRefs": [R("Program.cs", 545, "QueryReport"), R("Program.cs", 559, "QueryMenuStats"),
                    R("Program.cs", 568, "QueryGestureStats"), R("Program.cs", 398, "ShowWindowCalls"),
                    R("Program.cs", 407, "Installed"), R("Program.cs", 444, "IconsVisible")]},

    {"id": "e.ipc-identity", "from": "comp.ipcwindow", "to": "ext.kernel32",
     "type": "calls", "sync": "sync", "protocol": "OpenProcess + QueryFullProcessImageNameW", "confidence": "high",
     "description": "Instance discovery matches class AND title, then confirms the owning exe path. Title alone would let any foreign window receive --exit.",
     "sourceRefs": [R("IpcWindow.cs", 15, "WindowName"), R("IpcWindow.cs", 51, "PostMessageW"),
                    R("IpcWindow.cs", 91, "OpenProcess")]},

    {"id": "e.settings-create", "from": "comp.settings", "to": "ext.advapi32",
     "type": "writes", "sync": "sync", "protocol": "RegCreateKeyExW / RegSetValueExW", "confidence": "high",
     "description": "Create-on-write, no installer step; deleting the key is the documented way back to defaults.",
     "sourceRefs": [R("Settings.cs", 55, "RegCreateKeyExW")]},

    {"id": "e.tray-teardown", "from": "comp.trayicon", "to": "ext.shell32",
     "type": "writes", "sync": "sync", "protocol": "NIM_DELETE + DestroyIcon", "confidence": "high",
     "description": "Registration is removed on dispose; icon handles extracted for use are destroyed. Both matter - a leaked registration leaves a dead ghost icon in the shell.",
     "sourceRefs": [R("TrayIcon.cs", 76, "NIM_DELETE"), R("TrayIcon.cs", 79, "DestroyIcon")]},
]

existing_ids = {e["id"] for e in m["edges"]}
added = []
for e in NEW_EDGES:
    if e["id"] in existing_ids:
        print("ABORT: edge id already present: %s" % e["id"]); sys.exit(1)
    m["edges"].append(e)
    added.append(e["id"])

with io.open(P, "w", encoding="utf-8") as fh:
    json.dump(m, fh, indent=2, ensure_ascii=False)
    fh.write("\n")

nrefs = sum(len(x.get("sourceRefs", []) or []) for x in m["nodes"])
nrefs += sum(len(x.get("sourceRefs", []) or []) for x in m["edges"])
print("added %d edges: %s" % (len(added), ", ".join(added)))
print("nodes=%d edges=%d refs=%d" % (len(m["nodes"]), len(m["edges"]), nrefs))
