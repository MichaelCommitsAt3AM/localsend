import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/clipboard_sync_provider.dart';
import 'package:url_launcher/url_launcher.dart';

class ClipboardSyncTutorialPage extends StatelessWidget {
  final ClipboardSyncController controller;

  const ClipboardSyncTutorialPage({required this.controller, super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(t.clipboardSync.tutorial)),
    body: SingleChildScrollView(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(t.clipboardSync.tutorialIntro, style: Theme.of(context).textTheme.bodyLarge),
                const SizedBox(height: 24),
                _step(
                  context,
                  1,
                  t.clipboardSync.installTitle,
                  t.clipboardSync.installBody,
                  action: OutlinedButton.icon(
                    onPressed: () => _openLink(context, 'https://shizuku.rikka.app/download/'),
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: Text(t.clipboardSync.downloadShizuku),
                  ),
                ),
                _step(
                  context,
                  2,
                  t.clipboardSync.startTitle,
                  t.clipboardSync.startBody,
                  action: OutlinedButton.icon(
                    onPressed: () => _openLink(context, 'https://shizuku.rikka.app/guide/setup/'),
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: Text(t.clipboardSync.officialGuide),
                  ),
                ),
                _step(
                  context,
                  3,
                  t.clipboardSync.permissionsTitle,
                  t.clipboardSync.permissionsBody,
                  action: Platform.isAndroid
                      ? FilledButton.tonal(onPressed: () => _authorize(context), child: Text(t.clipboardSync.allowAccess))
                      : null,
                ),
                _step(context, 4, t.clipboardSync.pairTitle, t.clipboardSync.pairBody),
                _step(context, 5, t.clipboardSync.shareTitle, t.clipboardSync.shareBody),
                Text(
                  t.clipboardSync.restartReminder,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 20),
                FilledButton(onPressed: () => Navigator.pop(context), child: Text(t.clipboardSync.returnToSettings)),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _step(BuildContext context, int number, String title, String body, {Widget? action}) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(radius: 16, child: Text('$number')),
                const SizedBox(width: 12),
                Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
              ],
            ),
            const SizedBox(height: 12),
            Text(body),
            if (action != null) ...[const SizedBox(height: 16), action],
          ],
        ),
      ),
    ),
  );

  Future<void> _authorize(BuildContext context) async {
    final allowed = await controller.authorize();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(allowed ? t.clipboardSync.accessGranted : t.clipboardSync.shizukuHelp)));
    }
  }

  Future<void> _openLink(BuildContext context, String url) async {
    try {
      if (await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) return;
    } catch (_) {
      // Keep the tutorial usable when no browser is available.
    }
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.clipboardSync.openLinkFailed)));
  }
}
