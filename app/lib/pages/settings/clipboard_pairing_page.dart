import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/clipboard_sync_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_app/util/clipboard_pairing_link.dart';
import 'package:localsend_app/widget/clipboard/pairing_code_input.dart';
import 'package:localsend_isolates/rust/api/clipboard.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Invitation secrets stay in this route, never provider/debug state or logs.
class ClipboardPairingPage extends StatefulWidget {
  final ClipboardSyncController controller;
  final String deviceName;
  final String? initialInvitation;
  final bool returnOnPaired;
  final RsClipboardPairing? initialSession;
  const ClipboardPairingPage({
    super.key,
    required this.controller,
    required this.deviceName,
    this.initialInvitation,
    this.returnOnPaired = false,
    this.initialSession,
  });

  @override
  State<ClipboardPairingPage> createState() => _ClipboardPairingPageState();
}

class _ClipboardPairingPageState extends State<ClipboardPairingPage> {
  static const _native = MethodChannel('org.localsend.localsend_app/clipboard');
  RsClipboardPairing? _session;
  RsPairingUpdate? _update;
  String? _qr;
  DateTime? _expires;
  String? _error;
  bool _working = true;
  bool _approved = false;
  int _generation = 0;
  Timer? _timer;
  final _codeInput = TextEditingController();
  bool _submittingCode = false;
  String? _codeError;

  @override
  void initState() {
    super.initState();
    widget.controller.pairingScreenOpened();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _qr != null) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final invitation = widget.initialInvitation;
        if (widget.initialSession != null) {
          _session = widget.initialSession;
          unawaited(_listen(_session!, _generation));
        } else if (invitation != null) {
          unawaited(_join(invitation: invitation));
        } else {
          unawaited(_host());
        }
        unawaited(_refresh());
      }
    });
  }

  Future<void> _refresh() async {
    try {
      await context.ref.global.dispatchAsync(StartSmartScan());
    } catch (_) {
      /* Discovery can retry independently. */
    }
  }

  Future<int> _reset() async {
    final generation = ++_generation;
    final previous = _session;
    _session = null;
    if (mounted) {
      setState(() {
        _qr = null;
        _update = null;
        _error = null;
        _working = true;
        _approved = false;
        _submittingCode = false;
        _codeError = null;
        _codeInput.clear();
      });
    }
    if (previous != null) await widget.controller.closePairing(previous);
    return generation;
  }

  Future<void> _host() async {
    if (!mounted) return;
    final generation = await _reset();
    var abandoned = false;
    try {
      if (!mounted || generation != _generation) return;
      final name = widget.deviceName;
      final starting = widget.controller.hostPairing(name: name);
      unawaited(
        starting
            .then((session) {
              if (abandoned || !mounted || generation != _generation) unawaited(widget.controller.closePairing(session));
            })
            .catchError((Object _) {}),
      );
      final session = await starting.timeout(const Duration(seconds: 10));
      if (!mounted || generation != _generation) {
        await session.stop();
        return;
      }
      _session = session;
      final qr = await session.invitation().timeout(const Duration(seconds: 10));
      if (!mounted || generation != _generation) {
        await session.stop();
        return;
      }
      final expires = DateTime.fromMillisecondsSinceEpoch(((jsonDecode(qr!) as Map)['expires'] as int) * 1000);
      setState(() {
        _qr = encodeClipboardPairingLink(qr);
        _expires = expires;
        _working = false;
      });
      unawaited(_listen(session, generation));
    } catch (_) {
      abandoned = true;
      if (mounted && generation == _generation) {
        final session = _session;
        _session = null;
        if (session != null) unawaited(session.stop());
        setState(() {
          _error = t.clipboardSync.pairingFailed;
          _working = false;
        });
      }
    }
  }

  Future<void> _join({String? invitation, String? address}) async {
    if (!mounted) return;
    final generation = await _reset();
    try {
      if (!mounted || generation != _generation) return;
      final name = widget.deviceName;
      final session = await widget.controller.joinPairing(
        invitation: invitation == null ? null : decodeClipboardPairingLink(invitation),
        address: address,
        name: name,
      );
      if (!mounted || generation != _generation) {
        await session.stop();
        return;
      }
      _session = session;
      unawaited(_listen(session, generation));
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = t.clipboardSync.pairingFailed;
          _working = false;
        });
      }
    }
  }

  Future<void> _scan() async {
    final generation = await _reset();
    try {
      final code = await _native.invokeMethod<String>('scanPairingQr', {'prompt': t.clipboardSync.scanPrompt});
      if (!mounted || generation != _generation) return;
      if (code == null) {
        await _host();
        return;
      }
      await _join(invitation: code);
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = t.clipboardSync.pairingFailed;
          _working = false;
        });
      }
    }
  }

  Future<void> _listen(RsClipboardPairing session, int generation) async {
    var revision = BigInt.zero;
    String staged = '';
    var complete = false;
    try {
      while (mounted && generation == _generation) {
        final update = await session.nextUpdate(after: revision);
        if (!mounted || generation != _generation || update == null) return;
        revision = update.revision;
        if (update.phase != 'complete') {
          setState(() {
            _update = update;
            _working = false;
            if (update.phase != 'waiting') _qr = null;
            if (update.phase == 'enter_code' || update.phase == 'code_incorrect') {
              _submittingCode = false;
              _codeInput.clear();
              _codeError = update.phase == 'code_incorrect' ? t.clipboardSync.incorrectCode : null;
            }
          });
        }
        if (update.phase == 'authorized') {
          staged = update.fingerprint;
          await widget.controller.savePairing(update, pending: true);
          if (!mounted || generation != _generation) return;
          await session.persisted(saved: true);
        } else if (update.phase == 'complete') {
          await widget.controller.savePairing(update, pending: false);
          complete = true;
          if (mounted && generation == _generation) {
            if (widget.returnOnPaired) {
              Navigator.pop(context, true);
            } else {
              setState(() {
                _update = update;
              });
            }
          }
          await session.stop();
          return;
        } else if (update.phase == 'failed' || update.phase == 'expired' || update.phase == 'cancelled') {
          setState(() {
            _error = update.phase == 'expired' ? t.clipboardSync.pairingExpired : t.clipboardSync.pairingFailed;
          });
          await session.stop();
          return;
        }
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = t.clipboardSync.pairingFailed;
          _working = false;
        });
      }
      await session.stop();
    } finally {
      if (!complete && staged.isNotEmpty) await widget.controller.discardPendingPairing(staged);
    }
  }

  Future<void> _approve() async {
    final session = _session;
    if (session == null || _approved) return;
    setState(() {
      _approved = true;
    });
    try {
      await session.approve(approved: true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = t.clipboardSync.pairingFailed;
        });
      }
    }
  }

  Future<void> _submitCode() async {
    final session = _session;
    if (session == null || _submittingCode) return;
    final code = _codeInput.text;
    if (!RegExp(r'^\d{8}$').hasMatch(code)) {
      setState(() => _codeError = t.clipboardSync.codeLengthError);
      return;
    }
    setState(() {
      _submittingCode = true;
      _codeError = null;
    });
    try {
      await session.submitCode(code: code);
      _codeInput.clear();
    } catch (_) {
      if (mounted) {
        setState(() {
          _submittingCode = false;
          _codeError = t.clipboardSync.pairingFailed;
        });
      }
    }
  }

  @override
  void dispose() {
    widget.controller.pairingScreenClosed();
    _generation++;
    _timer?.cancel();
    final session = _session;
    if (session != null) unawaited(widget.controller.closePairing(session));
    _codeInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nearby = context.ref
        .watch(nearbyDevicesProvider)
        .devices
        .values
        .where((d) => d.ip != null && InternetAddress.tryParse(d.ip!)?.type == InternetAddressType.IPv4)
        .toList();
    final phase = _update?.phase;
    final seconds = (_expires?.difference(DateTime.now()).inSeconds ?? 0).clamp(0, 180);
    return Scaffold(
      appBar: AppBar(title: Text(t.clipboardSync.addDevice)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              if (_error != null) ...[
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 16),
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton(onPressed: _host, child: Text(t.clipboardSync.tryAgain)),
              ] else if (phase == 'complete') ...[
                const Icon(Icons.check_circle_outline, size: 64),
                const SizedBox(height: 16),
                Text(t.clipboardSync.paired, style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
                Text(_update!.name, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                Text(t.clipboardSync.pairedInstructions, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton(onPressed: () => Navigator.pop(context), child: Text(t.general.done)),
              ] else if (phase == 'request') ...[
                const Icon(Icons.devices_rounded, size: 48),
                const SizedBox(height: 16),
                Text(
                  t.clipboardSync.pairingRequest(device: _update!.name),
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(t.clipboardSync.requestDescription, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton(onPressed: _approved ? null : _approve, child: Text(t.clipboardSync.acceptRequest)),
                TextButton(onPressed: () => Navigator.pop(context), child: Text(t.clipboardSync.declineRequest)),
              ] else if (phase == 'display_code') ...[
                Text(t.clipboardSync.displayCodeTitle, style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                Text(_update!.name, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                Text(
                  _update!.code.replaceFirstMapped(RegExp(r'^(\d{4})(\d{4})$'), (match) => '${match[1]} ${match[2]}'),
                  style: Theme.of(context).textTheme.displaySmall?.copyWith(fontFamily: 'monospace'),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                Text(t.clipboardSync.displayCodeInstructions, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Text(t.clipboardSync.codeExpiry, textAlign: TextAlign.center),
                TextButton(onPressed: () => Navigator.pop(context), child: Text(t.general.cancel)),
              ] else if (phase == 'enter_code' || phase == 'code_incorrect') ...[
                Text(t.clipboardSync.enterCodeTitle, style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                Text(_update!.name, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                Text(t.clipboardSync.enterCodeInstructions, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                PairingCodeInput(
                  controller: _codeInput,
                  enabled: !_submittingCode,
                  label: t.clipboardSync.pairingCodeLabel,
                  errorText: _codeError,
                  onSubmitted: _submitCode,
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: _submittingCode ? null : _submitCode, child: Text(t.clipboardSync.confirmCode)),
                TextButton(onPressed: () => Navigator.pop(context), child: Text(t.general.cancel)),
              ] else if (phase == 'requesting' || phase == 'verifying_code' || phase == 'authorized') ...[
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 16),
                Text(
                  phase == 'authorized'
                      ? t.clipboardSync.pairingSaving
                      : phase == 'requesting'
                      ? t.clipboardSync.waitingForAcceptance
                      : t.clipboardSync.verifyingCode,
                  textAlign: TextAlign.center,
                ),
                TextButton(onPressed: () => Navigator.pop(context), child: Text(t.general.cancel)),
              ] else if (_working) ...[
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 16),
                Text(t.clipboardSync.pairingWorking, textAlign: TextAlign.center),
              ] else ...[
                Text(t.clipboardSync.qrInstructions, textAlign: TextAlign.center),
                const SizedBox(height: 20),
                if (_qr != null && seconds > 0)
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      color: Colors.white,
                      child: SizedBox(
                        width: 256,
                        height: 256,
                        child: PrettyQrView.data(
                          data: _qr!,
                          errorCorrectLevel: QrErrorCorrectLevel.M,
                          decoration: const PrettyQrDecoration(shape: PrettyQrSquaresSymbol(color: Colors.black)),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Text(t.clipboardSync.expires(seconds: seconds), textAlign: TextAlign.center),
                if (Platform.isAndroid) ...[
                  const SizedBox(height: 24),
                  FilledButton.icon(onPressed: _scan, icon: const Icon(Icons.qr_code_scanner), label: Text(t.clipboardSync.scanQr)),
                ],
                const SizedBox(height: 24),
                Text(t.clipboardSync.nearbyInstructions),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(child: Text(t.clipboardSync.nearby, style: Theme.of(context).textTheme.titleMedium)),
                    IconButton(onPressed: _refresh, tooltip: t.clipboardSync.refresh, icon: const Icon(Icons.refresh)),
                  ],
                ),
                if (nearby.isEmpty) Text(t.clipboardSync.noNearby),
                for (final device in nearby.take(16))
                  ListTile(
                    leading: const Icon(Icons.devices),
                    title: Text(device.alias),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _join(address: '${device.ip}:53319'),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
