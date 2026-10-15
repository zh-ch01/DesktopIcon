# 诊断：绕开鼠标钩子，直接往后台实例的消息窗口投 WM_APP_GESTURE（打包格式与钩子一致），
# 用来二分"钩子没收到双击" 还是 "收到了但判定链把它拦下了"。
$ErrorActionPreference = 'Stop'
Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class D {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowW(string c, string n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowEx2(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr h, ref P pt);
    [DllImport("user32.dll")] static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(P pt);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint a, bool i, uint pid);
    [DllImport("kernel32.dll")] static extern IntPtr VirtualAllocEx(IntPtr p, IntPtr a, int s, uint t, uint pr);
    [DllImport("kernel32.dll")] static extern bool VirtualFreeEx(IntPtr p, IntPtr a, int s, uint f);
    [DllImport("kernel32.dll")] static extern bool WriteProcessMemory(IntPtr p, IntPtr b, byte[] d, int s, out int w);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr p, IntPtr b, byte[] d, int s, out int r);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    [StructLayout(LayoutKind.Sequential)] public struct P { public int X; public int Y; }

    public static IntPtr Ipc() { return FindWindowExW(IntPtr.Zero, IntPtr.Zero, null, "DesktopIconToggle.Ipc.v1"); }
    public static IntPtr List() {
        IntPtr p = FindWindowW("Progman", null);
        IntPtr d = FindWindowExW(p, IntPtr.Zero, "SHELLDLL_DefView", null);
        if (d == IntPtr.Zero) { IntPtr w = IntPtr.Zero; while (true) { w = FindWindowExW(IntPtr.Zero, w, "WorkerW", null); if (w == IntPtr.Zero) break; d = FindWindowExW(w, IntPtr.Zero, "SHELLDLL_DefView", null); if (d != IntPtr.Zero) break; } }
        return d == IntPtr.Zero ? IntPtr.Zero : FindWindowExW(d, IntPtr.Zero, "SysListView32", null);
    }
    public static bool Visible() {
        IntPtr p = FindWindowW("Progman", null);
        IntPtr d = FindWindowExW(p, IntPtr.Zero, "SHELLDLL_DefView", null);
        return d != IntPtr.Zero && IsWindowVisible(d);
    }
    public static void Move(int x, int y) { SetCursorPos(x, y); }
    public static IntPtr Pack(int x, int y) { return new IntPtr((x & 0xFFFF) | ((y & 0xFFFF) << 16)); }
    public static bool PostGesture(IntPtr hwnd, int x, int y) { return PostMessageW(hwnd, 0x8004, Pack(x, y), new IntPtr(1)); }
    public static int Items(IntPtr l) { return (int)SendMessageW(l, 0x1004, IntPtr.Zero, IntPtr.Zero); }
    public static bool OverIcon(IntPtr l, int sx, int sy) {
        P pt = new P(); pt.X = sx; pt.Y = sy; ScreenToClient(l, ref pt);
        byte[] payload = new byte[24];
        BitConverter.GetBytes(pt.X).CopyTo(payload, 0); BitConverter.GetBytes(pt.Y).CopyTo(payload, 4);
        uint pid; GetWindowThreadProcessId(l, out pid);
        IntPtr proc = OpenProcess(0x38, false, pid); int junk;
        IntPtr mem = VirtualAllocEx(proc, IntPtr.Zero, 24, 0x3000, 0x04);
        WriteProcessMemory(proc, mem, payload, 24, out junk);
        SendMessageW(l, 0x1039, IntPtr.Zero, mem);
        byte[] back = new byte[24]; ReadProcessMemory(proc, mem, back, 24, out junk);
        VirtualFreeEx(proc, mem, 0, 0x8000); CloseHandle(proc);
        return (BitConverter.ToUInt32(back, 8) & 0x000E) != 0;
    }
    public static string Root(int x, int y) {
        P pt = new P(); pt.X = x; pt.Y = y;
        IntPtr h = WindowFromPoint(pt);
        StringBuilder sb = new StringBuilder(64);
        return h == IntPtr.Zero ? "(none)" : h.ToString();
    }
}
'@

$ipc = [D]::Ipc()
if ($ipc -eq [IntPtr]::Zero) { throw "找不到后台实例的消息窗口" }
"ipc窗口 = $ipc   当前图标 = $(if ([D]::Visible()) {'visible'} else {'hidden'})"

# 先最小化全部窗口，保证桌面露出
$shell = New-Object -ComObject Shell.Application
$shell.MinimizeAll()
Start-Sleep -Seconds 2

$x = 1820; $y = 60
$list = [D]::List()
"listview=$list 图标数=$([D]::Items($list)) 命中测试=$([D]::OverIcon($list,$x,$y)) 命中窗口=$([D]::Root($x,$y))"

[D]::Move($x, $y)
Start-Sleep -Milliseconds 200
"投 WM_APP_GESTURE 前: $(if ([D]::Visible()) {'visible'} else {'hidden'})"
$ok = [D]::PostGesture($ipc, $x, $y)
Start-Sleep -Milliseconds 800
"PostMessage 返回=$ok  投完之后: $(if ([D]::Visible()) {'visible'} else {'hidden'})"

# 再投一次，应翻回来
$ok2 = [D]::PostGesture($ipc, $x, $y)
Start-Sleep -Milliseconds 800
"第二次投完之后: $(if ([D]::Visible()) {'visible'} else {'hidden'}) (PostMessage=$ok2)"

$shell.UndoMinimizeALL()
"已还原窗口；最终图标 = $(if ([D]::Visible()) {'visible'} else {'hidden'})"
