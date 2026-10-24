# davinci-photo-align

Aligns photos with a video in DaVinci Resolve using capture timestamps.

## What it does

The Lua script reads the video and photo timestamps with ExifTool, calculates each photo's offset from the reference video, and writes the result to **Start TC** in the Resolve Media Pool. It does not change the original files or their EXIF metadata.

- `resolve_exif_timecode_sync.lua` — spreads photos that land on the same frame across the second, keeping them in chronological order.
- `resolve_exif_timecode_sync_oneframe.lua` — assigns those photos to consecutive frames, one frame apart.

## Requirements

- DaVinci Resolve with scripting API access
- macOS
- [ExifTool](https://exiftool.org/)

Install ExifTool with Homebrew:

```sh
brew install exiftool
```

## Install

1. Open Finder and choose **Go → Go to Folder…**
2. Open your Resolve scripts directory. For a per-user install, use:

   ```text
   ~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility
   ```

   Create the `Utility` folder if it does not exist. The system-wide equivalent is under `/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility`.
3. Copy the `.lua` files into that folder.
4. Restart DaVinci Resolve.

## Use

1. Open a project and go to the Media Pool.
2. Select **exactly one reference video** and one or more photos.
3. Run the script from **Workspace → Scripts → Utility**.
4. Review the generated `resolve_exif_timecode_sync.log` on your Desktop.

Before applying changes, open the Lua file and set `DRY_RUN = true`. Run it and check the log. When the results look right, set `DRY_RUN = false` and run it again.

## Settings

At the top of the Lua file:

- `REFERENCE_VIDEO_TC` — Start TC assigned to the reference video; defaults to `01:00:00:00`.
- `SET_REFERENCE_VIDEO_TC` — whether to change the reference video's Start TC.
- `VIDEO_START_DATETIME_OVERRIDE` — optional video recording time in `YYYY-MM-DD HH:MM:SS` format. Set this if the video's metadata timestamp is missing or incorrect.

Timestamps are compared as camera-local wall-clock times. This assumes the photos and video were recorded in the same local timezone.

## Notes

- The project and reference video frame rates must match.
- The script changes Resolve Media Pool Start TC values only; it does not rewrite source metadata.
- If timestamps are missing or inconsistent, check the log and the source metadata before applying changes.
