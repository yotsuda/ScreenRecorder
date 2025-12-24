param([switch]$Background, [int]$FPS = 2, [double]$Scale = 1.0, [int]$Threshold = 1)

$logFile = "C:\MyProj\ScreenRecorder\debug.log"
"=== Start $(Get-Date) ===" | Out-File $logFile -Append

if (-not $Background) {
    "Launching background process..." | Out-File $logFile -Append
    $exe = (Get-Process -Id $PID).Path
    $scriptPath = $MyInvocation.MyCommand.ScriptBlock.File
    if (-not $scriptPath) { $scriptPath = $PSCommandPath }
    Start-Process $exe -ArgumentList "-WindowStyle Hidden -File `"$scriptPath`" -Background" -WindowStyle Hidden
    return
}

"Background process started" | Out-File $logFile -Append

Add-Type -AssemblyName PresentationFramework,System.Windows.Forms,System.Drawing

$screens = [System.Windows.Forms.Screen]::AllScreens
"Screen count: $($screens.Count)" | Out-File $logFile -Append

for ($i = 0; $i -lt $screens.Count; $i++) {
    $s = $screens[$i]
    "  [$i] $($s.DeviceName) Primary=$($s.Primary) Bounds=$($s.Bounds)" | Out-File $logFile -Append
}

# Check DPI
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
"VirtualScreen: $vs" | Out-File $logFile -Append

"WPF VirtualScreenLeft: $([System.Windows.SystemParameters]::VirtualScreenLeft)" | Out-File $logFile -Append
"WPF VirtualScreenTop: $([System.Windows.SystemParameters]::VirtualScreenTop)" | Out-File $logFile -Append
"WPF VirtualScreenWidth: $([System.Windows.SystemParameters]::VirtualScreenWidth)" | Out-File $logFile -Append
"WPF VirtualScreenHeight: $([System.Windows.SystemParameters]::VirtualScreenHeight)" | Out-File $logFile -Append

"=== End ===" | Out-File $logFile -Append
