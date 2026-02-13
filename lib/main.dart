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
  logger.info("App Started (v1.7.0)");

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
  final offlineStorage = OfflineStorage();
  final storeManager = StoreManager(
    offlineStorage: offlineStorage,
    logger: logger,
  );

  // ✅ CRITICAL FIX: Initialize storeManager BEFORE offlineStorage
  await storeManager.init();

  // ✅ CRITICAL FIX: Initialize offlineStorage AFTER active store is set
  // This ensures offlineStorage loads data for the correct store
  if (storeManager.activeStore != null) {
    await offlineStorage.switchStore(storeManager.activeStore!['id']);
  }

  runApp(
    MultiProvider(
      providers: [
        Provider<LoggerService>.value(value: logger),
        ChangeNotifierProvider.value(value: storeManager),
        ChangeNotifierProvider.value(value: offlineStorage),
        // ⚠️ REMOVED GLOBAL SyncService PROVIDER
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
  String? _lastProcessedStoreId; // ✅ NEW: Track last processed store

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

      // ✅ CRITICAL: Only process if different from last processed store
      if (activeId == _lastProcessedStoreId) {
        return; // Exit early to prevent loop
      }

      _lastProcessedStoreId = activeId;

      // ✅ CRITICAL: Let StoreManager handle the service setup first
      // The service setup happens in setActiveStore() which should be called
      // by your UI flow (e.g., when user selects a store)

      // Only call switchStore if storage isn't ready for this store
      if (!offlineStorage.isReady || offlineStorage.currentStoreId != activeId) {
        print('DEBUG: Calling offlineStorage.switchStore($activeId)');
        offlineStorage.switchStore(activeId);
      }
    }
  }

  // ✅ ADDED: Missing build() method
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