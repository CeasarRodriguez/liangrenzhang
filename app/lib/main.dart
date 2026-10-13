import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'data/native.dart';
import 'data/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final native = NativeBridge();
  String? caPem;
  try {
    caPem = await rootBundle.loadString('assets/ca.crt');
  } on Object {
    caPem = null;
  }

  final env = AppEnv(
    native: native,
    platform: await native.platform(),
    dir: await native.filesDir(),
    caPem: (caPem?.trim().isEmpty ?? true) ? null : caPem,
  );
  final services = await AppServices.open(env);

  runApp(AppRoot(env: env, initial: services));
}
