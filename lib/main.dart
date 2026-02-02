import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import 'services/offline_storage.dart';
import 'services/google_sheets_service.dart';
import 'services/sync_service.dart';
import 'services/store_manager.dart';
import 'screens/home_screen.dart';
import 'screens/setup_store_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  final appDir = await getApplicationDocumentsDirectory();
  Hive.init(appDir.path);

  // Initialize Global Services
  final storeManager = StoreManager();
  await storeManager.init();

  final offlineStorage = OfflineStorage();
  await offlineStorage.init();

  runApp(
    MultiProvider(
      providers: [
        // 1. Store Manager (Global)
        ChangeNotifierProvider.value(value: storeManager),

        // 2. Offline Storage (Global)
        ChangeNotifierProvider.value(value: offlineStorage),

        // 3. Sync Service (Dependent on StoreManager)
        // This ProxyProvider automatically updates SyncService whenever StoreManager changes (e.g. switching stores)
        ChangeNotifierProxyProvider<StoreManager, SyncService>(
          create: (context) => SyncService(
            offlineStorage: offlineStorage,
            googleSheets: GoogleSheetsService(scriptUrl: ''), // Empty initially
          ),
          update: (context, storeMgr, previousSyncService) {
            final url = storeMgr.activeStore?['url'] ?? '';

            // If we have a previous service and the URL hasn't changed, reuse it
            if (previousSyncService != null && previousSyncService.googleSheets.scriptUrl == url) {
              return previousSyncService;
            }

            // Otherwise create a new SyncService with the correct URL
            return SyncService(
              offlineStorage: offlineStorage,
              googleSheets: GoogleSheetsService(scriptUrl: url),
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

// This widget handles the Logic of "Which screen to show?"
// and "Opening the correct database file"
class RootSwitcher extends StatefulWidget {
  const RootSwitcher({super.key});

  @override
  State<RootSwitcher> createState() => _RootSwitcherState();
}

class _RootSwitcherState extends State<RootSwitcher> {
  @override
  void initState() {
    super.initState();
    // Schedule the initial check
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleStoreChange());
    // Listen for future changes
    context.read<StoreManager>().addListener(_handleStoreChange);
  }

  @override
  void dispose() {
    context.read<StoreManager>().removeListener(_handleStoreChange);
    super.dispose();
  }

  // Checks if the OfflineStorage matches the Active Store
  void _handleStoreChange() {
    if (!mounted) return;
    final storeManager = context.read<StoreManager>();
    final offlineStorage = context.read<OfflineStorage>();

    if (storeManager.activeStore != null) {
      final activeId = storeManager.activeStore!['id'];

      // If storage is not ready OR we are pointing to the wrong store ID
      if (!offlineStorage.isReady || offlineStorage.currentStoreId != activeId) {
        // This triggers the async switch (which sets isReady=false, notifies, then true)
        offlineStorage.switchStore(activeId);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch both providers to trigger rebuilds on status change
    final storeManager = context.watch<StoreManager>();
    final offlineStorage = context.watch<OfflineStorage>();

    // 1. No Store Selected -> Setup
    if (storeManager.activeStore == null) {
      return const SetupStoreScreen();
    }

    // 2. Storage is switching/loading -> Loading Indicator
    // offlineStorage.isReady becomes false immediately when switchStore is called
    if (!offlineStorage.isReady) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // 3. Ready -> Home
    return const HomeScreen();
  }
}