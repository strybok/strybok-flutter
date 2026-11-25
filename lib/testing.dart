/// Test helpers for apps that integrate Strybok.
library;

import 'dart:async';

import 'src/deferred_links.dart';
import 'src/link_source.dart';

/// In-memory [LinkSource] to simulate incoming links in unit and widget tests.
class FakeLinkSource implements LinkSource {
  FakeLinkSource({this.initialLink, this.replayInitialLinkOnStream = false});

  /// Link reported as the one that launched the app.
  Uri? initialLink;

  /// Mimics platforms/plugins that also emit the launch link on the stream.
  final bool replayInitialLinkOnStream;

  late final StreamController<Uri> _controller = StreamController<Uri>.broadcast(
    onListen: () {
      final initial = initialLink;
      if (replayInitialLinkOnStream && initial != null) _controller.add(initial);
    },
  );

  bool get hasListener => _controller.hasListener;

  /// Simulates the OS delivering [uri] to the running app.
  void emit(Uri uri) => _controller.add(uri);

  @override
  Future<Uri?> getInitialLink() async => initialLink;

  @override
  Stream<Uri> get uriStream => _controller.stream;
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
