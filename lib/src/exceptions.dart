/// Base class of every error reported by the SDK.
sealed class StrybokException implements Exception {
  const StrybokException(this.message, {this.uri});

  final String message;

  /// The link that was being handled, when known. Always `null` for errors of
  /// `createLink`.
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
  const StrybokTimeoutException({super.uri, String message = 'The resolve request timed out'})
    : super(message);
}

/// The service answered with an unexpected status code or body.
final class StrybokServerException extends StrybokException {
  const StrybokServerException(super.message, {super.uri, this.statusCode});

  final int? statusCode;
}

/// `createLink` only: no `clientKey` is configured (thrown before any network
/// call), or the service refused the key (401) because it is wrong, was
/// replaced, or the owner switched link creation off. The service does not say
/// which. Retrying does not help.
final class StrybokUnauthorizedException extends StrybokException {
  const StrybokUnauthorizedException([
    super.message = 'The client key is missing or was not accepted',
  ]);
}

/// `createLink` only: the route is not covered by the route patterns listed
/// for the application in the dashboard (403). Retrying does not help.
final class RouteNotAllowedException extends StrybokException {
  const RouteNotAllowedException(this.routePath)
    : super('This route is not allowed for links created from the app');

  /// The route that was refused.
  final String routePath;
}

/// `createLink` only: too many requests from this device's address or for this
/// app, or the app's daily limit of new links is reached (429). Never retried
/// automatically; let the user try again later.
final class StrybokRateLimitedException extends StrybokException {
  const StrybokRateLimitedException({this.retryAfter}) : super('Too many requests');

  /// How long to wait before trying again, from the `Retry-After` header.
  /// `null` when the service did not say.
  final Duration? retryAfter;
}

/// `createLink` only: the arguments were rejected, either before sending or by
/// the service (400, 413 or 422). Retrying the same call does not help.
final class StrybokValidationException extends StrybokException {
  const StrybokValidationException(super.message, {this.issues = const []});

  /// What the service found wrong, field by field; empty when it did not say
  /// or when the call was rejected before sending.
  final List<StrybokValidationIssue> issues;
}

/// One problem reported by the service for a `createLink` call.
final class StrybokValidationIssue {
  const StrybokValidationIssue({required this.path, required this.message});

  /// The field concerned, for example `title` or `payload`; empty when the
  /// problem is not about one field.
  final String path;
  final String message;

  @override
  String toString() => path.isEmpty ? message : '$path: $message';
}
