# 旁路探针：自己装一个 WH_MOUSE_LL 钩子，把每一个左键事件（含"是否注入"标志）
# 和桌面图标可见性的每一次跳变，带时间戳写进 hook-probe.log。
# 用途：判断"双击没触发切换"到底是①钩子没收到 WM_LBUTTONDBLCLK，还是②收到了但被测程序的判定把它拦下了。
# 跑法：powershell -NoProfile -ExecutionPolicy Bypass -File tools\hook-probe.ps1 -Seconds 60
param([int]$Seconds = 60)
$ErrorActionPreference = 'Stop'

Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class Probe {
    public delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)] public struct MSLL {
        public int X; public int Y; public uint mouseData; public uint flags; public uint time; public IntPtr extra;
    }

    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SetWindowsHookExW(int idHook, HookProc lpfn, IntPtr hMod, uint threadId);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] static extern int GetMessageW(out MSG m, IntPtr h, uint a, uint b);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessageW(ref MSG m);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] static extern void PostQuitMessage(int code);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowW(string c, string n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandleW(string name);
    [DllImport("user32.dll")] static extern uint GetDoubleClickTime();

    [StructLayout(LayoutKind.Sequential)] public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int X; public int Y; }

    public static StringBuilder Log = new StringBuilder();
    static IntPtr hook = IntPtr.Zero;
    static HookProc kept;          // 强引用，防 GC
    static DateTime start;
    static int remaining;

    public static uint DoubleClickMs { get { return GetDoubleClickTime(); } }

    static IntPtr OnHook(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode == 0 && remaining > 0) {
            remaining--;
            MSLL d = (MSLL)Marshal.PtrToStructure(lParam, typeof(MSLL));
            int m = (int)wParam.ToInt64();
            string name;
            switch (m) {
                case 0x0200: name = "MOVE"; break;
                case 0x0201: name = "LBUTTONDOWN"; break;
                case 0x0202: name = "LBUTTONUP"; break;
                case 0x0203: name = "LBUTTONDBLCLK"; break;
                default: name = "0x" + m.ToString("X"); break;
            }
            if (name != "MOVE") {
                Log.Append("+").Append((int)(DateTime.Now - start).TotalMilliseconds).Append("ms ")
                   .Append(name).Append(" (").Append(d.X).Append(",").Append(d.Y).Append(")")
                   .Append(d.flags == 0 ? " [真实鼠标]" : " [注入 flags=" + d.flags + "]")
                   .AppendLine();
            }
        }
        return CallNextHookEx(hook, nCode, wParam, lParam);
    }

    static IntPtr DefView() {
        IntPtr p = FindWindowW("Progman", null);
        IntPtr d = p == IntPtr.Zero ? IntPtr.Zero : FindWindowExW(p, IntPtr.Zero, "SHELLDLL_DefView", null);
        if (d != IntPtr.Zero) { return d; }
        IntPtr w = IntPtr.Zero;
        while (true) {
            w = FindWindowExW(IntPtr.Zero, w, "WorkerW", null);
            if (w == IntPtr.Zero) { break; }
            d = FindWindowExW(w, IntPtr.Zero, "SHELLDLL_DefView", null);
            if (d != IntPtr.Zero) { break; }
        }
        return d;
    }

    public static string Run(int seconds) {
        start = DateTime.Now;
        remaining = 4000;
        kept = new HookProc(OnHook);
        hook = SetWindowsHookExW(14, kept, GetModuleHandleW(null), 0);
        if (hook == IntPtr.Zero) { return "SetWindowsHookEx failed: " + Marshal.GetLastWin32Error(); }

        bool last = IsWindowVisible(DefView());
        Log.AppendLine("探针启动，图标初始 " + (last ? "visible" : "hidden") + "，系统双击间隔 " + GetDoubleClickTime() + "ms");
        MSG m;
        DateTime deadline = DateTime.Now.AddSeconds(seconds);
        while (DateTime.Now < deadline) {
            int r = GetMessageW(out m, IntPtr.Zero, 0, 0);
            if (r == 0) { break; }
            if (r == -1) { Log.AppendLine("GetMessage 出错 " + Marshal.GetLastWin32Error()); break; }
            TranslateMessage(ref m);
            DispatchMessageW(ref m);
            bool now = IsWindowVisible(DefView());
            if (now != last) {
                last = now;
                Log.Append("+").Append((int)(DateTime.Now - start).TotalMilliseconds).Append("ms 图标可见性跳变 -> ")
                   .Append(now ? "visible" : "hidden").AppendLine();
            }
        }
        UnhookWindowsHookEx(hook);
        hook = IntPtr.Zero;
        PostQuitMessage(0);
        return "done";
    }
}
'@

$null = [Probe]::Run($Seconds)
$log = Join-Path (Split-Path -Parent $PSScriptRoot) 'hook-probe.log'
[Probe]::Log.ToString() | Set-Content $log -Encoding UTF8
Write-Host "[探针] 非移动类事件与可见性跳变已写到 $log"
[Probe]::Log.ToString()
