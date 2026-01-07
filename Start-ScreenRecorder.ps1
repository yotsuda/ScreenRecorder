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
    [double]$Scale = 1.0,
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
        [ValidateRange(0.1, 1.0)]
        [double]$Scale = 1.0,
        [switch]$SaveMasked
    )

    if (-not $Background) {
        $exe = (Get-Process -Id $PID).Path
        $scriptPath = $MyInvocation.MyCommand.ScriptBlock.File
        if (-not $scriptPath) { $scriptPath = $PSCommandPath }
        $procArgs = "-NoProfile -WindowStyle Hidden -File `"$scriptPath`" -Background -FPS $FPS -Scale $Scale"
        if ($SaveMasked) { $procArgs += " -SaveMasked" }
        Start-Process $exe -ArgumentList $procArgs -WindowStyle Hidden
        return
    }

    Add-Type -AssemblyName PresentationFramework,System.Windows.Forms,System.Drawing
    $drawingAsm = [System.Drawing.Bitmap].Assembly.Location
    $primAsm = [System.Drawing.Rectangle].Assembly.Location
    Add-Type -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
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
                    // Row intersects exclude region: process left and right parts
                    for (int x = 0; x < exL; x++) {
                        hash ^= row[x];
                        hash *= 0x100000001b3L;
                    }
                    for (int x = exR; x < width; x++) {
                        hash ^= row[x];
                        hash *= 0x100000001b3L;
                    }
                } else {
                    // Full row
                    for (int x = 0; x < width; x++) {
                        hash ^= row[x];
                        hash *= 0x100000001b3L;
                    }
                }
            }
            return hash;
        } finally {
            bmp.UnlockBits(data);
        }
    }
}
"@ -ReferencedAssemblies $drawingAsm,$primAsm -CompilerOptions '/unsafe'
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
    $script:prevHash = $null
    Update-CaptureRegion

    # Pre-cache JPEG encoder (avoid repeated lookup per frame)
    $script:jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq "image/jpeg" }
    if (-not $script:jpegCodec) { throw "JPEG encoder not found" }
    $script:encoderParams = [System.Drawing.Imaging.EncoderParameters]::new(1)
    $script:encoderParams.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new([System.Drawing.Imaging.Encoder]::Quality, 75L)


    $recTimer = New-Object System.Windows.Threading.DispatcherTimer
    $recTimer.Interval = [TimeSpan]::FromMilliseconds([int](1000 / $FPS))
    $recTimer.Add_Tick({
        if (-not $script:recording) { return }
        try {
            $now = Get-Date
            if ($script:selectedMonitors.Count -eq 1) {
                # Single monitor: fast path
                $script:captureG.CopyFromScreen($script:bounds.Location, [System.Drawing.Point]::Empty, $script:bounds.Size)
            } else {
                # Multiple monitors: clear and capture each using pre-allocated resources
                $script:captureG.Clear([System.Drawing.Color]::Black)
                foreach ($idx in $script:selectedMonitors) {
                    $b = $script:monitorBounds[$idx]
                    $script:monitorGs[$idx].CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
                    $relX = $b.Left - $script:bounds.Left
                    $relY = $b.Top - $script:bounds.Top
                    $script:captureG.DrawImage($script:monitorBmps[$idx], $relX, $relY)
                }
            }
            $script:thumbG.DrawImage($script:captureBmp, 0, 0, $script:w, $script:h)

            # Calculate exclude rectangle for clock window (scaled, relative to capture region)
            $exL = [int](($window.Left * $script:dpiScale - $script:bounds.Left) * $Scale)
            $exT = [int](($window.Top * $script:dpiScale - $script:bounds.Top) * $Scale)
            $exR = [int]((($window.Left + $window.ActualWidth) * $script:dpiScale - $script:bounds.Left) * $Scale)
            $exB = [int]((($window.Top + $window.ActualHeight) * $script:dpiScale - $script:bounds.Top) * $Scale)

            $currHash = [DisplayHelper]::ComputeImageHash($script:thumbBmp, $exL, $exT, $exR, $exB)

            if ($currHash -ne $script:prevHash) {
                $filename = $now.ToString("yyyyMMdd_HHmmss_ff")
                $script:thumbBmp.Save("$($script:outDir)\$filename.jpg", $script:jpegCodec, $script:encoderParams)
                if ($SaveMasked) {
                    $script:maskedBmp.Save("$($script:outDir)\${filename}_masked.jpg", $script:jpegCodec, $script:encoderParams)
                }
                $script:saved++
                $script:prevHash = $currHash
            }
        } catch {
            # Ignore capture errors (e.g., monitor disconnected)
        }
    })

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
            # Pre-allocate reusable bitmaps and graphics
            $script:captureBmp = New-Object System.Drawing.Bitmap($script:bounds.Width, $script:bounds.Height)
            $script:captureG = [System.Drawing.Graphics]::FromImage($script:captureBmp)
            $script:thumbBmp = New-Object System.Drawing.Bitmap($script:w, $script:h)
            $script:thumbG = [System.Drawing.Graphics]::FromImage($script:thumbBmp)
            $script:maskedBmp = New-Object System.Drawing.Bitmap($script:w, $script:h)
            $script:maskedG = [System.Drawing.Graphics]::FromImage($script:maskedBmp)
            # Pre-allocate per-monitor bitmaps for multi-monitor capture
            $script:monitorBmps = @{}
            $script:monitorGs = @{}
            $script:monitorBounds = @{}
            if ($script:selectedMonitors.Count -gt 1) {
                foreach ($idx in $script:selectedMonitors) {
                    $b = Get-PhysicalBounds $script:screens[$idx]
                    $script:monitorBounds[$idx] = $b
                    $script:monitorBmps[$idx] = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
                    $script:monitorGs[$idx] = [System.Drawing.Graphics]::FromImage($script:monitorBmps[$idx])
                }
            }
            $script:recording = $true
            $script:saved = 0
            $script:prevHash = $null
            $btnToggle.Content = "■ STOP"
            $btnToggle.Foreground = [System.Windows.Media.Brushes]::Red
            $script:monitorLabel.IsHitTestVisible = $false; $script:monitorLabel.Opacity = 0.5; $recTimer.Start()
        } else {
            # Stop recording
            $recTimer.Stop()
            # Dispose pre-allocated resources
            foreach ($idx in $script:monitorGs.Keys) { $script:monitorGs[$idx].Dispose() }
            foreach ($idx in $script:monitorBmps.Keys) { $script:monitorBmps[$idx].Dispose() }
            $script:monitorGs = @{}; $script:monitorBmps = @{}; $script:monitorBounds = @{}
            if ($script:maskedG) { $script:maskedG.Dispose(); $script:maskedG = $null }
            if ($script:maskedBmp) { $script:maskedBmp.Dispose(); $script:maskedBmp = $null }
            if ($script:thumbG) { $script:thumbG.Dispose(); $script:thumbG = $null }
            if ($script:thumbBmp) { $script:thumbBmp.Dispose(); $script:thumbBmp = $null }
            if ($script:captureG) { $script:captureG.Dispose(); $script:captureG = $null }
            if ($script:captureBmp) { $script:captureBmp.Dispose(); $script:captureBmp = $null }
            $script:recording = $false; $script:monitorLabel.IsHitTestVisible = $true; $script:monitorLabel.Opacity = 1.0
            $btnToggle.Content = "● REC"
            $btnToggle.Foreground = [System.Windows.Media.Brushes]::White
            Start-Process explorer $script:outDir
        }
    })

    $clockTimer = New-Object System.Windows.Threading.DispatcherTimer
    $clockTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $clockTimer.Add_Tick({ $clock.Text = (Get-Date).ToString("HH:mm:ss.f") })
    $clockTimer.Start()
    $window.Add_Closed({ $clockTimer.Stop(); $recTimer.Stop() })
    $window.ShowDialog()
}

# Run only when invoked directly (not dot-sourced or imported as module)
if ($MyInvocation.InvocationName -notin '.', '') {
    Start-ScreenRecorder @PSBoundParameters
}
