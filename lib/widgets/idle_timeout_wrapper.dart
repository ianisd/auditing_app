import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/firestore_service.dart';

class IdleTimeoutWrapper extends StatefulWidget {
  final Widget child;
  final Duration timeout;
  final Duration warningDuration;

  const IdleTimeoutWrapper({
    super.key,
    required this.child,
    this.timeout = const Duration(minutes: 5),
    this.warningDuration = const Duration(seconds: 60),
  });

  @override
  State<IdleTimeoutWrapper> createState() => _IdleTimeoutWrapperState();
}

class _IdleTimeoutWrapperState extends State<IdleTimeoutWrapper> {
  Timer? _idleTimer;
  bool _isWarningShowing = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    _resetTimer();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    super.dispose();
  }

  bool _onKeyEvent(KeyEvent event) {
    _resetTimer();
    return false; // never swallow the key — just observe it
  }

  void _handleActivity(PointerEvent _) => _resetTimer();

  void _resetTimer() {
    if (_isWarningShowing) return;
    _idleTimer?.cancel();
    var delay = widget.timeout - widget.warningDuration;
    if (delay < const Duration(seconds: 5)) {
      delay = const Duration(seconds: 5);
    }
    _idleTimer = Timer(delay, _showWarning);
  }

  Future<void> _showWarning() async {
    if (!mounted || _isWarningShowing) return;
    _isWarningShowing = true;

    final staySignedIn = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _IdleWarningDialog(warningDuration: widget.warningDuration),
    );

    _isWarningShowing = false;

    if (staySignedIn == true) {
      _resetTimer();
    } else {
      await _signOutNow();
    }
  }

  Future<void> _signOutNow() async {
    if (!mounted) return;
    await context.read<FirestoreService>().signOut();
    if (mounted) {
      Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _handleActivity,
      onPointerMove: _handleActivity,
      onPointerSignal: _handleActivity,
      behavior: HitTestBehavior.translucent,
      child: widget.child,
    );
  }
}

class _IdleWarningDialog extends StatefulWidget {
  final Duration warningDuration;
  const _IdleWarningDialog({required this.warningDuration});

  @override
  State<_IdleWarningDialog> createState() => _IdleWarningDialogState();
}

class _IdleWarningDialogState extends State<_IdleWarningDialog> {
  late int _secondsLeft;
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    _secondsLeft = widget.warningDuration.inSeconds;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) {
        timer.cancel();
        if (mounted) Navigator.of(context).pop(false); // false → sign out
      }
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Still there?'),
      content: Text("You'll be signed out in $_secondsLeft seconds due to inactivity."),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Sign Out Now'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Stay Signed In'),
        ),
      ],
    );
  }
}