import 'dart:async';
import 'package:counting_app/screens/login_screen.dart';
import 'package:counting_app/widgets/idle_timeout_wrapper.dart';
import 'package:path/path.dart' as path; // Add this
import 'package:path_provider/path_provider.dart'; // Add this

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:window_manager/window_manager.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

import 'services/offline_storage.dart';
import 'services/store_manager.dart';
import 'services/logger_service.dart';
import 'services/network_ping_service.dart';
import 'services/firestore_service.dart';
import 'models/sync_model.dart'; // 🔥 ADD THIS
import 'screens/home_screen.dart';
import 'screens/setup_store_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 0. Initialize Firebase
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    debugPrint('Firebase initialization failed: $e');
  }

  // 1. Device Orientation
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android)) {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  // 2. Window sizing (desktop only)
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      minimumSize: Size(960, 640),
      size: Size(1280, 800),
      title: 'Stock Counter',
      center: true,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  // 3. Initialize Hive
  final appDir = await getApplicationSupportDirectory();
  final dataPath = path.join(appDir.path, 'database');
  Hive.init(dataPath);

  // 4. Init Logger
  final logger = LoggerService();
  await logger.init();
  logger.info("App Started (v1.7.0)");

  // 5. Set up Global Error Catching
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    logger.error('UI Error', details.exception.toString());
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    logger.error('Platform Error', error.toString());
    return true;
  };

  // 6. Initialize Global Services
  final offlineStorage = OfflineStorage();
  final syncStatus = SyncStatus();
  final firestoreService = FirestoreService(logger: logger);

  final storeManager = StoreManager(
    offlineStorage: offlineStorage,
    logger: logger,
    syncStatus: syncStatus,
    firestoreService: firestoreService,
  );

  // 7. Initialize Network Ping Service & Attach Lifecycle Observer
  final networkPingService = NetworkPingService();
  WidgetsBinding.instance.addObserver(
    AppLifecycleObserver(pingService: networkPingService),
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
        // 🔥 Order matters! Providers can only see what's ABOVE them
        Provider<LoggerService>.value(value: logger),
        ChangeNotifierProvider.value(value: offlineStorage),
        ChangeNotifierProvider.value(value: storeManager),
        ChangeNotifierProvider.value(value: networkPingService),
        ChangeNotifierProvider.value(value: syncStatus), // 🔥 ADDED
        Provider<FirestoreService>.value(value: firestoreService),
        Provider<Connectivity>.value(value: Connectivity()),
        StreamProvider<List<ConnectivityResult>>(
          create: (_) => Connectivity().onConnectivityChanged,
          initialData: const [ConnectivityResult.none],
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
    return result.isNotEmpty && result.any((r) => r != ConnectivityResult.none);
  } catch (e) {
    return false;
  }
}

// ... rest of main.dart (AppLifecycleObserver, MyApp, RootSwitcher remain the same)

// ---------------------------------------------------------
// App Lifecycle Observer to pause/resume network pings
// ---------------------------------------------------------
class AppLifecycleObserver with WidgetsBindingObserver {
  final NetworkPingService pingService;

  AppLifecycleObserver({required this.pingService});

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      pingService.setAppBackground(true);
    } else if (state == AppLifecycleState.resumed) {
      pingService.setAppBackground(false);
    }
  }
}

// ---------------------------------------------------------
// App Root
// ---------------------------------------------------------
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
      home: StreamBuilder<User?>(
        stream: context.read<FirestoreService>().authStateChanges,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.data == null) {
            return const LoginScreen();
          }
          return const IdleTimeoutWrapper(child: RootSwitcher());
        },
      ),
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
  bool _isOfflineBannerShowing = false;
  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _handleInitialStoreSetup(),
    );

    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
      _handleConnectivityChange,
    );
  }

  @override
  void dispose() {
    _connectivitySubscription.cancel();
    super.dispose();
  }

  void _handleInitialStoreSetup() {
    if (!mounted) return;

    final storeManager = context.read<StoreManager>();
    final offlineStorage = context.read<OfflineStorage>();

    if (storeManager.activeStore != null) {
      final activeId = storeManager.activeStore!['id'];

      if (!offlineStorage.isReady ||
          offlineStorage.currentStoreId != activeId) {
        debugPrint(
          'DEBUG: Initial store setup - calling offlineStorage.switchStore($activeId)',
        );
        offlineStorage.switchStore(activeId);
      }
    }
  }

  void _handleConnectivityChange(List<ConnectivityResult> results) {
    final hasInternet =
        results.isNotEmpty && results.any((r) => r != ConnectivityResult.none);

    if (hasInternet && _isOfflineBannerShowing) {
      _refreshData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('📶 Back online - refreshing data'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
        setState(() => _isOfflineBannerShowing = false);
      }
    } else if (!hasInternet && !_isOfflineBannerShowing) {
      if (mounted) {
        setState(() => _isOfflineBannerShowing = true);
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

  Future<void> _refreshData() async {
    final offlineStorage = context.read<OfflineStorage>();
    final storeManager = context.read<StoreManager>();

    if (storeManager.activeStore != null && offlineStorage.isReady) {
      try {
        await offlineStorage.loadMasterSuppliersFromSheet();
      } catch (e) {
        debugPrint('Failed to refresh data: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final storeManager = context.watch<StoreManager>();
    final offlineStorage = context.watch<OfflineStorage>();
    final connectivityResults = context.watch<List<ConnectivityResult>>();
    final hasInternet =
        connectivityResults.isNotEmpty &&
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
