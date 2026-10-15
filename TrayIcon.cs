using System;
using System.Runtime.InteropServices;

namespace DeskIcons;

/// <summary>托盘图标（Shell_NotifyIcon）：没有主窗口、没有任务栏项。</summary>
internal sealed class TrayIcon : IDisposable
{
    private const uint NIF_SHOWTIP = 0x00000080;
    private const uint NIM_SETVERSION = 0x00000004;
    private const uint NOTIFYICON_VERSION_4 = 4;

    private Native.NOTIFYICONDATAW _data;
    private readonly IntPtr _icon;
    private readonly bool _ownsIcon;
    private bool _added;

    internal TrayIcon(IntPtr owner, string tip)
    {
        _icon = LoadOwnIcon();
        _ownsIcon = _icon != IntPtr.Zero && _icon != Native.LoadIconW(IntPtr.Zero, Native.IDI_APPLICATION);

        _data = new Native.NOTIFYICONDATAW
        {
            cbSize = Marshal.SizeOf<Native.NOTIFYICONDATAW>(),
            hWnd = owner,
            uID = 1,
            uFlags = Native.NIF_MESSAGE | Native.NIF_ICON | Native.NIF_TIP | NIF_SHOWTIP,
            uCallbackMessage = Native.WM_TRAY,
            hIcon = _icon,
            szTip = tip,
        };
    }

    internal bool Add()
    {
        // 只能用 |=：重补路径会在"已经注册成功"之后再次调用它，若那次失败就把 _added 覆盖成 false，
        // Dispose 于是跳过 NIM_DELETE —— 进程退了、shell 里留下一个点不动的幽灵托盘图标。
        bool ok = Native.Shell_NotifyIconW(Native.NIM_ADD, ref _data);
        _added |= ok;
        if (!ok) return false;

        // v4：鼠标消息挪到 lParam 高 16 位，位置信息改由 GetCursorPos 取。
        Native.NOTIFYICONDATAW versioned = _data;
        versioned.uVersion = NOTIFYICON_VERSION_4;
        Native.Shell_NotifyIconW(NIM_SETVERSION, ref versioned);
        return true;
    }

    /// <summary>从自身 exe 的图标资源取托盘图；取不到时退回系统应用图标。</summary>
    private static IntPtr LoadOwnIcon()
    {
        string? path = Environment.ProcessPath;
        if (path is not null)
        {
            var large = new IntPtr[1];
            var small = new IntPtr[1];
            // 同时传 large+small 两个数组时，返回的是"取出的句柄个数"=2，不是图标数 1；
            // 判 ==1 会永远落空，托盘就一直是系统通用图标。
            uint extracted = Native.ExtractIconExW(path, 0, large, small, 1);
            if (extracted > 0)
            {
                IntPtr keep = small[0] != IntPtr.Zero ? small[0] : large[0];
                IntPtr discard = small[0] != IntPtr.Zero ? large[0] : small[0];
                if (discard != IntPtr.Zero && discard != keep) Native.DestroyIcon(discard);
                if (keep != IntPtr.Zero) return keep;
            }
        }
        return Native.LoadIconW(IntPtr.Zero, Native.IDI_APPLICATION);
    }

    public void Dispose()
    {
        if (_added)
        {
            Native.Shell_NotifyIconW(Native.NIM_DELETE, ref _data);
            _added = false;
        }
        if (_ownsIcon) Native.DestroyIcon(_icon);
    }
}
