import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/settings/app_settings.dart';
import '../../core/util/tr.dart';

/// Covers the app with a lock screen when app lock is enabled: at start
/// and after the app has been in the background for over a minute.
class LockGate extends ConsumerStatefulWidget {
  const LockGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate> with WidgetsBindingObserver {
  bool _locked = true;
  bool _authenticating = false;
  DateTime? _backgroundedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_enabled) _unlock();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool get _enabled => ref.read(settingsProvider).appLock && !Platform.isLinux;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_enabled) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _backgroundedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final since = _backgroundedAt;
      _backgroundedAt = null;
      if (since != null && DateTime.now().difference(since) > const Duration(minutes: 1) && !_authenticating) {
        setState(() => _locked = true);
        _unlock();
      }
    }
  }

  Future<void> _unlock() async {
    if (_authenticating) return;
    _authenticating = true;
    try {
      final ok = await LocalAuthentication().authenticate(
        localizedReason: context.tr('Unlock Cirrus', '解锁 Cirrus'),
        persistAcrossBackgrounding: true,
      );
      if (ok && mounted) setState(() => _locked = false);
    } catch (_) {
      // Leave locked; user can retry.
    } finally {
      _authenticating = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(settingsProvider.select((s) => s.appLock)) && !Platform.isLinux;
    if (!enabled || !_locked) return widget.child;
    final theme = Theme.of(context);
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: Material(
            color: theme.colorScheme.surface,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Image.asset('assets/branding/cirrus_256.png', width: 88, height: 88),
                  ),
                  const SizedBox(height: 20),
                  Text('Cirrus', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _unlock,
                    icon: const Icon(Icons.lock_open),
                    label: Text(context.tr('Unlock', '解锁')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
