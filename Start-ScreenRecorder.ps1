<#PSScriptInfo
.VERSION 0.9.0
.GUID d47eab76-de84-454d-aead-8b61ed3335eb
.AUTHOR Yoshifumi Tsuda
.COPYRIGHT Copyright (c) 2025-2026 Yoshifumi Tsuda. MIT License.
.TAGS Screen Capture Recording Debug Screenshot Clock
.LICENSEURI https://github.com/yotsuda/ScreenRecorder/blob/master/LICENSE
.PROJECTURI https://github.com/yotsuda/ScreenRecorder
.DESCRIPTION Screen capture tool with clock overlay for debugging and log correlation.
#>

param(
    [Parameter(DontShow)]
    [switch]$Background,
    [ValidateRange(1, 60)]
    [int]$FPS = 2,
    [ValidateRange(0.1, 1.0)]
    [double]$Scale = 0.75,
    [ValidateRange(1, 100)]
    [int]$Quality = 75,
    [switch]$SaveMasked,
    [Parameter(DontShow)]
    [string]$ReadyFile,
    [ArgumentCompleter({ '00:05:00' })]
    [TimeSpan]$RecordFor
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
        Scale factor for captured images (0.1 to 1.0). Default is 0.75.
    .PARAMETER Quality
        JPEG quality for captured images (1-100). Default is 75.
    .PARAMETER SaveMasked
        Saves masked images (with clock area blacked out) for debugging.
    .PARAMETER RecordFor
        Starts recording immediately and stops after the specified duration.
    .EXAMPLE
        Start-ScreenRecorder
        Starts the recorder in background mode.
    .EXAMPLE
        Start-ScreenRecorder -FPS 10 -Scale 0.75
        Starts with higher frame rate and larger output images.
    .EXAMPLE
        Start-ScreenRecorder -RecordFor 0:10:00
        Starts recording immediately and stops after 10 minutes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(DontShow)]
        [switch]$Background,
        [ValidateRange(1, 60)]
        [int]$FPS = 2,
        [ValidateRange(0.1, 1.0)]
        [double]$Scale = 0.75,
        [ValidateRange(1, 100)]
        [int]$Quality = 75,
        [switch]$SaveMasked,
        [Parameter(DontShow)]
        [string]$ReadyFile,
        [ArgumentCompleter({ '00:05:00' })]
        [TimeSpan]$RecordFor
    )

    if (-not $Background) {
        Write-Host 'Starting ScreenRecorder... ' -NoNewline
        $readyFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "sr_ready_$PID.tmp")
        $exe = (Get-Process -Id $PID).Path
        $scriptPath = $MyInvocation.MyCommand.ScriptBlock.File
        if (-not $scriptPath) { $scriptPath = $PSCommandPath }
        $procArgs = "-NoProfile -WindowStyle Hidden -File `"$scriptPath`" -Background -FPS $FPS -Scale $Scale -Quality $Quality -ReadyFile `"$readyFile`""
        if ($SaveMasked) { $procArgs += " -SaveMasked" }
        if ($RecordFor -gt [TimeSpan]::Zero) { $procArgs += " -RecordFor $($RecordFor.ToString())" }
        Start-Process $exe -ArgumentList $procArgs -WindowStyle Hidden
        # Wait for background to be ready with spinner
        $spinner = '|', '/', '-', '\'
        $i = 0
        $timeout = [DateTime]::Now.AddSeconds(30)
        [Console]::CursorVisible = $false
        while (-not (Test-Path $readyFile) -and [DateTime]::Now -lt $timeout) {
            Write-Host "`b$($spinner[$i++ % 4])" -NoNewline
            Start-Sleep -Milliseconds 100
        }
        [Console]::CursorVisible = $true
        Remove-Item $readyFile -ErrorAction SilentlyContinue
        Write-Host "`b Ready!"
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

    // Fast FNV-1a hash for bitmap comparison
    public static long ComputeImageHash(Bitmap bmp, int exL, int exT, int exR, int exB) {
        var data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height),
            ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            long hash = unchecked((long)0xcbf29ce484222325);
            int stride = data.Stride;
            int width = bmp.Width;
            int height = bmp.Height;
            IntPtr scan0 = data.Scan0;
            for (int y = 0; y < height; y++) {
                IntPtr row = IntPtr.Add(scan0, y * stride);
                if (y >= exT && y < exB) {
                    for (int x = 0; x < exL; x++) { hash ^= Marshal.ReadInt32(row, x * 4); hash *= 0x100000001b3L; }
                    for (int x = exR; x < width; x++) { hash ^= Marshal.ReadInt32(row, x * 4); hash *= 0x100000001b3L; }
                } else {
                    for (int x = 0; x < width; x++) { hash ^= Marshal.ReadInt32(row, x * 4); hash *= 0x100000001b3L; }
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
    private int _quality;
    private volatile bool _showOverlay;
    // Multi-monitor support
    private Rectangle[] _monitorBounds;
    private Bitmap[] _monitorBmps;
    private Graphics[] _monitorGs;

    public int Saved { get { return _saved; } }
    public string LastError { get { return _lastError; } }
    public void MarkSettingsChanged(int quality) {
        _quality = quality;
        _encoderParams.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)quality);
        _showOverlay = true;
    }

    public bool Start(Rectangle bounds, Rectangle[] monitorBounds, int thumbW, int thumbH, int fps, int quality, string outDir, bool saveMasked, double scale, IntPtr windowHandle) {
        // Validate parameters
        if (bounds.Width <= 0 || bounds.Height <= 0 || thumbW <= 0 || thumbH <= 0) {
            _lastError = "Invalid dimensions: bounds=" + bounds.Width + "x" + bounds.Height + ", thumb=" + thumbW + "x" + thumbH;
            return false;
        }

        // Cleanup any previous resources
        Stop();

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
        _quality = quality;

        try {
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
        } catch (Exception ex) {
            _lastError = "Bitmap init failed: " + ex.Message;
            Stop();
            return false;
        }

        _jpegCodec = null;
        foreach (var codec in ImageCodecInfo.GetImageEncoders()) {
            if (codec.MimeType == "image/jpeg") { _jpegCodec = codec; break; }
        }
        _encoderParams = new EncoderParameters(1);
        _encoderParams.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)quality);

        _running = true;
        _task = Task.Run(RecordLoop);
        return true;
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
                if (hash != _prevHash || _showOverlay) {
                    string filename = DateTime.Now.ToString("yyyyMMdd_HHmmss_ff");
                    if (_saved == 0 || _showOverlay) {
                        _showOverlay = false;
                        using (var path = new System.Drawing.Drawing2D.GraphicsPath())
                        using (var fontFamily = new FontFamily("Consolas"))
                        {
                            _thumbG.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                            int fontSize = Math.Max(16, _thumbH / 25);
                            float lineH = fontSize * 1.3f;
                            string qname = _quality == 25 ? "Low" : _quality == 50 ? "Medium" : _quality == 75 ? "High" : _quality == 100 ? "Best" : _quality.ToString();
                            path.AddString("Quality: " + qname, fontFamily, (int)FontStyle.Regular, fontSize, new PointF(0, 0), StringFormat.GenericDefault);
                            path.AddString("Scale: " + (int)(_scale * 100) + "%", fontFamily, (int)FontStyle.Regular, fontSize, new PointF(0, lineH), StringFormat.GenericDefault);
                            var bounds = path.GetBounds();
                            int pad = fontSize * 2 / 3;
                            // Find corner farthest from clock window
                            float clockCX = (exL + exR) / 2f, clockCY = (exT + exB) / 2f;
                            float[][] corners = { new[]{0f,0f}, new[]{1f,0f}, new[]{0f,1f}, new[]{1f,1f} };
                            int best = 0; float maxDist = 0;
                            for (int i = 0; i < 4; i++) {
                                float cx = corners[i][0] * _thumbW, cy = corners[i][1] * _thumbH;
                                float dx = cx - clockCX, dy = cy - clockCY;
                                if (dx*dx + dy*dy > maxDist) { maxDist = dx*dx + dy*dy; best = i; }
                            }
                            float x = (corners[best][0] == 0) ? pad : _thumbW - bounds.Width - pad * 3;
                            float y = (corners[best][1] == 0) ? pad : _thumbH - bounds.Height - pad * 3;
                            var matrix = new System.Drawing.Drawing2D.Matrix();
                            matrix.Translate(x - bounds.X + pad, y - bounds.Y + pad);
                            path.Transform(matrix);
                            var finalBounds = path.GetBounds();
                            using (var bgBrush = new SolidBrush(Color.FromArgb(180, 0, 0, 0)))
                            using (var bgPath = new System.Drawing.Drawing2D.GraphicsPath()) {
                                float bx = finalBounds.X - pad, by = finalBounds.Y - pad, bw = finalBounds.Width + pad * 2, bh = finalBounds.Height + pad * 2, r = fontSize / 2f;
                                bgPath.AddArc(bx, by, r * 2, r * 2, 180, 90); bgPath.AddArc(bx + bw - r * 2, by, r * 2, r * 2, 270, 90);
                                bgPath.AddArc(bx + bw - r * 2, by + bh - r * 2, r * 2, r * 2, 0, 90); bgPath.AddArc(bx, by + bh - r * 2, r * 2, r * 2, 90, 90);
                                bgPath.CloseFigure(); _thumbG.FillPath(bgBrush, bgPath);
                            }

                            _thumbG.FillPath(Brushes.White, path);
                        }
                    }
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
"@ -ReferencedAssemblies (@($drawingAsm,$primAsm) + @($winCoreAsm | Where-Object { $_ }))
    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    Topmost="True" AllowsTransparency="True" WindowStyle="None" Background="#01000000"
    SizeToContent="WidthAndHeight" ResizeMode="NoResize" Left="20" Top="20">
    <Window.ContextMenu>
        <ContextMenu>
            <MenuItem Name="MenuInvisible" IsCheckable="True">
                <MenuItem.Header>
                    <TextBlock><Underline>A</Underline>uto-hide</TextBlock>
                </MenuItem.Header>
            </MenuItem>
            <MenuItem Name="MenuQuality" Header="Quality">
                <MenuItem Name="MenuQ25" Header="Low (25)" IsCheckable="True"/>
                <MenuItem Name="MenuQ50" Header="Medium (50)" IsCheckable="True"/>
                <MenuItem Name="MenuQ75" Header="High (75)" IsCheckable="True" IsChecked="True"/>
                <MenuItem Name="MenuQ100" Header="Best (100)" IsCheckable="True"/>
            </MenuItem>
            <MenuItem Name="MenuScale" Header="Scale">
                <MenuItem Name="MenuS50" Header="50%" IsCheckable="True"/>
                <MenuItem Name="MenuS75" Header="75%" IsCheckable="True" IsChecked="True"/>
                <MenuItem Name="MenuS100" Header="100%" IsCheckable="True"/>
            </MenuItem>
            <MenuItem Name="MenuFPS" Header="FPS">
                <MenuItem Name="MenuF1" Header="1" IsCheckable="True"/>
                <MenuItem Name="MenuF2" Header="2" IsCheckable="True" IsChecked="True"/>
                <MenuItem Name="MenuF5" Header="5" IsCheckable="True"/>
                <MenuItem Name="MenuF10" Header="10" IsCheckable="True"/>
            </MenuItem>
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
                <StackPanel Margin="8,0,0,0" VerticalAlignment="Center">
                    <TextBlock Name="RecSpacer" Foreground="#AAAAAA" FontSize="11" Height="14" TextAlignment="Right"/>
                    <Button Name="BtnToggle" Content="● REC" Width="45" Height="22" FontSize="11" Background="#AA444444" Foreground="White" BorderThickness="0" Padding="0"/>
                    <TextBlock Name="RecCounter" Text="0" Foreground="#FF6666" FontSize="11" Height="14" TextAlignment="Right" Visibility="Hidden"/>
                </StackPanel>
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
    $recCounter = $window.FindName("RecCounter")
    $recSpacer = $window.FindName("RecSpacer")
    $script:monitorLabel = $window.FindName("MonitorLabel")
    $menuExit = $window.FindName("MenuExit")
    $menuInvisible = $window.FindName("MenuInvisible")
    $script:quality = $Quality
    $script:qualityMenus = @{
        25 = $window.FindName("MenuQ25")
        50 = $window.FindName("MenuQ50")
        75 = $window.FindName("MenuQ75")
        100 = $window.FindName("MenuQ100")
    }
    foreach ($q in $script:qualityMenus.Keys) {
        $menu = $script:qualityMenus[$q]
        $menu.Tag = $q
        $menu.IsChecked = ($q -eq $Quality)
        $menu.Add_Click({
            param($s,$e)
            $script:quality = $s.Tag
            foreach ($m in $script:qualityMenus.Values) { $m.IsChecked = ($m -eq $s) }
            if ($script:recording) { $script:recorder.MarkSettingsChanged($script:quality) }
        })
    }
    $script:scaleValue = $Scale
    $script:scaleMenus = @{
        0.5 = $window.FindName("MenuS50")
        0.75 = $window.FindName("MenuS75")
        1.0 = $window.FindName("MenuS100")
    }
    foreach ($s in $script:scaleMenus.Keys) {
        $menu = $script:scaleMenus[$s]
        $menu.Tag = $s
        $menu.IsChecked = ($s -eq $Scale)
        $menu.Add_Click({
            param($sender,$e)
            if ($script:recording) { return }
            $script:scaleValue = $sender.Tag
            foreach ($m in $script:scaleMenus.Values) { $m.IsChecked = ($m -eq $sender) }
            Update-CaptureRegion
        })
    }
    $script:fpsValue = $FPS
    $script:fpsMenus = @{
        1 = $window.FindName("MenuF1")
        2 = $window.FindName("MenuF2")
        5 = $window.FindName("MenuF5")
        10 = $window.FindName("MenuF10")
    }
    foreach ($f in $script:fpsMenus.Keys) {
        $menu = $script:fpsMenus[$f]
        $menu.Tag = $f
        $menu.IsChecked = ($f -eq $FPS)
        $menu.Add_Click({
            param($sender,$e)
            if ($script:recording) { return }
            $script:fpsValue = $sender.Tag
            foreach ($m in $script:fpsMenus.Values) { $m.IsChecked = ($m -eq $sender) }
        })
    }
    $script:invisible = $false
    $menuExit.Add_Click({ $window.Close() })
    $menuInvisible.Add_Checked({ $script:invisible = $true })
    $menuInvisible.Add_Unchecked({ $script:invisible = $false; $mainBorder.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null); $mainBorder.Opacity = 1 })
    $window.ContextMenu.Add_Closed({ if ($script:invisible -and -not $window.IsMouseOver) { $mainBorder.BeginAnimation([System.Windows.UIElement]::OpacityProperty, [System.Windows.Media.Animation.DoubleAnimation]::new(0, [TimeSpan]::FromMilliseconds(100))) } })
    $menuExit.Parent.Add_KeyDown({ param($s,$e)
        if ($e.Key -eq 'X') { $window.Close() }
        if ($e.Key -eq 'A') { $menuInvisible.IsChecked = -not $menuInvisible.IsChecked }
    })
    $window.Add_MouseLeftButtonDown({ $window.DragMove() })
    $window.Add_Deactivated({ $window.Topmost = $true })
    $window.Add_MouseEnter({ if ($script:invisible) { $mainBorder.BeginAnimation([System.Windows.UIElement]::OpacityProperty, [System.Windows.Media.Animation.DoubleAnimation]::new(1, [TimeSpan]::FromMilliseconds(100))) } })
    $window.Add_MouseLeave({ if ($script:invisible -and -not $window.ContextMenu.IsOpen -and -not ($script:monitorMenu -and $script:monitorMenu.IsOpen) -and -not $script:overlayVisible) { $mainBorder.BeginAnimation([System.Windows.UIElement]::OpacityProperty, [System.Windows.Media.Animation.DoubleAnimation]::new(0, [TimeSpan]::FromMilliseconds(100))) } })
    function Update-FontSize($size) {
        if ($size -lt 12 -or $size -gt 200) { return }
        $clock.FontSize = $size
        $btnToggle.FontSize = $size * 0.35
        $btnToggle.Width = $size * 1.4
        $btnToggle.Height = $size * 0.7
        $btnToggle.Margin = [System.Windows.Thickness]::new($size * 0.25, 0, 0, 0)
        $recCounter.FontSize = $size * 0.35; $recCounter.Height = $size * 0.45
        $recSpacer.FontSize = $size * 0.35; $recSpacer.Height = $size * 0.45
        $script:monitorLabel.FontSize = $size * 0.3
        $script:monitorLabel.Margin = [System.Windows.Thickness]::new($size * 0.25, 0, 0, 0)
        $mainBorder.Padding = [System.Windows.Thickness]::new($size * 0.3, $size * 0.2, $size * 0.3, $size * 0.2)
    }
    $window.Add_MouseWheel({ param($s,$e)
        Update-FontSize ($clock.FontSize + ($e.Delta / 30))
    })

    # Settings file
    $script:settingsPath = [System.IO.Path]::Combine($env:APPDATA, 'ScreenRecorder', 'settings.json')

    function Save-Settings {
        $settings = @{
            Left = $window.Left
            Top = $window.Top
            FontSize = $clock.FontSize
            AutoHide = $script:invisible
            SelectedMonitors = $script:selectedMonitors
            Quality = $script:quality
            Scale = $script:scaleValue
            FPS = $script:fpsValue
            MonitorCount = $script:screens.Count
        }
        $dir = [System.IO.Path]::GetDirectoryName($script:settingsPath)
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $settings | ConvertTo-Json | Set-Content -Path $script:settingsPath -Encoding UTF8
    }

    function Load-Settings {
        if (-not (Test-Path $script:settingsPath)) { return $null }
        try { Get-Content -Path $script:settingsPath -Raw | ConvertFrom-Json } catch { Write-Warning "Failed to load settings: $_"; $null }
    }

    # Monitor setup
    $script:screens = [System.Windows.Forms.Screen]::AllScreens

    function Get-PhysicalBounds($screen) {
        $dm = New-Object DisplayHelper+DEVMODE
        $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($dm)
        [DisplayHelper]::EnumDisplaySettings($screen.DeviceName, [DisplayHelper]::ENUM_CURRENT_SETTINGS, [ref]$dm) | Out-Null
        [System.Drawing.Rectangle]::new($dm.dmPositionX, $dm.dmPositionY, $dm.dmPelsWidth, $dm.dmPelsHeight)
    }
    # Selected monitors (array of indices)
    $primaryIdx = [Array]::IndexOf($script:screens, [System.Windows.Forms.Screen]::PrimaryScreen)
    $script:selectedMonitors = @($primaryIdx -ge 0 ? $primaryIdx : 0)

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
        $script:w = [int]($script:bounds.Width * $script:scaleValue)
        $script:h = [int]($script:bounds.Height * $script:scaleValue)
    }

    function Show-MonitorOverlay {
        param([switch]$ReopenMenu)
        $script:pendingMenuReopen = $ReopenMenu.IsPresent
        $script:overlayVisible = $true
        $dpiScale = [System.Windows.Forms.SystemInformation]::VirtualScreen.Width / [System.Windows.SystemParameters]::VirtualScreenWidth
        $overlays = @()
        for ($i = 0; $i -lt $script:screens.Count; $i++) {
            $scr = $script:screens[$i]
            $isSelected = $script:selectedMonitors -contains $i
            $wpfLeft = $scr.Bounds.Left / $dpiScale
            $wpfTop = $scr.Bounds.Top / $dpiScale
            $wpfWidth = $scr.Bounds.Width / $dpiScale
            $wpfHeight = $scr.Bounds.Height / $dpiScale
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
            $overlay.Add_MouseLeftButtonDown({
                param($s,$e)
                $s.Close()
            })
            $overlay.Add_Closed({
                $script:overlayCloseCount++
                if ($script:overlayCloseCount -ge $script:overlayTotal) {
                    $script:overlayVisible = $false
                    if ($script:pendingMenuReopen) {
                        $script:pendingMenuReopen = $false
                        $script:monitorMenu.PlacementTarget = $script:monitorLabel
                        $script:monitorMenu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
                        $script:monitorMenu.IsOpen = $true
                    }
                }
            })
            $overlay.Show()
            $overlays += $overlay
        }
        $script:overlayCloseCount = 0
        $script:overlayTotal = $overlays.Count
        # Auto close after 1.5 seconds
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(1500)
        $timer.Add_Tick({
            $timer.Stop(); $timer.IsEnabled = $false
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
            })
            $script:monitorMenu.Items.Add($menuItem) | Out-Null
        }

        $script:monitorLabel.ContextMenu = $script:monitorMenu
        $script:monitorLabel.Add_MouseLeftButtonDown({
            param($sender, $e)
            if ($script:recording) {
                # Show menu only (no overlay) during recording
                $script:monitorMenu.PlacementTarget = $script:monitorLabel
                $script:monitorMenu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
                $script:monitorMenu.IsOpen = $true
            } else {
                Show-MonitorOverlay -ReopenMenu
            }
            $e.Handled = $true
        })
    }

    $script:recording = $false
    $script:outDir = $null
    $script:recordFor = $RecordFor
    $script:recordStartTime = $null

    # Load saved settings
    $savedSettings = Load-Settings
    if ($savedSettings) {
        # Check if monitor configuration changed
        $monitorConfigChanged = $savedSettings.MonitorCount -ne $script:screens.Count

        # Window position (skip if monitor config changed)
        if (-not $monitorConfigChanged) {
            if ($null -ne $savedSettings.Left) { $window.Left = $savedSettings.Left }
            if ($null -ne $savedSettings.Top) { $window.Top = $savedSettings.Top }
        }
        # Font size
        if ($savedSettings.FontSize) {
            Update-FontSize $savedSettings.FontSize
        }
        # Auto-hide
        if ($savedSettings.AutoHide) { $menuInvisible.IsChecked = $true }
        # Quality
        if ($savedSettings.Quality -ge 1 -and $savedSettings.Quality -le 100) {
            $script:quality = $savedSettings.Quality
            foreach ($m in $script:qualityMenus.Values) { $m.IsChecked = ($m.Tag -eq $script:quality) }
        }
        # Scale
        if ($savedSettings.Scale -ge 0.1 -and $savedSettings.Scale -le 1.0) {
            $script:scaleValue = $savedSettings.Scale
            foreach ($m in $script:scaleMenus.Values) { $m.IsChecked = ($m.Tag -eq $script:scaleValue) }
        }
        # FPS
        if ($savedSettings.FPS -in @(1, 2, 5, 10)) {
            $script:fpsValue = $savedSettings.FPS
            foreach ($m in $script:fpsMenus.Values) { $m.IsChecked = ($m.Tag -eq $script:fpsValue) }
        }
        # Selected monitors (skip if monitor config changed)
        if (-not $monitorConfigChanged -and $savedSettings.SelectedMonitors) {
            $validMonitors = @($savedSettings.SelectedMonitors | Where-Object { $_ -ge 0 -and $_ -lt $script:screens.Count })
            if ($validMonitors.Count -gt 0) {
                $script:selectedMonitors = $validMonitors
                # Update monitor menu checkboxes
                if ($script:monitorMenu) {
                    foreach ($item in $script:monitorMenu.Items) {
                        $item.IsChecked = $script:selectedMonitors -contains $item.Tag
                    }
                }
                Update-MonitorLabel
            }
        }
    }

    Update-CaptureRegion

    # Background recorder instance
    $script:recorder = [BackgroundRecorder]::new()

    # Get window handle for physical coordinate calculation
    $windowHelper = [System.Windows.Interop.WindowInteropHelper]::new($window)

    $btnToggle.Add_Click({
        if (-not $script:recording) {
            # Check if current directory is a system folder
            $blocked = @($env:SystemRoot, "$env:SystemRoot\System32", $env:ProgramFiles, ${env:ProgramFiles(x86)})
            if ((Get-Location).Path -iin $blocked) {
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
            $started = $script:recorder.Start($script:bounds, [System.Drawing.Rectangle[]]$monitorBoundsArray, $script:w, $script:h, $script:fpsValue, $script:quality, (Resolve-Path $script:outDir).Path, $SaveMasked, $script:scaleValue, $windowHelper.Handle)
            if (-not $started) {
                [System.Windows.MessageBox]::Show("Recording failed: $($script:recorder.LastError)", "Error", "OK", "Error")
                Remove-Item -Path $script:outDir -Force -ErrorAction SilentlyContinue
                return
            }
            $script:recording = $true
            $btnToggle.Content = "■ STOP"
            $btnToggle.Foreground = [System.Windows.Media.Brushes]::Red
            $script:monitorLabel.Opacity = 0.5
            foreach ($m in $script:scaleMenus.Values) { $m.IsEnabled = $false }
            foreach ($m in $script:fpsMenus.Values) { $m.IsEnabled = $false }
            if ($script:monitorMenu) { foreach ($m in $script:monitorMenu.Items) { $m.IsEnabled = $false } }

            $recCounter.Text = "0"; $recCounter.Visibility = "Visible"
            if ($script:recordFor -gt [TimeSpan]::Zero) {
                $script:recordStartTime = [DateTime]::Now
                $recSpacer.Text = $script:recordFor.ToString('hh\:mm\:ss')
            }
        } else {
            # Stop recording
            $script:recorder.Stop()
            $script:recording = $false
            $script:monitorLabel.Opacity = 1.0
            foreach ($m in $script:scaleMenus.Values) { $m.IsEnabled = $true }
            foreach ($m in $script:fpsMenus.Values) { $m.IsEnabled = $true }
            if ($script:monitorMenu) { foreach ($m in $script:monitorMenu.Items) { $m.IsEnabled = $true } }

            $recCounter.Visibility = "Hidden"
            $recSpacer.Text = ""
            $script:recordStartTime = $null
            $script:recordFor = [TimeSpan]::Zero
            if ($script:stopTimer) { $script:stopTimer.Stop(); $script:stopTimer = $null }
            $btnToggle.Content = "● REC"
            $btnToggle.Foreground = [System.Windows.Media.Brushes]::White
            Start-Process explorer $script:outDir
        }
    })

    $clockTimer = New-Object System.Windows.Threading.DispatcherTimer
    $clockTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $clockTimer.Add_Tick({
        $clock.Text = (Get-Date).ToString("HH:mm:ss.f")
        if ($script:recording) {
            $recCounter.Text = $script:recorder.Saved
            if ($script:recordStartTime) {
                $elapsed = [DateTime]::Now - $script:recordStartTime
                $remaining = $script:recordFor - $elapsed
                if ($remaining -lt [TimeSpan]::Zero) { $remaining = [TimeSpan]::Zero }
                $recSpacer.Text = $remaining.ToString('hh\:mm\:ss')
            }
        }
    })
    $clockTimer.Start()
    $window.Add_Closed({
        $clockTimer.Stop()
        Save-Settings
        if ($script:recording) { $script:recorder.Stop(); Start-Process explorer $script:outDir }
    })
    if ($ReadyFile) { New-Item -Path $ReadyFile -ItemType File -Force | Out-Null }

    # Auto-start recording if -RecordFor is specified
    if ($RecordFor -gt [TimeSpan]::Zero) {
        # Hide window immediately if Auto-hide is enabled
        if ($script:invisible) {
            $mainBorder.Opacity = 0
        }
        $window.Add_ContentRendered({
            # Initialize clock and wait for UI rendering to complete
            $clock.Text = (Get-Date).ToString("HH:mm:ss.f")
            $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Loaded, [Action]{
                $btnToggle.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
                # Set up auto-stop timer
                $script:stopTimer = [System.Windows.Threading.DispatcherTimer]::new()
                $script:stopTimer.Interval = $RecordFor
                $script:stopTimer.Add_Tick({
                    $script:stopTimer.Stop()
                    if ($script:recording) {
                        $btnToggle.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
                    }
                    $window.Close()
                })
                $script:stopTimer.Start()
            })
        })
    }

    $window.ShowDialog()
}

# Run only when invoked directly (not dot-sourced or imported as module)
if ($MyInvocation.InvocationName -notin '.', '') {
    Start-ScreenRecorder @PSBoundParameters
}
