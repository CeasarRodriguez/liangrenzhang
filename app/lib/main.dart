import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sembast/sembast_io.dart';

import 'app.dart';
import 'data/local_db.dart';
import 'data/native.dart';
import 'data/offline.dart';
import 'data/services.dart';
import 'providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final native = NativeBridge();
  final platform = await native.platform();
  final dir = await native.filesDir();
  final database = await databaseFactoryIo.openDatabase(
    // kept apart so trial data never mixes with a real account
    offlineMode ? '$dir/ledger-offline.db' : '$dir/ledger.db',
  );

  String? caPem;
  try {
    caPem = await rootBundle.loadString('assets/ca.crt');
  } on Object {
    caPem = null;
  }

  final services = AppServices(db: LocalDb(database), native: native, caPem: caPem, platform: platform);
  await services.init();

  runApp(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const LedgerApp()));
}
