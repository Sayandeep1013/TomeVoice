import 'dart:ui' show FramePhase;

import 'package:flutter/scheduler.dart';

/// The test app only (CI's variant=test): each frame's timing printed to the
/// phone's log (`adb logcat -s flutter`), so a stutter measured on a phone
/// can be told apart: the app slow to build the frame (its main thread),
/// slow to draw it (the raster thread and GPU), or neither, when the time
/// went in the phone's compositor. Times are microseconds; vsync is on the
/// clock SurfaceFlinger's present times use.
///
///   tvframe <number> <vsync start> <build> <raster> <vsync overhead> <total>
void printFrameTimings() {
  SchedulerBinding.instance.addTimingsCallback((timings) {
    for (final t in timings) {
      // ignore: avoid_print
      print('tvframe ${t.frameNumber} ${t.timestampInMicroseconds(FramePhase.vsyncStart)} '
          '${t.buildDuration.inMicroseconds} ${t.rasterDuration.inMicroseconds} '
          '${t.vsyncOverhead.inMicroseconds} ${t.totalSpan.inMicroseconds}');
    }
  });
}
