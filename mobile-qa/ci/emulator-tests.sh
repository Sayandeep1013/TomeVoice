#!/usr/bin/env bash
# TomeVoice on a CI emulator: the Maestro flows in mobile-qa/flows/, then the
# Back test. The emulator-test job of .github/workflows/build.yml runs it once
# the emulator has booted; docs/13 §13.11 explains each check.
#
#   bash mobile-qa/ci/emulator-tests.sh <apk> <results-dir>
#
# Needs adb with one device and maestro on PATH. Every check runs even when an
# earlier one failed, and the exit status is non-zero if any did. Screenshots,
# Maestro output, dumpsys snapshots and logcat go to <results-dir>; a table of
# results goes to $GITHUB_STEP_SUMMARY.
#
# CI only: it clears the app's data before each flow. Never point it at a
# phone whose library matters.
set -u

apk=${1:?usage: emulator-tests.sh <apk> <results-dir>}
out=${2:?usage: emulator-tests.sh <apk> <results-dir>}
pkg=app.tomevoice
activity=tomevoice_spike.MainActivity
flows=$(cd "$(dirname "$0")/../flows" && pwd)
summary=${GITHUB_STEP_SUMMARY:-$out/summary.md}
mkdir -p "$out/maestro"
: > "$out/results.md"
failures=0

dev() { adb shell "$@" 2>&1 | tr -d '\r'; }

# result PASS|FAIL|WARN|INFO <check> <detail>. Only FAIL fails the run.
result() {
  printf '| %s | %s | %s |\n' "$2" "$1" "$3" >> "$out/results.md"
  case $1 in
    FAIL)
      failures=$((failures + 1))
      echo "::error title=$2 (API $api)::$2: $3"
      ;;
    WARN) echo "::warning title=$2 (API $api)::$2: $3" ;;
    *) echo "$1 $2: $3" ;;
  esac
}

shot() { adb exec-out screencap -p > "$out/$1.png" 2>/dev/null || true; }

# flow <name>: mobile-qa/flows/<name>.yaml on an app with no data (as if just
# installed); succeeds if Maestro passed it.
flow() {
  local status
  adb shell pm clear "$pkg" > /dev/null
  # Whatever system dialog is up goes (an emulator's "isn't responding").
  adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS > /dev/null 2>&1 || true
  echo "::group::maestro test $1.yaml"
  timeout 600 maestro test --format junit --output "$out/maestro/$1.xml" --test-output-dir "$out/maestro/$1" "$flows/$1.yaml" 2>&1 | tee "$out/maestro/$1.log"
  status=${PIPESTATUS[0]}
  echo "::endgroup::"
  shot "$1"
  return "$status"
}

# check <flow> <check> <passed> <failed>
check() {
  if flow "$1"; then
    result PASS "$2" "$3"
  else
    result FAIL "$2" "$4"
    return 1
  fi
}

# MainActivity's "<state> <finishing>" in a dumpsys activity activities, or
# nothing if no task holds it.
record_state() {
  awk -v act="$activity" '
    /[*] Task[{]/ { inrec = 0 }
    /Hist[[:space:]]+#[0-9]+:/ { inrec = index($0, act) > 0; next }
    inrec && match($0, /(^|[[:space:]])state=[A-Z_]+/) {
      s = substr($0, RSTART, RLENGTH); sub(/.*state=/, "", s)
      f = "unknown"
      if (match($0, /finishing=[a-z]+/)) f = substr($0, RSTART + 10, RLENGTH - 10)
      print s, f
      exit
    }' "$1"
}

# Whether a dumpsys activity activities names MainActivity as the resumed one
# (in the foreground).
resumed() { grep -qE "(^|[[:space:]])(topResumedActivity=|ResumedActivity: ).*$activity" "$1"; }

# TomeVoice's media session in a dumpsys media_session: "active=..., state=...".
media_state() {
  awk -v pkg="$pkg" '
    /package=/ { inpkg = index($0, "package=" pkg) > 0; next }
    inpkg && /active=/ { a = $0; sub(/^[[:space:]]+/, "", a) }
    inpkg && /state=PlaybackState/ {
      s = $0; sub(/.*PlaybackState [{]state=/, "", s); sub(/,.*/, "", s)
      print a ", state=" s
      exit
    }' "$1"
}

snapshot() {
  dev dumpsys activity activities > "$out/$1-activities.txt"
  dev dumpsys media_session > "$out/$1-media_session.txt"
  dev dumpsys activity services "$pkg" > "$out/$1-services.txt"
  dev am stack list > "$out/$1-stack-list.txt"
}

# TomeVoice's task in Recents (what a swipe there removes), or nothing: from
# am stack list ("taskId=23: app.tomevoice/..."), else dumpsys activity recents.
task_id() {
  local id
  id=$(dev am stack list | grep -oE "taskId=[0-9]+: $pkg/" | head -n 1 | grep -oE "[0-9]+" || true)
  if [ -z "$id" ]; then
    id=$(dev dumpsys activity recents | awk -v pkg="$pkg" '
      /Recent #[0-9]+: Task[{]/ { if (match($0, / #[0-9]+ /)) t = substr($0, RSTART + 2, RLENGTH - 3) }
      index($0, "realActivity=" pkg "/") { print t; exit }')
  fi
  echo "$id"
}

# Whether a dumpsys activity services shows ReadAloudService in the foreground.
foreground_service() {
  awk '/ServiceRecord[{].*ReadAloudService/ { s = 1; next } /ServiceRecord[{]/ { s = 0 } s && /isForeground=true/ { f = 1 } END { exit !f }' "$1"
}

# ---------------------------------------------------------------- the device

adb wait-for-device
api=$(dev getprop ro.build.version.sdk)
release=$(dev getprop ro.build.version.release)
echo "Device: Android $release (API $api), $(dev getprop ro.product.model)"
# Awake and unlocked for the whole run.
adb shell svc power stayon true || true
adb shell input keyevent KEYCODE_WAKEUP || true
adb shell wm dismiss-keyguard || true
adb shell settings put system screen_off_timeout 1800000 || true
# A busy CI emulator can leave a system app's "isn't responding" dialog over
# everything (the Pixel Launcher did, in one run). With this set, Android
# kills a process that stops responding instead of asking; TomeVoice
# crashing or hanging still fails a flow, and a crash shows in the crash log.
adb shell settings put global hide_error_dialogs 1 || true
# Room for a whole run's logs.
adb logcat -G 16M || true

if ! adb install -r "$apk"; then
  echo "::error title=Install (API $api)::adb install failed; nothing was tested"
  exit 1
fi

tts=$(dev cmd package query-services --brief -a android.intent.action.TTS_SERVICE | grep / | sed 's/^[[:space:]]*//' | paste -sd ' ' -)
result INFO "Text-to-speech engines" "${tts:-none} (default: $(dev settings get secure tts_default_synth))"

# ----------------------------------------------------------------- the flows

check library-starter "Starter book" "a fresh install shows Pride and Prejudice on the shelf" "Pride and Prejudice did not appear on a fresh install"
check open-reader "Open the book" "the book's page opens and Read shows the reader" "could not open the starter book in the reader"

# The flow takes a screenshot in landscape: proof the screen really turned.
if flow rotate-reader; then
  png=$(find "$out/maestro/rotate-reader" . -maxdepth 4 -name 'reader-landscape*.png' 2>/dev/null | head -n 1)
  size=$(python3 -c 'import struct, sys; print(*struct.unpack(">II", open(sys.argv[1], "rb").read(24)[16:24]))' "$png" 2>/dev/null)
  if [ -z "$size" ]; then
    result PASS "Rotation" "the reader is still showing after landscape and back to portrait (no landscape screenshot found to measure)"
  elif [ "${size% *}" -gt "${size#* }" ]; then
    result PASS "Rotation" "the reader is still showing after landscape (${size% *}x${size#* }) and back to portrait"
  else
    result FAIL "Rotation" "the screen never turned: the landscape screenshot is ${size% *}x${size#* }"
  fi
else
  result FAIL "Rotation" "the reader did not survive a rotation"
fi

check contents-sheet "Contents" "the reader's contents open and close" "the reader's contents did not open or close"
check reading-settings "Reading settings" "the sheet opens, and its Listen tab shows speed and the sleep timer" "the reading settings sheet failed"

# ------------------------------------------------------------- the Back test
#
# On a phone, Back on the library leaves the app. If that finishes
# MainActivity, its onDestroy stops the reading service, the player and TTS,
# and listening stops with it. It should only move the task to the back.
#
# back_test <id> <name> <FAIL|WARN>: TomeVoice is on its shelf (reading
# aloud, if this emulator has a TTS engine); press Back and judge what became
# of MainActivity, from the activity events and dumpsys. A destroyed activity
# is reported as <FAIL|WARN>. Files go to $out/<id>-*.
back_test() {
  local id=$1 name=$2 level=$3 before after pid destroyed detail line process
  local media_before media_after service_before service_after
  snapshot "$id-before"
  before=$(record_state "$out/$id-before-activities.txt")
  adb logcat -b events -c
  adb shell input keyevent KEYCODE_BACK
  sleep 5
  adb logcat -b events -d | tr -d '\r' > "$out/$id-events.txt"
  snapshot "$id-after"
  shot "$id-after-back"

  grep -E "wm_[a-z_]+: .*tomevoice" "$out/$id-events.txt" > "$out/$id-events-tomevoice.txt" || true
  after=$(record_state "$out/$id-after-activities.txt")
  pid=$(dev pidof "$pkg")
  destroyed=no
  if grep -qE "wm_(finish_activity|destroy_activity|on_destroy_called): .*$activity" "$out/$id-events-tomevoice.txt"; then
    destroyed=yes
  elif [ -z "$after" ] && ! grep -qE "wm_(stop_activity|on_stop_called): .*$activity" "$out/$id-events-tomevoice.txt"; then
    destroyed=yes
  fi

  if [ "${before%% *}" != RESUMED ] && ! resumed "$out/$id-before-activities.txt"; then
    detail="TomeVoice was not on screen to press Back on API $api (MainActivity: ${before:-no activity})"
    result FAIL "$name" "$detail"
  elif [ "$destroyed" = yes ]; then
    detail="activity destroyed on API $api"
    result "$level" "$name" "$detail"
  elif [ "${after%% *}" = RESUMED ] || resumed "$out/$id-after-activities.txt"; then
    detail="Back did not leave the app on API $api (MainActivity still resumed)"
    result FAIL "$name" "$detail"
  else
    detail="activity kept, moved to the back on API $api (MainActivity ${after:-state unknown})"
    result PASS "$name" "$detail"
  fi
  line="$name: $detail"
  echo "$line"

  media_before=$(media_state "$out/$id-before-media_session.txt")
  media_after=$(media_state "$out/$id-after-media_session.txt")
  service_before=$(grep -q ReadAloudService "$out/$id-before-services.txt" && echo running || echo "not running")
  service_after=$(grep -q ReadAloudService "$out/$id-after-services.txt" && echo running || echo "not running")
  if [ -n "$pid" ]; then process="alive (pid $pid)"; else process=gone; fi
  result INFO "$name, after Back" "process $process; MainActivity ${after:-has no activity record}; ReadAloudService $service_before before Back, $service_after after; media session ${media_before:-none} before, ${media_after:-none} after"

  {
    echo "**$line**"
    echo
    echo "TomeVoice's activity events after that Back (\`logcat -b events\`):"
    echo
    echo '```'
    cat "$out/$id-events-tomevoice.txt"
    echo '```'
    echo
  } >> "$out/back-evidence.md"
}
: > "$out/back-evidence.md"

# ------------------------------------------------------------ the Recents test
#
# The voice is the Flutter engine's, which outlives MainActivity while a book
# is read (ReadingCore.kt): a swipe from Recents must not stop it. A paused
# book is put away instead (ReadAloudService.onTaskRemoved), and a headset's
# Play with the app closed reads again (the session's media button receiver
# starts the service, which starts the engine at backgroundMain).
#
# remove_task <id>: TomeVoice's task removed as a swipe in Recents removes it
# (am stack remove calls the same removeTask). Files go to $out/<id>-*.
remove_task() {
  local task
  task=$(task_id)
  echo "$task" > "$out/$1-task.txt"
  [ -n "$task" ] || return 1
  adb logcat -b events -c
  dev am stack remove "$task" > "$out/$1-remove.txt"
  sleep 8
  adb logcat -b events -d | tr -d '\r' | grep -E "tomevoice|wm_task_removed" > "$out/$1-events.txt" || true
  snapshot "$1-after"
}

# swipe_test <id> <name> <FAIL|WARN>: TomeVoice reading aloud (back on the
# shelf after the Back test) is swiped from Recents; the voice must go on.
swipe_test() {
  local id=$1 name=$2 level=$3 before after pid service detail
  snapshot "$id-before"
  before=$(media_state "$out/$id-before-media_session.txt")
  case "$before" in
    *"state=3"*) ;;
    *)
      result WARN "$name" "not reading aloud before the swipe on API $api (media session ${before:-none}): nothing to judge"
      return
      ;;
  esac
  if ! remove_task "$id"; then
    result WARN "$name" "TomeVoice had no task in Recents to remove on API $api"
    return
  fi
  after=$(media_state "$out/$id-after-media_session.txt")
  pid=$(dev pidof "$pkg")
  service=$(foreground_service "$out/$id-after-services.txt" && echo "in the foreground" || echo "not in the foreground")
  detail="process ${pid:-gone}; ReadAloudService $service; media session $before before, ${after:-none} after (API $api)"
  if [ -n "$pid" ] && printf '%s' "$after" | grep -q "state=3"; then
    result PASS "$name" "still reading after the swipe: $detail"
  else
    result "$level" "$name" "the reading stopped with the swipe: $detail"
  fi
}

# paused_swipe_test <id> <name>: TomeVoice opened again onto the engine still
# reading (the activity rejoins it), the book paused with a media key, then
# swiped from Recents: the paused book is put away, the service leaves the
# foreground and the session stops playing or pausing.
paused_swipe_test() {
  local id=$1 name=$2 after service
  dev am start -n "$pkg/.$activity" > "$out/$id-start.txt"
  sleep 6
  shot "$id-rejoined"
  adb shell input keyevent KEYCODE_MEDIA_PAUSE
  sleep 4
  snapshot "$id-before"
  if ! remove_task "$id"; then
    result WARN "$name" "TomeVoice had no task in Recents to remove on API $api"
    return
  fi
  after=$(media_state "$out/$id-after-media_session.txt")
  service=$(foreground_service "$out/$id-after-services.txt" && echo "in the foreground" || echo "not in the foreground")
  if [ "$service" = "not in the foreground" ] && ! printf '%s' "$after" | grep -qE "state=(2|3)[^0-9]|state=(2|3)$"; then
    result PASS "$name" "put away: ReadAloudService $service, media session ${after:-gone} (API $api)"
  else
    result WARN "$name" "still up after a paused swipe: ReadAloudService $service, media session ${after:-none} (API $api)"
  fi
}

# headset_play_test <id> <name>: with the app closed and nothing reading, a
# headset's Play (KEYCODE_MEDIA_PLAY, dispatched by the system as a real one
# is) reads the book again, from its place.
headset_play_test() {
  local id=$1 name=$2 after pid
  adb shell input keyevent KEYCODE_MEDIA_PLAY
  sleep 20
  snapshot "$id-after"
  shot "$id-after"
  after=$(media_state "$out/$id-after-media_session.txt")
  pid=$(dev pidof "$pkg")
  if printf '%s' "$after" | grep -qE "state=(3|6)[^0-9]|state=(3|6)$"; then
    result PASS "$name" "reading again with the app closed: media session $after, process ${pid:-gone} (API $api)"
  else
    result WARN "$name" "not reading after Play: media session ${after:-none}, process ${pid:-gone} (API $api)"
  fi
}

# The reader's way: TomeVoice opened from the launcher. Android 16 moves the
# task to the back on Back only for an activity the home screen launched
# (ActivityClientController.shouldMoveTaskToBack), so this is the case that
# must keep reading.
if check listen-from-home "Open from the home screen, listen, back to the library" "the launcher opens TomeVoice; Listen, then its Back buttons, return to the shelf" "could not open TomeVoice from the launcher, listen and go back to the library"; then
  back_test home "BACK TEST" FAIL
  # Still reading, the app behind: swiped from Recents, it reads on; opened,
  # paused and swiped, it is put away; a headset's Play reads it again.
  swipe_test swipe "SWIPE TEST" FAIL
  paused_swipe_test swipe-paused "SWIPE TEST, paused"
  headset_play_test headset "HEADSET PLAY, app closed"
else
  result FAIL "BACK TEST" "not run on API $api: TomeVoice could not be opened from the launcher"
fi

# TomeVoice opened by another app instead (Maestro here; by the same rule,
# any start that is not from the home screen). Android 16 finished the
# activity on Back then too, until TomeVoice took Back at the root itself
# (MainActivity's back callback): a failure now.
if check listen-to-library "Listen, then back to the library" "Listen opens the reader; its Back to library and the book page's Back return to the shelf" "could not listen and go back to the library"; then
  back_test other "BACK TEST, opened by another app" FAIL
fi

# -------------------------------------------------------------- Open with
#
# Open with and Share land on OpenActivity, which hands the file to the
# TomeVoice already running, in its own task. A file manager opening a file
# on MainActivity itself (for a result, which no adb command can ask for) put
# a second TomeVoice inside the file manager's task, each copy with its own
# library in memory. This checks the hand-over: one MainActivity afterwards,
# and on screen.
open_with_test() {
  local file=/sdcard/Download/tv-open-with.txt n
  adb shell "echo 'Opened with TomeVoice.' > $file"
  adb shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
  sleep 5
  dev am start -W -a android.intent.action.VIEW -t text/plain -d "file://$file" \
    -n "$pkg/app.tomevoice.tomevoice_spike.OpenActivity" > "$out/open-with-start.txt"
  sleep 4
  dev dumpsys activity activities > "$out/open-with-activities.txt"
  shot open-with
  n=$(grep -cE "Hist[[:space:]]+#[0-9]+:.*$activity" "$out/open-with-activities.txt")
  if grep -qE "^Error|Exception" "$out/open-with-start.txt"; then
    result FAIL "Open with" "OpenActivity could not be started: $(grep -m1 -E '^Error|Exception' "$out/open-with-start.txt")"
  elif [ "$n" -ne 1 ]; then
    result FAIL "Open with" "$n copies of MainActivity after a file was opened with TomeVoice (one expected)"
  elif ! resumed "$out/open-with-activities.txt"; then
    result FAIL "Open with" "TomeVoice was not brought to the front for the file"
  else
    result PASS "Open with" "the file went to the one TomeVoice, brought to the front"
  fi
  adb shell rm -f "$file"
}
open_with_test

# ------------------------------------------------------------------ crashes

adb logcat -d > "$out/logcat.txt" 2>&1 || true
adb logcat -d -b crash > "$out/crash.txt" 2>&1 || true
if grep -q "Process: $pkg" "$out/crash.txt"; then
  result FAIL "No crash" "TomeVoice crashed during the run (crash.txt)"
else
  result PASS "No crash" "nothing from TomeVoice in the crash log"
fi

{
  echo "### Android $release (API $api)"
  echo
  echo "| Check | Result | Detail |"
  echo "|---|---|---|"
  cat "$out/results.md"
  echo
  cat "$out/back-evidence.md"
} >> "$summary"

echo "$failures check(s) failed on API $api"
[ "$failures" -eq 0 ]
