# WhisperSRT

macOS native GUI app that transcribes audio/video to SRT subtitles using [whisper.cpp](https://github.com/ggerganov/whisper.cpp).

## Features

- **Drag & drop** — drop MP3 or MP4 files directly onto the window
- **Browse** — pick files or folders via native open panel
- **Real-time captions** — live subtitle preview while processing
- **Batch conversion** — queue multiple files
- **Auto language detection** — or pick manually (en/zh/ja/ko/fr/de/es/it/pt/ru)
- **MP4 support** — automatically extracts audio track via `afconvert` before transcribing

## Requirements

- macOS 14.0+
- [whisper-cli](https://github.com/ggerganov/whisper.cpp) installed via Homebrew:
  ```
  brew install whisper-cpp
  ```
- A Whisper model (default: `~/whisper.cpp/models/ggml-large-v3.bin`)

## Build

```bash
git clone https://github.com/cszwdy/WhisperSRT.git
cd WhisperSRT
./build.sh
open WhisperSRT.app
```

## Usage

1. Drop MP3/MP4 files or click **Browse…**
2. Optionally select language or keep auto-detect
3. Click **Convert to SRT**
4. SRT files are saved alongside the original files (`file.mp3` → `file.srt`)

## How it works

```
MP3 → whisper-cli → file.srt
MP4 → afconvert → temp.wav → whisper-cli → file.srt  (temp files cleaned up)
```
