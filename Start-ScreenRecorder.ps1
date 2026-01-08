<#PSScriptInfo
.VERSION 0.2.0
.GUID d47eab76-de84-454d-aead-8b61ed3335eb
.AUTHOR Yoshifumi Tsuda
.COPYRIGHT Copyright (c) 2025 Yoshifumi Tsuda. MIT License.
.TAGS Screen Capture Recording Debug Screenshot Clock
.LICENSEURI https://github.com/yotsuda/ScreenRecorder/blob/master/LICENSE
.PROJECTURI https://github.com/yotsuda/ScreenRecorder
.DESCRIPTION Screen capture tool with clock overlay for debugging and log correlation.
#>

param(
    [switch]$Background,
    [int]$FPS = 2,
    [double]$Scale = 0.75,
    [int]$Quality = 75,
    [switch]$SaveMasked
)

function Start-ScreenRecorder {
    <#
    .SYNOPSIS
        Starts a screen recorder with a clock overlay for debugging and log correlation.
    .DESCRIPTION
        Captures screenshots at regular intervals while displaying a large clock overlay.
        Designed for correlating screen captures with log timestamps during bug reproduction.
        Requires no external dependencies - uses only PowerShell and .NET.
        Can be run directly without module installation.
    .PARAMETER Background
        Runs the recorder in a hidden background process.
    .PARAMETER FPS
        Frames per second for capture. Default is 2.
    .PARAMETER Scale
        Scale factor for captured images (0.1 to 1.0). Default is 1.0.
    .PARAMETER SaveMasked
        Saves masked images (with clock area blacked out) for debugging.
    .EXAMPLE
        Start-ScreenRecorder
        Starts the recorder in background mode.
    .EXAMPLE
        Start-ScreenRecorder -FPS 10 -Scale 0.75
        Starts with higher frame rate and larger output images.
    #>
    [CmdletBinding()]
    param(
        [Parameter(DontShow)]
        [switch]$Background,
        [int]$FPS = 2,
        [double]$Scale = 0.75,
        [int]$Quality = 75,
        [switch]$SaveMasked
    )

    if (-not $Background) {
        $exe = (Get-Process -Id $PID).Path
        $scriptPath = $MyInvocation.MyCommand.ScriptBlock.File
        if (-not $scriptPath) { $scriptPath = $PSCommandPath }
        $procArgs = "-NoProfile -WindowStyle Hidden -File `"$scriptPath`" -Background -FPS $FPS -Scale $Scale -Quality $Quality"
        if ($SaveMasked) { $procArgs += " -SaveMasked" }
        Start-Process $exe -ArgumentList $procArgs -WindowStyle Hidden
        return
    }
    Add-Type -AssemblyName PresentationFramework,System.Windows.Forms,System.Drawing
    $drawingAsm = [System.Drawing.Bitmap].Assembly.Location
    $primAsm = [System.Drawing.Rectangle].Assembly.Location
    $winCoreAsm = [System.Drawing.Bitmap].Assembly.GetReferencedAssemblies() |
        Where-Object { $_.Name -eq 'System.Private.Windows.Core' } |
        ForEach-Object { [System.Reflection.Assembly]::Load($_).Location }
    Add-Type -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

public class DisplayHelper {
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

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hWnd, int dwAttribute, out RECT pvAttribute, int cbAttribute);

    public const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;

    // Get physical window rect using DWM (always returns physical pixels)
    public static RECT GetPhysicalWindowRect(IntPtr hWnd) {
        RECT rect;
        DwmGetWindowAttribute(hWnd, DWMWA_EXTENDED_FRAME_BOUNDS, out rect, Marshal.SizeOf(typeof(RECT)));
        return rect;
    }

    // Fast FNV-1a hash for bitmap comparison using unsafe pointer access
    public static unsafe long ComputeImageHash(Bitmap bmp, int exL, int exT, int exR, int exB) {
        var data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height),
            ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            long hash = unchecked((long)0xcbf29ce484222325);
            int stride = data.Stride;
            int width = bmp.Width;
            int height = bmp.Height;
            byte* scan0 = (byte*)data.Scan0;
            for (int y = 0; y < height; y++) {
                int* row = (int*)(scan0 + y * stride);
                if (y >= exT && y < exB) {
                    for (int x = 0; x < exL; x++) { hash ^= row[x]; hash *= 0x100000001b3L; }
                    for (int x = exR; x < width; x++) { hash ^= row[x]; hash *= 0x100000001b3L; }
                } else {
                    for (int x = 0; x < width; x++) { hash ^= row[x]; hash *= 0x100000001b3L; }
                }
            }
            return hash;
        } finally {
            bmp.UnlockBits(data);
        }
    }
}

public class BackgroundRecorder {
    private Task _task;
    private volatile bool _running;
    private int _intervalMs;
    private string _outDir;
    private bool _saveMasked;
    private double _scale;
    private IntPtr _windowHandle;
    private ImageCodecInfo _jpegCodec;
    private EncoderParameters _encoderParams;
    private Bitmap _captureBmp, _thumbBmp;
    private Graphics _captureG, _thumbG;
    private Rectangle _bounds;
    private int _thumbW, _thumbH;
    private long _prevHash;
    private int _saved;
    private string _lastError;
    // Multi-monitor support
    private Rectangle[] _monitorBounds;
    private Bitmap[] _monitorBmps;
    private Graphics[] _monitorGs;

    public int Saved => _saved;
    public string LastError => _lastError;

    public void Start(Rectangle bounds, Rectangle[] monitorBounds, int thumbW, int thumbH, int fps, int quality, string outDir, bool saveMasked, double scale, IntPtr windowHandle) {
        _bounds = bounds;
        _monitorBounds = monitorBounds;
        _thumbW = thumbW;
        _thumbH = thumbH;
        _intervalMs = 1000 / fps;
        _outDir = outDir;
        _saveMasked = saveMasked;
        _scale = scale;
        _windowHandle = windowHandle;
        _prevHash = 0;
        _saved = 0;

        _captureBmp = new Bitmap(bounds.Width, bounds.Height);
        _captureG = Graphics.FromImage(_captureBmp);
        _thumbBmp = new Bitmap(thumbW, thumbH);
        _thumbG = Graphics.FromImage(_thumbBmp);

        // Allocate per-monitor bitmaps for multi-monitor capture
        if (_monitorBounds != null && _monitorBounds.Length > 1) {
            _monitorBmps = new Bitmap[_monitorBounds.Length];
            _monitorGs = new Graphics[_monitorBounds.Length];
            for (int i = 0; i < _monitorBounds.Length; i++) {
                _monitorBmps[i] = new Bitmap(_monitorBounds[i].Width, _monitorBounds[i].Height);
                _monitorGs[i] = Graphics.FromImage(_monitorBmps[i]);
            }
        }

        _jpegCodec = null;
        foreach (var codec in ImageCodecInfo.GetImageEncoders()) {
            if (codec.MimeType == "image/jpeg") { _jpegCodec = codec; break; }
        }
        _encoderParams = new EncoderParameters(1);
        _encoderParams.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)quality);

        _running = true;
        _task = Task.Run((Action)RecordLoop);
    }

    public void Stop() {
        _running = false;
        if (_task != null) { _task.Wait(2000); _task = null; }
        // Dispose per-monitor resources
        if (_monitorGs != null) {
            for (int i = 0; i < _monitorGs.Length; i++) {
                if (_monitorGs[i] != null) { _monitorGs[i].Dispose(); _monitorGs[i] = null; }
            }
            _monitorGs = null;
        }
        if (_monitorBmps != null) {
            for (int i = 0; i < _monitorBmps.Length; i++) {
                if (_monitorBmps[i] != null) { _monitorBmps[i].Dispose(); _monitorBmps[i] = null; }
            }
            _monitorBmps = null;
        }
        if (_thumbG != null) { _thumbG.Dispose(); _thumbG = null; }
        if (_thumbBmp != null) { _thumbBmp.Dispose(); _thumbBmp = null; }
        if (_captureG != null) { _captureG.Dispose(); _captureG = null; }
        if (_captureBmp != null) { _captureBmp.Dispose(); _captureBmp = null; }
    }

    private void RecordLoop() {
        DisplayHelper.RECT _prevRect = new DisplayHelper.RECT();
        bool firstFrame = true;
        
        while (_running) {
            var start = DateTime.Now;
            try {
                // Get exclude rect BEFORE capture (more accurate timing)
                var rect = DisplayHelper.GetPhysicalWindowRect(_windowHandle);
                int exL = (int)((rect.Left - _bounds.Left) * _scale);
                int exT = (int)((rect.Top - _bounds.Top) * _scale);
                int exR = (int)((rect.Right - _bounds.Left) * _scale);
                int exB = (int)((rect.Bottom - _bounds.Top) * _scale);
                
                // Skip if window is moving (rect changed since last frame)
                bool isMoving = !firstFrame && (rect.Left != _prevRect.Left || rect.Top != _prevRect.Top || 
                                                 rect.Right != _prevRect.Right || rect.Bottom != _prevRect.Bottom);
                _prevRect = rect;
                firstFrame = false;
                
                if (isMoving) {
                    // Skip this frame - window is moving
                    var skipElapsed = (int)(DateTime.Now - start).TotalMilliseconds;
                    int skipSleep = _intervalMs - skipElapsed;
                    if (skipSleep > 0) Task.Delay(skipSleep).Wait();
                    continue;
                }
                
                // Capture screen
                if (_monitorBounds == null || _monitorBounds.Length == 1) {
                    _captureG.CopyFromScreen(_bounds.Location, Point.Empty, _bounds.Size);
                } else {
                    _captureG.Clear(Color.Black);
                    for (int i = 0; i < _monitorBounds.Length; i++) {
                        var b = _monitorBounds[i];
                        _monitorGs[i].CopyFromScreen(b.Location, Point.Empty, b.Size);
                        int relX = b.Left - _bounds.Left;
                        int relY = b.Top - _bounds.Top;
                        _captureG.DrawImage(_monitorBmps[i], relX, relY);
                    }
                }
                
                _thumbG.DrawImage(_captureBmp, 0, 0, _thumbW, _thumbH);

                long hash = DisplayHelper.ComputeImageHash(_thumbBmp, exL, exT, exR, exB);
                if (hash != _prevHash) {
                    string filename = DateTime.Now.ToString("yyyyMMdd_HHmmss_ff");
                    _thumbBmp.Save(System.IO.Path.Combine(_outDir, filename + ".jpg"), _jpegCodec, _encoderParams);
                    if (_saveMasked) {
                        using (var maskedBmp = new Bitmap(_thumbBmp))
                        using (var g = Graphics.FromImage(maskedBmp)) {
                            g.FillRectangle(Brushes.Black, exL, exT, exR - exL, exB - exT);
                            maskedBmp.Save(System.IO.Path.Combine(_outDir, filename + "_masked.jpg"), _jpegCodec, _encoderParams);
                        }
                    }
                    _saved++;
                    _prevHash = hash;
                }
            } catch (Exception ex) { _lastError = ex.ToString(); }

            var elapsed = (int)(DateTime.Now - start).TotalMilliseconds;
            int sleep = _intervalMs - elapsed;
            if (sleep > 0) Task.Delay(sleep).Wait();
        }
    }
}
"@ -ReferencedAssemblies (@($drawingAsm,$primAsm) + @($winCoreAsm | Where-Object { $_ })) -CompilerOptions '/unsafe'
    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    Topmost="True" AllowsTransparency="True" WindowStyle="None" Background="Transparent"
    SizeToContent="WidthAndHeight" Left="20" Top="20">
    <Window.ContextMenu>
        <ContextMenu>
            <MenuItem Name="MenuExit">
                <MenuItem.Header>
                    <TextBlock>E<Underline>x</Underline>it</TextBlock>
                </MenuItem.Header>
            </MenuItem>
        </ContextMenu>
    </Window.ContextMenu>
    <Border Name="MainBorder" Background="#AA000000" CornerRadius="8" Padding="10,6">
        <StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                <TextBlock Name="Clock" Foreground="White" FontSize="32" FontFamily="Consolas" VerticalAlignment="Center"/>
                <Button Name="BtnToggle" Content="● REC" Width="45" Height="22" FontSize="11" Margin="8,0,0,0" Background="#AA444444" Foreground="White" BorderThickness="0" Padding="0" VerticalAlignment="Center"/>
                <TextBlock Name="MonitorLabel" Foreground="White" FontSize="10" Margin="4,0,0,0" VerticalAlignment="Center" Cursor="Hand" Visibility="Collapsed"/>
            </StackPanel>
        </StackPanel>
    </Border>
</Window>
"@
    $window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))
    $clock = $window.FindName("Clock")
    $btnToggle = $window.FindName("BtnToggle")
    $mainBorder = $window.FindName("MainBorder")
    $script:monitorLabel = $window.FindName("MonitorLabel")
    $menuExit = $window.FindName("MenuExit")
    $menuExit.Add_Click({ $window.Close() })
    $menuExit.Parent.Add_KeyDown({ param($s,$e) if ($e.Key -eq 'X') { $window.Close() } })
    $window.Add_MouseLeftButtonDown({ $window.DragMove() })
    $window.Add_MouseWheel({ param($s,$e)
        $size = $clock.FontSize + ($e.Delta / 30)
        if ($size -ge 12 -and $size -le 200) {
            $clock.FontSize = $size
            $btnToggle.FontSize = $size * 0.35
            $btnToggle.Width = $size * 1.4
            $btnToggle.Height = $size * 0.7
            $btnToggle.Margin = [System.Windows.Thickness]::new($size * 0.25, 0, 0, 0)
            $script:monitorLabel.FontSize = $size * 0.3
            $script:monitorLabel.Margin = [System.Windows.Thickness]::new($size * 0.25, 0, 0, 0)
            $mainBorder.Padding = [System.Windows.Thickness]::new($size * 0.3, $size * 0.2, $size * 0.3, $size * 0.2)
        }
    })

    # Monitor setup
    $script:screens = [System.Windows.Forms.Screen]::AllScreens
    $script:targetScreen = [System.Windows.Forms.Screen]::PrimaryScreen
    $script:dpiScale = [System.Windows.Forms.SystemInformation]::VirtualScreen.Width / [System.Windows.SystemParameters]::VirtualScreenWidth

    function Get-PhysicalBounds($screen) {
        $dm = New-Object DisplayHelper+DEVMODE
        $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($dm)
        [DisplayHelper]::EnumDisplaySettings($screen.DeviceName, [DisplayHelper]::ENUM_CURRENT_SETTINGS, [ref]$dm) | Out-Null
        [System.Drawing.Rectangle]::new($dm.dmPositionX, $dm.dmPositionY, $dm.dmPelsWidth, $dm.dmPelsHeight)
    }
    # Selected monitors (array of indices)
    $script:selectedMonitors = @([Array]::IndexOf($script:screens, [System.Windows.Forms.Screen]::PrimaryScreen))

    function Update-MonitorLabel {
        if ($script:selectedMonitors.Count -eq 0) {
            $script:monitorLabel.Text = "None"
        } elseif ($script:selectedMonitors.Count -eq 1) {
            $idx = $script:selectedMonitors[0]
            $script:monitorLabel.Text = if ($script:screens[$idx].Primary) { "Mon $($idx+1)*" } else { "Mon $($idx+1)" }
        } else {
            $nums = ($script:selectedMonitors | Sort-Object | ForEach-Object { $_ + 1 }) -join '+'
            $script:monitorLabel.Text = "Mon $nums"
        }
    }

    function Update-CaptureRegion {
        if ($script:selectedMonitors.Count -eq 0) { return }
        # Calculate bounding rectangle of all selected monitors
        $minX = [int]::MaxValue; $minY = [int]::MaxValue
        $maxX = [int]::MinValue; $maxY = [int]::MinValue
        foreach ($idx in $script:selectedMonitors) {
            $b = Get-PhysicalBounds $script:screens[$idx]
            if ($b.Left -lt $minX) { $minX = $b.Left }
            if ($b.Top -lt $minY) { $minY = $b.Top }
            if ($b.Right -gt $maxX) { $maxX = $b.Right }
            if ($b.Bottom -gt $maxY) { $maxY = $b.Bottom }
        }
        $script:bounds = [System.Drawing.Rectangle]::new($minX, $minY, $maxX - $minX, $maxY - $minY)
        $script:w = [int]($script:bounds.Width * $Scale)
        $script:h = [int]($script:bounds.Height * $Scale)
    }

    function Show-MonitorOverlay {
        $overlays = @()
        for ($i = 0; $i -lt $script:screens.Count; $i++) {
            $scr = $script:screens[$i]
            $isSelected = $script:selectedMonitors -contains $i
            $wpfLeft = $scr.Bounds.Left / $script:dpiScale
            $wpfTop = $scr.Bounds.Top / $script:dpiScale
            $wpfWidth = $scr.Bounds.Width / $script:dpiScale
            $wpfHeight = $scr.Bounds.Height / $script:dpiScale
            [xml]$overlayXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    WindowStyle="None" AllowsTransparency="True" Topmost="True"
    Background="$( if ($isSelected) { '#88004488' } else { '#88000000' } )"
    Left="$wpfLeft" Top="$wpfTop" Width="$wpfWidth" Height="$wpfHeight">
    <Grid>
        <TextBlock Text="$($i+1)" FontSize="300" FontWeight="Bold"
            Foreground="$( if ($isSelected) { '#AAFFFFFF' } else { '#44FFFFFF' } )"
            HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Grid>
</Window>
"@
            $overlay = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($overlayXaml))
            $overlay.Add_MouseLeftButtonDown({ param($s,$e) $s.Close() })
            $overlay.Show()
            $overlays += $overlay
        }
        # Auto close after 1.5 seconds
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(1500)
        $timer.Add_Tick({
            $timer.Stop()
            foreach ($o in $overlays) { if ($o.IsVisible) { $o.Close() } }
        }.GetNewClosure())
        $timer.Start()
    }

    if ($script:screens.Count -gt 1) {
        $script:monitorLabel.Visibility = "Visible"
        Update-MonitorLabel

        # Create context menu with checkboxes
        $script:monitorMenu = [System.Windows.Controls.ContextMenu]::new()
        $script:monitorMenu.StaysOpen = $true
        for ($i = 0; $i -lt $script:screens.Count; $i++) {
            $menuItem = [System.Windows.Controls.MenuItem]::new()
            $menuItem.Header = if ($script:screens[$i].Primary) { "Mon $($i+1)*" } else { "Mon $($i+1)" }
            $menuItem.IsCheckable = $true
            $menuItem.IsChecked = $script:selectedMonitors -contains $i
            $menuItem.Tag = $i
            $menuItem.StaysOpenOnClick = $true
            $menuItem.Add_Click({
                param($sender, $e)
                $idx = $sender.Tag
                if ($sender.IsChecked) {
                    if ($script:selectedMonitors -notcontains $idx) {
                        $script:selectedMonitors += $idx
                    }
                } else {
                    # Prevent unchecking the last one
                    if ($script:selectedMonitors.Count -le 1) {
                        $sender.IsChecked = $true
                        return
                    }
                    $script:selectedMonitors = @($script:selectedMonitors | Where-Object { $_ -ne $idx })
                }
                Update-MonitorLabel
                Update-CaptureRegion
                Show-MonitorOverlay
            })
            $script:monitorMenu.Items.Add($menuItem) | Out-Null
        }


        $script:monitorLabel.ContextMenu = $script:monitorMenu
        $script:monitorLabel.Add_MouseLeftButtonDown({
            $script:monitorMenu.PlacementTarget = $script:monitorLabel
            $script:monitorMenu.IsOpen = $true
        })
    }

    $script:recording = $false
    $script:outDir = $null
    $script:saved = 0
    Update-CaptureRegion

    # Background recorder instance
    $script:recorder = [BackgroundRecorder]::new()

    # Get window handle for physical coordinate calculation
    $windowHelper = [System.Windows.Interop.WindowInteropHelper]::new($window)

    $btnToggle.Add_Click({
        if (-not $script:recording) {
            # Check if current directory is a system folder
            $blocked = @($env:SystemRoot, "$env:SystemRoot\System32", $env:ProgramFiles, ${env:ProgramFiles(x86)})
            if ((Get-Location).Path -in $blocked) {
                [System.Windows.MessageBox]::Show("Cannot record in system folder. Please change to a working directory.", "Warning", "OK", "Warning")
                return
            }
            # Start recording
            $script:outDir = ".\ScreenCaptures\$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            New-Item -ItemType Directory -Path $script:outDir -Force | Out-Null
            # Build monitor bounds array
            $monitorBoundsArray = @()
            foreach ($idx in $script:selectedMonitors) {
                $monitorBoundsArray += Get-PhysicalBounds $script:screens[$idx]
            }
            $script:recorder.Start($script:bounds, [System.Drawing.Rectangle[]]$monitorBoundsArray, $script:w, $script:h, $FPS, $Quality, (Resolve-Path $script:outDir).Path, $SaveMasked, $Scale, $windowHelper.Handle)
            $script:recording = $true
            $btnToggle.Content = "■ STOP"
            $btnToggle.Foreground = [System.Windows.Media.Brushes]::Red
            $script:monitorLabel.IsHitTestVisible = $false; $script:monitorLabel.Opacity = 0.5
        } else {
            # Stop recording
            $script:recorder.Stop()
            $script:saved = $script:recorder.Saved
            $script:recording = $false
            $script:monitorLabel.IsHitTestVisible = $true; $script:monitorLabel.Opacity = 1.0
            $btnToggle.Content = "● REC"
            $btnToggle.Foreground = [System.Windows.Media.Brushes]::White
            Start-Process explorer $script:outDir
        }
    })


    $clockTimer = New-Object System.Windows.Threading.DispatcherTimer
    $clockTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $clockTimer.Add_Tick({ $clock.Text = (Get-Date).ToString("HH:mm:ss.f") })
    $clockTimer.Start()
    $window.Add_Closed({ $clockTimer.Stop(); if ($script:recording) { $script:recorder.Stop() } })
    $window.ShowDialog()
}

# Run only when invoked directly (not dot-sourced or imported as module)
if ($MyInvocation.InvocationName -notin '.', '') {
    Start-ScreenRecorder @PSBoundParameters
}
