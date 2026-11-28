import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'link_campaign.dart';

/// Links without an API call: path links such as
/// `https://<host>/product/42?id=7` and Firebase long links
/// `https://<host>/?link=…`, which the owner switches on per application in
/// the dashboard. Pass it as `Strybok(parameterLinks: …)`.
///
/// Without it the SDK accepts only links whose path is a single slug and sends
/// nothing of the query but the `utm_*` values, exactly as before.
@immutable
class ParameterLinks {
  /// [payloadKeys] is `parameterLinks.payloadKeys` of the integration guide
  /// (`GET /v1/apps/:appId/integration`, shown on the dashboard's setup
  /// screen), in that order. An empty list is fine: path links then carry no
  /// payload. While the guide gives `null`, do not set the option at all.
  const ParameterLinks({required this.payloadKeys});

  /// The query keys whose values are sent with a path link, and with the deep
  /// link of a Firebase long link, in the owner's order: at most 20 keys of
  /// 1–40 characters of `A–Z a–z 0–9 _ . -`, none twice, none starting with
  /// `utm_` in any case and none of `st`, `sd`, `si` and `strybok_click`.
  ///
  /// The keys are compiled into the app: a key the owner adds later reaches
  /// users with the next release. Do not list keys that carry personal data.
  final List<String> payloadKeys;

  @override
  bool operator ==(Object other) =>
      other is ParameterLinks && listEquals(other.payloadKeys, payloadKeys);

  @override
  int get hashCode => Object.hashAll(payloadKeys);

  @override
  String toString() => 'ParameterLinks(payloadKeys: $payloadKeys)';
}

const _maxPayloadKeys = 20;
final RegExp _payloadKey = RegExp(r'^[A-Za-z0-9_.-]{1,40}$');

/// Query keys Strybok reads itself (previews and deferred links); `utm_*` too.
const _ownKeys = {'st', 'sd', 'si', 'strybok_click'};

/// Why [keys] is not a valid `payloadKeys` list, or `null` when it is.
String? payloadKeysProblem(List<String> keys) {
  if (keys.length > _maxPayloadKeys) return 'at most $_maxPayloadKeys payload keys are allowed';
  final seen = <String>{};
  for (final key in keys) {
    if (!_payloadKey.hasMatch(key)) {
      return 'the payload key "$key" is not 1–40 characters of A–Z a–z 0–9 _ . -';
    }
    // Compared exactly: `ST` is an ordinary key. The character rule above makes the key ASCII.
    if (key.toLowerCase().startsWith('utm_') || _ownKeys.contains(key)) {
      return 'the payload key "$key" is read by Strybok itself';
    }
    if (!seen.add(key)) return 'the payload key "$key" is listed twice';
  }
  return null;
}

final RegExp _slugPath = RegExp(r'^/[A-Za-z0-9_-]{1,64}$');
const _maxRoutePathLength = 512;
const _maxPayloadValueLength = 256;

/// Paths that are never links, whatever the owner allows: anything under these two …
const _reservedDirectories = ['/.well-known', '/_strybok'];

/// … and exactly these files, which browsers and crawlers ask for on their own.
const _reservedFiles = {
  '/favicon.ico',
  '/robots.txt',
  '/apple-touch-icon.png',
  '/apple-touch-icon-precomposed.png',
  '/sitemap.xml',
  '/ads.txt',
  '/app-ads.txt',
  '/security.txt',
  '/humans.txt',
  '/manifest.json',
  '/site.webmanifest',
  '/browserconfig.xml',
};

/// The `lookup` sent to resolve for [url] with the `parameterLinks` option
/// (SDK contract, "Links without an API call"), or `null` when [url] is not a
/// link of this app.
///
/// [url] is the link exactly as it was received. Everything is read from that
/// string, never through `Uri.parse`, which removes dot segments and rewrites
/// escapes: the path is sent as received or not at all. Of the query only the
/// [payloadKeys] (and for a long link `link`, `apn` and `ibi`) and the `utm_*`
/// values are sent; nothing else of the query and never the fragment.
String? parameterLinkLookup(String url, Set<String> allowedHosts, List<String> payloadKeys) {
  if (!_startsWithAscii(url, 'https://')) return null;
  var end = url.length;
  final hash = url.indexOf('#');
  if (hash >= 0) end = hash;
  final queryEnd = end;
  final question = url.indexOf('?');
  if (question >= 0 && question < end) end = question;
  final rest = url.substring(8, end);
  final slash = rest.indexOf('/');
  final authority = slash < 0 ? rest : rest.substring(0, slash);
  var path = slash < 0 ? '' : rest.substring(slash);
  final query = end < queryEnd ? url.substring(end + 1, queryEnd) : '';

  if (authority.contains('@')) return null; // user info
  var host = authority;
  final colon = authority.lastIndexOf(':');
  if (colon >= 0) {
    if (authority.substring(colon + 1) != '443') return null;
    host = authority.substring(0, colon);
  }
  host = host.toLowerCase();
  if (!allowedHosts.contains(host)) return null;

  final campaign = campaignQuery(query);
  // 1. A slug is ours as without the option; 2. an empty path is the root.
  if (!_slugPath.hasMatch(path)) {
    if (path.isEmpty) path = '/';
    // 3. A Firebase long link; `link` on any other path is an ordinary parameter.
    if (path == '/') {
      final link = _first(query, 'link');
      if (link != null) return _longLinkLookup(host, link.value, query, campaign, payloadKeys);
    }
    // 4. A route path.
    if (!_isRoutePath(path)) return null;
  }
  return _withQuery('https://$host$path', [
    ..._payloadPairs(query, payloadKeys),
    if (campaign.isNotEmpty) campaign,
  ]);
}

/// `https://{host}/?link={deep}`, then `apn` and `ibi` when the URL has them,
/// then the campaign query; `null` when the URL is not ours.
String? _longLinkLookup(
  String host,
  String? link,
  String query,
  String campaign,
  List<String> payloadKeys,
) {
  final deep = link == null ? null : _deepLink(link, payloadKeys);
  if (deep == null) return null;
  final pairs = ['link=${encodeQueryValue(deep)}'];
  for (final key in const ['apn', 'ibi']) {
    final occurrence = _first(query, key);
    if (occurrence == null) continue;
    // Sent as they are, even empty: the server compares them with the app's identifiers.
    final value = occurrence.value;
    if (value == null) return null; // Cannot be decoded: the URL is not ours.
    pairs.add('$key=${encodeQueryValue(value)}');
  }
  if (campaign.isNotEmpty) pairs.add(campaign);
  return 'https://$host/?${pairs.join('&')}';
}

/// The deep link [value] (the decoded `link` parameter) rebuilt from its
/// lower-cased scheme and host, its path and the payload keys of its query —
/// nothing else of it, and never its fragment; `null` when it is not a deep
/// link.
String? _deepLink(String value, List<String> payloadKeys) {
  for (final unit in value.codeUnits) {
    if (unit <= 0x20 || unit == 0x7F || unit == 0x5C) return null;
  }
  final String scheme;
  if (_startsWithAscii(value, 'https://')) {
    scheme = 'https';
  } else if (_startsWithAscii(value, 'http://')) {
    scheme = 'http';
  } else {
    return null;
  }
  final hostStart = scheme.length + 3;
  var index = hostStart;
  while (index < value.length && _isHostUnit(value.codeUnitAt(index))) {
    index++;
  }
  if (index == hostStart) return null;
  // The host is followed by nothing, a path, a query or a fragment: never user info or a port.
  if (index < value.length && !const [0x2F, 0x3F, 0x23].contains(value.codeUnitAt(index))) {
    return null;
  }
  final host = value.substring(hostStart, index).toLowerCase();
  var rest = value.substring(index);
  final hash = rest.indexOf('#');
  if (hash >= 0) rest = rest.substring(0, hash);
  final question = rest.indexOf('?');
  final path = question >= 0 ? rest.substring(0, question) : rest;
  final query = question >= 0 ? rest.substring(question + 1) : '';
  return _withQuery(
    '$scheme://$host${path.isEmpty ? '/' : path}',
    _payloadPairs(query, payloadKeys),
  );
}

/// `key=value` pairs of the [payloadKeys], in their order: of each key its
/// first occurrence in [query], kept when its decoded value is 1–256 UTF-16
/// code units without control characters. A first occurrence that cannot be
/// decoded or breaks these rules drops the key; a later one never counts.
List<String> _payloadPairs(String query, List<String> payloadKeys) {
  if (payloadKeys.isEmpty || query.isEmpty) return const [];
  final first = <String, String?>{};
  for (final part in query.split('&')) {
    final equals = part.indexOf('=');
    final key = decodeQueryText(equals >= 0 ? part.substring(0, equals) : part);
    if (key == null || first.containsKey(key) || !payloadKeys.contains(key)) continue;
    first[key] = equals >= 0 ? decodeQueryText(part.substring(equals + 1)) : '';
  }
  return [
    for (final key in payloadKeys)
      if (first[key] case final String value when _isPayloadValue(value))
        '$key=${encodeQueryValue(value)}',
  ];
}

bool _isPayloadValue(String value) {
  if (value.isEmpty || value.length > _maxPayloadValueLength) return false;
  for (final unit in value.codeUnits) {
    if (unit <= 0x1F || (unit >= 0x7F && unit <= 0x9F)) return false;
  }
  return true;
}

/// The first occurrence of [key] in [query], whose key is compared after
/// decoding: `null` when there is none; its `value` is `null` when it cannot
/// be decoded and empty for a part without `=`.
({String? value})? _first(String query, String key) {
  if (query.isEmpty) return null;
  for (final part in query.split('&')) {
    final equals = part.indexOf('=');
    if (decodeQueryText(equals >= 0 ? part.substring(0, equals) : part) != key) continue;
    return (value: equals >= 0 ? decodeQueryText(part.substring(equals + 1)) : '');
  }
  return null;
}

/// A route path as received: 1–512 characters of the URL path characters,
/// every `%` followed by two hexadecimal digits, no `//`, no `.` or `..`
/// segment (also written with `%2e`), and nothing a browser asks for on its
/// own. Never decoded or normalised.
bool _isRoutePath(String path) {
  if (path.isEmpty || path.length > _maxRoutePathLength || path.codeUnitAt(0) != 0x2F) {
    return false;
  }
  if (path.contains('//')) return false;
  for (var index = 0; index < path.length; index++) {
    final unit = path.codeUnitAt(index);
    if (unit == 0x25) {
      if (index + 2 >= path.length ||
          _hexValue(path.codeUnitAt(index + 1)) < 0 ||
          _hexValue(path.codeUnitAt(index + 2)) < 0) {
        return false;
      }
    } else if (!_isPathUnit(unit)) {
      return false;
    }
  }
  for (final segment in path.split('/')) {
    final dots = segment.replaceAll('%2e', '.').replaceAll('%2E', '.');
    if (dots == '.' || dots == '..') return false;
  }
  for (final directory in _reservedDirectories) {
    if (path == directory || path.startsWith('$directory/')) return false;
  }
  return !_reservedFiles.contains(path);
}

/// `A–Z a–z 0–9 - . _ ~ ! $ & ' ( ) * + , ; = : @` and `/`.
bool _isPathUnit(int unit) =>
    _isUnreserved(unit) || unit == 0x2F || unit == 0x3A || unit == 0x40 || _isSubDelim(unit);

bool _isSubDelim(int unit) => const [
  0x21, // !
  0x24, // $
  0x26, // &
  0x27, // '
  0x28, // (
  0x29, // )
  0x2A, // *
  0x2B, // +
  0x2C, // ,
  0x3B, // ;
  0x3D, // =
].contains(unit);

/// `A–Z a–z 0–9 . - _`: the characters of a deep link's host.
bool _isHostUnit(int unit) => _isAlphanumeric(unit) || unit == 0x2E || unit == 0x2D || unit == 0x5F;

/// `A–Z a–z 0–9 - . _ ~`: what is never percent-encoded.
bool _isUnreserved(int unit) =>
    _isAlphanumeric(unit) || unit == 0x2D || unit == 0x2E || unit == 0x5F || unit == 0x7E;

bool _isAlphanumeric(int unit) =>
    (unit >= 0x30 && unit <= 0x39) ||
    (unit >= 0x41 && unit <= 0x5A) ||
    (unit >= 0x61 && unit <= 0x7A);

/// Whether [text] starts with [lowerCasePrefix], with ASCII letters in any case.
bool _startsWithAscii(String text, String lowerCasePrefix) {
  if (text.length < lowerCasePrefix.length) return false;
  for (var index = 0; index < lowerCasePrefix.length; index++) {
    var unit = text.codeUnitAt(index);
    if (unit >= 0x41 && unit <= 0x5A) unit += 0x20;
    if (unit != lowerCasePrefix.codeUnitAt(index)) return false;
  }
  return true;
}

String _withQuery(String base, List<String> pairs) =>
    pairs.isEmpty ? base : '$base?${pairs.join('&')}';

const _hexDigits = '0123456789ABCDEF';

/// [value] as its UTF-8 bytes, each byte outside `A–Z a–z 0–9 - . _ ~` written
/// as `%XX` with upper-case digits: a space is `%20`, `+` is `%2B`.
String encodeQueryValue(String value) {
  final out = StringBuffer();
  for (final byte in utf8.encode(value)) {
    if (_isUnreserved(byte)) {
      out.writeCharCode(byte);
    } else {
      out
        ..write('%')
        ..write(_hexDigits[byte >> 4])
        ..write(_hexDigits[byte & 0x0F]);
    }
  }
  return out.toString();
}

/// Percent-decodes [text] (a key or a value of a query) as UTF-8, with `+` as
/// a space. `null` when it cannot be decoded: a `%` without two hexadecimal
/// digits, a lone surrogate, or bytes that are not UTF-8. Unlike
/// `decodeQueryComponent` nothing is replaced: what cannot be read is not sent.
String? decodeQueryText(String text) {
  var plain = true;
  for (final unit in text.codeUnits) {
    if (unit == 0x25 || unit >= 0x80) {
      plain = false;
      break;
    }
  }
  if (plain) return text.replaceAll('+', ' ');
  // A leading "A" keeps a byte-order mark at the start: the UTF-8 decoder would drop it.
  final bytes = <int>[0x41];
  for (var index = 0; index < text.length; index++) {
    final unit = text.codeUnitAt(index);
    if (unit == 0x25) {
      if (index + 2 >= text.length) return null;
      final high = _hexValue(text.codeUnitAt(index + 1));
      final low = _hexValue(text.codeUnitAt(index + 2));
      if (high < 0 || low < 0) return null;
      bytes.add(high * 16 + low);
      index += 2;
    } else if (unit == 0x2B) {
      bytes.add(0x20);
    } else if (unit < 0x80) {
      bytes.add(unit);
    } else {
      var rune = unit;
      if (unit >= 0xD800 && unit <= 0xDBFF && index + 1 < text.length) {
        final next = text.codeUnitAt(index + 1);
        if (next >= 0xDC00 && next <= 0xDFFF) {
          rune = 0x10000 + ((unit - 0xD800) << 10) + (next - 0xDC00);
          index++;
        }
      }
      if (rune >= 0xD800 && rune <= 0xDFFF) return null; // A lone surrogate.
      bytes.addAll(utf8.encode(String.fromCharCode(rune)));
    }
  }
  try {
    return utf8.decode(bytes).substring(1);
  } on FormatException {
    return null;
  }
}

int _hexValue(int unit) {
  if (unit >= 0x30 && unit <= 0x39) return unit - 0x30;
  final lower = unit | 0x20;
  return lower >= 0x61 && lower <= 0x66 ? lower - 0x57 : -1;
}
