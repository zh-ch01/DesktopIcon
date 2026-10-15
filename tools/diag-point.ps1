# 临时探针：看候选点到底命中什么窗口，以及桌面三层窗口现在的状态。只读，不动任何东西。
$ErrorActionPreference = 'Stop'
Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class D {
    [StructLayout(LayoutKind.Sequential)] public struct P { public int X; public int Y; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowW(string c, string n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(P pt);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);

    public static string Cls(IntPtr h) {
        if (h == IntPtr.Zero) return "(zero)";
        StringBuilder sb = new StringBuilder(64);
        int n = GetClassNameW(h, sb, sb.Capacity);
        return n <= 0 ? "(无类名)" : sb.ToString(0, n);
    }

    public static string At(int x, int y) {
        P pt = new P(); pt.X = x; pt.Y = y;
        IntPtr hit = WindowFromPoint(pt);
        IntPtr root = GetAncestor(hit, 2);
        return string.Format("({0},{1})  命中={2}  GA_ROOT={3}  GetParent链={4}",
            x, y, Cls(hit), Cls(root), Cls(GetParent(hit)));
    }

    public static string Tree() {
        IntPtr pr = FindWindowW("Progman", null);
        IntPtr v = pr == IntPtr.Zero ? IntPtr.Zero : FindWindowExW(pr, IntPtr.Zero, "SHELLDLL_DefView", null);
        IntPtr lv = v == IntPtr.Zero ? IntPtr.Zero : FindWindowExW(v, IntPtr.Zero, "SysListView32", null);
        return string.Format("Progman={0} DefView={1} ListView={2} 列表可见={3}",
            pr != IntPtr.Zero, v != IntPtr.Zero, lv != IntPtr.Zero,
            (lv != IntPtr.Zero && IsWindowVisible(lv)));
    }

    public static string Workers() {
        var sb = new StringBuilder();
        IntPtr w = IntPtr.Zero;
        int n = 0;
        while (true) {
            w = FindWindowExW(IntPtr.Zero, w, "WorkerW", null);
            if (w == IntPtr.Zero) break;
            n++;
            IntPtr v = FindWindowExW(w, IntPtr.Zero, "SHELLDLL_DefView", null);
            sb.Append(" WorkerW#" + n + " 有DefView=" + (v != IntPtr.Zero));
        }
        return n == 0 ? "没有 WorkerW" : sb.ToString().Trim();
    }
}
'@ -ReferencedAssemblies System.Runtime.InteropServices

Write-Host ("桌面三层：" + [D]::Tree())
Write-Host ("顶层 WorkerW：" + [D]::Workers())
foreach ($p in @(@(1700,400), @(1700,60), @(960,700), @(1400,1000), @(400,900), @(1850,60))) {
    Write-Host ([D]::At($p[0], $p[1]))
}
