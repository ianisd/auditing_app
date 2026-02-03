import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter/foundation.dart';

import 'services/offline_storage.dart';
import 'services/google_sheets_service.dart';
import 'services/sync_service.dart';
import 'services/store_manager.dart';
import 'services/logger_service.dart'; // Import Logger
import 'screens/home_screen.dart';
import 'screens/setup_store_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android)) {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  await Hive.initFlutter();

  // 1. Initialize Logger FIRST
  final logger = LoggerService();
  await logger.init();
  logger.info("App Started");

  // Initialize Global Services
  final storeManager = StoreManager();
  await storeManager.init();

  final offlineStorage = OfflineStorage();
  // offlineStorage.init(); // Handled by Hive.initFlutter

  runApp(
    MultiProvider(
      providers: [
        // 2. Add Logger Provider
        Provider<LoggerService>.value(value: logger),

        ChangeNotifierProvider.value(value: storeManager),
        ChangeNotifierProvider.value(value: offlineStorage),

        ChangeNotifierProxyProvider<StoreManager, SyncService>(
          create: (context) => SyncService(
            offlineStorage: offlineStorage,
            googleSheets: GoogleSheetsService(scriptUrl: ''),
            logger: logger, // <--- PASS LOGGER HERE
          ),
          update: (context, storeMgr, previousSyncService) {
            final url = storeMgr.activeStore?['url'] ?? '';
            if (previousSyncService != null && previousSyncService.googleSheets.scriptUrl == url) {
              return previousSyncService;
            }
            return SyncService(
              offlineStorage: offlineStorage,
              googleSheets: GoogleSheetsService(scriptUrl: url),
              logger: logger, // <--- AND HERE
            );
          },
        ),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Stock Counter',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
        appBarTheme: const AppBarTheme(elevation: 0, centerTitle: true),
      ),
      home: const RootSwitcher(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class RootSwitcher extends StatefulWidget {
  const RootSwitcher({super.key});

  @override
  State<RootSwitcher> createState() => _RootSwitcherState();
}

class _RootSwitcherState extends State<RootSwitcher> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleStoreChange());
    context.read<StoreManager>().addListener(_handleStoreChange);
  }

  @override
  void dispose() {
    context.read<StoreManager>().removeListener(_handleStoreChange);
    super.dispose();
  }

  void _handleStoreChange() {
    if (!mounted) return;
    final storeManager = context.read<StoreManager>();
    final offlineStorage = context.read<OfflineStorage>();

    if (storeManager.activeStore != null) {
      final activeId = storeManager.activeStore!['id'];
      if (!offlineStorage.isReady || offlineStorage.currentStoreId != activeId) {
        offlineStorage.switchStore(activeId);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final storeManager = context.watch<StoreManager>();
    final offlineStorage = context.watch<OfflineStorage>();

    if (storeManager.activeStore == null) {
      return const SetupStoreScreen();
    }

    if (!offlineStorage.isReady) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return const HomeScreen();
  }
}