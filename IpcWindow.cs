using System;
using System.Runtime.InteropServices;
using System.Text;

namespace DeskIcons;

/// <summary>
/// 承载托盘图标、同时充当命令行客户端与后台实例之间通信端点的隐藏窗口。
/// 它是"可见的 0×0 顶层窗口"（不是 message-only），但落在屏幕外且带 WS_EX_TOOLWINDOW，
/// 因此看不见、不进任务栏、不进 Alt+Tab；之所以要"可见"，原因见构造函数里的注释。
/// </summary>
internal sealed class IpcWindow : IDisposable
{
    internal const string ClassName = "DesktopIconToggle.MessageWindow.v1";
    internal const string WindowName = "DesktopIconToggle.Ipc.v1";

    private readonly Func<IntPtr, uint, IntPtr, IntPtr, IntPtr> _handler;
    private readonly Native.WndProcDelegate _procedure;
    private IntPtr _handle;

    internal IpcWindow(Func<IntPtr, uint, IntPtr, IntPtr, IntPtr> handler)
    {
        _handler = handler;
        _procedure = OnMessage;   // 委托必须被强引用持有：原生侧只存着函数指针，被 GC 掉就是随机崩溃

        IntPtr instance = Native.GetModuleHandleW(null);
        var registration = new Native.WNDCLASSEXW
        {
            cbSize = (uint)Marshal.SizeOf<Native.WNDCLASSEXW>(),
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_procedure),
            hInstance = instance,
            lpszClassName = ClassName,
        };
        if (Native.RegisterClassExW(ref registration) == 0 && Marshal.GetLastPInvokeError() != 1408)   // 1408 = ERROR_CLASS_ALREADY_EXISTS（原先写的 141 是 ERROR_POINT_NOT_FOUND，那条容错其实从未生效）
            throw new InvalidOperationException("注册窗口类失败：" + Marshal.GetLastPInvokeError());

        // 为什么是"可见的 0×0 顶层窗口"而不是 message-only 窗口：
        // 托盘菜单要能"点外部自动收起"，owner 必须能成为前台窗口；实测 message-only 时
        // SetForegroundWindow 返回 0（不可见的窗口没有资格当前台），菜单就一直挂在屏幕上。
        // 所以这里给它 WS_VISIBLE，但尺寸 0×0 且挪到屏幕外，配合 WS_EX_TOOLWINDOW 不进任务栏/Alt+Tab。
        _handle = Native.CreateWindowExW(Native.WS_EX_TOOLWINDOW, ClassName, WindowName,
            Native.WS_POPUP | Native.WS_VISIBLE, -32000, -32000, 0, 0,
            IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);
        if (_handle == IntPtr.Zero) throw new InvalidOperationException("创建隐藏窗口失败：" + Marshal.GetLastPInvokeError());
    }

    internal IntPtr Handle => _handle;

    private IntPtr OnMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam) => _handler(hWnd, msg, wParam, lParam);

    internal bool Post(uint message, IntPtr wParam, IntPtr lParam) =>
        Native.PostMessageW(_handle, message, wParam, lParam);

    /// <summary>
    /// 把双击坐标打包进一个 IntPtr：LOWORD=x、HIWORD=y（各 16 位有符号，负坐标对应副屏在左/在上）。
    /// 一条消息就带上坐标，省掉一次跨进程内存。
    /// </summary>
    internal static IntPtr Pack(Native.POINT pt) =>
        new(unchecked((pt.X & 0xFFFF) | ((pt.Y & 0xFFFF) << 16)));

    internal static Native.POINT Unpack(IntPtr packed)
    {
        int raw = packed.ToInt32();
        return new Native.POINT { X = (short)(raw & 0xFFFF), Y = (short)((raw >> 16) & 0xFFFF) };
    }

    /// <summary>
    /// 正在运行的另一个实例。三重确认：类名 + 标题 + 属主 exe 必须与自己是同一个文件。
    /// 只按标题找，任何程序建个同名标题窗口，`--exit` 就会把 WM_APP_QUIT 投给人家；
    /// 只加类名也不够——类名字符串在别的进程里能重复注册（我们没带 CS_GLOBALCLASS），
    /// 所以最后按 pid 查出可执行文件路径比一次。查不到就当没有实例：宁可不做事，也不投给陌生窗口。
    /// </summary>
    internal static IntPtr? FindOther()
    {
        string? me = Environment.ProcessPath;
        if (me is null) return null;
        for (IntPtr found = Native.FindWindowExW(IntPtr.Zero, IntPtr.Zero, ClassName, WindowName);
             found != IntPtr.Zero;
             found = Native.FindWindowExW(IntPtr.Zero, found, ClassName, WindowName))
        {
            Native.GetWindowThreadProcessId(found, out uint pid);
            string? owner = OwningExePath(pid);
            if (owner is not null && string.Equals(owner, me, StringComparison.OrdinalIgnoreCase)) return found;
        }
        return null;
    }

    private static string? OwningExePath(uint pid)
    {
        if (pid == 0) return null;
        IntPtr process = Native.OpenProcess(Native.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (process == IntPtr.Zero) return null;
        try
        {
            var text = new StringBuilder(512);
            int size = text.Capacity;   // 这个接口的长度参数是 DWORD，不是 SIZE_T
            return Native.QueryFullProcessImageNameW(process, 0, text, ref size)
                ? text.ToString(0, size) : null;
        }
        finally
        {
            Native.CloseHandle(process);
        }
    }

    /// <summary>问一次菜单跟踪统计（次数 + 最后一次跟踪毫秒数）。</summary>
    internal static long? QueryMenuStats(IntPtr target)
    {
        if (!Native.SendMessageTimeoutW(target, Native.WM_APP_MENU_STATS, IntPtr.Zero, IntPtr.Zero,
                Native.SMTO_ABORTIFHUNG | Native.SMTO_BLOCK, 1000, out IntPtr result)) return null;
        return result.ToInt64();
    }

    /// <summary>问一次"双击为什么没落地"的统计（让位次数 / 落点非桌面次数 / 最近一次结局码）。</summary>
    internal static long? QueryGestureStats(IntPtr target)
    {
        if (!Native.SendMessageTimeoutW(target, Native.WM_APP_GESTURE_STATS, IntPtr.Zero, IntPtr.Zero,
                Native.SMTO_ABORTIFHUNG | Native.SMTO_BLOCK, 1000, out IntPtr result)) return null;
        return result.ToInt64();
    }

    /// <summary>问一次运行报告（标志位 + 各级计数，见 Program.PingPacked）；无实例或不应答返回 null。</summary>
    internal static long? QueryReport(IntPtr target)
    {
        if (!Native.SendMessageTimeoutW(target, Native.WM_APP_PING, IntPtr.Zero, IntPtr.Zero,
                Native.SMTO_ABORTIFHUNG | Native.SMTO_BLOCK, 1000, out IntPtr result)) return null;
        return result.ToInt64();
    }

    public void Dispose()
    {
        if (_handle == IntPtr.Zero) return;
        Native.DestroyWindow(_handle);
        _handle = IntPtr.Zero;
    }
}
