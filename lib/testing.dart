/// Test helpers for apps that integrate Strybok.
library;

import 'dart:async';

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
