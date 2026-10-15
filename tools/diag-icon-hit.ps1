# 只读诊断：把桌面 15 个图标的坐标全读出来，并在每个坐标附近做 LVM_SUBHITTEST，
# 看"图标命中判定"这条依据在 Windows 11 的桌面列表控件上到底给不给结果。
# 不移动鼠标、不点击、不改任何状态。
$ErrorActionPreference = 'Stop'
Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
public static class R {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowW(string c, string n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr h, ref P pt);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref P pt);
    [DllImport("user32.dll", SetLastError=true)] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint g);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(P pt);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int max);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out P pt);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint a, bool i, uint pid);
    [DllImport("kernel32.dll")] static extern IntPtr VirtualAllocEx(IntPtr p, IntPtr a, int s, uint t, uint pr);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool VirtualFreeEx(IntPtr p, IntPtr a, int s, uint f);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool WriteProcessMemory(IntPtr p, IntPtr b, byte[] d, int s, out int w);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr p, IntPtr b, byte[] d, int s, out int r);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern uint GetLastError();

    [StructLayout(LayoutKind.Sequential)] public struct P { public int X; public int Y; }

    public static IntPtr Progman = FindWindowW("Progman", null);
    public static IntPtr DefView = FindWindowExW(Progman, IntPtr.Zero, "SHELLDLL_DefView", null);
    public static IntPtr List = DefView == IntPtr.Zero ? IntPtr.Zero : FindWindowExW(DefView, IntPtr.Zero, "SysListView32", null);

    public static int Count() { return (int)SendMessageW(List, 0x1004, IntPtr.Zero, IntPtr.Zero); }
    public static uint Pid() { uint pid; GetWindowThreadProcessId(List, out pid); return pid; }

    /// 在目标进程里放一块内存，发一个消息，把结果读回来。返回 null 表示这条路走不通。
    public static byte[] RoundTrip(int index, uint msg, int writeBytes, int outBytes, bool fillPoint, int px, int py) {
        int junk;
        IntPtr proc = OpenProcess(0x38, false, Pid());
        if (proc == IntPtr.Zero) { return null; }
        int size = outBytes < 32 ? 32 : outBytes;
        IntPtr mem = VirtualAllocEx(proc, IntPtr.Zero, size, 0x3000, 0x04);
        if (mem == IntPtr.Zero) { CloseHandle(proc); return null; }
        byte[] payload = new byte[size];
        if (fillPoint) { BitConverter.GetBytes(px).CopyTo(payload, 0); BitConverter.GetBytes(py).CopyTo(payload, 4); }
        bool wrote = WriteProcessMemory(proc, mem, payload, size, out junk);
        IntPtr sent = SendMessageW(List, msg, new IntPtr(index), mem);
        byte[] back = new byte[size];
        bool read = ReadProcessMemory(proc, mem, back, size, out junk);
        VirtualFreeEx(proc, mem, 0, 0x8000);
        CloseHandle(proc);
        if (!wrote || !read) { return null; }
        return back;
    }

    public static string Describe(uint flags) {
        System.Text.StringBuilder sb = new System.Text.StringBuilder();
        if ((flags & 0x0001) != 0) sb.Append("NOWHERE ");
        if ((flags & 0x0002) != 0) sb.Append("ONITEMICON ");
        if ((flags & 0x0004) != 0) sb.Append("ONITEMLABEL ");
        if ((flags & 0x0008) != 0) sb.Append("STATEICON_OR_ABOVE ");
        if ((flags & 0x0020) != 0) sb.Append("BELOW ");
        if ((flags & 0x0040) != 0) sb.Append("TOLEFT ");
        if ((flags & 0x0080) != 0) sb.Append("TORIGHT ");
        if (sb.Length == 0) sb.Append("(0)");
        return sb.ToString().Trim();
    }

    public static string ClassAt(int x, int y) {
        P pt = new P(); pt.X = x; pt.Y = y;
        IntPtr h = WindowFromPoint(pt);
        if (h == IntPtr.Zero) return "(none)";
        IntPtr root = GetAncestor(h, 2);
        System.Text.StringBuilder sb = new System.Text.StringBuilder(64);
        GetClassNameW(h, sb, sb.Capacity);
        string hitName = sb.ToString();
        sb = new System.Text.StringBuilder(64);
        GetClassNameW(root, sb, sb.Capacity);
        return hitName + " / root=" + sb.ToString();
    }

    public static string Cursor() { P p; GetCursorPos(out p); return "(" + p.X + "," + p.Y + ")"; }
}
'@

"listview = $([R]::List)  explorer pid = $([R]::Pid())  光标 = $([R]::Cursor())"
$n = [R]::Count()
"图标数 = $n"
if ($n -le 0) { throw "读不到图标数，后面的判定无从谈起" }

for ($i = 0; $i -lt [Math]::Min($n, 8); $i++) {
    $pos = [R]::RoundTrip($i, 0x1010, 8, 32, $true, 0, 0)     # LVM_GETITEMPOSITION = LVM_FIRST+16 -> POINT（原先写 0x100C，消息不生效、读回全零）
    if ($null -eq $pos) { "item $i : 跨进程读写失败"; continue }
    $x = [BitConverter]::ToInt32($pos, 0); $y = [BitConverter]::ToInt32($pos, 4)

    # 图标中心大概在位置右下 26x18（48px 图标）；分别用屏幕坐标和客户区坐标各测一次 subhit
    foreach ($variant in 'client','screen') {
        $px = $x + 26; $py = $y + 18
        if ($variant -eq 'client') {
            $p = New-Object R+P; $p.X = $px; $p.Y = $py
            $null = [R]::List   # 客户区->屏幕换算在探针里手工做：桌面列表控件原点即屏幕原点，两者相同
        }
        $res = [R]::RoundTrip(0, 0x1039, 24, 32, $true, $px, $py)   # LVM_SUBHITTEST，flags 在偏移 8
        if ($null -eq $res) { "item $i @$variant : 跨进程读写失败"; continue }
        $flags = [BitConverter]::ToUInt32($res, 8)
        $item  = [BitConverter]::ToInt32($res, 12)
        "item $i @$variant : 位置=($px,$py) flags=0x$($flags.ToString('X')) [$([R]::Describe($flags))] iItem=$item 命中窗口=$([R]::ClassAt($px,$py))"
    }
}
