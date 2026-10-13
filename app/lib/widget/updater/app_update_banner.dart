import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/app_update_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

class AppUpdateBanner extends StatelessWidget {
  const AppUpdateBanner({super.key});
  @override
  Widget build(BuildContext context) {
    final state = context.watch(appUpdateProvider);
    final controller = context.notifier(appUpdateProvider);
    if (state.release == null || !state.isBannerVisible) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final downloading = state.stage == UpdateStage.downloading;
    final installing = state.stage == UpdateStage.installing;
    final title = switch (state.stage) {
      UpdateStage.failed => state.errorMessage ?? t.appUpdate.downloadFailed,
      UpdateStage.downloading => t.appUpdate.downloading(percent: (state.downloadProgress * 100).toInt()),
      UpdateStage.ready => t.appUpdate.verifiedReady,
      UpdateStage.installing => t.appUpdate.installing,
      UpdateStage.installerOpened => t.appUpdate.installerOpened,
      UpdateStage.replaced => t.appUpdate.restartRequired,
      _ => t.appUpdate.updateAvailable(version: state.release!.version),
    };
    return Material(
      color: colors.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  state.stage == UpdateStage.failed ? Icons.error_outline_rounded : Icons.system_update_rounded,
                  color: colors.onPrimaryContainer,
                  size: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.bodyMedium?.copyWith(color: colors.onPrimaryContainer, fontWeight: FontWeight.w600),
                  ),
                ),
                Semantics(
                  label: t.appUpdate.dismiss,
                  button: true,
                  child: IconButton(onPressed: controller.dismissBanner, icon: const Icon(Icons.close_rounded)),
                ),
              ],
            ),
            if (downloading) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: state.downloadProgress > 0 ? state.downloadProgress : null),
            ],
            if (!installing && state.stage != UpdateStage.replaced) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                alignment: WrapAlignment.end,
                children: [
                  if (downloading)
                    OutlinedButton(onPressed: controller.cancelDownload, child: Text(t.general.cancel))
                  else if (state.stage == UpdateStage.ready ||
                      state.stage == UpdateStage.installerOpened ||
                      (state.stage == UpdateStage.failed && state.downloadProgress == 1))
                    FilledButton(onPressed: controller.installDownloaded, child: Text(t.appUpdate.openInstaller))
                  else if (state.targetAsset != null)
                    FilledButton(
                      onPressed: controller.downloadAndInstall,
                      child: Text(state.stage == UpdateStage.failed ? t.appUpdate.retry : t.appUpdate.download),
                    ),
                  if (!downloading) TextButton(onPressed: controller.openReleaseInBrowser, child: Text(t.appUpdate.openBrowser)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
