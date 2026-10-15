using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace DeskIcons;

/// <summary>
/// 桌面图标可见性控制。图标实体是 explorer 里的 SHELLDLL_DefView（多屏时每个监视器一个），
/// 隐藏/显示即 ShowWindow 该窗口。可见状态不落缓存在本进程，每次都现查，避免和资源管理器
/// 自己造成的变化（右键桌面 → 查看 → 显示桌面图标、F5、explorer 重启）脱节。
/// </summary>
internal static class Desktop
{
    private const string ProgmanClass = "Progman";
    private const string WorkerWClass = "WorkerW";
    private const string DefViewClass = "SHELLDLL_DefView";
    private const string ListViewClass = "SysListView32";

    /// <summary>桌面上所有 SHELLDLL_DefView 句柄（多屏时每个监视器一个）。</summary>
    internal static List<IntPtr> FindDefViews()
    {
        var found = new List<IntPtr>(2);
        foreach (IntPtr root in FindDesktopRoots())
        {
            IntPtr child = IntPtr.Zero;
            while ((child = Native.FindWindowExW(root, child, DefViewClass, null)) != IntPtr.Zero) found.Add(child);
        }
        return found;
    }

    /// <summary>
    /// 桌面的顶层宿主：Progman，以及资源管理器为每个监视器建的 WorkerW。
    /// 只找 Progman 在单屏上够用，多屏会漏掉副屏的图标层，所以两个都扫。
    /// </summary>
    private static List<IntPtr> FindDesktopRoots()
    {
        var roots = new List<IntPtr>(4);
        IntPtr progman = Native.FindWindowW(ProgmanClass, null);
        if (progman != IntPtr.Zero) roots.Add(progman);

        IntPtr worker = IntPtr.Zero;
        while ((worker = Native.FindWindowExW(IntPtr.Zero, worker, WorkerWClass, null)) != IntPtr.Zero)
        {
            if (worker != progman) roots.Add(worker);
        }
        return roots;
    }

    /// <summary>
    /// 真正要隐藏的是图标层 SysListView32("FolderView")，不是 SHELLDLL_DefView。
    /// 实测（Win11 24H2，截图对比）：隐藏 DefView 会把桌面背景一起带走，整屏变黑（平均亮度 128→28）；
    /// 只隐藏列表控件则图标消失、壁纸不动（128.5→128.3）。
    /// 某个 DefView 下找不到列表控件时宁可跳过，也不要退化成黑屏。
    /// </summary>
    internal static List<IntPtr> FindIconLayers()
    {
        var layers = new List<IntPtr>(2);
        foreach (IntPtr view in FindDefViews())
        {
            IntPtr list = Native.FindWindowExW(view, IntPtr.Zero, ListViewClass, null);
            if (list != IntPtr.Zero) layers.Add(list);
        }
        return layers;
    }

    internal static bool IconsVisible()
    {
        List<IntPtr> layers = FindIconLayers();
        return layers.Count > 0 && Native.IsWindowVisible(layers[0]);
    }

    /// <summary>切换全部监视器的桌面图标可见性。false = 找不到图标层。</summary>
    internal static bool ToggleIcons()
    {
        List<IntPtr> layers = FindIconLayers();
        if (layers.Count == 0) return false;
        SetIconsVisible(!Native.IsWindowVisible(layers[0]));
        return true;
    }

    internal static void SetIconsVisible(bool visible)
    {
        // 切换时就记一次：崩溃或被任务管理器杀掉时不至于丢掉用户的选择；
        // 注销时的 RememberCurrentState 再按真实值刷一遍，覆盖"用户用 explorer 右键菜单改的"那种情况。
        Settings.Write(Settings.IconsVisibleOnExit, visible ? 1 : 0);

        foreach (IntPtr layer in FindIconLayers())
        {
            if (Native.IsWindowVisible(layer) == visible) continue;
            Native.ShowWindowAsync(layer, visible ? Native.SW_SHOW : Native.SW_HIDE);
            ShowWindowCalls++;
            if (visible)
            {
                // 不带 RDW_UPDATENOW：强制同步重绘会占住消息线程，把重绘交给系统自己排。
                Native.RedrawWindow(layer, IntPtr.Zero, IntPtr.Zero,
                    Native.RDW_INVALIDATE | Native.RDW_ERASE | Native.RDW_ALLCHILDREN);
            }
        }
    }

    /// <summary>把当前真实状态记进注册表，供下次开机复原。只在确实有图标层可查时才写。</summary>
    internal static void RememberCurrentState()
    {
        if (FindIconLayers().Count == 0) return;
        Settings.Write(Settings.IconsVisibleOnExit, IconsVisible() ? 1 : 0);
    }

    /// <summary>成功调用 ShowWindow 的次数，供 --status 报告。与"用户请求次数"不同：重复设成同一状态不计。</summary>
    internal static long ShowWindowCalls { get; private set; }

    /// <summary>
    /// 判定一个屏幕坐标是否落在"桌面本体"（Progman / WorkerW）上；若是，回传该处的图标列表控件
    /// （图标已隐藏时为 IntPtr.Zero）。只用父子关系和窗口类，不向 explorer 发消息。
    /// </summary>
    internal static bool IsDesktopPoint(Native.POINT screenPt, out IntPtr iconList)
    {
        iconList = IntPtr.Zero;
        IntPtr hit = Native.WindowFromPoint(screenPt);
        if (hit == IntPtr.Zero) return false;

        IntPtr root = Native.GetAncestor(hit, Native.GA_ROOT);
        if (root == IntPtr.Zero) return false;
        if (!(IsClass(root, ProgmanClass) || IsClass(root, WorkerWClass))) return false;

        if (!IconsVisible()) return true;   // 图标已隐藏，命中窗口就是 Progman/WorkerW 本身

        for (IntPtr node = hit; node != IntPtr.Zero && node != root; node = Native.GetParent(node))
        {
            if (IsClass(node, ListViewClass)) { iconList = node; break; }
        }
        return true;
    }

    /// <summary>该窗口是否对鼠标点击透明（WS_EX_TRANSPARENT）——即"看穿"它、真正被点到的不是它。</summary>
    internal static bool ClicksThrough(IntPtr hWnd)
    {
        long style = Native.GetWindowLongPtr(hWnd, Native.GWLP_EXSTYLE);
        return (style & Native.WS_EX_TRANSPARENT) != 0;
    }

    /// <summary>
    /// 这次双击是不是"压在某个图标上"。文档要求 LVHITTESTINFO.pt 是列表控件的**客户区坐标**，所以先 ScreenToClient。
    /// 判不了时一律返回 true（当作点在图标上）：宁可少切一次，也不抢走用户启动程序的点击。
    /// 跨进程调用（往 explorer 写 24 字节 + 发消息 + 读回），150ms 超时，由调用方放到工作线程上发起。
    /// </summary>
    internal static bool IsDoubleClickOnIcon(IntPtr listView, Native.POINT screenPt)
    {
        if (listView == IntPtr.Zero || !Native.IsWindow(listView) || !Native.IsWindowVisible(listView)) return true;

        var info = new Native.LVHITTESTINFO { pt = screenPt };
        if (!Native.ScreenToClient(listView, ref info.pt)) return true;

        Native.GetWindowThreadProcessId(listView, out uint pid);
        if (pid == 0) return true;

        int size = Marshal.SizeOf<Native.LVHITTESTINFO>();
        byte[] buffer = new byte[size];
        MemoryMarshal.Write(buffer, in info);

        using RemoteBlock? remote = RemoteBlock.TryAlloc(pid, size);
        if (remote is null) return true;
        if (!remote.Write(buffer)) return true;

        if (!Native.SendMessageTimeoutW(listView, Native.LVM_SUBITEMHITTEST, IntPtr.Zero, remote.Address,
                Native.SMTO_ABORTIFHUNG | Native.SMTO_BLOCK, 150, out _) || !remote.Read(buffer)) return true;

        Native.LVHITTESTINFO result = MemoryMarshal.Read<Native.LVHITTESTINFO>(buffer);
        return (result.flags & Native.LVHT_ONITEM) != 0;
    }

    private static bool IsClass(IntPtr hWnd, string name)
    {
        var sb = new StringBuilder(64);
        int len = Native.GetClassNameW(hWnd, sb, sb.Capacity);
        return len > 0 && string.Equals(sb.ToString(0, len), name, StringComparison.Ordinal);
    }
}

/// <summary>目标进程内的一小段临时内存，用完立即释放。只为跨进程 ListView 命中测试而存在。</summary>
internal sealed class RemoteBlock : IDisposable
{
    private readonly IntPtr _process;
    private readonly IntPtr _address;
    private bool _disposed;

    private RemoteBlock(IntPtr process, IntPtr address)
    {
        _process = process;
        _address = address;
    }

    internal IntPtr Address => _address;

    internal static RemoteBlock? TryAlloc(uint pid, int size)
    {
        IntPtr process = Native.OpenProcess(
            Native.PROCESS_VM_OPERATION | Native.PROCESS_VM_READ | Native.PROCESS_VM_WRITE | Native.PROCESS_QUERY_LIMITED_INFORMATION,
            false, pid);
        if (process == IntPtr.Zero) return null;

        IntPtr address = Native.VirtualAllocEx(process, IntPtr.Zero, (UIntPtr)(uint)size,
            Native.MEM_COMMIT | Native.MEM_RESERVE, Native.PAGE_READWRITE);
        if (address == IntPtr.Zero)
        {
            Native.CloseHandle(process);
            return null;
        }
        return new RemoteBlock(process, address);
    }

    internal bool Write(byte[] data) =>
        !_disposed && Native.WriteProcessMemory(_process, _address, data, (UIntPtr)(uint)data.Length, out _);

    internal bool Read(byte[] data) =>
        !_disposed && Native.ReadProcessMemory(_process, _address, data, (UIntPtr)(uint)data.Length, out _);

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Native.VirtualFreeEx(_process, _address, UIntPtr.Zero, Native.MEM_RELEASE);
        Native.CloseHandle(_process);
    }
}
