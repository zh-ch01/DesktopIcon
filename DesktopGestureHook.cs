using System;
using System.Runtime.InteropServices;

namespace DeskIcons;

/// <summary>
/// 全局鼠标低级钩子，只识别一件事：左键双击。
///
/// 关键点（实测出来的）：WH_MOUSE_LL 不会投递 WM_LBUTTONDBLCLK——它只给原始的
/// LBUTTONDOWN/LBUTTONUP（旁路探针实测：真双击只看到 0x201/0x202 交替，没有 0x203），
/// 双击是系统稍后在目标线程里合成的。所以这里自己判：第二次抬起落在
/// GetDoubleClickTime() 时间窗和 SM_C?DOUBLECLK 位移窗内，就算一次双击。
///
/// 回调里只做一次消息号比较、读一次结构、几个整数比较、PostMessage：不发消息给别的进程、
/// 不查窗口树。低级钩子有 LowLevelHooksTimeout（默认 300ms）超时，超时会表现为全系统鼠标发涩，
/// 这是这个文件唯一的设计约束。
/// </summary>
internal sealed class DesktopGestureHook : IDisposable
{
    // LLMHF_INJECTED=0x1，LLMHF_LOWER_IL_INJECTED=0x2：两个位都算"不是真实鼠标"，
    // 只看 0x1 会让低完整性会话里的远控/脚本被当成真实鼠标。
    private const int LLMHF_ANY_INJECTED = 0x00000003;
    private const int SM_CXDOUBLECLK = 36;
    private const int SM_CYDOUBLECLK = 37;

    private readonly IpcWindow _window;
    private readonly Native.LowLevelMouseProc _callback;   // 强引用：被 GC 掉的话原生回调地址直接失效
    private readonly int _doubleClickMs;
    private readonly int _halfDragX;
    private readonly int _halfDragY;
    private IntPtr _handle;

    // 只在钩子回调线程（= 消息循环线程）里读写，不需要加锁。
    private long _lastUpTick;
    private int _lastUpX;
    private int _lastUpY;

    internal DesktopGestureHook(IpcWindow window)
    {
        _window = window;
        _callback = OnMouse;
        // 注册表里被改成 0 时 GetDoubleClickTime 会返回 0，那样永远配不出双击；
        // 取系统默认 500ms / 4x4px 兜底，并且把实际生效值报出去（见 --status）。
        uint measured = Native.GetDoubleClickTime();
        _doubleClickMs = measured == 0 ? 500 : (int)measured;
        int cx = Native.GetSystemMetrics(SM_CXDOUBLECLK);
        int cy = Native.GetSystemMetrics(SM_CYDOUBLECLK);
        if (cx <= 0) cx = 4;
        if (cy <= 0) cy = 4;
        _halfDragX = Math.Max(2, cx / 2);
        _halfDragY = Math.Max(2, cy / 2);
        _handle = Native.SetWindowsHookExW(Native.WH_MOUSE_LL, _callback, Native.GetModuleHandleW(null), 0);
    }

    internal bool Installed => _handle != IntPtr.Zero;

    /// <summary>钩子回调实际收到的左键抬起次数 / 其中配对成双击的次数。</summary>
    internal long UpsSeen => _upsSeen;

    internal long CandidatesSeen => _candidatesSeen;

    private long _candidatesSeen;
    private long _upsSeen;

    private IntPtr OnMouse(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode == Native.HC_ACTION && (uint)wParam.ToInt64() == Native.WM_LBUTTONUP)
        {
            // 只数左键抬起：把移动/滚轮也算进来的话，这个计数几秒就冲过 65536 回绕，失去诊断价值。
            _upsSeen++;
            // 逐字段按偏移读，不用 Marshal.PtrToStructure：后者每次都要在**钩子栈上**分配一个装箱结构体，
            // 而这条回调挂在系统输入链上，预算是 LowLevelHooksTimeout(300ms)，一次偶发的 gen0 就够全系统鼠标发涩。
            // 偏移是实测标定过的：pt.x=0、pt.y=4、flags=12（MSLLHOOKSTRUCT 在 x64 上总长 32）。
            int ptX = Marshal.ReadInt32(lParam, 0);
            int ptY = Marshal.ReadInt32(lParam, 4);
            uint flags = (uint)Marshal.ReadInt32(lParam, 12);
            long tick = unchecked((long)Native.GetTickCount64());
            bool secondClickOfPair = _lastUpTick != 0
                && tick - _lastUpTick <= _doubleClickMs
                && Math.Abs(ptX - _lastUpX) <= _halfDragX
                && Math.Abs(ptY - _lastUpY) <= _halfDragY;

            if (secondClickOfPair)
            {
                _lastUpTick = 0;            // 三连点不再叠加成第二次双击
                _candidatesSeen++;
                bool fromRealMouse = (flags & LLMHF_ANY_INJECTED) == 0;
                // 不吞掉点击：桌面空白处的双击在 explorer 里没有副作用，放行更不容易和系统抢输入。
                var pt = new Native.POINT { X = ptX, Y = ptY };
                _window.Post(Native.WM_APP_GESTURE, IpcWindow.Pack(pt), new IntPtr(fromRealMouse ? 1 : 0));
            }
            else
            {
                _lastUpTick = tick;
                _lastUpX = ptX;
                _lastUpY = ptY;
            }
        }
        return Native.CallNextHookEx(_handle, nCode, wParam, lParam);
    }

    public void Dispose()
    {
        if (_handle == IntPtr.Zero) return;
        Native.UnhookWindowsHookEx(_handle);
        _handle = IntPtr.Zero;
    }
}
