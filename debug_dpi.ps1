Add-Type -AssemblyName PresentationFramework,System.Windows.Forms,System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DH {
    [DllImport("user32.dll")]
    public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    }
    public const int ENUM_CURRENT_SETTINGS = -1;
}
"@

$dpiScale = [System.Windows.Forms.SystemInformation]::VirtualScreen.Width / [System.Windows.SystemParameters]::VirtualScreenWidth
"dpiScale = $dpiScale"
""

$screens = [System.Windows.Forms.Screen]::AllScreens
for ($i = 0; $i -lt $screens.Count; $i++) {
    $scr = $screens[$i]
    $dm = New-Object DH+DEVMODE
    $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($dm)
    [DH]::EnumDisplaySettings($scr.DeviceName, [DH]::ENUM_CURRENT_SETTINGS, [ref]$dm) | Out-Null
    $phys = [System.Drawing.Rectangle]::new($dm.dmPositionX, $dm.dmPositionY, $dm.dmPelsWidth, $dm.dmPelsHeight)
    $monitorDpiScale = $phys.Width / $scr.Bounds.Width
    
    "Monitor $($i+1):"
    "  phys.Width = $($phys.Width)"
    "  scr.Bounds.Width = $($scr.Bounds.Width)"
    "  monitorDpiScale = $monitorDpiScale"
    "  wpfWidth (phys/dpiScale) = $($phys.Width / $dpiScale)"
    "  wpfWidth (phys/monitorDpiScale) = $($phys.Width / $monitorDpiScale)"
    "  wpfWidth (scr.Bounds.Width) = $($scr.Bounds.Width)"
    ""
}
