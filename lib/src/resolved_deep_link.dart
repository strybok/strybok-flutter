import 'package:flutter/foundation.dart';

import 'link_campaign.dart';

/// A link resolved by the Strybok API.
///
/// [routePath], [payload] and [campaign] are plain data chosen by whoever
/// created or shared the link. Treat them like any other untrusted input: map
/// them onto routes your app already knows, never execute them.
@immutable
class ResolvedDeepLink {
  const ResolvedDeepLink({
    required this.uri,
    required this.linkId,
    required this.appId,
    required this.routePath,
    required this.payload,
    this.campaign = const LinkCampaign(),
    this.isDeferred = false,
    this.isProbabilisticMatch = false,
  });

  /// The full URL that opened the app.
  final Uri uri;
  final String linkId;
  final String appId;

  /// In-app route, always starting with `/` (for example `/invite/abc123`).
  final String routePath;

  /// Decoded JSON object attached to the link; empty when none was set.
  final Map<String, Object?> payload;

  /// Campaign values of this open: the link's defaults with the `utm_*`
  /// parameters of [uri] on top. Never `null`; empty when there are none.
  final LinkCampaign campaign;

  /// Whether this link was restored after an installation (a deferred link:
  /// tapped before the app was installed) instead of opening the app directly.
  /// `false` for every link that arrived the normal way.
  final bool isDeferred;

  /// Whether the server **guessed** this link from the network address (iOS
  /// probabilistic matching, only with `allowProbabilisticMatching`). `false`
  /// for every other link.
  ///
  /// Check it: such a link may be another person's, for example on a shared
  /// Wi-Fi. It must never by itself sign anyone in, accept an invitation,
  /// apply a personal discount or show personal content.
  final bool isProbabilisticMatch;

  @override
  String toString() => 'ResolvedDeepLink($routePath, linkId: $linkId)';
}
