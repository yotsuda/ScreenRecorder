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
        $args = "-WindowStyle Hidden -File `"$scriptPath`" -Background -FPS $FPS -Scale $Scale"
        if ($SaveMasked) { $args += " -SaveMasked" }
        Start-Process $exe -ArgumentList $args -WindowStyle Hidden
        return
    }

    Add-Type -AssemblyName PresentationFramework,System.Windows.Forms,System.Drawing
    Add-Type -TypeDefinition @"
using System;
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
}
"@
    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    Topmost="True" AllowsTransparency="True" WindowStyle="None" Background="Transparent"
    SizeToContent="WidthAndHeight" Left="20" Top="20">
    <Window.ContextMenu>
        <ContextMenu>
            <MenuItem Name="MenuExit" Header="終了 (_X)"/>
        </ContextMenu>
    </Window.ContextMenu>
    <Border Name="MainBorder" Background="#AA000000" CornerRadius="8" Padding="10,6">
        <StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                <TextBlock Name="Clock" Foreground="White" FontSize="32" FontFamily="Consolas" VerticalAlignment="Center"/>
                <Button Name="BtnToggle" Content="● REC" Width="45" Height="22" FontSize="11" Margin="8,0,0,0" Background="#AA444444" Foreground="White" BorderThickness="0" Padding="0" VerticalAlignment="Center"/>
                <ComboBox Name="ComboMonitor" Width="50" Height="22" FontSize="10" Margin="4,0,0,0" VerticalAlignment="Center" Visibility="Collapsed"/>
            </StackPanel>
        </StackPanel>
    </Border>
</Window>
"@
    $window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))
    $clock = $window.FindName("Clock")
    $btnToggle = $window.FindName("BtnToggle")
    $mainBorder = $window.FindName("MainBorder")
    $comboMonitor = $window.FindName("ComboMonitor")
    $window.FindName("MenuExit").Add_Click({ $window.Close() })
    $window.Add_MouseLeftButtonDown({ $window.DragMove() })
    $window.Add_MouseWheel({ param($s,$e)
        $size = $clock.FontSize + ($e.Delta / 30)
        if ($size -ge 12 -and $size -le 200) {
            $clock.FontSize = $size
            $btnToggle.FontSize = $size * 0.35
            $btnToggle.Width = $size * 1.4
            $btnToggle.Height = $size * 0.7
            $btnToggle.Margin = [System.Windows.Thickness]::new($size * 0.25, 0, 0, 0)
            $comboMonitor.FontSize = $size * 0.3
            $comboMonitor.Width = $size * 1.5
            $comboMonitor.Height = $size * 0.7
            $comboMonitor.Margin = [System.Windows.Thickness]::new($size * 0.12, 0, 0, 0)
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
    if ($script:screens.Count -gt 1) {
        $comboMonitor.Visibility = "Visible"
        for ($i = 0; $i -lt $script:screens.Count; $i++) {
            $label = if ($script:screens[$i].Primary) { "Mon $($i+1)*" } else { "Mon $($i+1)" }
            $comboMonitor.Items.Add($label) | Out-Null
        }
        $comboMonitor.SelectedIndex = [Array]::IndexOf($script:screens, [System.Windows.Forms.Screen]::PrimaryScreen)
    }

    function Show-MonitorOverlay {
        $overlays = @()
        for ($i = 0; $i -lt $script:screens.Count; $i++) {
            $scr = $script:screens[$i]
            $phys = Get-PhysicalBounds $scr
            $isSelected = ($i -eq $comboMonitor.SelectedIndex)
            $wpfLeft = $phys.Left / $script:dpiScale
            $wpfTop = $phys.Top / $script:dpiScale
            $wpfWidth = $phys.Width / $script:dpiScale
            $wpfHeight = $phys.Height / $script:dpiScale
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

    $comboMonitor.Add_SelectionChanged({
        $script:targetScreen = $script:screens[$comboMonitor.SelectedIndex]
        $script:bounds = Get-PhysicalBounds $script:targetScreen
        $script:w = [int]($script:bounds.Width * $Scale)
        $script:h = [int]($script:bounds.Height * $Scale)
        Show-MonitorOverlay
    })

    $script:recording = $false
    $script:outDir = $null
    $script:saved = 0
    $script:prevHash = $null
    $script:bounds = Get-PhysicalBounds $script:targetScreen
    $script:w = [int]($script:bounds.Width * $Scale)
    $script:h = [int]($script:bounds.Height * $Scale)

    function Get-ImageHash($bmp, $excludeRect) {
        # Black out the clock area for hash calculation
        if ($excludeRect) {
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.FillRectangle([System.Drawing.Brushes]::Black,
                $excludeRect.Left, $excludeRect.Top,
                ($excludeRect.Right - $excludeRect.Left),
                ($excludeRect.Bottom - $excludeRect.Top))
            $g.Dispose()
        }
        $ms = [System.IO.MemoryStream]::new()
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Bmp)
        $hash = [System.Security.Cryptography.MD5]::Create().ComputeHash($ms.ToArray())
        $ms.Dispose()
        [Convert]::ToHexString($hash)
    }

    $recTimer = New-Object System.Windows.Threading.DispatcherTimer
    $recTimer.Interval = [TimeSpan]::FromMilliseconds([int](1000 / $FPS))
    $recTimer.Add_Tick({
        if (-not $script:recording) { return }
        try {
            $now = Get-Date
            $bmp = New-Object System.Drawing.Bitmap($script:bounds.Width, $script:bounds.Height)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($script:bounds.Location, [System.Drawing.Point]::Empty, $script:bounds.Size)
            $g.Dispose()
            $thumb = New-Object System.Drawing.Bitmap($script:w, $script:h)
            $g2 = [System.Drawing.Graphics]::FromImage($thumb)
            $g2.DrawImage($bmp, 0, 0, $script:w, $script:h)
            $g2.Dispose()
            $bmp.Dispose()

            # Calculate exclude rectangle for clock window (scaled, relative to target monitor)
            $excludeRect = @{
                Left   = [int](($window.Left * $script:dpiScale - $script:bounds.Left) * $Scale)
                Top    = [int](($window.Top * $script:dpiScale - $script:bounds.Top) * $Scale)
                Right  = [int]((($window.Left + $window.ActualWidth) * $script:dpiScale - $script:bounds.Left) * $Scale)
                Bottom = [int]((($window.Top + $window.ActualHeight) * $script:dpiScale - $script:bounds.Top) * $Scale)
            }

            # Create masked copy for hash calculation
            $masked = $thumb.Clone()
            $currHash = Get-ImageHash $masked $excludeRect

            if ($currHash -ne $script:prevHash) {
                $filename = $now.ToString("yyyyMMdd_HHmmss_f")
                $jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq "image/jpeg" }
                $qualityParam = [System.Drawing.Imaging.Encoder]::Quality
                $encoderParams = [System.Drawing.Imaging.EncoderParameters]::new(1)
                $encoderParams.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new($qualityParam, 75L)
                $thumb.Save("$($script:outDir)\$filename.jpg", $jpegCodec, $encoderParams)
                if ($SaveMasked) {
                    $masked.Save("$($script:outDir)\${filename}_masked.jpg", $jpegCodec, $encoderParams)
                }
                $script:saved++
                $script:prevHash = $currHash
            }
            $masked.Dispose()
            $thumb.Dispose()
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
            $script:recording = $true
            $script:saved = 0
            $script:prevHash = $null
            $btnToggle.Content = "■ STOP"
            $btnToggle.Foreground = [System.Windows.Media.Brushes]::Red
            $comboMonitor.IsEnabled = $false; $recTimer.Start()
        } else {
            # Stop recording
            $recTimer.Stop()
            $script:recording = $false; $comboMonitor.IsEnabled = $true
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

# Standalone execution
if ($MyInvocation.InvocationName -notin '.', '') {
    Start-ScreenRecorder @PSBoundParameters
}
