import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter/foundation.dart';

import 'services/offline_storage.dart';
import 'services/google_sheets_service.dart';
import 'services/sync_service.dart';
import 'services/store_manager.dart';
import 'services/logger_service.dart';
import 'screens/home_screen.dart';
import 'screens/setup_store_screen.dart';

// Import your generated adapters if you have run 'flutter pub run build_runner build'
// import 'models/inventory_item.dart';
// import 'models/store_config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Device Orientation
  if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android)) {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  // 2. Initialize Hive
  await Hive.initFlutter();

  // --- OPTIONAL: Register Adapters ---
  // If you generated the .g.dart files, register them here to avoid crashes later.
  // Hive.registerAdapter(InventoryItemAdapter());
  // Hive.registerAdapter(StoreConfigAdapter());

  // 3. Init Logger
  final logger = LoggerService();
  await logger.init();
  logger.info("App Started (v1.4.0)");

  // 4. Set up Global Error Catching
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    logger.error('UI Error', details.exception.toString());
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    logger.error('Platform Error', error.toString());
    return true;
  };

  // 5. Initialize Global Services
  final storeManager = StoreManager();
  await storeManager.init(); // Load active store info before app starts

  final offlineStorage = OfflineStorage();
  // We do NOT init offlineStorage here; RootSwitcher handles that based on active store.

  runApp(
    MultiProvider(
      providers: [
        Provider<LoggerService>.value(value: logger),
        ChangeNotifierProvider.value(value: storeManager),
        ChangeNotifierProvider.value(value: offlineStorage),

        // SyncService depends on the URL in StoreManager
        ChangeNotifierProxyProvider<StoreManager, SyncService>(
          create: (context) => SyncService(
            offlineStorage: offlineStorage,
            googleSheets: GoogleSheetsService(scriptUrl: ''),
            logger: logger,
          ),
          update: (context, storeMgr, previousSyncService) {
            final url = storeMgr.activeStore?['url'] ?? '';

            // Avoid recreating service if URL hasn't changed
            if (previousSyncService != null && previousSyncService.googleSheets.scriptUrl == url) {
              return previousSyncService;
            }

            return SyncService(
              offlineStorage: offlineStorage,
              googleSheets: GoogleSheetsService(scriptUrl: url),
              logger: logger,
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
    // Check initial state
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleStoreChange());
    // Listen for future changes
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

    // If we have an active store, make sure OfflineStorage is pointing to the right box
    if (storeManager.activeStore != null) {
      final activeId = storeManager.activeStore!['id'];

      // If storage isn't ready OR we switched stores, initialize the specific store box
      if (!offlineStorage.isReady || offlineStorage.currentStoreId != activeId) {
        offlineStorage.switchStore(activeId);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final storeManager = context.watch<StoreManager>();
    final offlineStorage = context.watch<OfflineStorage>();

    // 1. No store selected -> Go to Setup
    if (storeManager.activeStore == null) {
      return const SetupStoreScreen();
    }

    // 2. Store selected, but Hive boxes loading -> Show Spinner
    if (!offlineStorage.isReady) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // 3. Ready -> Go Home
    return const HomeScreen();
  }
}