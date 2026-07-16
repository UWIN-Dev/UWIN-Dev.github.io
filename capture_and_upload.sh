#!/bin/bash
#
# capture_and_upload.sh
# NASA Grow Beyond Earth / UWIN Astronomy Camp 2026
#
# Captures one image from a USB webcam (e.g. Logitech C920), saves it into
# a local clone of the project's GitHub Pages repo, regenerates the image
# manifest, rebuilds the timelapse GIF, and pushes the update to GitHub.
#
# Designed to run once a day (via cron, see setup instructions) for an
# unattended 6-month deployment. Includes locking, logging, retries, and
# camera warm-up so it can run reliably without anyone watching it.
#
# ---------------------------------------------------------------------------
# CONFIGURATION - edit these values for your setup
# ---------------------------------------------------------------------------

# Absolute path to your local clone of the GitHub Pages repo
REPO_DIR="/home/pi/grow-beyond-earth"

# Subfolder inside the repo where daily images are stored
IMAGES_SUBDIR="images"

# Video device for the webcam (check with: v4l2-ctl --list-devices)
VIDEO_DEVICE="/dev/video0"

# Image resolution (C920 supports up to 1920x1080; 1280x720 keeps repo size
# reasonable over a 6-month run)
RESOLUTION="1280x720"

# Number of throwaway frames to let the camera auto-exposure/focus settle
WARMUP_FRAMES=5

# Git branch to push to
GIT_BRANCH="main"

# Log file (rotated manually or via logrotate, see README)
LOG_FILE="/home/pi/grow-beyond-earth/capture.log"

# Timelapse GIF settings
TIMELAPSE_FILE="timelapse.gif"     # written to repo root
TIMELAPSE_FPS=6                    # playback speed of the GIF
TIMELAPSE_WIDTH=640                # scaled width, keeps GIF size reasonable

# ---------------------------------------------------------------------------
# END CONFIGURATION
# ---------------------------------------------------------------------------

set -u
LOCK_FILE="/tmp/grow_beyond_earth_capture.lock"
DATE_STAMP="$(date +%Y-%m-%d)"
TIME_STAMP="$(date +%H:%M:%S)"
IMAGE_NAME="${DATE_STAMP}.jpg"
IMAGES_DIR="${REPO_DIR}/${IMAGES_SUBDIR}"
MANIFEST_FILE="${REPO_DIR}/data/manifest.json"
TIMELAPSE_PATH="${REPO_DIR}/${TIMELAPSE_FILE}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Prevent overlapping runs (e.g. if a previous run is still retrying a push)
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "Another capture is already running. Exiting."
    exit 1
fi

log "=== Starting daily capture for $DATE_STAMP ==="

# --- Sanity checks ---------------------------------------------------------

if [ ! -d "$REPO_DIR/.git" ]; then
    log "ERROR: $REPO_DIR is not a git repo. Aborting."
    exit 1
fi

if [ ! -e "$VIDEO_DEVICE" ]; then
    log "ERROR: Camera device $VIDEO_DEVICE not found. Is the webcam plugged in? Aborting."
    exit 1
fi

mkdir -p "$IMAGES_DIR"
mkdir -p "$(dirname "$MANIFEST_FILE")"

# --- Capture -----------------------------------------------------------

# fswebcam skips a few frames itself, but we also loop to give a cheap
# webcam extra time to settle exposure/white balance/focus.
CAPTURE_OK=0
for attempt in 1 2 3; do
    if fswebcam -d "$VIDEO_DEVICE" \
                --resolution "$RESOLUTION" \
                --skip "$WARMUP_FRAMES" \
                --no-banner \
                --jpeg 85 \
                "${IMAGES_DIR}/${IMAGE_NAME}" >> "$LOG_FILE" 2>&1; then
        CAPTURE_OK=1
        break
    else
        log "Capture attempt $attempt failed. Retrying in 10s..."
        sleep 10
    fi
done

if [ "$CAPTURE_OK" -ne 1 ]; then
    log "ERROR: All capture attempts failed for $DATE_STAMP. Aborting."
    exit 1
fi

log "Captured ${IMAGE_NAME}"

# --- Regenerate manifest.json ----------------------------------------------
# Simple JSON array of image filenames, newest first, used by index.html.

python3 - "$IMAGES_DIR" "$MANIFEST_FILE" <<'PYEOF'
import json
import os
import sys

images_dir, manifest_file = sys.argv[1], sys.argv[2]

files = sorted(
    (f for f in os.listdir(images_dir) if f.lower().endswith((".jpg", ".jpeg", ".png"))),
    reverse=True,  # newest date first, since filenames are YYYY-MM-DD.jpg
)

with open(manifest_file, "w") as fh:
    json.dump(files, fh, indent=2)
    fh.write("\n")
PYEOF

if [ $? -ne 0 ]; then
    log "ERROR: Failed to regenerate manifest.json. Aborting before commit."
    exit 1
fi

log "Regenerated manifest.json (entries: $(python3 -c "import json;print(len(json.load(open('$MANIFEST_FILE'))))"))"

# --- Rebuild timelapse GIF ---------------------------------------------
# Uses ffmpeg to stitch every image in the images/ folder, oldest-first,
# into a looping GIF. Requires: sudo apt install ffmpeg

if command -v ffmpeg >/dev/null 2>&1; then
    CONCAT_LIST="$(mktemp)"
    # oldest first for a natural forward-playing timelapse
    for f in $(ls "$IMAGES_DIR" | sort); do
        echo "file '${IMAGES_DIR}/${f}'" >> "$CONCAT_LIST"
        echo "duration 0.2" >> "$CONCAT_LIST"
    done
    # ffmpeg's concat demuxer needs the last file listed twice (no duration
    # after the final entry) to avoid dropping the last frame
    LAST_FILE=$(ls "$IMAGES_DIR" | sort | tail -n 1)
    echo "file '${IMAGES_DIR}/${LAST_FILE}'" >> "$CONCAT_LIST"

    TMP_GIF="$(mktemp --suffix=.gif)"
    if ffmpeg -y -f concat -safe 0 -i "$CONCAT_LIST" \
        -vf "fps=${TIMELAPSE_FPS},scale=${TIMELAPSE_WIDTH}:-1:flags=lanczos" \
        "$TMP_GIF" >> "$LOG_FILE" 2>&1; then
        mv "$TMP_GIF" "$TIMELAPSE_PATH"
        log "Rebuilt timelapse.gif"
    else
        log "WARNING: ffmpeg failed to build timelapse.gif. Continuing without updating it."
        rm -f "$TMP_GIF"
    fi
    rm -f "$CONCAT_LIST"
else
    log "WARNING: ffmpeg not installed, skipping timelapse rebuild. Install with: sudo apt install ffmpeg"
fi

# --- Commit & push -----------------------------------------------------

cd "$REPO_DIR" || { log "ERROR: cannot cd into $REPO_DIR"; exit 1; }

git add "${IMAGES_SUBDIR}/${IMAGE_NAME}" data/manifest.json
[ -f "$TIMELAPSE_PATH" ] && git add "$TIMELAPSE_FILE"

if git diff --cached --quiet; then
    log "No changes to commit (unexpected — image should be new). Skipping push."
    exit 0
fi

git commit -m "Daily image: ${DATE_STAMP} ${TIME_STAMP}" >> "$LOG_FILE" 2>&1

# Retry push a few times in case of transient network issues or a remote
# that moved on (e.g. someone manually edited the repo).
PUSH_OK=0
for attempt in 1 2 3; do
    git pull --rebase origin "$GIT_BRANCH" >> "$LOG_FILE" 2>&1
    if git push origin "$GIT_BRANCH" >> "$LOG_FILE" 2>&1; then
        PUSH_OK=1
        break
    else
        log "Push attempt $attempt failed. Retrying in 30s..."
        sleep 30
    fi
done

if [ "$PUSH_OK" -ne 1 ]; then
    log "ERROR: Failed to push after 3 attempts. Commit is saved locally; will retry next run."
    exit 1
fi

log "=== Successfully pushed ${IMAGE_NAME} (and timelapse.gif) to $GIT_BRANCH ==="
exit 0
