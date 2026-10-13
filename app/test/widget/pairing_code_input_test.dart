import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/widget/clipboard/pairing_code_input.dart';

void main() {
  setUpAll(() async {
    final directory = Platform.environment['CLIPBOARD_UI_FONT_DIR'];
    if (Platform.environment['PAIRING_PIN_PREVIEW'] == '1' && directory != null) {
      final loader = FontLoader('Roboto')..addFont(File('$directory/roboto-regular.ttf').readAsBytes().then((bytes) => ByteData.sublistView(bytes)));
      await loader.load();
    }
  });

  testWidgets('code entry autofocuses the first box, shows its caret, and requests a numeric keyboard', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PairingCodeInput(controller: controller, label: '8-digit code', onSubmitted: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, true);
    expect(tester.testTextInput.setClientArgs!['inputType'], {'name': 'TextInputType.number', 'signed': false, 'decimal': false});
    expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus, true);
    expect(
      find.descendant(of: find.byKey(const ValueKey('pairing-code-digit-0')), matching: find.byKey(const ValueKey('pairing-code-caret'))),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField), '12');
    await tester.pump();
    expect(
      find.descendant(of: find.byKey(const ValueKey('pairing-code-digit-2')), matching: find.byKey(const ValueKey('pairing-code-caret'))),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, false);
    controller.dispose();
  });

  for (final width in [360.0, 1280.0]) {
    testWidgets('eight code boxes and a middle dash fit width $width with large text', (tester) async {
      tester.view.physicalSize = Size(width, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = TextEditingController(text: '01234567');
      final preview = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.8)),
            child: child!,
          ),
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: preview,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: PairingCodeInput(controller: controller, label: '8-digit code', onSubmitted: () {}),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var index = 0; index < 8; index++) {
        expect(find.byKey(ValueKey('pairing-code-digit-$index')), findsOneWidget);
      }
      expect(find.text('-'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (Platform.environment['PAIRING_PIN_PREVIEW'] == '1') {
        await tester.runAsync(() async {
          final boundary = preview.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/ui-preview/pairing-pin-${width.toInt()}.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }

  testWidgets('paste strips the separator, backspace edits the unified value, and tapping a filled box selects its digit', (tester) async {
    final controller = TextEditingController();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': '0123-4567'};
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PairingCodeInput(controller: controller, label: '8-digit code', onSubmitted: () {}),
        ),
      ),
    );
    await tester.longPress(find.byKey(const ValueKey('pairing-code-digit-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste'));
    await tester.pumpAndSettle();
    expect(controller.text, '01234567');
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(controller.text, '0123456');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(controller.selection.baseOffset, 6);
    await tester.tap(find.byKey(const ValueKey('pairing-code-digit-2')));
    await tester.pump();
    expect(controller.selection, const TextSelection(baseOffset: 2, extentOffset: 3));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
