# Zombs Recorder

A menu-bar app that only records ZombsRoyale matches. It has no detector, no decisions and no input. Each finished match is uploaded to your Kaggle account as a private dataset. On your Mac, `tools/training/ingest_recordings.py` pulls new matches into an annotation corpus with frozen whole-match splits and an annotation queue. From there, annotation (`annotate.py`) and Kaggle training (`dataset.py` → `kaggle_train.py`) work as before.

```
Any Mac                                  Kaggle (your account)            Your Mac
Zombs Recorder (menu bar)                one private dataset per match    ingest_recordings.py pull
  = start/stop → HEVC video       ──►    zombs-rec-<match id>       ──►   verify → frames → audit → split → queue
  uploads only between matches           recording.json + part-*.mov          ↓
                                                    annotate.py → dataset.py → kaggle_train.py push/pull
```

To set it up on a friend's Mac, build a [friend kit](#set-up-a-friends-mac).

## Build

Needs an Apple silicon or Intel Mac with macOS 14+ and Swift 6 Command Line Tools or Xcode.

```sh
bash ZombsRecorder/scripts/swift.sh test                     # unit tests (fake Kaggle, real hardware encode/decode)
ZOMBS_LIVE_KAGGLE=1 bash ZombsRecorder/scripts/swift.sh test --filter LiveKaggleTests
                                                             # optional: real Kaggle round trip with ~/.kaggle/access_token;
                                                             # creates and deletes a tiny private zrec-smoke-* dataset
bash ZombsRecorder/scripts/package.sh                        # dist/ZombsRecorder.app and dist/ZombsRecorder.zip (arm64 + x86_64)
bash ZombsRecorder/scripts/swift.sh build -c release --product zombs-extract   # frame extractor used by ingest
```

The app is ad-hoc signed, not notarized. Rebuilding changes its signature, so macOS may ask for Screen Recording permission again.

## Set up a friend's Mac

```sh
bash ZombsRecorder/scripts/make-friend-kit.sh        # → ZombsRecorder/dist/Zombs Recorder Kit.zip
```

The kit holds two things:
- `ZombsRecorder.app`, with your Kaggle setup code built in, so nobody pastes anything.
- `Setup Guide.html`, the step-by-step guide for the friend's Mac. It is also in the app's menu as **Setup guide**.

Get the zip onto the friend's Mac (AirDrop, USB stick or a private link) and follow the guide:
1. Drag the app into Applications.
2. Open it, approving it once under System Settings → Privacy & Security → **Open Anyway**.
3. In the setup window that opens, allow Screen Recording.
4. Check the red line on the game preview.
5. Press **=** in the game to record.

Copying the zip from a USB stick avoids the Open Anyway step, because macOS only flags files that were downloaded or AirDropped.

The kit script asks Kaggle whose token `~/.kaggle/access_token` is and embeds that token. Pass another token file to use a different one: `make-friend-kit.sh path/to/token`. **The kit contains the token, which gives full API access to your Kaggle account, so send it privately.** If Kaggle lets you create a second token, use one made just for friends. You can then revoke it without breaking `kaggle_train.py`. A kit built with a new token replaces the old one on the next launch.

## Set up your own Mac

The kit works here too. Alternatively, open `dist/ZombsRecorder.app`, and under **Setup… → Advanced** click **Use this Mac's Kaggle token**. Turn off **Delete the local video once Kaggle has it**, so ingest reads your recordings directly instead of downloading them again.

## Recording

- **Starting and stopping.** Choose Solo, Duo or Squad in the menu, click into the game, and press **=** about 10 s before joining a match. Press it again once you are back in the menu. Keep one match per recording.
  - **=** is claimed only while the ZombsRoyale Chrome window is in front, so it types normally in every other app and tab.
  - It needs no Accessibility permission (Carbon `RegisterEventHotKey`).
  - Presses within 1 s of each other are ignored.
  - Sounds: a tick means started, a pop means saved, a low bonk means it could not start. The menu says why.
- **First launch.** A setup window opens by itself until screen recording is allowed, uploads are set up and **Done** was clicked once. The name on recordings defaults to the Mac's user name. There are no notification prompts.
- **What gets recorded.** Only the game area of the largest Chrome window whose title contains "zombs" and "royale". The area below the top inset is cropped by ScreenCaptureKit, so tabs, the address bar and bookmarks are never captured.
  - Frames are recorded only while that window still shows ZombsRoyale.
  - Changing tab pauses recording within 0.25 s.
- **Format.** Up to 30 FPS at the display's pixel scale, capped at 3840 px.
  - Your window gives 3840×1736, the same as the existing corpus.
  - Hardware HEVC, falling back to hardware H.264, at about 0.08 bit/pixel/frame: about 16 Mbps or 120 MB/min at 3840×1736.
  - The app refuses to record if the Mac has no hardware encoder rather than encoding in software.
- **Low load.**
  - Frames go from the capture straight to the media engine, with no CPU image conversion and no preview.
  - During a recording, the window is checked 4 times a second.
  - The **=** key checks which window is in front twice a second, only while Chrome is the front app (about 0.6 ms per check).
  - When the encoder is busy, frames are dropped instead of queued.
- **Resizing.** Resizing the window mid-match continues the same match in `part-001.mov`, and so on. A match is never split into two IDs, which would risk leaking across splits.
- **Automatic stops.** The match is saved if the window is gone or off the game page for 10 s, or after 45 min. Recordings under 20 s are discarded as accidental starts.
- **Crash safety.** The movie is written in 10-second fragments. After a crash or force quit, the next launch rebuilds `recording.json` from what was written, with `endReason: "recovered"`.

### Files

Everything is under `~/Library/Application Support/ZombsRecorder/`, in a private (0700) folder:

```
credentials.json                 {owner, token}, 0600
matches/<matchID>/               matchID as in ZombsAssistant, e.g. 2026-10-06T19-02-11Z-4C1A9E
  recording-start.json           written at start; used to recover after a crash
  part-000.mov …                 the video
  recording.json                 written last and atomically: its presence means the match is finished
  upload.json                    upload progress (blob tokens, resumable URLs, bytes sent, dataset ref)
```

`recording.json`:

```json
{"schema": 1, "matchID": "…", "mode": "duo", "teammates": [], "recordedBy": "alex", "recorderVersion": "0.1.0",
 "createdAt": "…", "endedAt": "…", "endReason": "hotkey|menu|window-closed|max-duration|error|recovered",
 "capture": {"fps": 30, "codec": "hevc", "bitrate": 15998976, "topInsetPoints": 87, "scale": 2},
 "parts": [{"file": "part-000.mov", "width": 3840, "height": 1736, "frames": 13480, "startSeconds": 0,
            "durationSeconds": 449.3, "bytes": 898123456, "sha256": "…"}], "complete": true}
```

### Uploads

Each match becomes one private dataset named `zombs-rec-<lowercased match id>`, containing the parts and `recording.json`.

- **API.** The calls mirror the installed kagglesdk:
  - `IntrospectToken` checks the token.
  - `StartBlobUpload`, then resumable 8 MiB PUTs to the returned Google upload URL.
  - `CreateDataset`, then `GetDatasetStatus` until it reports `READY`.
- **Pacing.**
  - One match uploads at a time, oldest first.
  - Every request waits while a match is being recorded, so uploads never compete with the game's network.
  - Interrupted uploads resume from the byte the server confirmed.
- **Errors.**
  - A rejected token stops uploads until a new setup code is entered.
  - Other permanent errors mark only that match as failed; use **Retry failed uploads** in the menu.
- **Kaggle quirks**, both covered by tests:
  - Kaggle sets a session cookie that makes later API calls fail with 401, so the app never stores cookies.
  - A dataset that does not exist returns 403.

## Ingest, annotate and train on your Mac

Run in the project `.venv`, which has the kaggle package and Pillow. Nothing here trains locally.

```sh
# Once: a new corpus. --seed symlinks the existing Solo sessions and keeps their frozen splits,
# without changing data/solo-pilot-v2 or its input lock.
.venv/bin/python tools/training/ingest_recordings.py init data/recorder-corpus \
  --seed data/solo-recordings-v2 --seed-plan data/solo-pilot-v2/split-plan.json

# Whenever you want new matches (from Kaggle, plus finished recordings on this Mac):
.venv/bin/python tools/training/ingest_recordings.py pull data/recorder-corpus

# Annotate (restart after each pull; annotate.py loads frames at startup):
python3 tools/training/annotate.py data/recorder-corpus --queue data/recorder-corpus/annotation-queue.json

# Export and train on Kaggle as before, with a plan for the modes you export:
.venv/bin/python tools/training/ingest_recordings.py plan data/recorder-corpus --modes duo -o data/recorder-corpus/plan-duo.json
python3 tools/training/dataset.py data/recorder-corpus data/dataset-rec-duo-<date> --modes duo \
  --split-plan data/recorder-corpus/plan-duo.json --reviewed-snapshot
```

For each new match, `pull`:

1. **Fetches** it into `data/recorder-raw/<matchID>/`. A local copy is an APFS clone; otherwise it downloads from Kaggle.
2. **Checks** `complete` and every part's size and SHA-256. A mismatch skips the match and leaves the corpus untouched.
3. **Extracts** frames at 5 FPS with `zombs-extract` (`--fps` changes this):
   - Decoding uses the hardware decoder with BT.709 full-range conversion.
   - Frames are saved as JPEG at quality 0.95 with ImageIO, the same as ZombsAssistant's recorder.
   - Images are named by the frame's index in the whole video, so denser windows can be extracted later.
   - The extractor runs at low priority.
4. **Writes the session** in ZombsAssistant's format, so `annotate.py`, `dataset.py` and `audit_recordings.py` read it unchanged:
   - `session.json`, `frames.jsonl` and `images/NNNNNN.jpg`
   - empty `observations.jsonl` and `decisions.jsonl`
5. **Audits** the session with `audit_recordings.py` into `audits/<matchID>.json`. The session moves into the corpus only if the audit passes.
6. **Freezes the split** in append-only `split-assignments.json`. Each mode first fills any missing train, val or test split, in that order. After that, `sha256(matchID)` decides with 70/15/15. The split is decided from metadata before any review and never moved. `split-plan.json` is regenerated for `scene_coverage.py`.
7. **Queues frames** in `annotation-queue.json`: 12 evenly spaced anchors per match (the v2 rule), plus `--per-match N` extra frames.
8. **Writes a contact sheet** to `contact-sheets/<matchID>.jpg` and records the match in `ingest-log.json`.

Running `pull` again skips matches that are already ingested. A run that stops partway is repaired on the next run without duplicate queue entries.

**Video retention:**
- By default each downloaded video is deleted once its frames are extracted and Kaggle holds a copy; `--keep-video` keeps it.
- `--delete-remote` deletes each Kaggle dataset after ingest, and is allowed only while the local video is kept, so one copy always survives.
- Watch Kaggle's private-dataset storage quota.

`dataset.py --split-plan` requires the plan's modes to equal the exported modes, which is why `plan` writes one per mode set. For release exports that require every planned match, add `--annotated-only`.

## Code

- `Sources/RecorderCore`: models, match IDs and slugs, capture geometry and bitrate, the movie writer, the frame extractor, crash recovery, the Kaggle client, resumable upload and the upload queue.
- `Sources/ZombsRecorder`: the menu-bar app (ScreenCaptureKit capture, Carbon hotkey, settings).
- `Sources/ZombsExtract`: `zombs-extract RECORDING OUTPUT [--fps 5]`, and `zombs-extract --info MOVIE` for size, frames, duration, bitrate and SHA-256.
- `Tests/RecorderCoreTests`: Swift Testing. Python tests for ingest are in `tools/training/test_ingest_recordings.py`.
