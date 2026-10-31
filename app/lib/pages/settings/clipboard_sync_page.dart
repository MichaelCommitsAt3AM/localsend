import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/settings/clipboard_pairing_page.dart';
import 'package:localsend_app/pages/settings/clipboard_sync_tutorial_page.dart';
import 'package:localsend_app/provider/clipboard_sync_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

class ClipboardSyncPage extends StatelessWidget {
  const ClipboardSyncPage({super.key});

  @override
  Widget build(BuildContext context) => ViewModelBuilder(
    provider: (ref) => clipboardSyncProvider,
    // Application-wide service state must survive leaving this settings page.
    disposeProvider: false,
    builder: (context, state) {
      final controller = context.ref.notifier(clipboardSyncProvider);
      final theme = Theme.of(context);
      final needsAttention = _needsAttention(state);
      final pairedCount = state.peers.where((p) => !p.pending).length;
      return Scaffold(
        appBar: AppBar(
          title: Text(t.clipboardSync.title),
          actions: [
            PopupMenuButton<String>(
              tooltip: t.clipboardSync.moreOptions,
              onSelected: (action) async {
                switch (action) {
                  case 'tutorial':
                    await _openTutorial(context, controller);
                  case 'help':
                    await _showHelp(context);
                  case 'access':
                    await controller.authorize();
                  case 'manual':
                    await _showManualPairing(context, controller);
                  case 'diagnostics':
                    await _showDiagnostics(context);
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'tutorial', child: Text(t.clipboardSync.tutorial)),
                PopupMenuItem(value: 'help', child: Text(t.clipboardSync.howItWorks)),
                if (Platform.isAndroid) PopupMenuItem(value: 'access', enabled: state.ready, child: Text(t.clipboardSync.androidAccess)),
                PopupMenuItem(value: 'manual', child: Text(t.clipboardSync.advanced)),
                PopupMenuItem(value: 'diagnostics', child: Text(t.clipboardSync.diagnostics)),
              ],
            ),
          ],
        ),
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
                    Text(t.clipboardSync.simpleDescription, style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 24),
                    _panel(
                      context,
                      Column(
                        children: [
                          SwitchListTile.adaptive(
                            title: Text(t.clipboardSync.enable),
                            subtitle: Text(pairedCount == 0 ? t.clipboardSync.addDeviceFirst : t.clipboardSync.textSummary),
                            value: state.enabled,
                            onChanged: state.ready ? (value) => _setEnabled(context, controller, value) : null,
                          ),
                          const Divider(height: 1, indent: 16, endIndent: 16),
                          SwitchListTile.adaptive(
                            title: Text(t.clipboardSync.syncImages),
                            subtitle: Text(t.clipboardSync.imagesSummary),
                            value: state.syncImages,
                            onChanged: state.ready && state.enabled ? controller.setSyncImages : null,
                          ),
                        ],
                      ),
                    ),
                    if (state.connectionWarning) ...[
                      const SizedBox(height: 12),
                      _panel(
                        context,
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(t.clipboardSync.networkWarning),
                        ),
                      ),
                    ],
                    if (needsAttention) ...[
                      const SizedBox(height: 12),
                      _panel(
                        context,
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(t.clipboardSync.needsAttention, style: theme.textTheme.titleSmall),
                              const SizedBox(height: 6),
                              Text(_friendlyIssue(state.status)),
                              const SizedBox(height: 12),
                              if (Platform.isAndroid && state.ready && _accessIssue(state.status))
                                FilledButton.tonal(onPressed: controller.authorize, child: Text(t.clipboardSync.setupAccess))
                              else
                                TextButton(onPressed: () => _showDiagnostics(context), child: Text(t.clipboardSync.viewDetails)),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 32),
                    Text('${t.clipboardSync.pairedDevices}: $pairedCount', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 12),
                    if (state.peers.isEmpty)
                      _panel(
                        context,
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            children: [
                              Icon(Icons.devices_rounded, size: 36, color: theme.colorScheme.primary),
                              const SizedBox(height: 12),
                              Text(t.clipboardSync.noDevices, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
                              const SizedBox(height: 6),
                              Text(
                                t.clipboardSync.noDevicesHint,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      )
                    else ...[
                      for (var i = 0; i < state.peers.length; i++) ...[
                        if (i > 0) const SizedBox(height: 10),
                        _panel(
                          context,
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            leading: CircleAvatar(
                              backgroundColor: theme.colorScheme.surfaceContainerHighest,
                              child: Icon(Icons.devices_rounded, color: theme.colorScheme.onSurfaceVariant),
                            ),
                            title: Row(
                              children: [
                                Flexible(child: Text(_deviceName(state.peers[i]), maxLines: 2, overflow: TextOverflow.ellipsis)),
                                if (state.connectedPeers.contains(state.peers[i].fingerprint)) ...[
                                  const SizedBox(width: 8),
                                  Tooltip(
                                    message: t.clipboardSync.onlineDevice,
                                    child: Semantics(
                                      label: t.clipboardSync.onlineDevice,
                                      child: const SizedBox(
                                        width: 9,
                                        height: 9,
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(color: Color(0xFF4CAF50), shape: BoxShape.circle),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            subtitle: Text(_sharingLabel(state.peers[i])),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () => _managePeer(context, controller, state.peers[i].fingerprint),
                          ),
                        ),
                      ],
                    ],
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      icon: const Icon(Icons.add_rounded),
                      label: Text(t.clipboardSync.addDevice),
                      onPressed: state.ready && state.peers.length < 8
                          ? () => Navigator.push<void>(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ClipboardPairingPage(controller: controller, deviceName: context.ref.read(settingsProvider).alias),
                              ),
                            )
                          : null,
                    ),
                    const SizedBox(height: 20),
                    TextButton.icon(
                      onPressed: () => _showHelp(context),
                      icon: const Icon(Icons.help_outline_rounded, size: 18),
                      label: Text(t.clipboardSync.howItWorks),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _panel(BuildContext context, Widget child) => Card(
    margin: EdgeInsets.zero,
    elevation: 0,
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    clipBehavior: Clip.antiAlias,
    child: child,
  );

  bool _needsAttention(ClipboardSyncState state) =>
      !{
        'Disabled',
        'Starting',
        'Starting Android clipboard listener',
        'Connected',
        'Waiting for paired devices',
        'Device paired',
        'Finishing pairing',
        'Clipboard access authorized',
        'Clipboard and screenshot access authorized',
        'Clipboard monitor ready',
      }.contains(state.status) &&
      !state.status.startsWith('Clipboard peer disconnected; reconnecting');

  bool _accessIssue(String status) =>
      status.contains('Shizuku') || status.contains('access') || status.contains('permission') || status.contains('Authorize');
  String _friendlyIssue(String status) {
    if (status.startsWith('No compatible Shizuku')) return t.clipboardSync.shizukuNotFound;
    if (status.contains('Shizuku')) return t.clipboardSync.shizukuHelp;
    if (status.contains('photo')) return t.clipboardSync.photoHelp;
    if (Platform.isAndroid && _accessIssue(status)) return t.clipboardSync.accessHelp;
    if (status.contains('image limits') || status.contains('oversized') || status.contains('exceeds')) return t.clipboardSync.imageLimitHelp;
    if (status.contains('configuration') || status.contains('storage')) return t.clipboardSync.settingsHelp;
    if (status.contains('capture') || status.contains('clipboard operation') || status.contains('clipboard write')) {
      return t.clipboardSync.clipboardHelp;
    }
    return t.clipboardSync.connectionHelp;
  }

  String _deviceName(ClipboardPeer peer) => peer.name.isEmpty ? t.clipboardSync.devicePlaceholder : peer.name;
  String _sharingLabel(ClipboardPeer peer) => peer.pending
      ? t.clipboardSync.pending
      : peer.send && peer.receive
      ? t.clipboardSync.bothWays
      : peer.send
      ? t.clipboardSync.sendOnly
      : peer.receive
      ? t.clipboardSync.receiveOnly
      : t.clipboardSync.sharingPaused;

  Future<void> _setEnabled(BuildContext context, ClipboardSyncController controller, bool value) async {
    if (value) {
      if (!context.ref.read(clipboardSyncProvider).peers.any((peer) => !peer.pending)) {
        final connect = await _showConnectDevice(context);
        if (connect != true || !context.mounted) return;
        await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (_) => ClipboardPairingPage(
              controller: controller,
              deviceName: context.ref.read(settingsProvider).alias,
              returnOnPaired: true,
            ),
          ),
        );
        // Pairing completion enables sharing on each endpoint. Cancellation
        // leaves it unchanged; do not add a second enable/consent flow here.
        return;
      }
      if (Theme.of(context).platform == TargetPlatform.android && !context.ref.read(clipboardSyncProvider).hasEnabledBefore) {
        final action = await _showAndroidSetup(context);
        if (!context.mounted) return;
        if (action == 'tutorial') {
          await _openTutorial(context, controller);
          return;
        }
        if (action != 'continue') return;
        final authorized = await controller.authorize();
        if (!context.mounted || !authorized) return;
      }
      final allowed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(t.clipboardSync.enable),
          scrollable: true,
          content: Text(t.clipboardSync.consent),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.general.cancel)),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t.general.confirm)),
          ],
        ),
      );
      if (allowed != true || !context.mounted || !context.ref.read(clipboardSyncProvider).peers.any((peer) => !peer.pending)) return;
    }
    await controller.setEnabled(value);
  }

  Future<bool?> _showConnectDevice(BuildContext context) => showModalBottomSheet<bool>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 720),
    builder: (context) => SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.devices_rounded, size: 36, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(t.clipboardSync.addDeviceFirst, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(t.clipboardSync.noDevicesHint),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.add_rounded),
              label: Text(t.clipboardSync.addDevice),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.general.cancel)),
          ],
        ),
      ),
    ),
  );

  Future<void> _openTutorial(BuildContext context, ClipboardSyncController controller) => Navigator.push<void>(
    context,
    MaterialPageRoute(builder: (_) => ClipboardSyncTutorialPage(controller: controller)),
  );

  Future<String?> _showAndroidSetup(BuildContext context) => showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 720),
    builder: (context) => SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.phonelink_setup_rounded, size: 36, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(t.clipboardSync.setupTitle, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(t.clipboardSync.setupDescription),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, 'tutorial'),
              icon: const Icon(Icons.menu_book_rounded),
              label: Text(t.clipboardSync.tutorial),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: () => Navigator.pop(context, 'continue'), child: Text(t.clipboardSync.continueSetup)),
          ],
        ),
      ),
    ),
  );

  Future<void> _managePeer(BuildContext context, ClipboardSyncController controller, String fingerprint) => showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 720),
    builder: (context) => ViewModelBuilder(
      provider: (_) => clipboardSyncProvider,
      disposeProvider: false,
      builder: (context, state) {
        final peer = state.peers.where((p) => p.fingerprint == fingerprint).firstOrNull;
        if (peer == null) return const SizedBox.shrink();
        return SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.viewInsetsOf(context).bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(_deviceName(peer), style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(_sharingLabel(peer), style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 16),
                SwitchListTile.adaptive(
                  title: Text(t.clipboardSync.send),
                  value: peer.send,
                  onChanged: peer.pending ? null : (value) => _setDirection(context, controller, fingerprint, send: value),
                ),
                SwitchListTile.adaptive(
                  title: Text(t.clipboardSync.receive),
                  value: peer.receive,
                  onChanged: peer.pending ? null : (value) => _setDirection(context, controller, fingerprint, receive: value),
                ),
                if (state.enabled && !peer.pending && !state.connectedPeers.contains(fingerprint)) ...[
                  ListTile(
                    leading: const Icon(Icons.refresh),
                    title: Text(t.clipboardSync.retryConnection),
                    subtitle: Text(t.clipboardSync.retryConnectionHint),
                    onTap: () {
                      final messenger = ScaffoldMessenger.of(context);
                      Navigator.pop(context);
                      messenger.showSnackBar(SnackBar(content: Text(t.clipboardSync.pairingWorking)));
                      controller.retryPeer(fingerprint);
                    },
                  ),
                ],
                ExpansionTile(
                  title: Text(t.clipboardSync.details),
                  children: [
                    ListTile(title: Text(t.clipboardSync.addressLabel), subtitle: SelectableText(peer.address)),
                    ListTile(title: Text(t.clipboardSync.identityLabel), subtitle: SelectableText(peer.fingerprint)),
                  ],
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                  icon: const Icon(Icons.link_off_rounded),
                  label: Text(t.clipboardSync.revoke),
                  onPressed: () async {
                    await _removePeer(context, controller, peer);
                    if (context.mounted && !context.ref.read(clipboardSyncProvider).peers.any((p) => p.fingerprint == fingerprint)) {
                      Navigator.pop(context);
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    ),
  );

  Future<void> _setDirection(BuildContext context, ClipboardSyncController controller, String fingerprint, {bool? send, bool? receive}) {
    final peers = context.ref.read(clipboardSyncProvider).peers;
    return controller.setPeers(
      peers
          .map(
            (peer) => peer.fingerprint == fingerprint
                ? ClipboardPeer(
                    fingerprint: peer.fingerprint,
                    address: peer.address,
                    name: peer.name,
                    pending: peer.pending,
                    send: send ?? peer.send,
                    receive: receive ?? peer.receive,
                  )
                : peer,
          )
          .toList(),
    );
  }

  Future<void> _showHelp(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t.clipboardSync.howItWorks),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.clipboardSync.helpBasics),
            const SizedBox(height: 16),
            Text(t.clipboardSync.helpImages),
            const SizedBox(height: 16),
            Text(t.clipboardSync.helpPrivacy),
            if (Platform.isAndroid) ...[const SizedBox(height: 16), Text(t.clipboardSync.helpAndroid)],
            ExpansionTile(title: Text(t.clipboardSync.buildDetails), children: [Text(t.clipboardSync.limitations)]),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.general.close))],
    ),
  );

  Future<void> _showDiagnostics(BuildContext context) {
    final state = context.ref.read(clipboardSyncProvider);
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.clipboardSync.diagnostics),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(state.status),
              const SizedBox(height: 12),
              Text('${t.clipboardSync.connected}: ${state.connected}'),
              Text('${t.clipboardSync.captures}: ${state.captures}'),
              Text('${t.clipboardSync.applied}: ${state.applied}'),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.general.close))],
      ),
    );
  }

  Future<void> _showManualPairing(BuildContext context, ClipboardSyncController controller) => showDialog<void>(
    context: context,
    builder: (context) => ViewModelBuilder(
      provider: (_) => clipboardSyncProvider,
      disposeProvider: false,
      builder: (context, state) => AlertDialog(
        title: Text(t.clipboardSync.advanced),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t.clipboardSync.codeInstructions),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                icon: const Icon(Icons.copy_rounded),
                label: Text(t.clipboardSync.copyCode),
                onPressed: state.ready && state.pairingCode.isNotEmpty
                    ? () async {
                        try {
                          await Clipboard.setData(ClipboardData(text: state.pairingCode));
                          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.clipboardSync.codeCopied)));
                        } catch (_) {
                          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.clipboardSync.copyFailed)));
                        }
                      }
                    : null,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.add_rounded),
                label: Text(t.clipboardSync.pair),
                onPressed: state.ready && state.peers.length < 8 ? () => _pair(context, controller, state) : null,
              ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.general.close))],
      ),
    ),
  );

  Future<void> _removePeer(BuildContext context, ClipboardSyncController controller, ClipboardPeer peer) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.clipboardSync.removeTitle),
        content: Text(t.clipboardSync.removeMessage(device: _deviceName(peer))),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(context, false), child: Text(t.general.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.clipboardSync.revoke),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      final peers = context.ref.read(clipboardSyncProvider).peers;
      await controller.setPeers(peers.where((p) => p.fingerprint != peer.fingerprint).toList());
    }
  }

  Future<void> _pair(BuildContext context, ClipboardSyncController controller, ClipboardSyncState state) async {
    final input = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.clipboardSync.pair),
        content: TextField(
          controller: input,
          maxLength: 4096,
          maxLines: 4,
          decoration: InputDecoration(labelText: t.clipboardSync.peerCode),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(t.general.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, input.text), child: Text(t.general.continueStr)),
        ],
      ),
    );
    // Dispose after dialog animations no longer use its text field.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    if (code == null || !context.mounted) return;
    try {
      if (code.length > 4096) throw const FormatException();
      final json = jsonDecode(code) as Map<String, dynamic>;
      final fingerprint = json['fingerprint'] as String;
      final port = json['port'] as int;
      final addresses = (json['addresses'] as List).cast<String>();
      if (json['version'] != 1 ||
          !RegExp(r'^[A-F0-9]{64}$').hasMatch(fingerprint) ||
          port < 1 ||
          port > 65535 ||
          addresses.isEmpty ||
          addresses.length > 16 ||
          addresses.any((a) => InternetAddress.tryParse(a)?.type != InternetAddressType.IPv4) ||
          state.peers.any((p) => p.fingerprint == fingerprint)) {
        throw const FormatException();
      }
      var address = addresses.first;
      var verified = false;
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: Text(t.clipboardSync.verify),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SelectableText(fingerprint),
                  const SizedBox(height: 12),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: address,
                    items: addresses.map((a) => DropdownMenuItem(value: a, child: Text(a))).toList(),
                    onChanged: (a) => setState(() => address = a ?? address),
                  ),
                  CheckboxListTile(
                    value: verified,
                    title: Text(t.clipboardSync.verified),
                    onChanged: (value) => setState(() => verified = value ?? false),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.general.cancel)),
              FilledButton(onPressed: verified ? () => Navigator.pop(context, true) : null, child: Text(t.general.confirm)),
            ],
          ),
        ),
      );
      if (approved == true) await controller.setPeers([...state.peers, ClipboardPeer(fingerprint: fingerprint, address: '$address:$port')]);
    } catch (_) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.clipboardSync.invalidCode)));
    }
  }
}
