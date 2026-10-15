workspace "DesktopIconToggle" "Evidence-backed current-state architecture model. Generated 2026-09-30 by architecture-visualization:explore -> system-modeler + c4model. Every relationship description carries a file:line citation. Machine-readable evidence model: evidence.json (gate: verify_refs.py, plus cross_check.py which forbids any citation in this file that evidence.json has not verified)." {

  model {

    // ---------- actors (L1) ----------
    user = person "Desktop user" "Double-clicks empty desktop; left-double-clicks and right-clicks the tray icon. [README.md:3]"
    scripts = person "Scripts / hotkeys / Task Scheduler" "Invokes the exe with one argv flag; --toggle works with no background instance. [README.md:28]"
    injected = person "Injected input source" "SendInput, remote-control and screen-share tooling. Detected via LLMHF injected bits. [DesktopGestureHook.cs:22]"

    // ---------- external systems (L1) ----------
    explorerDesktop = softwareSystem "Explorer desktop window tree" "Progman and every WorkerW, each holding SHELLDLL_DefView and the SysListView32 icon layer. Class names declared at [Desktop.cs:18]; root enumeration at [Desktop.cs:39]; layer lookup at [Desktop.cs:61]. This is not our code - the app reaches into it." {
      tags "External System"
    }
    explorerTray = softwareSystem "Explorer notification area" "Hosts the tray icon; owns the notify callback and broadcasts TaskbarCreated when the shell restarts. [TrayIcon.cs:29] [Program.cs:199]" {
      tags "External System"
    }
    win32Api = softwareSystem "Win32 API" "user32 / shell32 / kernel32 / advapi32, reached only through the Native declaration surface. [Native.cs:42] [Native.cs:290] [Native.cs:370] [Native.cs:379] [Native.cs:437]" {
      tags "External System"
    }
    winRegistry = softwareSystem "Windows registry (HKCU)" "Two keys only: HKCU\\Software\\DesktopIconToggle for settings, and the CurrentVersion\\Run value for autostart. [Settings.cs:12] [Autostart.cs:11]" {
      tags "External System"
    }

    // ---------- system under design (L2 / L3) ----------
    dtit = softwareSystem "DesktopIconToggle" "Single-file Windows utility: double-click empty desktop to hide desktop icons, double-click again to restore. Tray-resident, optional autostart. No window, no taskbar entry, no polling thread. [DesktopIconToggle.csproj:9]" {
      exe = container "DesktopIconToggle.exe" ".NET 8 WinExe, x64, framework-dependent, asInvoker, PerMonitorV2. Zero NuGet packages; all OS access is hand-written P/Invoke. [DesktopIconToggle.csproj:6] [app.manifest:8]" {

        program = component "Program" "Main, argv dispatch, single-instance mutex, message loop, WndProc handler, tray menu, gesture decision, boot restore. [Program.cs:30]" {
          tags "Orchestrator"
        }
        ipcwindow = component "IpcWindow" "0x0 offscreen WS_POPUP|WS_VISIBLE top-level window. Doubles as tray owner and command-line IPC endpoint. Named by class AND title. [IpcWindow.cs:14] [IpcWindow.cs:41]"
        gesturehook = component "DesktopGestureHook" "WH_MOUSE_LL global hook. Pairs raw LBUTTONUPs into a double click itself because low-level hooks never see WM_LBUTTONDBLCLK. [DesktopGestureHook.cs:52] [DesktopGestureHook.cs:44]"
        trayicon = component "TrayIcon" "Shell notify icon registration, v4 protocol, bounded re-add, icon extraction from its own exe. [TrayIcon.cs:39]"
        desktop = component "Desktop" "Finds DefViews and icon layers under Progman and every WorkerW; reads and writes visibility; classifies a screen point as desktop or not; drives the cross-process hit test. [Desktop.cs:91] [Desktop.cs:70]"
        remoteblock = component "RemoteBlock" "Private nested helper: borrows 24 bytes of memory inside explorer for the LVHITTESTINFO struct, then frees it. [Desktop.cs:197] [Desktop.cs:202]"
        settings = component "Settings" "REG_DWORD read/write under HKCU\\Software\\DesktopIconToggle. Four values, three user-facing and one persisted state. [Settings.cs:12] [Settings.cs:33]"
        autostart = component "Autostart" "One REG_SZ in CurrentVersion\\Run carrying --boot; self-heals only a path whose file has disappeared. [Autostart.cs:11] [Autostart.cs:26]"
        native = component "Native" "The only file containing DllImport. 61 declarations plus structs, delegates, message and style constants. Business code never names a DLL. [Native.cs:290] [README.md:116]" {
          tags "Seam"
        }
      }
    }

    // ---------- L1 context relationships ----------
    user -> gesturehook "double-clicks empty desktop; hook sees raw button-ups [DesktopGestureHook.cs:87]" "mouse input"
    user -> trayicon "left double-click toggles, right button-up opens the menu [Program.cs:275] [Program.cs:281]" "shell notify callback"
    injected -> gesturehook "synthetic events carry LLMHF injected bits and may be refused [DesktopGestureHook.cs:22]" "mouse input"
    scripts -> dtit "runs the exe with one argv flag [README.md:28] [Program.cs:33]" "process spawn"
    dtit -> explorerDesktop "hides and shows the SysListView32 icon layer; asks it whether a point is on an icon [Desktop.cs:91] [Desktop.cs:165]" "ShowWindowAsync / SendMessageTimeoutW"
    dtit -> explorerTray "registers the notify icon and re-registers after a shell restart [TrayIcon.cs:39] [Program.cs:199]" "Shell_NotifyIconW / TaskbarCreated"
    dtit -> win32Api "everything, through one declaration surface [Native.cs:42]" "P/Invoke"
    dtit -> winRegistry "reads settings, persists last visibility state, registers autostart [Settings.cs:12] [Autostart.cs:26]" "advapi32 registry calls"

    // ---------- L2 container relationships ----------
    dtit -> exe "is deployed as one framework-dependent single-file exe [DesktopIconToggle.csproj:6] [README.md:5]" "single file"

    // ---------- L3 component relationships ----------
    program -> desktop "reads state, toggles, classifies the point, requests the hit test [Program.cs:275] [Program.cs:319] [Program.cs:344] [Program.cs:142]" "in-process call"
    program -> ipcwindow "creates it, posts to it, discovers the other instance, disposes it [Program.cs:79] [Program.cs:71]" "in-process call"
    program -> gesturehook "installs the hook and reads its counters [Program.cs:87]" "in-process call"
    program -> trayicon "creates it and drives the bounded re-arm [Program.cs:88] [Program.cs:175]" "in-process call"
    program -> settings "single read funnel plus menu writes [Program.cs:383] [Program.cs:125]" "in-process call"
    program -> autostart "self-heal at startup; set/read from menu and CLI [Program.cs:96] [Program.cs:625]" "in-process call"
    program -> native "message loop and timers [Program.cs:99] [Program.cs:149]" "in-process call"

    gesturehook -> ipcwindow "hands the paired double click off the hook thread with PostMessage [DesktopGestureHook.cs:90]" "PostMessage, async"
    gesturehook -> native "hook install, double-click time, double-click rect [DesktopGestureHook.cs:52] [DesktopGestureHook.cs:44]" "in-process call"

    ipcwindow -> native "class registration, window creation, discovery, send and post [IpcWindow.cs:34] [IpcWindow.cs:41] [IpcWindow.cs:109]" "in-process call"
    trayicon -> native "notify icon add, setversion, delete, icon extraction [TrayIcon.cs:39] [TrayIcon.cs:60]" "in-process call"
    desktop -> native "enumeration, visibility, hit test, remote memory [Desktop.cs:39] [Desktop.cs:165]" "in-process call"
    desktop -> settings "records last visibility on every real change, so it survives reboot [Desktop.cs:86] [Desktop.cs:106]" "in-process call"
    desktop -> remoteblock "scratch space for the hit-test struct inside explorer [Desktop.cs:202] [Desktop.cs:213] [Desktop.cs:216]" "in-process call"
    settings -> native "registry get, create, set, close [Settings.cs:43] [Settings.cs:60]" "in-process call"
    autostart -> native "registry open, set, delete, close [Autostart.cs:34] [Autostart.cs:57]" "in-process call"

    remoteblock -> explorerDesktop "writes and reads 24 bytes in the explorer process [Desktop.cs:197] [Desktop.cs:202]" "VirtualAllocEx / WriteProcessMemory / ReadProcessMemory"
    desktop -> explorerDesktop "ShowWindowAsync SW_HIDE / SW_SHOW, then RedrawWindow [Desktop.cs:91] [Desktop.cs:96]" "cross-process window command, async"
    desktop -> explorerDesktop "IsWindowVisible - state is re-read every call, never cached [Desktop.cs:70]" "cross-process read"
    explorerTray -> program "broadcasts TaskbarCreated after a shell restart, triggering re-registration [Program.cs:199] [Native.cs:42]" "dynamic registered message"

    // ---------- the two roles of one exe ----------
    scripts -> program "argv token selects a role; with args the process is a short-lived client [Program.cs:32] [Program.cs:35]" "process spawn"
    program -> program "boot restore retries on WM_TIMER 0xB007 every 2000 ms, max 10, then kills itself [Program.cs:115] [Program.cs:149] [Program.cs:146]" "in-process timer"
  }

  views {
    systemContext dtit "context" "L1 System context - who uses it and which foreign systems it reaches into" {
      autoLayout ranksep 700 nodesep 500
      include *
    }

    container dtit "containers" "L2 Container - one exe, two roles, zero external packages" {
      autoLayout ranksep 600 nodesep 400
      include *
    }

    component exe "components" "L3 Component - the eight files inside DesktopIconToggle.exe" {
      autoLayout ranksep 500 nodesep 300
      include *
    }

    // ---------- styling ----------
    styles {
      element "Person" {
        shape person
        background #aed1e0
        color #000000
        fontStyle bold
      }
      element "Orchestrator" {
        background #e07a5f
        color #ffffff
        fontStyle bold
      }
      element "Seam" {
        background #81b29a
        color #000000
        shape hexagon
      }
      element "Software System" {
        background #d4a373
        color #000000
      }
      element "External System" {
        shape Hexagon
        background #ccd5ae
        color #000000
      }
      element "Container" {
        background #f2cc8f
        color #000000
        fontStyle bold
      }
      element "Component" {
        background #ffffff
        color #111111
        shape RoundedBox
      }
      element "Deployment Group" {
        shape DashedBorder
      }
      relationship "cross-process call" {
        color #d62828
        lineWidth 3
        style dashed
      }
      relationship "in-process call" {
        color #33415c
        lineWidth 1
      }
    }
  }
}
