import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'services/offline_storage.dart';
import 'services/store_manager.dart';
import 'services/logger_service.dart';
import 'screens/home_screen.dart';
import 'screens/setup_store_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Device Orientation
  if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android)) {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  // 2. Initialize Hive
  await Hive.initFlutter();

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

  // ✅ CRITICAL: Check connectivity before initialization
  final hasInternet = await _checkConnectivity();

  if (!hasInternet) {
    logger.info('📱 App starting in OFFLINE mode - using cached data only');
  } else {
    logger.info('🌐 App starting in ONLINE mode - will sync data');
  }

  // Initialize storeManager
  await storeManager.init();

  // ✅ CRITICAL: If active store exists, set up services
  if (storeManager.activeStore != null) {
    await storeManager.setActiveStore(storeManager.activeStore!['id']);
  }

  runApp(
    MultiProvider(
      providers: [
        Provider<LoggerService>.value(value: logger),
        ChangeNotifierProvider.value(value: storeManager),
        ChangeNotifierProvider.value(value: offlineStorage),
        Provider<Connectivity>.value(value: Connectivity()),
        // StreamProvider for connectivity status
        StreamProvider<List<ConnectivityResult>>(
          create: (_) => Connectivity().onConnectivityChanged,
          initialData: const [],
        ),
      ],
      child: const MyApp(),
    ),
  );
}

Future<bool> _checkConnectivity() async {
  try {
    final connectivity = Connectivity();
    final result = await connectivity.checkConnectivity();
    return result.isNotEmpty &&
        result.any((r) => r != ConnectivityResult.none);
  } catch (e) {
    return false;
  }
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
  String? _lastProcessedStoreId;
  bool _isOfflineBannerShowing = false;
  bool _hasInitialSetup = false;
  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;

  @override
  void initState() {
    super.initState();
    // ✅ FIXED: Only call once after build, no listener loop
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleInitialStoreSetup());

    // Subscribe to connectivity changes
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(_handleConnectivityChange);
  }

  @override
  void dispose() {
    _connectivitySubscription.cancel(); // Cancel subscription
    super.dispose();
  }

  // ✅ FIXED: Initial setup only
  void _handleInitialStoreSetup() {
    if (!mounted) return;

    final storeManager = context.read<StoreManager>();
    final offlineStorage = context.read<OfflineStorage>();

    if (storeManager.activeStore != null) {
      final activeId = storeManager.activeStore!['id'];

      if (!offlineStorage.isReady || offlineStorage.currentStoreId != activeId) {
        print('DEBUG: Initial store setup - calling offlineStorage.switchStore($activeId)');
        offlineStorage.switchStore(activeId);
        _hasInitialSetup = true;
      }
    }
  }

  // ✅ NEW: Handle connectivity changes
  void _handleConnectivityChange(List<ConnectivityResult> results) {
    final hasInternet = results.isNotEmpty &&
        results.any((r) => r != ConnectivityResult.none);

    if (hasInternet && _isOfflineBannerShowing) {
      // Just came online - refresh data
      _refreshData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('📶 Back online - refreshing data'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
        setState(() {
          _isOfflineBannerShowing = false;
        });
      }
    } else if (!hasInternet && !_isOfflineBannerShowing) {
      // Just went offline
      if (mounted) {
        setState(() {
          _isOfflineBannerShowing = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('📴 Offline mode - using cached data'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  // ✅ FIXED: Refresh data when coming online
  Future<void> _refreshData() async {
    final offlineStorage = context.read<OfflineStorage>();
    final storeManager = context.read<StoreManager>();

    if (storeManager.activeStore != null && offlineStorage.isReady) {
      try {
        // ✅ FIXED: Use correct method name
        await offlineStorage.loadMasterSuppliersFromSheet();
        // Note: setState is already called in _handleConnectivityChange
      } catch (e) {
        print('Failed to refresh data: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final storeManager = context.watch<StoreManager>();
    final offlineStorage = context.watch<OfflineStorage>();

    // Watch connectivity (this will trigger rebuilds when connectivity changes)
    final connectivityResults = context.watch<List<ConnectivityResult>>();
    final hasInternet = connectivityResults.isNotEmpty &&
        connectivityResults.any((r) => r != ConnectivityResult.none);

    if (storeManager.activeStore == null) {
      return const SetupStoreScreen();
    }

    if (!offlineStorage.isReady) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              if (!hasInternet) ...[
                const Icon(Icons.wifi_off, color: Colors.orange, size: 32),
                const SizedBox(height: 8),
                Text(
                  'Offline mode - using cached data',
                  style: TextStyle(color: Colors.orange.shade700),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        const HomeScreen(),
        // Offline banner
        if (_isOfflineBannerShowing)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              color: Colors.orange,
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.wifi_off, color: Colors.white, size: 16),
                  SizedBox(width: 8),
                  Text(
                    'Offline Mode - Working from cache',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}