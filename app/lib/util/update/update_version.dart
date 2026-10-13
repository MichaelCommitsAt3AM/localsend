/// SemVer precedence, with numeric build metadata used when both builds
/// explicitly provide a build number (the Flutter release convention).
class UpdateVersion implements Comparable<UpdateVersion> {
  final List<int> core;
  final List<String> prerelease;
  final int? build;
  UpdateVersion._(this.core, this.prerelease, this.build);
  factory UpdateVersion.parse(String value) {
    final match = RegExp(
      r'^[vV]?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
    ).firstMatch(value.trim());
    if (match == null) throw const FormatException('Invalid release version');
    final pre = match[4]?.split('.') ?? <String>[];
    if (pre.any((p) => RegExp(r'^0[0-9]+$').hasMatch(p))) throw const FormatException('Invalid prerelease version');
    return UpdateVersion._([int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!)], pre, int.tryParse(match[5] ?? ''));
  }
  @override
  int compareTo(UpdateVersion other) {
    for (var i = 0; i < 3; i++) {
      final result = core[i].compareTo(other.core[i]);
      if (result != 0) return result;
    }
    if (prerelease.isEmpty != other.prerelease.isEmpty) return prerelease.isEmpty ? 1 : -1;
    for (var i = 0; i < prerelease.length && i < other.prerelease.length; i++) {
      final a = int.tryParse(prerelease[i]);
      final b = int.tryParse(other.prerelease[i]);
      final result = a != null && b != null
          ? a.compareTo(b)
          : a != null
          ? -1
          : b != null
          ? 1
          : prerelease[i].compareTo(other.prerelease[i]);
      if (result != 0) return result;
    }
    final length = prerelease.length.compareTo(other.prerelease.length);
    if (length != 0) return length;
    return build != null && other.build != null ? build!.compareTo(other.build!) : 0;
  }
}
