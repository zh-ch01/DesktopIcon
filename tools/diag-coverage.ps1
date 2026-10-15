# 只读：把"压在桌面上的顶层可见窗口"列出来，看清到底是什么盖住了桌面。
# 不动任何东西。判据：根窗口类不是 Progman/WorkerW、且窗口面积大到能盖住采样点。
$ErrorActionPreference = 'Stop'
Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public static class LW {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct P { public int X; public int Y; }
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out P pt);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(P pt);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint f);

    public static List<string> Big = new List<string>();
    public static List<IntPtr> Handles = new List<IntPtr>();

    // 回传给托管的 StringBuilder 长度由封送器决定，极端情况下会短于 API 返回的字符数，
    // 所以 ToString 之前一律按 sb.Length 夹一次——枚举回调里抛异常会整轮扫描报废。
    static string Take(StringBuilder sb, int len) {
        int n = len <= 0 ? 0 : Math.Min(len, sb.Length);
        return n <= 0 ? "" : sb.ToString(0, n);
    }

    public static void Scan() {
        Big.Clear(); Handles.Clear();
        EnumProc cb = delegate (IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            RECT r; if (!GetWindowRect(h, out r)) return true;
            int w = r.R - r.L, hh = r.B - r.T;
            if (w < 600 || hh < 400) return true;                    // 只看足够大的
            StringBuilder cls = new StringBuilder(128);
            string c = Take(cls, GetClassNameW(h, cls, cls.Capacity));
            if (c == "" || c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd"
                || c == "Windows.UI.Core.CoreWindow") return true;
            StringBuilder tt = new StringBuilder(256);
            string title = Take(tt, GetWindowTextW(h, tt, tt.Capacity));
            uint pid; GetWindowThreadProcessId(h, out pid);
            string owner = "";
            try { owner = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { }
            Big.Add(string.Format("类={0,-26} 进程={1,-14} pid={2,-6} 尺寸={3}x{4} 标题=[{5}]",
                c, owner, pid, w, hh, title));
            Handles.Add(h);
            return true;
        };
        EnumWindows(cb, IntPtr.Zero);
    }

    public static string Rows() { return string.Join("\n", Big.ToArray()); }
    public static IntPtr[] Wins() { return Handles.ToArray(); }
}
'@ -ReferencedAssemblies System.Runtime.InteropServices

[LW]::Scan()
Write-Host ("挡住桌面的大窗口共 {0} 个：" -f ([LW]::Big).Count)
if (([LW]::Big).Count -gt 0) { Write-Host ([LW]::Rows() -replace '^', '   ') }
