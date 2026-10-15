using System;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;

namespace DeskIcons;

/// <summary>开机自启动：HKCU\...\CurrentVersion\Run 的一个 REG_SZ，不需要管理员权限。</summary>
internal static class Autostart
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "DesktopIconToggle";
    private const uint REG_SZ = 1;
    private const uint RRF_RT_REG_SZ = 0x00000002;
    private const int ERROR_SUCCESS = 0;
    private const int KEY_SET_VALUE = 0x0002;
    private const int KEY_QUERY_VALUE = 0x0001;

    internal static string DesiredCommand
    {
        get
        {
            string path = Environment.ProcessPath ?? "DesktopIconToggle.exe";
            // 带 --boot：只有开机自启这条路径才会去复原上次的图标显示状态。
            // 手动双击 exe 时不该被"复原"打断当前的桌面布局。
            return "\"" + path + "\" --boot";
        }
    }

    /// <summary>返回已登记的启动命令；未登记返回 null。</summary>
    internal static string? Read()
    {
        int size = 0;
        int code = Native.RegGetValueW(Native.HKEY_CURRENT_USER, RunKey, ValueName, RRF_RT_REG_SZ,
            out _, null, ref size);
        if (code != ERROR_SUCCESS || size <= 0) return null;

        var buffer = new byte[size];
        code = Native.RegGetValueW(Native.HKEY_CURRENT_USER, RunKey, ValueName, RRF_RT_REG_SZ,
            out _, buffer, ref size);
        if (code != ERROR_SUCCESS) return null;

        return Encoding.Unicode.GetString(buffer, 0, Math.Max(0, size - 2)).TrimEnd('\0');
    }

    internal static bool IsEnabled() => Read() is not null;

    /// <summary>登记/撤销自启。返回 false 时通过 LastWin32Error 提供原因。</summary>
    internal static bool Set(bool enable)
    {
        int access = enable ? KEY_SET_VALUE : KEY_SET_VALUE | KEY_QUERY_VALUE;
        if (Native.RegOpenKeyExW(Native.HKEY_CURRENT_USER, RunKey, 0, access, out IntPtr key) != ERROR_SUCCESS) return false;
        try
        {
            if (!enable)
            {
                int code = Native.RegDeleteValueW(key, ValueName);
                return code == ERROR_SUCCESS || code == 2 /* ERROR_FILE_NOT_FOUND：本来就没开 */;
            }

            byte[] data = Encoding.Unicode.GetBytes(DesiredCommand + "\0");
            return Native.RegSetValueExW(key, ValueName, 0, REG_SZ, data, data.Length) == ERROR_SUCCESS;
        }
        finally
        {
            Native.RegCloseKey(key);
        }
    }

    /// <summary>
    /// 只有当登记的那个文件已经不存在时才改写路径——否则用户故意留两份 exe（比如一份在 U 盘、
    /// 一份在固态）会被互相覆盖。
    /// </summary>
    /// <summary>从 "\\"C:\path\x.exe\\" --boot" 里取出可执行文件路径。</summary>
    private static string Unquote(string commandLine)
    {
        string t = commandLine.Trim();
        if (t.Length > 1 && t[0] == '"')
        {
            int end = t.IndexOf('"', 1);
            return end > 1 ? t.Substring(1, end - 1) : t.TrimStart('"');
        }
        int space = t.IndexOf(' ');
        return space > 0 ? t.Substring(0, space) : t;
    }

    internal static void SelfHeal()
    {
        string? stored = Read();
        if (stored is null || stored == DesiredCommand) return;

        // 登记的是另一份仍然存在的 exe：那是用户故意的（U 盘 / 双副本），不动它。
        // 但如果是同一个 exe、只是命令行参数落后了（例如缺 --boot），要升级。
        string current = (Environment.ProcessPath ?? string.Empty);
        string storedPath = Unquote(stored);
        if (storedPath.Length > 0 && System.IO.File.Exists(storedPath)
            && !string.Equals(storedPath, current, StringComparison.OrdinalIgnoreCase)) return;

        if (stored != DesiredCommand) Set(true);
    }
}
