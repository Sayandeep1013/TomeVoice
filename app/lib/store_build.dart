/// Which store this build is for. The GitHub build has everything. The
/// Google Play build, made with `--dart-define=TV_STORE=play` (the CI's play
/// job), leaves out what Play does not allow: web novels and their sources,
/// updating itself from GitHub, asking to be left out of battery saving, and
/// the voices whose recordings are not open (see
/// private/play-store-report-2026-11-20.html). Nothing is removed from the
/// GitHub build for Play's sake.
const playBuild = String.fromEnvironment('TV_STORE') == 'play';

/// The separate test app (app.tomevoice.test, CI's variant=test), never
/// released: its sources may reach a test site on the PC through adb
/// reverse, and take a source list over plain http. Every released build
/// keeps both refused.
const testBuild = String.fromEnvironment('TV_TEST') == '1';
