import 'package:flutter/material.dart';
import 'package:strybok/strybok.dart';

import 'app.dart';
import 'config.dart';
import 'session.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final strybok = Strybok(
    apiBaseUrl: Uri.parse(AppConfig.apiBaseUrl),
    allowedHosts: {AppConfig.linkHost},
    onError: (error) => debugPrint('Deep link could not be opened: $error'),
  );
  runApp(ExampleApp(strybok: strybok, session: Session()));
}
