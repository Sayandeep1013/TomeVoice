// Back with the drawer open closes the drawer and the app stays, even on a
// page whose Back leaves the app (the library): on Android 16 it took the
// whole app to the background with its drawer still open. With the drawer
// shut, Back leaves, or goes where the page says.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/ui.dart';

void main() {
  final platform = <MethodCall>[];

  setUp(() {
    platform.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platform.add(call);
      return null;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));

  /// What the app last told Android: whether it takes Back itself.
  bool? takesBack() {
    final said = platform.where((c) => c.method == 'SystemNavigator.setFrameworkHandlesBack');
    return said.isEmpty ? null : said.last.arguments as bool;
  }

  Future<void> pumpShell(WidgetTester tester, {bool canPop = true, VoidCallback? onBack}) =>
      tester.pumpWidget(MaterialApp(
        home: DrawerBackScaffold(
          canPop: canPop,
          onBack: onBack ?? () {},
          drawer: const Drawer(child: Text('In the drawer')),
          body: Builder(
            builder: (context) => Center(
              child: TextButton(onPressed: () => Scaffold.of(context).openDrawer(), child: const Text('Menu')),
            ),
          ),
        ),
      ));

  testWidgets('Back with the drawer open closes it, and the app stays', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.text('Menu'));
    await tester.pumpAndSettle();
    expect(find.text('In the drawer'), findsOneWidget);
    expect(takesBack(), isTrue, reason: 'Android hands Back to the app while the drawer is open');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('In the drawer'), findsNothing);
    expect(platform.where((c) => c.method == 'SystemNavigator.pop'), isEmpty, reason: 'the app was not left');
    expect(takesBack(), isFalse, reason: 'shut, Back leaves the app as before');
  });

  testWidgets('with the drawer shut, Back goes where the page says; open, it only closes the drawer',
      (tester) async {
    var backs = 0;
    await pumpShell(tester, canPop: false, onBack: () => backs++);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(backs, 1);

    await tester.tap(find.text('Menu'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('In the drawer'), findsNothing);
    expect(backs, 1, reason: 'the drawer closed, and the page did not go back too');
  });
}
