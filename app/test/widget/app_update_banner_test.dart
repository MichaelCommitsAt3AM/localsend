import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/update/app_release.dart';
import 'package:localsend_app/provider/app_update_provider.dart';
import 'package:localsend_app/widget/watcher/app_update_banner_watcher.dart';
import 'package:refena_flutter/refena_flutter.dart';

class _TestUpdateNotifier extends AppUpdateNotifier {
  final AppUpdateState initialState;
  _TestUpdateNotifier(this.initialState);

  @override
  AppUpdateState init() => initialState;

  void hideBanner() => state = const AppUpdateState(stage: UpdateStage.idle);
}

void main() {
  final dummyAsset = const AppReleaseAsset(
    name: 'LocalSend-1.19.0-windows-setup.exe',
    downloadUrl: 'https://download/setup.exe',
    size: 30000000,
    contentType: 'application/x-msdownload',
  );

  final dummyRelease = AppRelease(
    version: '1.19.0',
    tagName: 'v1.19.0',
    name: 'LocalSend v1.19.0',
    body: 'Bug fixes and new features',
    htmlUrl: 'https://github.com/MichaelCommitsAt3AM/localsend/releases/tag/v1.19.0',
    publishedAt: null,
    assets: [dummyAsset],
  );

  for (final visible in [false, true]) {
    testWidgets('phone safe areas are applied once with banner visible=$visible, including after dismissal', (tester) async {
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 16);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 16);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetDevicePixelRatio);
      final notifier = _TestUpdateNotifier(
        visible ? AppUpdateState(stage: UpdateStage.available, release: dummyRelease) : const AppUpdateState(stage: UpdateStage.idle),
      );
      await tester.pumpWidget(
        RefenaScope(
          overrides: [appUpdateProvider.overrideWithNotifier((_) => notifier)],
          child: TranslationProvider(
            child: MaterialApp(
              builder: (context, child) => AppUpdateBannerWatcher(child: child!),
              home: Scaffold(
                appBar: AppBar(title: const Text('Page title')),
                body: const SafeArea(child: SizedBox.expand(key: ValueKey('body'))),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scaffoldTop = tester.getTopLeft(find.byType(Scaffold)).dy;
      expect(scaffoldTop, visible ? greaterThan(24) : 0);
      expect(tester.getSize(find.byType(AppBar)).height, kToolbarHeight + (visible ? 0 : 24));
      expect(tester.getBottomRight(find.byKey(const ValueKey('body'))).dy, tester.view.physicalSize.height - 16);
      if (visible) {
        final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
          find.ancestor(of: find.byIcon(Icons.system_update_rounded), matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>)).first,
        );
        expect(region.value.statusBarColor, Colors.transparent);
        expect(region.value.systemStatusBarContrastEnforced, false);
        notifier.hideBanner();
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(find.byType(Scaffold)).dy, 0);
        expect(tester.getSize(find.byType(AppBar)).height, kToolbarHeight + 24);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('does not show banner when update stage is idle', (tester) async {
    await tester.pumpWidget(
      RefenaScope(
        overrides: [
          appUpdateProvider.overrideWithNotifier((_) => _TestUpdateNotifier(const AppUpdateState(stage: UpdateStage.idle))),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            builder: (context, child) => AppUpdateBannerWatcher(child: child!),
            home: const Scaffold(
              body: Text('Main Content'),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Main Content'), findsOneWidget);
    expect(find.byIcon(Icons.system_update_rounded), findsNothing);
  });

  testWidgets('shows banner and pushes child down when update is available without requiring an overlay', (tester) async {
    await tester.pumpWidget(
      RefenaScope(
        overrides: [
          appUpdateProvider.overrideWithNotifier(
            (_) => _TestUpdateNotifier(
              AppUpdateState(
                stage: UpdateStage.available,
                release: dummyRelease,
                targetAsset: dummyAsset,
              ),
            ),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            builder: (context, child) => AppUpdateBannerWatcher(child: child!),
            home: const Scaffold(
              body: Text('Main Content'),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Main Content'), findsOneWidget);
    expect(find.byIcon(Icons.system_update_rounded), findsOneWidget);
    expect(find.textContaining('1.19.0'), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Download'), findsOneWidget);
  });

  testWidgets('shows progress bar during download', (tester) async {
    await tester.pumpWidget(
      RefenaScope(
        overrides: [
          appUpdateProvider.overrideWithNotifier(
            (_) => _TestUpdateNotifier(
              AppUpdateState(
                stage: UpdateStage.downloading,
                release: dummyRelease,
                targetAsset: dummyAsset,
                downloadProgress: 0.45,
              ),
            ),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            builder: (context, child) => AppUpdateBannerWatcher(child: child!),
            home: const Scaffold(
              body: Text('Main Content'),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.textContaining('45%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Cancel'), findsOneWidget);
  });
  for (final stage in [UpdateStage.failed, UpdateStage.ready, UpdateStage.installerOpened, UpdateStage.replaced]) {
    testWidgets('update banner $stage fits a narrow screen with large text and does not show a stuck spinner', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RefenaScope(
          overrides: [
            appUpdateProvider.overrideWithNotifier(
              (_) => _TestUpdateNotifier(AppUpdateState(stage: stage, release: dummyRelease, targetAsset: dummyAsset)),
            ),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.8)),
                child: AppUpdateBannerWatcher(child: child!),
              ),
              home: const Scaffold(body: Text('Main Content')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      if (stage == UpdateStage.ready) expect(find.text(t.appUpdate.openInstaller), findsOneWidget);
    });
  }
}
