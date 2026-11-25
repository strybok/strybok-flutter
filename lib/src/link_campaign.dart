import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Campaign values of a resolved link: the link's defaults, overridden per
/// value by the `utm_*` parameters of the URL that was tapped (`utm_source` is
/// [source], and so on).
///
/// A value that is not set is `null`. They are labels chosen by whoever created
/// or shared the link, so use them for attribution only and never to decide
/// what the user may see or do.
@immutable
class LinkCampaign {
  const LinkCampaign({this.source, this.medium, this.campaign, this.term, this.content});

  /// Reads the `campaign` object of a resolve answer: keeps the string fields
  /// with the five known names and ignores everything else. Anything that is
  /// not a JSON object gives an empty [LinkCampaign]; this never throws.
  factory LinkCampaign.fromJson(Object? json) {
    if (json is! Map) return const LinkCampaign();
    String? field(String name) {
      final value = json[name];
      return value is String ? value : null;
    }

    return LinkCampaign(
      source: field('source'),
      medium: field('medium'),
      campaign: field('campaign'),
      term: field('term'),
      content: field('content'),
    );
  }

  /// `utm_source`: where the link was shared, for example `instagram`.
  final String? source;

  /// `utm_medium`: the kind of channel, for example `social`.
  final String? medium;

  /// `utm_campaign`: the name of the campaign.
  final String? campaign;

  /// `utm_term`.
  final String? term;

  /// `utm_content`.
  final String? content;

  /// Whether no value is set.
  bool get isEmpty =>
      source == null && medium == null && campaign == null && term == null && content == null;

  /// Whether at least one value is set.
  bool get isNotEmpty => !isEmpty;

  /// The values that are set, under the names `source`, `medium`, `campaign`,
  /// `term` and `content`. This is what the SDK reports with an app open.
  Map<String, String> toJson() => {
    'source': ?source,
    'medium': ?medium,
    'campaign': ?campaign,
    'term': ?term,
    'content': ?content,
  };

  @override
  bool operator ==(Object other) =>
      other is LinkCampaign &&
      other.source == source &&
      other.medium == medium &&
      other.campaign == campaign &&
      other.term == term &&
      other.content == content;

  @override
  int get hashCode => Object.hash(source, medium, campaign, term, content);

  @override
  String toString() => 'LinkCampaign(${toJson()})';
}

/// The only query parameters ever sent to the API, in the order they are sent.
const _campaignQueryKeys = ['utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content'];

final RegExp _campaignValue = RegExp(r'^[A-Za-z0-9._~-]{1,64}$');

/// The SDK contract's "campaign query": what of a tapped link's raw query
/// string (the text after `?`) is sent to the API. Empty when nothing is.
///
/// Only the five `utm_*` keys are kept, compared exactly after decoding; of
/// each the first occurrence counts, and it is dropped unless its decoded value
/// is 1–64 characters of `A-Z a-z 0-9 . _ ~ -`. The result is `key=value`
/// pairs joined with `&` in a fixed order; such values never need encoding.
/// Every other parameter may hold private data and is never returned.
String campaignQuery(String query) {
  if (query.isEmpty) return '';
  final first = <String, String?>{};
  for (final part in query.split('&')) {
    final equals = part.indexOf('=');
    final key = decodeQueryComponent(equals >= 0 ? part.substring(0, equals) : part);
    if (key == null || first.containsKey(key) || !_campaignQueryKeys.contains(key)) continue;
    // A value that cannot be decoded still is the first occurrence of its key.
    first[key] = equals >= 0 ? decodeQueryComponent(part.substring(equals + 1)) : '';
  }
  return [
    for (final key in _campaignQueryKeys)
      if (first[key] case final String value when _campaignValue.hasMatch(value)) '$key=$value',
  ].join('&');
}

/// Percent-decodes as UTF-8 with `+` as a space. `null` for a malformed escape,
/// which no key or value of ours can contain; invalid UTF-8 becomes U+FFFD,
/// which none can contain either. Never throws, unlike
/// [Uri.decodeQueryComponent]. Not exported from the package.
String? decodeQueryComponent(String text) {
  if (!text.contains('%')) return text.replaceAll('+', ' ');
  final bytes = <int>[];
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit == 0x25) {
      if (i + 2 >= text.length) return null;
      final high = _hexDigit(text.codeUnitAt(i + 1));
      final low = _hexDigit(text.codeUnitAt(i + 2));
      if (high < 0 || low < 0) return null;
      bytes.add(high * 16 + low);
      i += 2;
    } else if (unit == 0x2B) {
      bytes.add(0x20);
    } else if (unit < 0x80) {
      bytes.add(unit);
    } else {
      bytes.addAll(utf8.encode(String.fromCharCode(unit)));
    }
  }
  return utf8.decode(bytes, allowMalformed: true);
}

int _hexDigit(int unit) {
  if (unit >= 0x30 && unit <= 0x39) return unit - 0x30;
  final lower = unit | 0x20;
  return lower >= 0x61 && lower <= 0x66 ? lower - 0x57 : -1;
}
