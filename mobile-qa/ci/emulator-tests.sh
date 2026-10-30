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

# result PASS|FAIL|INFO <check> <detail>
result() {
  printf '| %s | %s | %s |\n' "$2" "$1" "$3" >> "$out/results.md"
  if [ "$1" = FAIL ]; then
    failures=$((failures + 1))
    echo "::error title=$2 (API $api)::$3"
  else
    echo "$1 $2: $3"
  fi
}

shot() { adb exec-out screencap -p > "$out/$1.png" 2>/dev/null || true; }

# flow <name>: mobile-qa/flows/<name>.yaml on an app with no data (as if just
# installed); succeeds if Maestro passed it.
flow() {
  local status
  adb shell pm clear "$pkg" > /dev/null
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
# First, listening (when the emulator has a TTS engine to listen with) and
# back to the library, as a reader would be.

if ! check listen-to-library "Listen, then back to the library" "Listen opens the reader; its Back to library and the book page's Back return to the shelf" "could not listen and go back to the library"; then
  # The Back test still runs, from a plain library.
  flow library-starter || true
fi

snapshot before
before=$(record_state "$out/before-activities.txt")
adb logcat -b events -c
adb shell input keyevent KEYCODE_BACK
sleep 5
adb logcat -b events -d | tr -d '\r' > "$out/back-events.txt"
snapshot after
shot after-back

grep -E "wm_[a-z_]+: .*tomevoice" "$out/back-events.txt" > "$out/back-events-tomevoice.txt" || true
after=$(record_state "$out/after-activities.txt")
pid=$(dev pidof "$pkg")
destroyed=no
if grep -qE "wm_(finish_activity|destroy_activity|on_destroy_called): .*$activity" "$out/back-events-tomevoice.txt"; then
  destroyed=yes
elif [ -z "$after" ] && ! grep -qE "wm_(stop_activity|on_stop_called): .*$activity" "$out/back-events-tomevoice.txt"; then
  destroyed=yes
fi

if [ "${before%% *}" != RESUMED ] && ! resumed "$out/before-activities.txt"; then
  back="BACK TEST: TomeVoice was not on screen to press Back on API $api (MainActivity: ${before:-no activity})"
  result FAIL "BACK TEST" "$back"
elif [ "$destroyed" = yes ]; then
  back="BACK TEST: activity destroyed on API $api"
  result FAIL "BACK TEST" "$back"
elif [ "${after%% *}" = RESUMED ] || resumed "$out/after-activities.txt"; then
  back="BACK TEST: Back did not leave the app on API $api (MainActivity still resumed)"
  result FAIL "BACK TEST" "$back"
else
  back="BACK TEST: activity kept, moved to the back on API $api (MainActivity ${after:-state unknown})"
  result PASS "BACK TEST" "$back"
fi
echo "$back"

media_before=$(media_state "$out/before-media_session.txt")
media_after=$(media_state "$out/after-media_session.txt")
service_before=$(grep -q ReadAloudService "$out/before-services.txt" && echo running || echo "not running")
service_after=$(grep -q ReadAloudService "$out/after-services.txt" && echo running || echo "not running")
if [ -n "$pid" ]; then process="alive (pid $pid)"; else process=gone; fi
result INFO "After Back" "process $process; MainActivity ${after:-has no activity record}; ReadAloudService $service_before before Back, $service_after after"
result INFO "Media session" "before Back: ${media_before:-no TomeVoice session}; after Back: ${media_after:-no TomeVoice session}"

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
  echo "**$back**"
  echo
  echo "TomeVoice's activity events after Back (\`logcat -b events\`):"
  echo
  echo '```'
  cat "$out/back-events-tomevoice.txt"
  echo '```'
} >> "$summary"

echo "$failures check(s) failed on API $api"
[ "$failures" -eq 0 ]
