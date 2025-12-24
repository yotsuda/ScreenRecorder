param(
    [switch]$Background,
    [int]$FPS = 2,
    [double]$Scale = 1.0,
    [int]$Threshold = 1
)

function Start-ScreenRecorder {
    <#
    .SYNOPSIS
        Starts a screen recorder with a clock overlay for debugging and log correlation.
    .DESCRIPTION
        Captures screenshots at regular intervals while displaying a large clock overlay.
        Designed for correlating screen captures with log timestamps during bug reproduction.
        Requires no external dependencies - uses only PowerShell and .NET.
    .PARAMETER Background
        Runs the recorder in a hidden background process.
    .PARAMETER FPS
        Frames per second for capture. Default is 5.
    .PARAMETER Scale
        Scale factor for captured images (0.1 to 1.0). Default is 0.5.
    .PARAMETER Threshold
        Minimum pixel difference to save a frame. Default is 1.
    .EXAMPLE
        Start-ScreenRecorder
        Starts the recorder in background mode.
    .EXAMPLE
        Start-ScreenRecorder -FPS 10 -Scale 0.75
        Starts with higher frame rate and larger output images.
    #>
    [CmdletBinding()]
    param(
        [switch]$Background,
        [int]$FPS = 2,
        [ValidateRange(0.1, 1.0)]
        [double]$Scale = 1.0,
        [int]$Threshold = 1
    )

    if (-not $Background) {
        $exe = (Get-Process -Id $PID).Path
        $scriptPath = $MyInvocation.MyCommand.ScriptBlock.File
        if (-not $scriptPath) { $scriptPath = $PSCommandPath }
        Start-Process $exe -ArgumentList "-WindowStyle Hidden -File `"$scriptPath`" -Background -FPS $FPS -Scale $Scale -Threshold $Threshold" -WindowStyle Hidden
        return
    }

    Add-Type -AssemblyName PresentationFramework,System.Windows.Forms,System.Drawing
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
            </StackPanel>
        </StackPanel>
    </Border>
</Window>
"@
    $window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))
    $clock = $window.FindName("Clock")
    $btnToggle = $window.FindName("BtnToggle")
    $mainBorder = $window.FindName("MainBorder")
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
            $mainBorder.Padding = [System.Windows.Thickness]::new($size * 0.3, $size * 0.2, $size * 0.3, $size * 0.2)
        }
    })

    $script:recording = $false
    $script:outDir = $null
    $script:saved = 0
    $script:prevBytes = $null
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $w = [int]($bounds.Width * $Scale)
    $h = [int]($bounds.Height * $Scale)

    function Get-SampleBytes($bmp, $excludeRect) {
        $bytes = @()
        $stepX = [Math]::Max(1, [int]($bmp.Width / 20))
        $stepY = [Math]::Max(1, [int]($bmp.Height / 20))
        for ($y = 0; $y -lt $bmp.Height; $y += $stepY) {
            for ($x = 0; $x -lt $bmp.Width; $x += $stepX) {
                # Skip if inside exclude rectangle
                if ($excludeRect -and 
                    $x -ge $excludeRect.Left -and $x -lt $excludeRect.Right -and
                    $y -ge $excludeRect.Top -and $y -lt $excludeRect.Bottom) {
                    continue
                }
                $c = $bmp.GetPixel($x, $y)
                $bytes += $c.R, $c.G, $c.B
            }
        }
        $bytes
    }

    $recTimer = New-Object System.Windows.Threading.DispatcherTimer
    $recTimer.Interval = [TimeSpan]::FromMilliseconds([int](1000 / $FPS))
    $recTimer.Add_Tick({
        if (-not $script:recording) { return }
        $now = Get-Date
        $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $g.Dispose()
        $thumb = New-Object System.Drawing.Bitmap($w, $h)
        $g2 = [System.Drawing.Graphics]::FromImage($thumb)
        $g2.DrawImage($bmp, 0, 0, $w, $h)
        $g2.Dispose()
        $bmp.Dispose()

        # Calculate exclude rectangle for clock window (scaled)
        $excludeRect = @{
            Left   = [int]($window.Left * $Scale)
            Top    = [int]($window.Top * $Scale)
            Right  = [int](($window.Left + $window.ActualWidth) * $Scale)
            Bottom = [int](($window.Top + $window.ActualHeight) * $Scale)
        }
        $currBytes = Get-SampleBytes $thumb $excludeRect
        $diff = 0
        if ($script:prevBytes) {
            for ($i = 0; $i -lt $currBytes.Count; $i++) {
                $diff += [Math]::Abs($currBytes[$i] - $script:prevBytes[$i])
            }
            $diff = $diff / $currBytes.Count
        } else { $diff = 999 }

        if ($diff -ge $Threshold) {
            $filename = $now.ToString("yyyyMMdd_HHmmss_f")
            $jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
            $qualityParam = [System.Drawing.Imaging.Encoder]::Quality
            $encoderParams = [System.Drawing.Imaging.EncoderParameters]::new(1)
            $encoderParams.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new($qualityParam, 75L)
            $thumb.Save("$($script:outDir)\$filename.jpg", $jpegCodec, $encoderParams)
            $script:saved++
            $script:prevBytes = $currBytes
        }
        $thumb.Dispose()
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
            $script:prevBytes = $null
            $btnToggle.Content = "■ STOP"
            $btnToggle.Foreground = [System.Windows.Media.Brushes]::Red
            $recTimer.Start()
        } else {
            # Stop recording
            $recTimer.Stop()
            $script:recording = $false
            $btnToggle.Content = "● REC"
            $btnToggle.Foreground = [System.Windows.Media.Brushes]::White
            Start-Process explorer $script:outDir
        }
    })

    $clockTimer = New-Object System.Windows.Threading.DispatcherTimer
    $clockTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $clockTimer.Add_Tick({ $clock.Text = (Get-Date).ToString("HH:mm:ss.f") })
    $clockTimer.Start()
    $window.ShowDialog()
}

# Standalone execution
if ($MyInvocation.InvocationName -notin '.', '') {
    Start-ScreenRecorder @PSBoundParameters
}
