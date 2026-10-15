

```
DesktopIconToggle.exe              后台启动（已有一份在跑就静默退出，不会多开）
DesktopIconToggle.exe --toggle     切换一次（不需要后台实例在场）
DesktopIconToggle.exe --hide / --show
DesktopIconToggle.exe --status     看实例/图标/自启/手势状态
DesktopIconToggle.exe --autostart / --no-autostart
DesktopIconToggle.exe --exit       退出后台实例（图标保持当前状态）
```



## 文件

| 文件 | 作用 |
| --- | --- |
| `Program.cs` | 入口、命令行客户端、消息循环、托盘菜单、手势判定 |
| `Native.cs` | 全部 P/Invoke 声明与结构体（业务代码里不出现 DllImport） |
| `Desktop.cs` | 找 DefView、切换可见性、落点判定、跨进程命中测试、`RemoteBlock` |
| `DesktopGestureHook.cs` | `WH_MOUSE_LL` 钩子 |
| `IpcWindow.cs` | 隐藏顶层窗口（托盘宿主 + 命令行 IPC，0×0 且屏幕外） |
| `TrayIcon.cs` / `Autostart.cs` / `Settings.cs` | 托盘、HKCU Run、HKCU 设置项 |
| `app.manifest` | asInvoker + PerMonitorV2 DPI 声明 |
| `TEST-REPORT.md` | 独立测试人的实测记录（含被测 exe 的 SHA256） |
| `RESUME.md` | 断点快照与下一步 |
