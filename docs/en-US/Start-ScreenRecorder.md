---
external help file: ScreenRecorder-help.xml
Module Name: ScreenRecorder
online version: https://github.com/yotsuda/ScreenRecorder/blob/master/docs/en-US/Start-ScreenRecorder.md
schema: 2.0.0
---

# Start-ScreenRecorder

## SYNOPSIS
Starts a screen recorder with a clock overlay for debugging and log correlation.

## SYNTAX

```
Start-ScreenRecorder [[-FPS] <Int32>] [[-Scale] <Double>] [[-Quality] <Int32>] [-SaveMasked]
 [[-RecordFor] <TimeSpan>] [[-OutputPath] <String>] [-ProgressAction <ActionPreference>] [<CommonParameters>]
```

## DESCRIPTION
Captures screenshots at regular intervals while displaying a large clock overlay.
Designed for correlating screen captures with log timestamps during bug reproduction.
Requires no external dependencies - uses only PowerShell and .NET.
Can be run directly without module installation.

## EXAMPLES

### EXAMPLE 1
```
Start-ScreenRecorder
Starts the recorder in background mode.
```

### EXAMPLE 2
```
Start-ScreenRecorder -FPS 10 -Scale 0.75
Starts with higher frame rate and larger output images.
```

### EXAMPLE 3
```
Start-ScreenRecorder -RecordFor 0:10:00
Starts recording immediately and stops after 10 minutes.
```

### EXAMPLE 4
```
Start-ScreenRecorder -OutputPath D:\Screenshots
Saves screenshots to D:\Screenshots\yyyyMMdd_HHmmss\ folder.
```

## PARAMETERS

### -FPS
Frames per second for capture.
Default is 2.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: 2
Accept pipeline input: False
Accept wildcard characters: False
```

### -OutputPath
Base directory for saving screenshots.
A timestamped subfolder will be created.
If not specified, uses current directory or TEMP folder as fallback.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 6
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -ProgressAction
{{ Fill ProgressAction Description }}

```yaml
Type: ActionPreference
Parameter Sets: (All)
Aliases: proga

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Quality
JPEG quality for captured images (1-100).
Default is 75.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: 75
Accept pipeline input: False
Accept wildcard characters: False
```

### -RecordFor
Starts recording immediately and stops after the specified duration.

```yaml
Type: TimeSpan
Parameter Sets: (All)
Aliases:

Required: False
Position: 5
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -SaveMasked
Saves masked images (with clock area blacked out) for debugging.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### -Scale
Scale factor for captured images (0.1 to 1.0).
Default is 0.75.

```yaml
Type: Double
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: 0.75
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

## NOTES

## RELATED LINKS

[https://github.com/yotsuda/ScreenRecorder/blob/master/docs/en-US/Start-ScreenRecorder.md](https://github.com/yotsuda/ScreenRecorder/blob/master/docs/en-US/Start-ScreenRecorder.md)

[https://github.com/yotsuda/ScreenRecorder](https://github.com/yotsuda/ScreenRecorder)

