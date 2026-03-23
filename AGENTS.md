# AGENTS.md

This file is the working memory for agents operating in this repository. Read it before making changes.

## Project Summary

- Project name: `cuecast`
- Goal: native macOS CLI that records internet radio streams to `./records` without transcoding.
- Recording behavior: write incoming bytes exactly as received, rotate files when stream metadata title changes.
- Filename shape: `YYYY-MM-DD_<station>_<title>.<ext>`
- Primary use case: long-running DJ/radio recordings where metadata changes define segment boundaries.

## Stack

- Language: Swift 6
- Build tool: Swift Package Manager
- Entry points:
  - `./cuecast ...` from repo root
  - `swift run cuecast ...`
- The repo-root `cuecast` script builds and runs the release binary from `.build/release/cuecast`.

## Current Status

Implemented:

- Direct HTTP stream recording
- ICY metadata request and parsing (`Icy-MetaData: 1`)
- Metadata-driven file splitting based on `StreamTitle`
- Playlist resolution for `.pls`, `.m3u`, `.m3u8`, `.asx`
- Live TTY dashboard with runtime/title/codec/bitrate/progress
- Live disk-space display in the dashboard
- MP3 ID3 tagging on finalized segments
- `retag` command for rebuilding MP3 tags later from JSONL manifests
- Session manifest written as `.jsonl`, one entry per segment
- Graceful shutdown on `SIGINT` / `SIGTERM`
- Disk-space safety checks with early-stop reserve

Important behavior:

- `Ctrl-C` should now cancel recording gracefully, flush pending bytes, close the current file, finalize the manifest, restore the terminal, and exit cleanly.
- A second `Ctrl-C` forces exit.
- `SIGKILL` cannot be handled.
- Disk space is checked before recording starts and during recording.
- Current built-in thresholds: warn below 2 GB free, stop below 1 GB free.
- Finalized MP3 files are now rewritten with ID3 tags after the segment closes.
- MP3 tagging is currently default-on, with `--no-embed-tags` intended as the opt-out path.
- `retag` can backfill/rebuild MP3 tags from existing session manifests.
- Artwork embedding is best-effort from TuneIn metadata when the input URL exposes a station identifier.
- Active files are written with a `_recording` suffix and only become a clean final name after the next metadata boundary.
- If recording stops before the next metadata/title change, the last segment is renamed with `_partial`.
- Do not commit personal station names, direct stream URLs, service-specific station IDs, or local absolute paths.
- The dashboard progress scale is visual only. It does not trigger segment splits.
- Segment splits happen only when metadata title changes.

## Key Files

- `Package.swift`: package definition
- `cuecast`: repo-root launcher script
- `README.md`: user-facing overview
- `LICENSE`: MIT license for public distribution
- `SECURITY.md`: vulnerability reporting policy
- `CONTRIBUTING.md`: contributor workflow and guardrails
- `CONTRIBUTORS.md`: maintainer/contributor listing
- `.github/workflows/ci.yml`: GitHub Actions build check
- `.github/dependabot.yml`: dependency and Actions update policy
- `.github/pull_request_template.md`: PR checklist and change framing
- `.github/ISSUE_TEMPLATE/*`: public issue intake templates

Core runtime:

- `Sources/cuecast/cuecast.swift`: main entrypoint and shutdown wiring
- `Sources/cuecast/CLI.swift`: CLI parsing
- `Sources/cuecast/StreamRecorder.swift`: recording orchestration
- `Sources/cuecast/RecordingSink.swift`: current file management and rotation
- `Sources/cuecast/IcyStreamParser.swift`: ICY parser
- `Sources/cuecast/StreamMetadata.swift`: metadata model/parser
- `Sources/cuecast/FileNamer.swift`: slugification and file naming
- `Sources/cuecast/ContentType.swift`: codec/content header extraction
- `Sources/cuecast/PlaylistResolver.swift`: playlist resolution
- `Sources/cuecast/TerminalUI.swift`: live terminal dashboard
- `Sources/cuecast/SegmentManifest.swift`: JSONL segment log
- `Sources/cuecast/ShutdownMonitor.swift`: signal handling
- `Sources/cuecast/DiskSpaceMonitor.swift`: free-space checks and thresholds
- `Sources/cuecast/MP3TagWriter.swift`: ID3 embedding for finalized MP3 segments
- `Sources/cuecast/ArtworkResolver.swift`: best-effort artwork lookup for supported sources
- `Sources/cuecast/Retagger.swift`: rebuild tags later from manifests or recorded files
- `Sources/cuecast/Logger.swift`: logging abstraction

## Privacy

- Keep examples generic: use `example.com`, `Station-Name`, `Artist-Track-Title`, and similar placeholders.
- Do not add real station names, direct stream URLs, personal listening habits, service-specific station IDs, or local absolute paths to docs or committed tests.
- If debugging a live stream locally, do it outside committed files.

## Data Output

Output directory:

- Default: `./records`

Files produced:

- segment audio files, original codec/container preserved
- session manifest file ending in `_session-manifest.jsonl`

Manifest entries currently include:

- source URL
- resolved URL
- station metadata
- codec / bitrate / sample rate / content type
- split count
- segment start/end/duration
- file name
- title
- raw metadata fields

## Operational Notes

- This repo may contain real recordings in `records/`; do not delete user captures casually.
- `--quiet` disables live dashboard/log noise.
- The dashboard uses ANSI styling and is intended for 256-color / truecolor terminals like Ghostty.
- The terminal UI hides the cursor while active and restores it on clean shutdown.
- GitHub repo automation now includes CI, Dependabot, vulnerability alerts, and automated security fixes.
- Direct push protection on `main` is not currently enforceable on this private repo because GitHub branch protection is unavailable on the current plan.
- Repo merge policy is now squash-only, and GitHub Projects are disabled to reduce public clutter.
- Secret scanning is not currently available on this private repo; re-check availability after switching the repository to public.

## Common Commands

Build:

```bash
swift build
```

Run:

```bash
./cuecast --help
./cuecast "https://example.com/live.mp3"
./cuecast retag ./records
```

Typical development smoke test:

```bash
./cuecast "https://example.com/live.mp3"
```

Then stop with `Ctrl-C` and confirm:

- the current audio file exists and is playable
- the manifest file contains a final entry
- the terminal cursor/state is restored

## Gaps / Next Likely Work

- Add automated tests or integration fixtures if this Swift toolchain supports a test module in the environment.
- Add optional richer stream discovery for TuneIn or service-specific sources.
- Consider optional `--monitor` playback mode if local listening is desired while recording.
- Consider future pause/stop/start semantics carefully:
  - `stop` is straightforward
  - `pause` for live radio is a product decision, not just a transport toggle
  - resuming after pause should likely create a new segment

## Ideas

- Optional monitor/playback mode on the default audio device while recording.
- Compact/detail/help dashboard layouts with stronger visual hierarchy and better long-title handling.
- Configurable disk safety thresholds instead of built-in 2 GB warn / 1 GB stop values.
- Optional disable flag for manifest writing if a user wants audio files only.
- Optional disable flag for MP3 tag embedding if a user wants untouched saved MP3 files.
- Better artist/title parsing heuristics for DJ mix streams.
- Optional sidecar export formats beyond JSONL, for example CSV or a richer JSON session file.
- More stream discovery help for TuneIn-like services and browser/player sourced URLs.
- Optional post-record hooks for organizing files into library folders.
- Playback/record controls beyond `q` and `c`, once monitor mode exists.

## Agent Guidance

- Do not change the core rule that files split on metadata title changes unless explicitly requested.
- Preserve “record without transcoding” as a core invariant.
- When adjusting the dashboard, avoid implying time-based auto-cut behavior.
- Keep repository text and examples privacy-safe and generic.
