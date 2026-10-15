Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
public static class E {
    [DllImport("shell32.dll", CharSet=CharSet.Unicode)]
    static extern uint ExtractIconExW(string f, int idx, IntPtr[] big, IntPtr[] small, uint n);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);
    public static string Probe(string path) {
        IntPtr[] big = new IntPtr[4]; IntPtr[] small = new IntPtr[4];
        uint count = ExtractIconExW(path, -1, big, small, 0);
        IntPtr[] b2 = new IntPtr[1]; IntPtr[] s2 = new IntPtr[1];
        uint r0 = ExtractIconExW(path, 0, b2, s2, 1);
        string s = "文件内图标数=" + count + "  index0 返回=" + r0 + " big=" + b2[0] + " small=" + s2[0];
        if (b2[0] != IntPtr.Zero) DestroyIcon(b2[0]);
        if (s2[0] != IntPtr.Zero) DestroyIcon(s2[0]);
        return s;
    }
}
'@
[E]::Probe("$PWD\dist\DesktopIconToggle.exe")
