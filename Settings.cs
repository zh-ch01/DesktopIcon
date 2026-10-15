using System;

namespace DeskIcons;

/// <summary>
/// 本程序自己的设置，存在 HKCU\Software\DesktopIconToggle（REG_DWORD）。
/// 故意放在当前用户配置根下而不是 Run 键旁边，卸载时删一个键就干净。
/// 用户可以从托盘菜单改回默认，本程序不会在启动时覆盖这些值。
/// </summary>
internal static class Settings
{
    private const string AppKey = @"Software\DesktopIconToggle";
    private const int KEY_WRITE = 0x20006;
    private const uint REG_DWORD = 4;
    private const uint RRF_RT_REG_DWORD = 0x00000010;
    private const int ERROR_SUCCESS = 0;

    /// <summary>
    /// 是否响应"注入"的左键双击（SendInput、自动化脚本、部分远程控制/投屏工具会走这条路径）。
    /// 默认 1 = 响应，这样远程协助和自动化脚本还能用；改成 0 就只有真实鼠标双击会切换。
    /// </summary>
    internal const string RespondToInjectedDoubleClick = nameof(RespondToInjectedDoubleClick);
    internal const int RespondToInjectedDoubleClickDefault = 1;

    /// <summary>
    /// 是否启用"双击桌面空白处切换"这个全局手势。0 = 完全不响应双击，只能用托盘菜单或命令行。
    /// 关掉它就没有任何跨进程命中测试，占用和行为都最干净。
    /// </summary>
    internal const string DesktopDoubleClickGesture = nameof(DesktopDoubleClickGesture);
    internal const int DesktopDoubleClickGestureDefault = 1;

    /// <summary>用户最后一次选择的状态（1=图标显示，0=隐藏），开机时按它复原。</summary>
    internal const string IconsVisibleOnExit = nameof(IconsVisibleOnExit);
    internal const int IconsVisibleOnExitDefault = 1;

    /// <summary>关掉后，开机一律按 explorer 自己的状态来，本程序不动图标。</summary>
    internal const string RestoreStateOnStartup = nameof(RestoreStateOnStartup);
    internal const int RestoreStateOnStartupDefault = 1;

    internal static int Read(string name, int fallback)
    {
        int size = 0;
        int code = Native.RegGetValueW(Native.HKEY_CURRENT_USER, AppKey, name, RRF_RT_REG_DWORD, out _, null, ref size);
        if (code != ERROR_SUCCESS || size < 4) return fallback;

        var buffer = new byte[size];
        code = Native.RegGetValueW(Native.HKEY_CURRENT_USER, AppKey, name, RRF_RT_REG_DWORD, out _, buffer, ref size);
        if (code != ERROR_SUCCESS || size < 4) return fallback;

        return BitConverter.ToInt32(buffer, 0);
    }

    internal static bool Write(string name, int value)
    {
        if (Native.RegCreateKeyExW(Native.HKEY_CURRENT_USER, AppKey, 0, null, 0, KEY_WRITE, IntPtr.Zero,
                out IntPtr key, out _) != ERROR_SUCCESS) return false;
        try
        {
            byte[] data = BitConverter.GetBytes(value);
            return Native.RegSetValueExW(key, name, 0, REG_DWORD, data, data.Length) == ERROR_SUCCESS;
        }
        finally
        {
            Native.RegCloseKey(key);
        }
    }

    internal static bool RestoreDefaults() =>
        Write(RespondToInjectedDoubleClick, RespondToInjectedDoubleClickDefault)
        && Write(DesktopDoubleClickGesture, DesktopDoubleClickGestureDefault)
        && Write(RestoreStateOnStartup, RestoreStateOnStartupDefault);
}
