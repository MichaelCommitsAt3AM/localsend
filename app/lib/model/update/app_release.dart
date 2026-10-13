class AppReleaseAsset {
  final String name;
  final String downloadUrl;
  final int size;
  final String contentType;
  final String? digest;

  const AppReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
    required this.contentType,
    this.digest,
  });

  factory AppReleaseAsset.fromJson(Map<String, dynamic> json) {
    return AppReleaseAsset(
      name: json['name'] as String? ?? '',
      downloadUrl: json['browser_download_url'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      contentType: json['content_type'] as String? ?? '',
      digest: json['digest'] as String?,
    );
  }
}

class AppRelease {
  final String version;
  final String tagName;
  final String name;
  final String body;
  final String htmlUrl;
  final DateTime? publishedAt;
  final List<AppReleaseAsset> assets;

  const AppRelease({
    required this.version,
    required this.tagName,
    required this.name,
    required this.body,
    required this.htmlUrl,
    required this.publishedAt,
    required this.assets,
  });

  factory AppRelease.fromJson(Map<String, dynamic> json) {
    final tagName = json['tag_name'] as String? ?? '';
    // Strip leading 'v' or 'V'
    final cleanVersion = tagName.replaceFirst(RegExp(r'^[vV]'), '');

    final assetsList = (json['assets'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>().map(AppReleaseAsset.fromJson).toList();

    return AppRelease(
      version: cleanVersion,
      tagName: tagName,
      name: json['name'] as String? ?? tagName,
      body: json['body'] as String? ?? '',
      htmlUrl: json['html_url'] as String? ?? '',
      publishedAt: json['published_at'] != null ? DateTime.tryParse(json['published_at'] as String) : null,
      assets: assetsList,
    );
  }
}
