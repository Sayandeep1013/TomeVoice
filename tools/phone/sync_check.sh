#!/bin/sh
# Mirror app/ lib+test (and packages) into the scratch Flutter project at D:/tvchk/w.
set -e
SRC=${TV_REPO:-D:/Projects/TomeVoice}
W=${TV_CHECK:-D:/tvchk/w}
rm -rf $W/app/lib $W/app/test $W/packages
cp -r $SRC/packages $W/packages
cp -r $SRC/app/lib $W/app/lib
cp -r $SRC/app/test $W/app/test
cp -r $SRC/app/assets $W/app/ 2>/dev/null || true
cat > $W/app/lib/sources/qjs_runtime.dart <<'STUB'
import 'plugin_host.dart';

/// Local stub: QuickJS is not built on Windows (CI tests the real engine).
JsRuntime createJsRuntime() => throw UnsupportedError('QuickJS is not available in this local check');
STUB
