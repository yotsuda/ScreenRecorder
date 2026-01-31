# ScreenRecorder

Screen capture tool with clock overlay for debugging and log correlation. No external dependencies required.

## Use Cases

- **Debugging** - Correlate screen captures with log timestamps during bug reproduction
- **Documentation** - Automatically capture screenshots while performing tasks for creating step-by-step guides

## Features

- **Clock Overlay** - Always-on-top transparent window showing current time (HH:mm:ss.f)
- **Smart Capture** - Only saves frames when screen content changes (excludes clock area from comparison)
- **Multi-Monitor Support** - Capture single or multiple monitors simultaneously
- **Scalable UI** - Mouse wheel to resize the clock display
- **Auto-hide** - Clock window becomes transparent when not hovered
- **Settings Overlay** - Quality and Scale settings are shown on the first captured frame
- **Timed Recording** - Auto-start and auto-stop recording with `-RecordFor` parameter
- **Settings Persistence** - Window position, size, and preferences are saved automatically

## Installation

```powershell
Install-Module ScreenRecorder
```

Or simply download and run `Start-ScreenRecorder.ps1` directly - no module installation required.

## Usage

```powershell
# Basic usage - starts recorder with clock overlay
Start-ScreenRecorder

# Higher frame rate with custom quality
Start-ScreenRecorder -FPS 10 -Scale 0.75 -Quality 50

# Save masked images for debugging hash calculation
Start-ScreenRecorder -SaveMasked

# Record for 10 minutes and automatically stop
Start-ScreenRecorder -RecordFor 0:10:00
```

### Controls

| Action | Description |
|--------|-------------|
| **REC button** | Start/stop recording |
| **Mouse wheel** | Resize clock display |
| **Drag** | Move clock window |
| **Right-click** | Context menu (Auto-hide, Quality, Scale, FPS, Exit) |
| **A key** | Toggle auto-hide mode |
| **X key** | Exit |
| **Monitor label** | Click to select monitors (multi-monitor) |

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| -FPS | int | 2 | Frames per second |
| -Scale | double | 0.75 | Image scale (0.1-1.0) |
| -Quality | int | 75 | JPEG quality (1-100) |
| -SaveMasked | switch | - | Save masked images for debugging |
| -RecordFor | TimeSpan | - | Auto-start recording and stop after specified duration |

## Output

Screenshots are saved to `./ScreenCaptures/yyyyMMdd_HHmmss/` as JPEG files.

Filename format: `yyyyMMdd_HHmmss_ff.jpg`

## Requirements

- PowerShell 5.1 or later
- Windows (uses WPF and System.Windows.Forms)

## License

[MIT](LICENSE)
