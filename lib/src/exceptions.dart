/// Base class of every error reported by the SDK.
sealed class StrybokException implements Exception {
  const StrybokException(this.message, {this.uri});

  final String message;

  /// The link that was being handled, when known.
  final Uri? uri;

  @override
  String toString() => '$runtimeType: $message';
}

/// The URI is not a Strybok link for this app: wrong scheme, a host outside
/// `allowedHosts`, or a path that is not a single slug.
final class UnsupportedLinkException extends StrybokException {
  const UnsupportedLinkException(super.message, {super.uri});
}

/// The service does not know this link, or it is disabled or expired.
final class LinkNotFoundException extends StrybokException {
  const LinkNotFoundException({super.uri}) : super('No active link matches this URL');
}

/// The request could not be completed (offline, DNS, connection reset) after
/// all retries.
final class StrybokNetworkException extends StrybokException {
  const StrybokNetworkException(super.message, {super.uri, this.cause});

  final Object? cause;
}

/// The service did not answer in time, after all retries.
final class StrybokTimeoutException extends StrybokException {
  const StrybokTimeoutException({super.uri}) : super('The resolve request timed out');
}

/// The service answered with an unexpected status code or body.
final class StrybokServerException extends StrybokException {
  const StrybokServerException(super.message, {super.uri, this.statusCode});

  final int? statusCode;
}
