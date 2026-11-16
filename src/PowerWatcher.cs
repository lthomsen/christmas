using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace JuleHygge
{
    // Reports when the display turns off or on (GUID_CONSOLE_DISPLAY_STATE), so the overlay can stop
    // completely while nobody can see it. Uses a hidden window, because Windows delivers power-setting
    // notifications as window messages.
    sealed class PowerWatcher : NativeWindow, IDisposable
    {
        [DllImport("user32.dll", SetLastError = true)]
        static extern IntPtr RegisterPowerSettingNotification(IntPtr hRecipient, ref Guid powerSettingGuid, int flags);
        [DllImport("user32.dll")]
        static extern bool UnregisterPowerSettingNotification(IntPtr handle);

        static Guid GUID_CONSOLE_DISPLAY_STATE = new Guid("6FE69556-704A-47A0-8F24-C28D936FDA47");
        const int WM_POWERBROADCAST = 0x0218, PBT_POWERSETTINGCHANGE = 0x8013, DEVICE_NOTIFY_WINDOW_HANDLE = 0;

        readonly Action<bool> onDisplayChanged;
        IntPtr registration;

        public PowerWatcher(Action<bool> onDisplayChanged)
        {
            this.onDisplayChanged = onDisplayChanged;
            CreateHandle(new CreateParams());
            registration = RegisterPowerSettingNotification(Handle, ref GUID_CONSOLE_DISPLAY_STATE, DEVICE_NOTIFY_WINDOW_HANDLE);
            if (registration == IntPtr.Zero) ErrorLog.Debug("RegisterPowerSettingNotification failed: " + Marshal.GetLastWin32Error());
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_POWERBROADCAST && m.WParam.ToInt32() == PBT_POWERSETTINGCHANGE && m.LParam != IntPtr.Zero)
            {
                // POWERBROADCAST_SETTING: GUID (16 bytes), DataLength (4), Data. Display state: 0 = off, 1 = on, 2 = dimmed.
                var guid = (Guid)Marshal.PtrToStructure(m.LParam, typeof(Guid));
                if (guid == GUID_CONSOLE_DISPLAY_STATE)
                {
                    int state = Marshal.ReadInt32(m.LParam, 20);
                    ErrorLog.Debug("display state " + state);
                    try { onDisplayChanged(state != 0); }
                    catch (Exception ex) { ErrorLog.Write(ex); }
                }
            }
            base.WndProc(ref m);
        }

        public void Dispose()
        {
            if (registration != IntPtr.Zero) { UnregisterPowerSettingNotification(registration); registration = IntPtr.Zero; }
            DestroyHandle();
        }
    }
}
