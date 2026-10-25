import 'dart:async';

import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/model/state/server/web_share_state.dart';
import 'package:localsend_app/provider/network/server/controller/receive_controller.dart';
import 'package:localsend_app/provider/network/server/controller/send_controller.dart';
import 'package:localsend_app/provider/network/server/server_utils.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/alias_generator.dart';
import 'package:localsend_app/util/native/web_pages_loader.dart';
import 'package:localsend_app/util/server_health_probe.dart';
import 'package:localsend_isolates/constants.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:localsend_isolates/rust/api/server.dart' show WebI18n, WebMode, WebParams;
import 'package:localsend_isolates/util/rust.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('Server');

/// This provider runs the server and provides the current server state.
/// It is a singleton provider, so only one server can be running at a time.
/// The server state is null if the server is not running.
/// The server can receive files (since v1) and send files (since v2).
///
/// The HTTP server itself runs in Rust (inside the server isolate); this
/// provider starts it, listens to its events and holds the resulting state.
final serverProvider = NotifierProvider<ServerService, ServerState?>(
  (ref) {
    return ServerService();
  },
  onChanged: (_, next, ref) {
    final settings = ref.read(settingsProvider);
    final syncState = ref.read(parentIsolateProvider).syncState;
    final syncStatePrev = (syncState.alias, syncState.port, syncState.protocol, syncState.serverRunning, syncState.download);
    final syncStateNext = (
      next?.alias ?? settings.alias,
      next?.port ?? settings.port,
      (next?.https ?? settings.https) ? ProtocolType.https : ProtocolType.http,
      next != null,
      next?.webDownloadState != null,
    );

    if (syncStatePrev == syncStateNext) {
      return;
    }

    ref
        .redux(parentIsolateProvider)
        .dispatch(
          IsolateSyncServerStateAction(
            alias: syncStateNext.$1,
            port: syncStateNext.$2,
            protocol: syncStateNext.$3,
            serverRunning: syncStateNext.$4,
            download: syncStateNext.$5,
          ),
        );
  },
);

class ServerService extends Notifier<ServerState?> {
  late final _serverUtils = ServerUtils(
    refFunc: () => ref,
    getState: () => state!,
    getStateOrNull: () => state,
    setState: (builder) => state = builder(state),
  );

  late final _receiveController = ReceiveController(_serverUtils);
  late final _sendController = SendController(_serverUtils);

  StreamSubscription<HttpServerEvent>? _subscription;

  ServerService();

  @override
  ServerState? init() {
    return null;
  }

  /// The default (equality) strategy runs the dart_mappable deep equality which
  /// walks the whole files map on every change, making state updates O(n) per received file.
  @override
  bool updateShouldNotify(ServerState? prev, ServerState? next) => !identical(prev, next);

  /// The debug observer stringifies the state on every change,
  /// so large file maps must be summarized to keep transfers responsive in debug mode.
  @override
  String describeState(ServerState? state) {
    final session = state?.session;
    if (session == null || session.files.length <= 10) {
      return state.toString();
    }
    return state!.copyWith(session: session.copyWith(files: {})).toString().replaceFirst('files: {}', 'files: <${session.files.length} files>');
  }

  /// Starts the server from user settings.
  Future<ServerState?> startServerFromSettings() async {
    final settings = ref.read(settingsProvider);
    return startServer(
      alias: settings.alias,
      port: settings.port,
      https: settings.https,
    );
  }

  /// Starts the server.
  /// Passing a [web] share additionally serves the download page
  /// ([WebShareDownload], so web browsers can download the offered files)
  /// or the upload page ([WebShareUpload], so web browsers can upload files).
  Future<ServerState?> startServer({
    required String alias,
    required int port,
    required bool https,
    WebShareState? web,
  }) async {
    if (state != null) {
      _logger.info('Server already running.');
      return null;
    }

    alias = alias.trim();
    if (alias.isEmpty) {
      alias = generateRandomAlias();
    }

    if (port < 0 || port > 65535) {
      port = defaultPort;
    }

    _logger.info('Starting server...');

    // The server isolate derives its configuration from the sync state,
    // so it must be published before the start task.
    _syncServerState(alias: alias, port: port, https: https, serverRunning: true, download: web is WebShareDownload);

    final settings = ref.read(settingsProvider);
    // Custom pages provided by the user next to the executable, if any.
    // A custom error-403.html replaces the built-in 403 page even while no web
    // share is active; client certificates stay mandatory in that mode.
    final customWebPages = await loadCustomWebPages();
    final events = ref
        .redux(parentIsolateProvider)
        .dispatchTakeResult(
          IsolateHttpServerStartAction(
            pin: switch (web) {
              WebShareUpload(:final pin) => pin,
              _ => settings.receivePin,
            },
            verifyChecksums: settings.verifyChecksums,
            web: WebParams(
              mode: switch (web) {
                WebShareDownload(:final state, :final pin) => WebMode.download(
                  files: {
                    for (final entry in state.files.entries) entry.key: entry.value.file.toRust(),
                  },
                  pin: pin,
                ),
                WebShareUpload() => const WebMode.upload(),
                null => const WebMode.disabled(),
              },
              i18N: WebI18n(
                waiting: t.web.waiting,
                enterPin: t.web.enterPin,
                invalidPin: t.web.invalidPin,
                tooManyAttempts: t.web.tooManyAttempts,
                rejected: t.web.rejected,
                uploadRejected: t.sendPage.rejected,
                busy: t.sendPage.busy,
                files: t.web.files,
                fileName: t.web.fileName,
                size: t.web.size,
                dropHint: t.sendTab.placeItems,
              ),
              pages: customWebPages,
            ),
            showToken: settings.showToken,
          ),
        );

    final started = Completer<void>();
    var ended = false;
    final subscription = events.listen(
      (event) {
        if (event is HttpServerStartedEvent) {
          if (!started.isCompleted) {
            started.complete();
          }
          return;
        }
        _handleEvent(event);
      },
      onError: (Object error) {
        if (!started.isCompleted) {
          started.completeError(error);
        } else {
          _logger.severe('HTTP server error: $error');
        }
      },
      onDone: () {
        ended = true;
        if (!started.isCompleted) {
          started.completeError(StateError('Server event stream ended before startup'));
        } else if (identical(_serverEvents, events)) {
          _recoverAfterStreamEnds(events);
        }
      },
    );

    try {
      await started.future;
    } catch (e) {
      await subscription.cancel();
      _syncServerState(alias: alias, port: port, https: https, serverRunning: false, download: false);
      _logger.warning('Failed to start server', e);
      rethrow;
    }

    _subscription = subscription;
    _serverEvents = events;

    final newServerState = ServerState(
      alias: alias,
      port: port,
      https: https,
      session: null,
      web: web,
    );

    state = newServerState;
    if (ended) {
      _recoverAfterStreamEnds(events);
    }
    _logger.info('Server started. (Port: $port, ${https ? 'HTTPS' : 'HTTP'} only)');
    return newServerState;
  }

  Future<void> stopServer() async {
    _logger.info('Stopping server...');
    _serverEvents = null;
    await _subscription?.cancel();
    _subscription = null;
    await ref.redux(parentIsolateProvider).dispatchAsync(IsolateHttpServerStopAction());
    state = null;
    _logger.info('Server stopped.');
  }

  Future<ServerState?> restartServerFromSettings() async {
    await stopServer();
    return await startServerFromSettings();
  }

  Future<ServerState?> restartServer({
    required String alias,
    required int port,
    required bool https,
    WebShareState? web,
  }) async {
    await stopServer();
    return await startServer(alias: alias, port: port, https: https, web: web);
  }

  Future<void> acceptFileRequest(Map<String, String> fileNameMap) async {
    await _receiveController.acceptFileRequest(fileNameMap);
  }

  void declineFileRequest() {
    _receiveController.declineFileRequest();
  }

  /// Updates the destination directory for the current session.
  void setSessionDestinationDir(String destinationDirectory) {
    _receiveController.setSessionDestinationDir(destinationDirectory);
  }

  /// Updates the save to gallery setting for the current session.
  void setSessionSaveToGallery(bool saveToGallery) {
    _receiveController.setSessionSaveToGallery(saveToGallery);
  }

  /// In addition to [closeSession], this method also cancels incoming requests.
  void cancelSession() {
    _receiveController.cancelSession();
  }

  /// Clears the session.
  void closeSession() {
    _receiveController.closeSession();
  }

  /// Restarts the server with web download (the download API) enabled for [files].
  /// The auto accept setting of a previous web download state is kept.
  Future<void> restartServerWithWebDownload({
    required String alias,
    required int port,
    required bool https,
    required List<CrossFile> files,
    String? pin,
  }) async {
    final webDownloadState = await _sendController.buildWebDownloadState(files: files);
    await restartServer(
      alias: alias,
      port: port,
      https: https,
      web: WebShareDownload(state: webDownloadState, pin: pin),
    );
  }

  /// Updates the pin of the active web share mode (download or upload page).
  /// The pin is enforced by the Rust server, so the server is restarted.
  Future<void> setWebPin(String? pin) async {
    final current = state;
    final web = current?.web;
    if (current == null || web == null || web.pin == pin) {
      return;
    }

    await restartServer(
      alias: current.alias,
      port: current.port,
      https: current.https,
      web: switch (web) {
        // Sessions do not survive a server restart.
        WebShareDownload(:final state) => WebShareDownload(
          state: state.copyWith(sessions: {}),
          pin: pin,
        ),
        WebShareUpload() => WebShareUpload(pin: pin),
      },
    );
  }

  /// Updates the auto accept setting for web download.
  void setWebDownloadAutoAccept(bool autoAccept) {
    state = state?.updateWebDownloadState((webDownload) => webDownload.copyWith(autoAccept: autoAccept));
  }

  /// Accepts the web download request.
  void acceptWebDownloadRequest(String sessionId) {
    _sendController.acceptRequest(sessionId);
  }

  /// Declines the web download request.
  void declineWebDownloadRequest(String sessionId) {
    _sendController.declineRequest(sessionId);
  }

  void _handleEvent(HttpServerEvent event) {
    switch (event) {
      case HttpServerStartedEvent():
        break;
      case HttpServerRegisterEvent():
        // ignore: discarded_futures
        _receiveController.onRegister(event);
      case HttpServerPrepareUploadEvent():
        // ignore: discarded_futures
        _receiveController.onPrepareUpload(event);
      case HttpServerFileUploadEvent():
        _receiveController.onFileUpload(event);
      case HttpServerFileUploadProgressEvent():
        _receiveController.onFileUploadProgress(event);
      case HttpServerFileUploadResultEvent():
        // ignore: discarded_futures
        _receiveController.onFileUploadResult(event);
      case HttpServerSessionEndEvent():
        _receiveController.onSessionEnd(event);
      case HttpServerPrepareUploadAbortedEvent():
        _receiveController.onPrepareUploadAborted(event);
      case HttpServerCancelReceivedEvent():
        _receiveController.onCancelReceived(event);
      case HttpServerShowEvent():
        _receiveController.onShow(event);
      case HttpServerWebPrepareDownloadEvent():
        _sendController.onPrepareDownload(event);
      case HttpServerWebFileDownloadEvent():
        // ignore: discarded_futures
        _sendController.onFileDownload(event);
      case HttpServerListenerFailedEvent():
        // ignore: discarded_futures
        _restartAfterListenerFailure(event.error);
    }
  }

  /// Restarts the server after its listening socket failed permanently,
  /// e.g. because iOS reclaimed it while the app was suspended.
  /// The Rust server has already stopped itself at this point.
  Future<void> _restartAfterListenerFailure(String error) async {
    _logger.warning('The server listener failed: $error. Restarting server.');
    await _restartDeadServer();
  }

  bool _probeInFlight = false;
  bool _recoveryInFlight = false;
  Stream<HttpServerEvent>? _serverEvents;

  void _recoverAfterStreamEnds(Stream<HttpServerEvent> events) {
    // Avoid a restart loop if the replacement isolate cannot initialize. A
    // deliberate stop or a newer server invalidates this recovery attempt.
    Timer(const Duration(seconds: 1), () {
      if (identical(_serverEvents, events)) {
        _logger.warning('The server event stream ended unexpectedly. Recreating the server isolate.');
        unawaited(_restartDeadServer());
      }
    });
  }

  /// Checks the HTTP service after mobile suspension, including whether its
  /// application event receiver is still alive.
  Future<void> ensureRunning() async {
    final current = state;
    if (current == null || _probeInFlight) {
      return;
    }

    _probeInFlight = true;
    try {
      await probeLocalServer(
        port: current.port,
        https: current.https,
        identity: ref.read(parentIsolateProvider).syncState.securityContext,
      );
    } catch (e) {
      if (identical(state, current)) {
        _logger.warning('The server failed its HTTP readiness probe: $e. Restarting server.');
        await _restartDeadServer();
      }
    } finally {
      _probeInFlight = false;
    }
  }

  /// Restarts the server with its current configuration after its listening socket died.
  Future<void> _restartDeadServer() async {
    final current = state;
    if (current == null || _recoveryInFlight) {
      return;
    }

    _recoveryInFlight = true;
    try {
      _serverEvents = null;
      await _subscription?.cancel();
      _subscription = null;
      await ref.redux(parentIsolateProvider).dispatchAsync(IsolateRecreateHttpServerAction());
      state = null;
      await startServer(
        alias: current.alias,
        port: current.port,
        https: current.https,
        web: switch (current.web) {
          // Sessions do not survive a server restart.
          WebShareDownload(:final state, :final pin) => WebShareDownload(
            state: state.copyWith(sessions: {}),
            pin: pin,
          ),
          final other => other,
        },
      );
    } catch (e) {
      _logger.severe('Failed to restart the server after its listener failed', e);
    } finally {
      _recoveryInFlight = false;
    }
  }

  void _syncServerState({
    required String alias,
    required int port,
    required bool https,
    required bool serverRunning,
    required bool download,
  }) {
    ref
        .redux(parentIsolateProvider)
        .dispatch(
          IsolateSyncServerStateAction(
            alias: alias,
            port: port,
            protocol: https ? ProtocolType.https : ProtocolType.http,
            serverRunning: serverRunning,
            download: download,
          ),
        );
  }
}
