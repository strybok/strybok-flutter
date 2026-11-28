/// Test helpers for apps that integrate Strybok.
library;

import 'dart:async';

import 'src/deferred_links.dart';
import 'src/link_source.dart';

/// In-memory [LinkSource] to simulate incoming links in unit and widget tests.
///
/// It hands links to the SDK as strings, like the platform does
/// ([RawLinkSource]). [emit] and [initialLink] take a [Uri], which `Uri.parse`
/// has already rewritten; [emitString] and [initialLinkString] take the URL
/// exactly as written, for example to test `parameterLinks` with
/// `https://my-app.links.example.com/a/../b`.
class FakeLinkSource implements RawLinkSource {
  FakeLinkSource({
    this.initialLink,
    this.initialLinkString,
    this.replayInitialLinkOnStream = false,
  });

  /// Link reported as the one that launched the app.
  Uri? initialLink;

  /// The launch link exactly as written; used instead of [initialLink] when
  /// set.
  String? initialLinkString;

  /// Mimics platforms/plugins that also emit the launch link on the stream.
  final bool replayInitialLinkOnStream;

  late final StreamController<String> _controller = StreamController<String>.broadcast(
    onListen: () {
      final initial = _initial;
      if (replayInitialLinkOnStream && initial != null) _controller.add(initial);
    },
  );

  String? get _initial => initialLinkString ?? initialLink?.toString();

  bool get hasListener => _controller.hasListener;

  /// Simulates the OS delivering [uri] to the running app.
  void emit(Uri uri) => _controller.add('$uri');

  /// Simulates the OS delivering [url], exactly as written, to the running app.
  void emitString(String url) => _controller.add(url);

  @override
  Future<Uri?> getInitialLink() async {
    final text = initialLinkString;
    return text == null ? initialLink : Uri.tryParse(text);
  }

  @override
  Stream<Uri> get uriStream => _controller.stream.expand((url) {
    final uri = Uri.tryParse(url);
    return uri == null ? const <Uri>[] : [uri];
  });

  @override
  Future<String?> getInitialLinkString() async => _initial;

  @override
  Stream<String> get stringLinkStream => _controller.stream;
}

/// **For tests only.** A [DeferredLinkStore] that keeps its values in memory.
///
/// Never use it in an app: the values are gone when the process ends, so the
/// deferred-link check would run, and could deliver, again on every launch.
/// Pass the same instance to a second `Strybok` to simulate a restart.
class InMemoryDeferredLinkStore implements DeferredLinkStore {
  InMemoryDeferredLinkStore([Map<String, String>? values]) : values = {...?values};

  /// Everything that was written.
  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
