# ScreenRecorder

Screen capture tool with clock overlay for debugging and log correlation. No external dependencies required.

## Features

- **Clock Overlay** - Always-on-top transparent window showing current time (HH:mm:ss.f)
- **Smart Capture** - Only saves frames when screen content changes (excludes clock area from comparison)
- **Multi-Monitor Support** - Select which monitor to capture
- **Scalable UI** - Mouse wheel to resize the clock display

## Installation

```powershell
Install-Module ScreenRecorder
```

Or simply download and run `Start-ScreenRecorder.ps1` directly - no module installation required.

## Usage

```powershell
# Basic usage - starts recorder with clock overlay
Start-ScreenRecorder

# Higher frame rate with 75% scale
Start-ScreenRecorder -FPS 10 -Scale 0.75

# Save masked images for debugging hash calculation
Start-ScreenRecorder -SaveMasked
```

### Controls

| Action | Description |
|--------|-------------|
| **REC button** | Start/stop recording |
| **Mouse wheel** | Resize clock display |
| **Drag** | Move clock window |
| **Right-click** | Exit menu |
| **Monitor dropdown** | Select capture target (multi-monitor) |

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| -FPS | int | 2 | Frames per second |
| -Scale | double | 1.0 | Image scale (0.1-1.0) |
| -SaveMasked | switch | - | Save masked images for debugging |

## Output

Screenshots are saved to `./ScreenCaptures/yyyyMMdd_HHmmss/` as JPEG files (quality 75%).

Filename format: `yyyyMMdd_HHmmss_f.jpg`

## Requirements

- PowerShell 5.1 or later
- Windows (uses WPF and System.Windows.Forms)

## License

[MIT](LICENSE)