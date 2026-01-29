#!/bin/sh
# overlay-space-manager by pp4mnk
# EasyOS Overlay Space Manager (GUI via YAD + CLI)
# Features:
#  - Status (real overlay usage)
#  - Safe-ish cache cleanup
#  - Move heavy /root folders outside overlay (symlinks)
#  - Watch mode: auto-warning at 85%
#
# Works with /bin/sh (ash), POSIX-safe.

set -u

MOUNTPOINT="/"
DEFAULT_TARGET="/mnt/home/EasyData"
WARN_PERCENT=85
CHECK_INTERVAL=60   # seconds (watch mode)

# Icon files used in buttons (existing in your system)
ICON_STATUS="/usr/share/pixmaps/apps48.png"
ICON_CLEAN="/usr/share/pixmaps/archive48.png"
ICON_MOVE="/usr/share/pixmaps/card_mntd48.png"
ICON_QUIT="/usr/share/pixmaps/apps48.png"

APP_ICON="/usr/share/pixmaps/overlay-space-manager.svg"
LOCK_FILE="/tmp/overlay-space-watch.lock"
STATE_FILE="/tmp/overlay-space-watch.state"

say() { printf "%s\n" "$*"; }
die() { say "ERROR: $*"; exit 1; }

need_root() {
  [ "$(id -u 2>/dev/null)" = "0" ] || die "This tool needs root (EasyOS usually runs as root)."
}

have_yad() { command -v yad >/dev/null 2>&1; }

df_line() { df -kP "$MOUNTPOINT" 2>/dev/null | awk 'NR==2'; }

get_usage_percent() {
  USEP="$(df_line | awk '{print $5}')"
  P="$(echo "$USEP" | tr -d '%')"
  case "$P" in
    ''|*[!0-9]*) echo ""; return 1 ;;
  esac
  echo "$P"
}

status_text() {
  DFL="$(df_line)"
  [ -n "$DFL" ] || die "df failed for $MOUNTPOINT"

  FS="$(echo "$DFL" | awk '{print $1}')"
  SIZE="$(echo "$DFL" | awk '{print $2}')"
  USED="$(echo "$DFL" | awk '{print $3}')"
  AVAIL="$(echo "$DFL" | awk '{print $4}')"
  USEP="$(echo "$DFL" | awk '{print $5}')"

  FREE_MB=$((AVAIL / 1024))
  PERCENT="$(echo "$USEP" | tr -d '%')"

  printf "EasyOS writable layer (overlay) — mount: %s\n" "$MOUNTPOINT"
  printf "------------------------------------------------------\n"
  printf "Filesystem : %s\n" "$FS"
  printf "Total      : %d MB\n" $((SIZE / 1024))
  printf "Used       : %d MB\n" $((USED / 1024))
  printf "Available  : %d MB\n" "$FREE_MB"
  printf "Usage      : %s\n" "$USEP"
  printf "\n"

  case "$PERCENT" in
    ''|*[!0-9]*) printf "NOTE: Cannot parse usage percent (%s)\n" "$USEP" ;;
    *)
      if [ "$PERCENT" -ge 95 ]; then
        printf "CRITICAL: Overlay is almost FULL.\n"
      elif [ "$PERCENT" -ge "$WARN_PERCENT" ]; then
        printf "WARNING: Overlay usage is high (>= %d%%).\n" "$WARN_PERCENT"
      else
        printf "OK: Overlay usage is fine.\n"
      fi
      ;;
  esac

  if command -v du >/dev/null 2>&1; then
    printf "\nTop heavy paths under /root (approx):\n"
    printf "-----------------------------------\n"
    du -x -d 2 /root 2>/dev/null | sort -nr | head -n 12 | awk '
      { kb=$1; $1=""; sub(/^ /,"");
        if (kb>=1048576) printf "%.2f GB\t%s\n", kb/1048576, $0;
        else if (kb>=1024) printf "%.1f MB\t%s\n", kb/1024, $0;
        else printf "%d KB\t%s\n", kb, $0;
      }'
  fi
}

safe_rm_dir() {
  D="$1"
  [ -d "$D" ] || return 0
  [ -n "$D" ] || return 0
  rm -rf "$D"/* "$D"/.[!.]* "$D"/..?* 2>/dev/null
}

clean_overlay() {
  need_root

  # Browsers (if present)
  safe_rm_dir "/root/.cache/mozilla"
  safe_rm_dir "/root/.cache/chromium"
  safe_rm_dir "/root/.cache/google-chrome"
  safe_rm_dir "/root/.cache/slimjet"
  safe_rm_dir "/root/.cache/BraveSoftware"
  safe_rm_dir "/root/.cache/opera"
  safe_rm_dir "/root/.cache/microsoft-edge"

  # Thumbnails / caches
  safe_rm_dir "/root/.cache/thumbnails"
  safe_rm_dir "/root/.cache/fontconfig"
  safe_rm_dir "/root/.cache/mesa_shader_cache"
  safe_rm_dir "/root/.cache"

  # Trim logs (safe-ish)
  if [ -d /var/log ]; then
    find /var/log -type f -name "*.log" -size +1M -exec sh -c ': > "$1"' _ {} \; 2>/dev/null
    find /var/log -type f -name "*.gz" -delete 2>/dev/null
    find /var/log -type f -name "*.old" -delete 2>/dev/null
  fi

  # Trash
  safe_rm_dir "/root/.local/share/Trash/files"
  safe_rm_dir "/root/.local/share/Trash/info"
}

ensure_target() {
  T="$1"
  [ -n "$T" ] || die "Empty destination."
  mkdir -p "$T" || die "Cannot create destination: $T"
  [ -d "$T" ] || die "Destination is not a directory: $T"
}

move_one() {
  SRC="$1"
  DSTROOT="$2"
  NAME="$(basename "$SRC")"
  DST="$DSTROOT/$NAME"

  [ -e "$SRC" ] || return 0
  [ -L "$SRC" ] && return 0

  # avoid overwrite
  if [ -e "$DST" ]; then
    TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
    DST="${DSTROOT}/${NAME}-${TS}"
  fi

  mv "$SRC" "$DST" || die "Move failed: $SRC -> $DST"
  ln -s "$DST" "$SRC" || die "Symlink failed: $SRC -> $DST"
}

move_out() {
  need_root
  TARGET="${1:-$DEFAULT_TARGET}"
  ensure_target "$TARGET"

  move_one "/root/Downloads" "$TARGET"
  move_one "/root/Video"     "$TARGET"
  move_one "/root/Videos"    "$TARGET"
  move_one "/root/Pictures"  "$TARGET"
  move_one "/root/Music"     "$TARGET"
  move_one "/root/Documents" "$TARGET"
  move_one "/root/Backup"    "$TARGET"
  move_one "/root/Backups"   "$TARGET"
}

# ---- GUI helpers ----
gui_text() {
  TITLE="$1"
  TEXT="$2"
  # text-info (monospace) works well on EasyOS
  yad --title="$TITLE" --center --width=760 --height=520 \
      --text-info --wrap --fontname="monospace 10" \
      --button="OK:0" <<EOF
$TEXT
EOF
}

gui_pick_folder() {
  yad --title="Pick a destination OUTSIDE the overlay" --center \
      --file-selection --directory --filename="$DEFAULT_TARGET/"
}

gui_confirm() {
  yad --title="Confirm" --center --question --text="$1"
}

gui_main() {
  have_yad || die "yad not found. Install yad or use CLI mode."
  while :; do
    yad --title="EasyOS Overlay Space Manager" --center --width=560 \
      --text="Manage writable overlay space (what REALLY limits /root).\n\nChoose:" \
      --image="$APP_ICON" --image-on-top \
      --button="Status!$ICON_STATUS:10" \
      --button="Clean caches!$ICON_CLEAN:20" \
      --button="Move /root folders out!$ICON_MOVE:30" \
      --button="Quit!$ICON_QUIT:0"
    RC="$?"
    [ "$RC" -eq 0 ] && exit 0

    case "$RC" in
      10) gui_text "Overlay status" "$(status_text)" ;;
      20)
        if gui_confirm "This removes common caches and empties Trash.\n\nContinue?"; then
          clean_overlay
          gui_text "Cleanup done" "$(status_text)"
        fi
        ;;
      30)
        DEST="$(gui_pick_folder)"
        [ -z "${DEST:-}" ] && continue
        if gui_confirm "Will move typical heavy folders from /root to:\n\n$DEST\n\nThen create symlinks.\n\nContinue?"; then
          move_out "$DEST"
          gui_text "Move done" "$(status_text)"
        fi
        ;;
    esac
  done
}

# ---- Watch mode (auto warning) ----
notify_warn() {
  P="$1"
  MSG="Overlay usage is ${P}% (>= ${WARN_PERCENT}%).\n\nFix: clean caches or move /root heavy folders outside overlay."

  if have_yad; then
    yad --title="Overlay WARNING" --center --on-top \
        --image="$APP_ICON" \
        --text="$MSG" \
        --button="Open Manager:0" \
        --timeout=12 --timeout-indicator=right \
        >/dev/null 2>&1
    # If user clicks button, open GUI
    if [ "$?" -eq 0 ]; then
      "$0" gui >/dev/null 2>&1 &
    fi
  else
    echo "WARNING: $MSG" >&2
  fi
}

watch_loop() {
  # crude lock to avoid multiple instances
  if [ -e "$LOCK_FILE" ]; then
    OLDPID="$(cat "$LOCK_FILE" 2>/dev/null || true)"
    if [ -n "${OLDPID:-}" ] && kill -0 "$OLDPID" 2>/dev/null; then
      exit 0
    fi
  fi
  echo $$ > "$LOCK_FILE" 2>/dev/null || true

  while :; do
    P="$(get_usage_percent 2>/dev/null || true)"
    if [ -n "${P:-}" ] && [ "$P" -ge "$WARN_PERCENT" ]; then
      LAST="$(cat "$STATE_FILE" 2>/dev/null || echo 0)"
      # only warn again if percent changed or state empty
      if [ "$LAST" != "$P" ]; then
        echo "$P" > "$STATE_FILE" 2>/dev/null || true
        notify_warn "$P"
      fi
    else
      # reset state when under threshold
      echo 0 > "$STATE_FILE" 2>/dev/null || true
    fi
    sleep "$CHECK_INTERVAL"
  done
}

usage() {
  cat <<EOF
EasyOS Overlay Space Manager

GUI:
  overlay-space-manager

CLI:
  overlay-space-manager status
  overlay-space-manager clean
  overlay-space-manager move [DEST]
  overlay-space-manager watch

Examples:
  overlay-space-manager status
  overlay-space-manager clean
  overlay-space-manager move /mnt/sda1/EasyData
  overlay-space-manager watch
EOF
}

CMD="${1:-gui}"
case "$CMD" in
  gui)    gui_main ;;
  status) status_text ;;
  clean)  clean_overlay; status_text ;;
  move)   move_out "${2:-$DEFAULT_TARGET}"; status_text ;;
  watch)  watch_loop ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
