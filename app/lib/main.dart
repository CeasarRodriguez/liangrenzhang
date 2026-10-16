import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'data/native.dart';
import 'data/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final native = NativeBridge();
  Future<String?> pem(String asset) async {
    try {
      final text = await rootBundle.loadString(asset);
      return text.trim().isEmpty ? null : text;
    } on Object {
      return null;
    }
  }

  final env = AppEnv(
    native: native,
    platform: await native.platform(),
    dir: await native.filesDir(),
    caPem: await pem('assets/ca.crt'),
    relayCaPem: await pem('assets/relay_ca.crt'),
  );
  final services = await AppServices.open(env);

  runApp(AppRoot(env: env, initial: services));
}
