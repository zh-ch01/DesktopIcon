using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace DeskIcons;

internal static class Program
{
    private const string MutexName = @"Local\DesktopIconToggle.SingleInstance.v1";
    private const int AttachParentProcess = -1;

    private const int MenuToggle = 1;
    private const int MenuAutostart = 2;
    private const int MenuGesture = 3;
    private const int MenuInjected = 4;
    private const int MenuRestoreDefaults = 5;
    private const int MenuQuit = 6;
    private const int MenuRestoreOnBoot = 7;

    private const string Tooltip = "桌面图标开关｜双击桌面空白处 = 显示/隐藏桌面图标";

    private static IpcWindow? _window;
    private static DesktopGestureHook? _hook;
    private static TrayIcon? _tray;
    private static IntPtr _mutex;

    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length > 0) Native.AttachConsole(AttachParentProcess);
        string command = args.Length > 0 ? args[0].Trim().ToLowerInvariant() : string.Empty;

        switch (command)
        {
            case "": return RunServer(fromBoot: false);
            case "--boot": return RunServer(fromBoot: true);   // 开机自启路径：会复原上次的图标显示状态
            case "--toggle": return CommandToggle();
            case "--show": return CommandSet(true);
            case "--hide": return CommandSet(false);
            case "--status": return ClientStatus();
            case "--autostart": return ClientAutostart(true);
            case "--no-autostart": return ClientAutostart(false);
            case "--exit": return ClientExit();
            case "--help":
            case "-h":
            case "/?":
                Console.WriteLine(Help);
                return 0;
            default:
                Console.Error.WriteLine("未知参数：" + command);
                Console.Error.WriteLine(Help);
                return 2;
        }
    }

    // ============================ 后台实例 ============================

    private static int RunServer(bool fromBoot)
    {
        _mutex = Native.CreateMutexW(IntPtr.Zero, true, MutexName);
        if (_mutex == IntPtr.Zero) return 3;
        if (Native.LastWin32Error == Native.ERROR_ALREADY_EXISTS)
        {
            Native.CloseHandle(_mutex);
            _mutex = IntPtr.Zero;
            // 互斥体按名字全会话唯一，而实例发现还要校验属主 exe 全路径（F28：不许认错陌生窗口）。
            // 于是有一种组合会让人一头雾水：在场那一份是"另一个路径下的同一个文件"——我们既问不到它，
            // 又在这里静默退出，用户看到的是"双击没反应、--status 说未运行"。至少把话说清楚。
            if (IpcWindow.FindOther() is null)
                Console.Error.WriteLine("已有一份实例在运行，但它不是这个路径下的文件，所以 --status/--exit 不认它。"
                    + "要管它请用它自己那份 exe，或先结束它的进程。");
            return 0;   // 已有一份在跑：双击 exe 不会再长出一个托盘图标
        }

        try
        {
            _window = new IpcWindow(OnMessage);
        }
        catch (InvalidOperationException e)
        {
            Console.Error.WriteLine(e.Message);
            return 4;
        }

        _hook = new DesktopGestureHook(_window);
        _tray = new TrayIcon(_window.Handle, Tooltip);
        if (!_tray.Add())
        {
            // 开机时 Run 键完全可能比 explorer 的通知区更早起来，那时 NIM_ADD 会直接返回失败。
            // 光喊一声就算完是不够的——用户看不到 stderr，只会看到"托盘图标没了"。交给同一个有界重补调度。
            Console.Error.WriteLine("托盘图标没注册上，双击桌面和命令行仍然可用。");
            RearmTray();
        }
        Autostart.SelfHeal();
        if (fromBoot) RequestBootRestore();

        while (Native.GetMessageW(out Native.MSG msg, IntPtr.Zero, 0, 0) > 0)
        {
            Native.TranslateMessage(ref msg);
            Native.DispatchMessageW(ref msg);
        }

        _tray?.Dispose();
        _tray = null;
        _hook?.Dispose();
        _hook = null;
        _window?.Dispose();
        _window = null;
        ReleaseMutexOnce();
        return 0;
    }

    private const uint BootRetryTimer = 0xB007;
    private static int _bootRetriesLeft;

    /// <summary>
    /// 开机自启时把上次的显示状态复原：不然"我把图标收起来了"这件事活不过一次重启。
    /// 只在 `--boot`（也就是 Run 键里登记的那条命令行）路径上做——用户手动双击 exe 不应该被强行改桌面。
    /// 开机时 explorer 可能还没把图标层建出来，所以用一次性定时器重试几次。
    /// </summary>
    private static void RequestBootRestore()
    {
        if (SettingIsOn(Settings.RestoreStateOnStartup, Settings.RestoreStateOnStartupDefault) != 1) return;
        _bootRetriesLeft = 10;
        TryBootRestore();
    }

    private static void TryBootRestore()
    {
        if (_window is not { } window) return;
        // 重试次数用完后必须把定时器拆掉：SetTimer 是周期性的，不拆就会每 2 秒空转到进程结束，
        // 表现是"占用小"这条承诺被一次没成功的开机复原悄悄破坏掉。
        if (_bootRetriesLeft <= 0)
        {
            Native.KillTimer(window.Handle, (UIntPtr)BootRetryTimer);
            return;
        }
        _bootRetriesLeft--;

        if (Desktop.FindIconLayers().Count > 0)
        {
            bool want = SettingIsOn(Settings.IconsVisibleOnExit, Settings.IconsVisibleOnExitDefault) == 1;
            if (Desktop.IconsVisible() != want) Desktop.SetIconsVisible(want);
            Native.KillTimer(window.Handle, (UIntPtr)BootRetryTimer);
            return;
        }
        Native.SetTimer(window.Handle, (UIntPtr)BootRetryTimer, 2000, IntPtr.Zero);
    }

    private static void ReleaseMutexOnce()
    {
        if (_mutex == IntPtr.Zero) return;
        Native.ReleaseMutex(_mutex);
        Native.CloseHandle(_mutex);
        _mutex = IntPtr.Zero;
    }

    private const uint TrayRearmTimer = 0x7DAC;
    private static int _trayRearmLeft;

    /// <summary>
    /// 托盘注册的有界重补：再补 3 次（0 / 800ms / 1600ms），补满立刻拆表。
    /// 从启动失败那条路进来时总尝试数是 4 次（调用方已经试过 1 次），这里如实按"再补 3 次"记。
    /// 两条入口都用它：① 启动时 NIM_ADD 明确返回失败（开机时 Run 键比 explorer 的通知区更早）；
    /// ② 收到 TaskbarCreated（shell 换进程后旧注册必然作废，且新 shell 的通知区不一定已经能接）。
    /// ②这一条要老实标注：它属于"便宜的保险"而不是"已证实的缺陷"——我一度以为一次补不上会被测出来，
    /// 后来发现那个读数把"被 Win11 收进溢出区"和"根本没注册"混成了一件事（溢出区收起时子元素不在 UIA 树里）。
    /// 一个活着的周期定时器就等于违背"占用小"这条承诺，所以两条分支都必须拆表（与 B10 同一纪律）。
    /// </summary>
    private static void RearmTray()
    {
        if (_tray is null) return;
        _tray.Add();
        _trayRearmLeft = 2;
        if (_window is { } window) Native.SetTimer(window.Handle, (UIntPtr)TrayRearmTimer, 800, IntPtr.Zero);
    }

    private static void OnTrayRearmTick()
    {
        if (_window is not { } window) return;
        if (_trayRearmLeft <= 0)
        {
            Native.KillTimer(window.Handle, (UIntPtr)TrayRearmTimer);
            return;
        }
        _trayRearmLeft--;
        _tray?.Add();
        if (_trayRearmLeft <= 0) Native.KillTimer(window.Handle, (UIntPtr)TrayRearmTimer);
    }

    private static IntPtr OnMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        // explorer 重启后托盘图标必须由我们自己重新注册一次才会回来——shell 侧的注册表随旧进程一起没了。
        // 这条消息号是每会话动态分配的，所以不能放在 switch 的常量分支里。
        // RegisterWindowMessageW 失败返回 0，而 0 恰好是 WM_NULL：不排掉 0 的话，我们自己
        // PostMessageW(NULL) 的那条空消息会被当成"shell 换进程了"，反复触发重补。
        if (msg == Native.TaskbarCreatedMessage && Native.TaskbarCreatedMessage != 0 && _tray is { })
        {
            RearmTray();
            return IntPtr.Zero;
        }

        switch (msg)
        {
            case Native.WM_TRAY:
                OnTrayCallback(wParam, lParam);
                return IntPtr.Zero;

            case Native.WM_APP_GESTURE:
                StartGesture(IpcWindow.Unpack(wParam), (long)lParam != 0);
                return IntPtr.Zero;

            case Native.WM_APP_ICON_TEST:
                // 跨进程命中测试在工作线程做完了，回到消息线程落地动作。
                if (wParam == IntPtr.Zero) Note(ApplyToggle() ? GestureToggled : GestureNoLayer);
                else Note(GestureOnIcon);
                return IntPtr.Zero;

            case Native.WM_APP_GESTURE_STATS:
                return new IntPtr(GestureStatsPacked());

            case Native.WM_TIMER:
                // 两个定时器共用一条 WM_TIMER，靠 wParam 里的 id 分流：分错了就是一边永远拆不掉。
                uint timerId = unchecked((uint)wParam.ToInt64());
                if (timerId == TrayRearmTimer) OnTrayRearmTick();
                else if (timerId == BootRetryTimer) TryBootRestore();
                return IntPtr.Zero;

            case Native.WM_QUERYENDSESSION:
                // 注销/关机前把"此刻的真实状态"记下来：用户可能用 explorer 自己的右键菜单改过图标显示，
                // 只有本程序改的时候才回写会让下次开机被一个过期值强行改回去。
                Desktop.RememberCurrentState();
                return new IntPtr(1);   // 1 = 允许结束会话

            case Native.WM_APP_PING:
                return new IntPtr(PingPacked());

            case Native.WM_APP_MENU_STATS:
                return new IntPtr((MenuTracks & 0xFFFF) | ((MenuLastTrackMs & 0xFFFF) << 16)
                    | ((MenuFgOk & 0xF) << 32) | ((MenuIsFg & 0xF) << 36));

            case Native.WM_APP_QUIT:
                Native.DestroyWindow(hWnd);
                return IntPtr.Zero;

            case Native.WM_CLOSE:
                // 绝不能在这里销毁窗口：TrackPopupMenuEx 跟踪菜单期间，系统会给 owner 窗口发 WM_CLOSE。
                // 以前把它当成退出，结果"右键托盘"= 菜单还没显示就把自己的进程杀了。
                // 退出只认显式的 WM_APP_QUIT（托盘菜单的"退出"或 --exit）。
                return IntPtr.Zero;

            case Native.WM_DESTROY:
                Native.PostQuitMessage(0);
                return IntPtr.Zero;
        }
        return Native.DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    /// <summary>
    /// 托盘回调的消息号放在哪个字，各版本说法不一致（v4 有文档说是 uID 在低 16 位、消息在高 16 位，
    /// 也有实现相反）。所以三个候选位置都扫，认我们关心的那几个消息号——uID 恒为 1，不会撞车。
    /// </summary>
    private static void OnTrayCallback(IntPtr wParam, IntPtr lParam)
    {
        uint l = (uint)lParam.ToInt64();
        // 消息号落在哪个字各版本说法不一，三个候选槽都扫；uID 恒为 1，不会和消息号撞车。
        uint[] candidates = { (uint)wParam.ToInt64(), l & 0xFFFFu, (l >> 16) & 0xFFFFu };
        foreach (uint candidate in candidates)
        {
            switch (candidate)
            {
                case Native.WM_LBUTTONDBLCLK:
                    Desktop.ToggleIcons();
                    return;

                case Native.WM_RBUTTONUP:
                    // 只认 RBUTTONUP。v4 下一次右键可能同时给 RBUTTONUP 和 CONTEXTMENU，
                    // 两个都处理会把菜单弹两遍，第二遍的抬起正好选中光标下面那一项。
                    ShowMenu();
                    return;
            }
        }
    }

    /// <summary>
    /// 桌面上的一次左键双击。分两步：
    /// ① 消息线程上只做便宜的判定（父子关系、窗口类、透明位），绝不跨进程发消息；
    /// ② 需要问 explorer"这一点是不是压在某个图标上"时，丢给工作线程，测完再 Post 回来。
    /// 这样消息循环永远不会被 150ms 级的跨进程调用占住——低级鼠标钩子超时会直接表现为鼠标发涩。
    /// </summary>
    private static void StartGesture(Native.POINT point, bool fromRealMouse)
    {
        if (SettingIsOn(Settings.DesktopDoubleClickGesture, Settings.DesktopDoubleClickGestureDefault) != 1)
        {
            Note(GestureOff);
            return;
        }
        if (!fromRealMouse && SettingIsOn(Settings.RespondToInjectedDoubleClick,
                Settings.RespondToInjectedDoubleClickDefault) != 1)
        {
            Note(GestureInjectedOff);
            return;
        }

        // 节流：一次手势在消息线程上要做 4~8 次注册表调用 + 十来次窗口查询 + ShowWindowAsync。
        // 单条只有几十微秒，但队列一旦堆起来就会撞上 LowLevelHooksTimeout(300ms) —— 后果不是我们崩溃，
        // 而是全系统鼠标发涩 + 钩子被系统悄悄摘掉（hook_set 仍报 1，骗人）。100ms 的下限远在人手能力之外
        // （实测背靠背双击最快约 330ms 一次），只挡得住洪水，挡不住真人。
        long nowTick = unchecked((long)Native.GetTickCount64());
        if (nowTick - _lastGestureTick < GestureThrottleMs)
        {
            _gestureThrottled++;
            return;
        }
        _lastGestureTick = nowTick;

        if (!Desktop.IsDesktopPoint(point, out IntPtr iconList))
        {
            _gestureNotDesktop++;
            Note(GestureNotDesktop);
            return;
        }
        if (iconList == IntPtr.Zero || Desktop.ClicksThrough(iconList))
        {
            Note(ApplyToggle() ? GestureToggled : GestureNoLayer);
            return;
        }

        if (_window is not { } window) return;
        if (Interlocked.CompareExchange(ref _iconTestInFlight, 1, 0) != 0)
        {
            // 上一次的命中测试还在路上，这一次只能丢弃。这本来极少发生，但必须可查——
            // 否则表现就是"我明明双击了却没反应"，而 pairs 一直在涨，看不出差错在哪。
            _gestureBusyDropped++;
            Note(GestureBusy);
            return;
        }

        ThreadPool.QueueUserWorkItem(_ =>
        {
            bool onIcon = true;   // 测不出来就当作"点在图标上"：宁可不切，不抢用户启动程序的点击
            try { onIcon = Desktop.IsDoubleClickOnIcon(iconList, point); }
            finally { Interlocked.Exchange(ref _iconTestInFlight, 0); }
            window.Post(Native.WM_APP_ICON_TEST, new IntPtr(onIcon ? 1 : 0), IntPtr.Zero);
        });
    }

    private const int GestureThrottleMs = 100;
    private static long _lastGestureTick;
    private static int _gestureThrottled;

    private static int _iconTestInFlight;
    private static int _gestureBusyDropped;

    // 「pairs 在涨但 showwindow 不涨」必须有一个名字，否则又回到"看起来一切正常而功能不响"。
    // 这些都只在消息线程上读写，不需要原子量。
    private const int GestureToggled = 1;
    private const int GestureOnIcon = 2;
    private const int GestureNotDesktop = 3;
    private const int GestureOff = 4;
    private const int GestureInjectedOff = 5;
    private const int GestureBusy = 6;
    private const int GestureNoLayer = 7;

    private static int _gestureOnIcon;
    private static int _gestureNotDesktop;
    private static int _gestureLast;

    private static void Note(int result)
    {
        if (result == GestureOnIcon) _gestureOnIcon++;
        _gestureLast = result;
    }

    /// <summary>bit0-15 让位给图标的次数，bit16-31 落点不在桌面的次数，
    /// bit32-39 最近一次手势的结局码，bit40-55 被节流丢掉的次数。</summary>
    private static long GestureStatsPacked() =>
        (_gestureOnIcon & 0xFFFFL) | ((_gestureNotDesktop & 0xFFFFL) << 16)
        | ((_gestureLast & 0xFFL) << 32) | ((_gestureThrottled & 0xFFFFL) << 40);

    private static int SettingIsOn(string name, int fallback) => Settings.Read(name, fallback);


    /// <summary>
    /// 一次 IPC 只带回一个 IntPtr，所以把诊断数据打包：
    /// bit0-7 标志位，bit8-23 左键抬起数，bit24-39 双击候选数，bit40-55 实际 ShowWindow 次数，
    /// bit56-59 命中测试在途被丢弃次数，bit60-63 切换失败（找不到图标层）次数。
    /// 目的是把"钩子没被调用 / 调用了但配不出双击 / 配出了但被落点拦下 / 真的切了 / 想切但没窗口可切"
    /// 一次分清——之前只报"钩子已装载"，害我按错方向查了整整一轮。
    /// </summary>
    private static long PingPacked()
    {
        long flags = PingFlags() & 0xFF;
        long ups = (_hook?.UpsSeen ?? 0) & 0xFFFF;
        long pairs = (_hook?.CandidatesSeen ?? 0) & 0xFFFF;
        long shown = Desktop.ShowWindowCalls & 0xFFFF;
        long busy = _gestureBusyDropped & 0xF;
        long failed = ToggleFailed & 0xF;
        return flags | (ups << 8) | (pairs << 24) | (shown << 40) | (busy << 56) | (failed << 60);
    }

    private static int PingFlags()
    {
        int flags = 0;
        if (_hook is { Installed: true })
        {
            flags |= Native.PingHookInstalled;
            if (_hook.UpsSeen > 0) flags |= Native.PingHookAnyUp;
            if (_hook.CandidatesSeen > 0) flags |= Native.PingHookFired;
        }
        if (SettingIsOn(Settings.DesktopDoubleClickGesture, Settings.DesktopDoubleClickGestureDefault) == 1)
            flags |= Native.PingGestureEnabled;
        if (SettingIsOn(Settings.RespondToInjectedDoubleClick, Settings.RespondToInjectedDoubleClickDefault) == 1)
            flags |= Native.PingRespondToInjected;
        if (SettingIsOn(Settings.RestoreStateOnStartup, Settings.RestoreStateOnStartupDefault) == 1)
            flags |= Native.PingRestoreOnBoot;
        return flags;
    }

    // ============================ 托盘菜单 ============================

    /// <summary>统一的切换出口：找不到图标层时不再静默"点了没反应"，而是计入 failed 供 --status 报出。</summary>
    private static bool ApplyToggle()
    {
        if (!Desktop.ToggleIcons()) { ToggleFailed++; return false; }
        return true;
    }

    private static int ToggleFailed;
    private static int MenuTracks;
    private static int MenuLastTrackMs;
    private static int MenuFgOk;        // SetForegroundWindow 的返回值
    private static int MenuIsFg;        // 调用之后前台窗口确实是我们

    private static void ShowMenu()
    {
        if (_window is null) return;
        IntPtr menu = Native.CreatePopupMenu();
        if (menu == IntPtr.Zero) return;
        try
        {
            bool visible = Desktop.IconsVisible();
            bool autostart = Autostart.IsEnabled();
            bool gesture = SettingIsOn(Settings.DesktopDoubleClickGesture, Settings.DesktopDoubleClickGestureDefault) == 1;
            bool injected = SettingIsOn(Settings.RespondToInjectedDoubleClick, Settings.RespondToInjectedDoubleClickDefault) == 1;

            Append(menu, MenuToggle, visible ? "隐藏桌面图标" : "显示桌面图标");
            Native.AppendMenuW(menu, Native.MF_SEPARATOR, UIntPtr.Zero, null);
            Append(menu, MenuAutostart, "开机自启动", autostart);
            Append(menu, MenuGesture, "双击桌面空白处切换", gesture);
            Append(menu, MenuInjected, "接受注入的双击（脚本/远控）", injected);
            Append(menu, MenuRestoreOnBoot, "开机后保持上次状态",
                SettingIsOn(Settings.RestoreStateOnStartup, Settings.RestoreStateOnStartupDefault) == 1);
            Append(menu, MenuRestoreDefaults, "恢复默认设置");
            Native.AppendMenuW(menu, Native.MF_SEPARATOR, UIntPtr.Zero, null);
            Append(menu, MenuQuit, "退出");
            Native.AppendMenuW(menu, Native.MF_SEPARATOR, UIntPtr.Zero, null);
            // 灰色提示必须是最后一项：托盘菜单在屏幕右下角往上长，光标正好压在菜单底部那一行；
            // 右键那一下的抬起会被菜单当成一次选择，落在不可选中的行上才不会被误退出。
            Native.AppendMenuW(menu, Native.MF_STRING | Native.MF_GRAYED, UIntPtr.Zero,
                "双击桌面空白处切换；双击图标仍是启动程序");

            Native.GetCursorPos(out Native.POINT at);

            // 实测：后台进程这里 SetForegroundWindow 一直返回 0，菜单照样能正常随点击外部关闭。
            // 真正起作用的是 owner 是个"可见"的顶层窗口（见 IpcWindow 的 WS_VISIBLE 注释）；
            // 这里保留调用是因为它在前台就是我们时会让行为更稳，且失败无副作用。
            MenuFgOk = Native.SetForegroundWindow(_window.Handle) ? 1 : 0;
            MenuIsFg = Native.GetForegroundWindow() == _window.Handle ? 1 : 0;

            int startedAt = unchecked((int)Native.GetTickCount64()) & 0xFFFF;
            int chosen = Native.TrackPopupMenuEx(menu, Native.TPM_RETURNCMD | Native.TPM_RIGHTBUTTON,
                at.X, at.Y, _window.Handle, IntPtr.Zero);

            // 跟踪时长是判据：正常应当停在菜单里等用户选（几百毫秒到几秒）；
            // 若几乎为 0，说明菜单刚弹出就被某个激活/取消动作关掉了。
            MenuTracks++;
            MenuLastTrackMs = (unchecked((int)Native.GetTickCount64()) & 0xFFFF) - startedAt;

            Native.SetWindowPos(_window.Handle, Native.HWND_NOTOPMOST, 0, 0, 0, 0,
                Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
            Native.PostMessageW(_window.Handle, Native.WM_NULL, IntPtr.Zero, IntPtr.Zero);

            switch (chosen)
            {
                case MenuToggle: ApplyToggle(); break;
                case MenuAutostart: Autostart.Set(!autostart); break;
                case MenuGesture: Settings.Write(Settings.DesktopDoubleClickGesture, gesture ? 0 : 1); break;
                case MenuInjected: Settings.Write(Settings.RespondToInjectedDoubleClick, injected ? 0 : 1); break;
                case MenuRestoreOnBoot:
                    Settings.Write(Settings.RestoreStateOnStartup,
                        SettingIsOn(Settings.RestoreStateOnStartup, Settings.RestoreStateOnStartupDefault) == 1 ? 0 : 1);
                    break;
                case MenuRestoreDefaults: Settings.RestoreDefaults(); break;
                case MenuQuit: Native.PostMessageW(_window.Handle, Native.WM_APP_QUIT, IntPtr.Zero, IntPtr.Zero); break;
            }
        }
        finally
        {
            Native.DestroyMenu(menu);
        }
    }

    private static void Append(IntPtr menu, int id, string text, bool isChecked = false) =>
        Native.AppendMenuW(menu, Native.MF_STRING | (isChecked ? Native.MF_CHECKED : 0u), new UIntPtr((uint)id), text);

    // ============================ 命令行 ============================

    private const string Help = """
        桌面图标开关 DesktopIconToggle 1.0
          （无参数）          后台运行：托盘图标 + 双击桌面空白处切换桌面图标
          --toggle           切换一次桌面图标显示
          --show / --hide    直接显示或隐藏桌面图标
          --status           查看实例、图标可见性、自启动、手势设置
          --autostart        开启开机自启动（HKCU Run，无需管理员）
          --no-autostart     关闭开机自启动
          --exit             退出后台实例（桌面图标保持当前状态）
          --help             本帮助
        """;

    /// <summary>
    /// 这三个动作本身就是对 explorer 窗口 ShowWindow，谁来做结果都一样，
    /// 所以不要求后台实例在场——顺带保证了"找不到托盘图标时用户仍能恢复图标"这条退路。
    /// </summary>
    private static int CommandToggle()
    {
        if (!Desktop.ToggleIcons()) return Fail("没找到桌面图标层（SysListView32）。");
        Console.WriteLine("icons = " + (Desktop.IconsVisible() ? "visible" : "hidden"));
        return 0;
    }

    private static int CommandSet(bool visible)
    {
        if (Desktop.FindDefViews().Count == 0) return Fail("没找到桌面图标层（SysListView32），explorer 可能正在重启。");
        Desktop.SetIconsVisible(visible);
        Console.WriteLine("icons = " + (visible ? "visible" : "hidden"));
        return 0;
    }

    private static int ClientStatus()
    {
        IntPtr? instance = IpcWindow.FindOther();
        long report = instance is not null ? IpcWindow.QueryReport(instance.Value) ?? 0 : 0;
        int flags = (int)(report & 0xFF);
        string? stored = Autostart.Read();
        int defViews = Desktop.FindDefViews().Count;

        Console.WriteLine("exe        = " + (Environment.ProcessPath ?? "(未知)"));
        Console.WriteLine("runtime    = .NET " + Environment.Version);
        Console.WriteLine("instance   = " + DescribeInstance(instance));
        Console.WriteLine("defviews   = " + defViews + "，iconlayers = " + Desktop.FindIconLayers().Count);
        Console.WriteLine("icons      = " + (defViews == 0 ? "unknown" : Desktop.IconsVisible() ? "visible" : "hidden"));
        Console.WriteLine("autostart  = " + (stored is null ? "off" : "on   " + stored));
        Console.WriteLine("flags      =" + DescribeFlags(instance, flags));
        if (instance is not null)
        {
            long menu = IpcWindow.QueryMenuStats(instance.Value) ?? 0;
            // 这一行刻意全 ASCII：方便脚本抓取，也避开控制台码页把中文换成问号。
            Console.WriteLine("diag       = ups=" + ((report >> 8) & 0xFFFF)
                + " pairs=" + ((report >> 24) & 0xFFFF)
                + " showwindow=" + ((report >> 40) & 0xFFFF)
                + " dropped=" + ((report >> 56) & 0xF)
                + " toggle_failed=" + ((report >> 60) & 0xF));
            Console.WriteLine("menu       = tracks=" + (menu & 0xFFFF) + " last_track_ms=" + ((menu >> 16) & 0xFFFF)
                + " setfg_ok=" + ((menu >> 32) & 0xF) + " is_foreground=" + ((menu >> 36) & 0xF));
            long gesture = IpcWindow.QueryGestureStats(instance.Value) ?? 0;
            Console.WriteLine("gesture    = on_icon=" + (gesture & 0xFFFF)
                + " not_desktop=" + ((gesture >> 16) & 0xFFFF)
                + " throttled=" + ((gesture >> 40) & 0xFFFF)
                + " last=" + DescribeGestureResult((int)((gesture >> 32) & 0xFF)));
        }
        return 0;
    }

    private static string DescribeInstance(IntPtr? instance)
    {
        if (instance is null) return "未运行";
        Native.GetWindowThreadProcessId(instance.Value, out uint pid);
        return "运行中 pid=" + pid;
    }

    /// <summary>
    /// 标志位摊成一行 ASCII，脚本可直接 grep。
    /// hook_set 只说明 SetWindowsHookEx 成没成；hook_saw_up 才说明回调真的被调用过；
    /// hook_paired_dblclk 说明配出了双击。三者分开，才不会出现"状态一切正常但功能不响"这种骗局。
    /// </summary>
    private static string DescribeFlags(IntPtr? instance, int flags)
    {
        if (instance is null)
        {
            return " (no instance) gesture=" + OnOff(SettingIsOn(Settings.DesktopDoubleClickGesture, Settings.DesktopDoubleClickGestureDefault) == 1)
                + " accept_injected=" + OnOff(SettingIsOn(Settings.RespondToInjectedDoubleClick, Settings.RespondToInjectedDoubleClickDefault) == 1)
                + " restore_on_boot=" + OnOff(SettingIsOn(Settings.RestoreStateOnStartup, Settings.RestoreStateOnStartupDefault) == 1) + " (注册表口径)";
        }

        return " hook_set=" + Bit(flags, Native.PingHookInstalled)
            + " hook_saw_up=" + Bit(flags, Native.PingHookAnyUp)
            + " hook_paired_dblclk=" + Bit(flags, Native.PingHookFired)
            + " gesture_on=" + Bit(flags, Native.PingGestureEnabled)
            + " accept_injected=" + Bit(flags, Native.PingRespondToInjected)
            + " restore_on_boot=" + Bit(flags, Native.PingRestoreOnBoot);
    }

    private static string Bit(int flags, int bit) => (flags & bit) != 0 ? "1" : "0";
    private static string OnOff(bool on) => on ? "1" : "0";

    /// <summary>最近一次双击的结局，摊成 ASCII 词，方便脚本直接 grep（codes 见 Program 内的 Gesture* 常量）。</summary>
    private static string DescribeGestureResult(int code) => code switch
    {
        GestureToggled => "toggled",
        GestureOnIcon => "on_icon",
        GestureNotDesktop => "not_desktop",
        GestureOff => "gesture_off",
        GestureInjectedOff => "injected_off",
        GestureBusy => "busy",
        GestureNoLayer => "no_icon_layer",
        _ => "none",
    };


    private static int ClientAutostart(bool enable)
    {
        if (!Autostart.Set(enable)) return Fail((enable ? "开启" : "关闭") + "自启动失败");
        string? stored = Autostart.Read();
        Console.WriteLine("autostart = " + (stored is null ? "off" : "on   " + stored));
        return 0;
    }

    private static int ClientExit()
    {
        IntPtr? instance = IpcWindow.FindOther();
        if (instance is null) return Fail("没有正在运行的实例");
        if (!Native.PostMessageW(instance.Value, Native.WM_APP_QUIT, IntPtr.Zero, IntPtr.Zero))
            return Fail("退出指令投递失败");
        Console.WriteLine("已请求退出（桌面图标保持当前状态）。");
        return 0;
    }

    private static int Fail(string message)
    {
        Console.Error.WriteLine(message + "（Win32 错误 " + Marshal.GetLastPInvokeError() + "）");
        return 1;
    }
}
