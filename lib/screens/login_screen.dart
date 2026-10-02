import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/firestore_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _passwordFocusNode = FocusNode();
  final _formKey = GlobalKey<FormState>();
  bool _isSigningIn = false;
  bool _capsLockOn = false;
  String? _error;

  void _checkCapsLock(KeyEvent event) {
    final capsOn = HardwareKeyboard.instance.lockModesEnabled.contains(
      KeyboardLockMode.capsLock,
    );
    if (capsOn != _capsLockOn) {
      setState(() => _capsLockOn = capsOn);
    }
  }

  Future<void> _signIn() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isSigningIn = true;
      _error = null;
    });

    try {
      await context.read<FirestoreService>().signInWithEmail(
        _emailController.text,
        _passwordController.text,
      );
      // Auth state stream picks this up automatically — nothing else to do here.
    } catch (e) {
      setState(() => _error = 'Sign in failed. Check your email and password.');
    } finally {
      if (mounted) setState(() => _isSigningIn = false);
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 64, color: Colors.blue),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _emailController,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.emailAddress,
                  validator: (v) =>
                      (v == null || v.isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 16),
                KeyboardListener(
                  focusNode: _passwordFocusNode,
                  onKeyEvent: _checkCapsLock,
                  child: TextFormField(
                    controller: _passwordController,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      border: const OutlineInputBorder(),
                      suffixIcon: _capsLockOn
                          ? Tooltip(
                              message: 'Caps Lock is on',
                              child: Icon(
                                Icons.keyboard_capslock,
                                color: Colors.orange.shade700,
                              ),
                            )
                          : null,
                    ),
                    obscureText: true,
                    validator: (v) =>
                        (v == null || v.isEmpty) ? 'Required' : null,
                  ),
                ),
                if (_capsLockOn) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.orange.shade200),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber,
                          color: Colors.orange.shade700,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Caps Lock is on',
                          style: TextStyle(
                            color: Colors.orange.shade700,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                ],
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _isSigningIn ? null : _signIn,
                  child: _isSigningIn
                      ? const CircularProgressIndicator()
                      : const Text('SIGN IN'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
