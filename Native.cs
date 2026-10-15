using System;
using System.Runtime.InteropServices;
using System.Text;

namespace DeskIcons;

/// <summary>Win32 互操作层。集中所有 P/Invoke，业务代码不直接出现 DllImport。</summary>
internal static class Native
{
    internal const uint WM_LBUTTONDBLCLK = 0x0203;
    internal const uint WM_LBUTTONDOWN = 0x0201;
    internal const uint WM_LBUTTONUP = 0x0202;
    internal const uint WM_RBUTTONUP = 0x0205;
    internal const uint WM_QUERYENDSESSION = 0x0011;
    internal const uint WM_TIMER = 0x0113;
    internal const uint WM_DESTROY = 0x0002;
    internal const uint WM_CLOSE = 0x0006;
    internal const uint WM_NULL = 0x0000;

    /// <summary>托盘回调消息（WM_USER+1）。v4 协议下鼠标消息在 lParam 高 16 位。</summary>
    internal const uint WM_TRAY = 0x0400;

    /// <summary>钩子入队：wParam = 打包的双击坐标，lParam = 1 真实鼠标 / 0 注入。</summary>
    internal const uint WM_APP_GESTURE = 0x8004;

    /// <summary>工作线程做完图标命中测试后回投：wParam = 1 表示确实压在图标上（不切换）。</summary>
    internal const uint WM_APP_ICON_TEST = 0x8007;

    /// <summary>探活：返回值低位是运行状态标志位。</summary>
    internal const uint WM_APP_PING = 0x8002;

    /// <summary>第二诊断通道：返回"菜单被跟踪过几次"与"最后一次跟踪了多少毫秒"。</summary>
    internal const uint WM_APP_MENU_STATS = 0x8008;
    /// <summary>第三诊断通道：一次手势为什么没落地（见 Program.GestureStatsPacked）。</summary>
    internal const uint WM_APP_GESTURE_STATS = 0x8009;
    internal const uint WM_APP_QUIT = 0x8003;

    /// <summary>explorer 重启后shell 会广播这条动态消息，托盘图标必须重新注册一次才会回来。</summary>
    internal static readonly uint TaskbarCreatedMessage = RegisterWindowMessageW("TaskbarCreated");

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern uint RegisterWindowMessageW(string lpString);

    internal const int PingHookInstalled = 0x1;
    internal const int PingGestureEnabled = 0x2;
    internal const int PingRespondToInjected = 0x4;

    /// <summary>钩子装上了、而且回调真的被调用过（这是两件事，必须分开报）。</summary>
    internal const int PingHookFired = 0x8;

    /// <summary>钩子回调收到过至少一次左键抬起：区分"回调根本没被调用"和"调用了但没判成双击"。</summary>
    internal const int PingHookAnyUp = 0x10;

    /// <summary>开机时是否把上次的图标显示状态复原。</summary>
    internal const int PingRestoreOnBoot = 0x20;


    internal const int SW_HIDE = 0;
    internal const int SW_SHOW = 5;

    // 托盘菜单的 owner 必须是一个"可被置前"的窗口：message-only 窗口做不到，
    // 那样 TrackPopupMenu 的"点外部自动收起"就失效了（实测菜单会一直挂在屏幕上）。
    internal const uint WS_POPUP = 0x8000_0000;
    internal const uint WS_VISIBLE = 0x1000_0000;
    internal const uint WS_EX_TOOLWINDOW = 0x0000_0080;
    internal static readonly IntPtr HWND_TOPMOST = new(-1);
    internal static readonly IntPtr HWND_NOTOPMOST = new(-2);
    internal const uint SWP_NOSIZE = 0x0001;
    internal const uint SWP_NOMOVE = 0x0002;
    internal const uint SWP_NOACTIVATE = 0x0010;

    internal const int GWLP_EXSTYLE = -20;   // GWL_EXSTYLE：索引值不按指针宽度换算
    internal const long WS_EX_TRANSPARENT = 0x0000_0020L;

    internal const int GA_ROOT = 2;

    internal const uint TPM_RETURNCMD = 0x0100;
    internal const uint TPM_RIGHTBUTTON = 0x0002;
    internal const uint MF_STRING = 0x0000;
    internal const uint MF_CHECKED = 0x0008;
    internal const uint MF_GRAYED = 0x0001;
    internal const uint MF_SEPARATOR = 0x0800;

    internal const uint NIM_ADD = 0x00000000;
    internal const uint NIM_MODIFY = 0x00000001;
    internal const uint NIM_DELETE = 0x00000002;
    internal const uint NIF_MESSAGE = 0x00000001;
    internal const uint NIF_ICON = 0x00000002;
    internal const uint NIF_TIP = 0x00000004;

    internal const int WH_MOUSE_LL = 14;
    internal const int HC_ACTION = 0;

    internal const uint RDW_INVALIDATE = 0x0001;
    internal const uint RDW_ALLCHILDREN = 0x0080;
    internal const uint RDW_ERASE = 0x0004;

    /// <summary>
    /// LVM_SUBITEMHITTEST = LVM_FIRST(0x1000) + 57 = 0x1039。
    /// 别写成 0x103F——那不是命中测试消息，发给列表控件只会拿到 flags=0，
    /// 于是"双击落在图标上"永远判不出来，图标上的双击会被手势抢走。
    /// </summary>
    internal const uint LVM_SUBITEMHITTEST = 0x1039;

    /// <summary>
    /// LVHT_ONITEM = ONITEMICON(0x2)|ONITEMLABEL(0x4)|ONITEMSTATEICON(0x8) = 0xE。
    /// 不能含 LVHT_NOWHERE(0x1)，否则点在桌面空白处也会被判定成"命中图标"，切换手势永久失效。
    /// </summary>
    internal const uint LVHT_ONITEM = 0x000E;

    internal const uint SMTO_ABORTIFHUNG = 0x0002;
    internal const uint SMTO_BLOCK = 0x0001;

    internal const uint PROCESS_VM_OPERATION = 0x0008;
    internal const uint PROCESS_VM_READ = 0x0010;
    internal const uint PROCESS_VM_WRITE = 0x0020;
    internal const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

    internal const uint MEM_COMMIT = 0x1000;
    internal const uint MEM_RESERVE = 0x2000;
    internal const uint MEM_RELEASE = 0x8000;
    internal const uint PAGE_READWRITE = 0x04;

    internal const uint ERROR_ALREADY_EXISTS = 183;

    /// <summary>ERROR_CLASS_ALREADY_EXISTS：原来 IpcWindow 里写的 141 是 ERROR_POINT_NOT_FOUND，
    /// 那条"类已注册也放过"的容错其实从未生效（本进程只注册一次，所以没暴露）。</summary>
    internal const int ERROR_CLASS_ALREADY_EXISTS = 1408;

    internal static readonly IntPtr HKEY_CURRENT_USER = unchecked(new IntPtr((int)0x80000001));
    internal static readonly IntPtr IDI_APPLICATION = new(32512);

    [StructLayout(LayoutKind.Sequential)]
    internal struct POINT
    {
        internal int X;
        internal int Y;
    }

    // MSLLHOOKSTRUCT 故意不声明：钩子回调按偏移直读字段（见 DesktopGestureHook.OnMouse），
    // 留着结构体只会诱使有人再把它 Marshal 出来、在 300ms 预算里分配一次堆内存。
    [StructLayout(LayoutKind.Sequential)]
    internal struct LVHITTESTINFO
    {
        internal POINT pt;
        internal uint flags;
        internal int iItem;
        internal int iSubItem;
        internal int iHitDataApplied;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct MSG
    {
        internal IntPtr hwnd;
        internal uint message;
        internal IntPtr wParam;
        internal IntPtr lParam;
        internal uint time;
        internal POINT pt;
        /// <summary>真实 MSG 在 Vista+ 上是 48 字节（末尾还有 DWORD lPrivate）。
        /// 不声明它，x64 上只是靠对齐填充侥幸接住那 4 字节；换到 x86 就会越界写。</summary>
        internal uint lPrivate;
    }

    /// <summary>
    /// 注意 WNDCLASSEX（EX 版）比 WNDCLASS 多一个 lpszMenuName，位置在 hbrBackground 和
    /// lpszClassName 之间；漏掉它会让类名指针错位，RegisterClassEx 直接返回 87。
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct WNDCLASSEXW
    {
        internal uint cbSize;
        internal uint style;
        internal IntPtr lpfnWndProc;
        internal int cbClsExtra;
        internal int cbWndExtra;
        internal IntPtr hInstance;
        internal IntPtr hIcon;
        internal IntPtr hCursor;
        internal IntPtr hbrBackground;
        [MarshalAs(UnmanagedType.LPWStr)] internal string? lpszMenuName;
        [MarshalAs(UnmanagedType.LPWStr)] internal string? lpszClassName;
        internal IntPtr hIconSm;
    }

    /// <summary>
    /// 与 shellapi.h 的 NOTIFYICONDATAW 对齐（x64 自然对齐、szTip/szInfo/szInfoTitle 为 128/256/64 WCHAR）。
    /// cbSize 必须和系统期望一致，所以三个字符串字段都按现代 SDK 的容量声明。
    /// </summary>
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct NOTIFYICONDATAW
    {
        internal int cbSize;
        internal IntPtr hWnd;
        internal uint uID;
        internal uint uFlags;
        internal uint uCallbackMessage;
        internal IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string szTip;
        internal uint dwState;
        internal uint dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] internal string szInfo;
        internal uint uVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] internal string szInfoTitle;
        internal uint dwInfoFlags;
        internal Guid guidItem;
        internal IntPtr hBalloonIcon;
    }

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    internal delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    internal delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern IntPtr FindWindowW(string? className, string? windowName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern IntPtr FindWindowExW(IntPtr parent, IntPtr childAfter, string? className, string? windowName);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool IsWindowVisible(IntPtr hWnd);

    /// <summary>
    /// 改可见性只用这个，不要引入同步版 ShowWindow：它会等目标线程处理 show-window 事件，
    /// 而我们这个线程装着 WH_MOUSE_LL —— explorer 一卡，全系统鼠标就跟着发涩，
    /// 钩子超时后还会被系统悄悄不再调用（此时 hook_set 仍报 1，骗人）。
    /// </summary>
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    internal static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetTimer(IntPtr hWnd, UIntPtr id, uint elapsed, IntPtr proc);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool KillTimer(IntPtr hWnd, UIntPtr id);

    [DllImport("user32.dll")]
    internal static extern IntPtr GetAncestor(IntPtr hWnd, uint gaFlags);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    internal static extern IntPtr GetWindowLongPtr64W(IntPtr hWnd, int nIndex);

    internal static long GetWindowLongPtr(IntPtr hWnd, int nIndex) => GetWindowLongPtr64W(hWnd, nIndex).ToInt64();

    [DllImport("user32.dll")]
    internal static extern IntPtr GetParent(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    internal static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int maxCount);

    [DllImport("user32.dll")]
    internal static extern IntPtr WindowFromPoint(POINT pt);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool ScreenToClient(IntPtr hWnd, ref POINT lpPoint);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool RedrawWindow(IntPtr hWnd, IntPtr lprc, IntPtr hrgn, uint flags);

    [DllImport("user32.dll")]
    internal static extern int GetSystemMetrics(int nIndex);

    [DllImport("user32.dll")]
    internal static extern uint GetDoubleClickTime();

    [DllImport("kernel32.dll")]
    internal static extern ulong GetTickCount64();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll", SetLastError = true)]
    internal static extern IntPtr SetWindowsHookExW(int idHook, LowLevelMouseProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    internal static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool PostMessageW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SendMessageTimeoutW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam,
        uint flags, uint timeoutMs, out IntPtr result);

    [DllImport("user32.dll", SetLastError = true)]
    internal static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern ushort RegisterClassExW(ref WNDCLASSEXW lpwcx);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern IntPtr CreateWindowExW(uint exStyle, string className, string? windowName, uint style,
        int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr hInstance, IntPtr lpParam);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool DestroyWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    internal static extern void PostQuitMessage(int nExitCode);

    [DllImport("user32.dll")]
    internal static extern int GetMessageW(out MSG lpMsg, IntPtr hWnd, uint msgFilterMin, uint msgFilterMax);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    internal static extern IntPtr DispatchMessageW(ref MSG lpMsg);

    [DllImport("user32.dll")]
    internal static extern IntPtr DefWindowProcW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    internal static extern IntPtr LoadIconW(IntPtr hInstance, IntPtr lpIconName);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool DestroyIcon(IntPtr hIcon);

    [DllImport("user32.dll")]
    internal static extern IntPtr CreatePopupMenu();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool AppendMenuW(IntPtr hMenu, uint flags, UIntPtr id, string? text);

    /// <summary>带 TPM_RETURNCMD 时直接返回被点击项的 id，返回 0 表示失败或没选。</summary>
    [DllImport("user32.dll")]
    internal static extern int TrackPopupMenuEx(IntPtr hMenu, uint flags, int x, int y, IntPtr hWnd, IntPtr lptpm);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool DestroyMenu(IntPtr hMenu);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool Shell_NotifyIconW(uint dwMessage, ref NOTIFYICONDATAW lpData);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    internal static extern uint ExtractIconExW(string fileName, int iconIndex, IntPtr[]? large, IntPtr[]? small, uint count);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern IntPtr GetModuleHandleW(string? name);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern IntPtr CreateMutexW(IntPtr attributes, bool initialOwner, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool ReleaseMutex(IntPtr handle);

    /// <summary>
    /// 查某个 pid 的可执行文件路径，用来确认"找到的窗口是不是我们自己那个 exe 开的"。
    /// 第三个参数是 DWORD（不是 SIZE_T），别照其它接口的习惯改成 UIntPtr。
    /// </summary>
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder buffer, ref int size);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool AttachConsole(int dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);

    /// <summary>
    /// 这三个接口的长度/写出字节数在 Win32 里是 SIZE_T（x64 为 64 位），必须用 UIntPtr 声明。
    /// 写成 int 时原生侧会往那个 4 字节的出参槽里落 8 字节，踩掉互操作桩上的相邻临时变量。
    /// </summary>
    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern IntPtr VirtualAllocEx(IntPtr hProcess, IntPtr address, UIntPtr size, uint allocType, uint protect);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool VirtualFreeEx(IntPtr hProcess, IntPtr address, UIntPtr size, uint freeType);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr baseAddress, byte[] buffer, UIntPtr size, out UIntPtr written);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr baseAddress, byte[] buffer, UIntPtr size, out UIntPtr read);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern int RegOpenKeyExW(IntPtr hKey, string subKey, int options, int access, out IntPtr result);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern int RegCreateKeyExW(IntPtr hKey, string subKey, int options, string? logClass,
        int optionsFlags, int access, IntPtr security, out IntPtr result, out int disposition);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern int RegCloseKey(IntPtr hKey);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern int RegSetValueExW(IntPtr hKey, string valueName, int reserved, uint regType, byte[] data, int cbData);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern int RegDeleteValueW(IntPtr hKey, string valueName);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern int RegGetValueW(IntPtr hKey, string? subKey, string? value, uint flags,
        out uint regType, byte[]? data, ref int cbData);


    internal static int LastWin32Error => Marshal.GetLastPInvokeError();
}
