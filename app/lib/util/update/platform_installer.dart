import 'dart:io';
import 'package:flutter/services.dart';
import 'package:open_file/open_file.dart';

enum InstallationOutcome { opened, replaced }

class PlatformInstaller {
  static bool get canSelfUpdateLinux =>
      Platform.isLinux && Platform.environment['FLATPAK_ID'] == null && (Platform.environment['APPIMAGE'] ?? '').startsWith('/');

  static Future<InstallationOutcome> install(File file) async {
    if (!await file.exists()) throw const FileSystemException('Verified update is missing');
    if (Platform.isWindows) {
      if (!file.path.endsWith('.exe')) throw const FormatException('Expected a Windows installer');
      final header = await _header(file);
      if (header.length < 2 || header[0] != 77 || header[1] != 90) throw const FormatException('Invalid Windows executable');
      // OpenFile uses ShellExecute, allowing Windows to show an elevation prompt.
      final result = await OpenFile.open(file.path);
      if (result.type != ResultType.done) throw Exception('Windows could not open the installer');
      return InstallationOutcome.opened;
    }
    if (Platform.isAndroid) {
      if (!file.path.endsWith('.apk')) throw const FormatException('Expected an Android APK');
      await const MethodChannel('org.localsend.localsend_app/updater').invokeMethod<void>('validateApk', {'path': file.path});
      final result = await OpenFile.open(file.path, type: 'application/vnd.android.package-archive');
      if (result.type != ResultType.done) {
        throw Exception('Allow installation from LocalSend in Android Settings, then try opening the installer again');
      }
      return InstallationOutcome.opened;
    }
    if (Platform.isMacOS) {
      if (!file.path.endsWith('.dmg')) throw const FormatException('Expected a macOS disk image');
      final result = await OpenFile.open(file.path);
      if (result.type != ResultType.done) throw Exception('macOS could not open the disk image');
      return InstallationOutcome.opened;
    }
    if (Platform.isLinux) {
      if (!canSelfUpdateLinux) throw const FileSystemException('Use the package manager for this Linux installation');
      await replaceAppImage(file, File(Platform.environment['APPIMAGE']!));
      return InstallationOutcome.replaced;
    }
    throw UnsupportedError('Use the app store for this platform');
  }

  static Future<List<int>> _header(File file) async {
    final handle = await file.open();
    try {
      return await handle.read(12);
    } finally {
      await handle.close();
    }
  }

  static Future<bool> isAppImage(File file) async {
    final header = await _header(file);
    return header.length >= 11 &&
        header[0] == 127 &&
        header[1] == 69 &&
        header[2] == 76 &&
        header[3] == 70 &&
        header[8] == 65 &&
        header[9] == 73 &&
        header[10] == 2;
  }

  /// Same-filesystem staging and rollback. Never runs a temporary AppImage or
  /// modifies a distro/package-manager installation. Keeps one previous version.
  static Future<void> replaceAppImage(File update, File installed, {Future<void> Function(String)? makeExecutable}) async {
    if (await FileSystemEntity.type(installed.path, followLinks: false) != FileSystemEntityType.file ||
        !await isAppImage(installed) ||
        !await isAppImage(update)) {
      throw const FormatException('Expected regular AppImage files');
    }
    final staged = File('${installed.path}.localsend-new');
    final backup = File('${installed.path}.localsend-previous');
    if (await FileSystemEntity.type(staged.path, followLinks: false) != FileSystemEntityType.notFound) {
      throw const FileSystemException('A pending AppImage update already exists; resolve it before updating again');
    }
    final backupType = await FileSystemEntity.type(backup.path, followLinks: false);
    if (backupType != FileSystemEntityType.notFound && (backupType != FileSystemEntityType.file || !await isAppImage(backup))) {
      throw const FileSystemException('An unrelated file exists at the reserved AppImage backup path');
    }
    var moved = false;
    try {
      await update.copy(staged.path);
      if (makeExecutable != null) {
        await makeExecutable(staged.path);
      } else {
        final result = await Process.run('chmod', ['0755', '--', staged.path]);
        if (result.exitCode != 0) throw const FileSystemException('Cannot make the new AppImage executable');
      }
      // Resolve and validate the exact backup before replacing our previous copy.
      if (backupType == FileSystemEntityType.file) await backup.delete();
      await installed.rename(backup.path);
      moved = true;
      await staged.rename(installed.path);
    } catch (_) {
      if (moved && !await installed.exists()) await backup.rename(installed.path);
      rethrow;
    } finally {
      if (await staged.exists()) await staged.delete();
    }
  }
}
