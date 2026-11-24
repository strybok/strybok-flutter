import 'package:flutter/foundation.dart';

/// A link made by `Strybok.createLink`.
@immutable
class CreatedLink {
  const CreatedLink({
    required this.url,
    required this.slug,
    required this.routePath,
    required this.linkId,
  });

  /// The HTTPS link to share.
  final Uri url;

  /// Last part of [url]; identifies the link on its host.
  final String slug;

  /// The in-app route the link opens.
  final String routePath;
  final String linkId;

  @override
  String toString() => 'CreatedLink($url, linkId: $linkId)';
}
