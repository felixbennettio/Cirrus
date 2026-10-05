import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/cf_client.dart';
import '../core/session/session.dart';
import '../core/util/tr.dart';
import '../features/generic/resource_page.dart';
import '../features/generic/resource_specs.dart';
import '../features/home/home_page.dart';
import '../features/onboarding/add_profile_page.dart';
import '../features/settings/settings_page.dart';
import '../features/zones/domains_page.dart';
import '../ui/shell/app_shell.dart';
import '../ui/widgets/async_view.dart';
import 'feature_routes.dart';

final _rootKey = GlobalKey<NavigatorState>();
final _shellKey = GlobalKey<NavigatorState>();

/// Bridges Riverpod state changes into GoRouter's refresh.
class _RouterRefresh extends ChangeNotifier {
  void ping() => notifyListeners();
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh();
  ref.listen(profilesProvider, (_, _) => refresh.ping());
  ref.onDispose(refresh.dispose);

  return GoRouter(
    navigatorKey: _rootKey,
    // Development builds (pointed at a mock API) can open a given page.
    initialLocation: isDevApiBase ? (Platform.environment['CIRRUS_INITIAL_ROUTE'] ?? '/') : '/',
    refreshListenable: refresh,
    redirect: (context, state) {
      final profiles = ref.read(profilesProvider);
      if (profiles.isLoading && !profiles.hasValue) return null;
      final hasProfile = (profiles.value ?? const []).isNotEmpty;
      final atWelcome = state.matchedLocation == '/welcome';
      if (!hasProfile && !atWelcome) return '/welcome';
      if (hasProfile && atWelcome) return '/';
      return null;
    },
    errorBuilder: (context, state) => Scaffold(
      appBar: AppBar(),
      body: EmptyView(
        icon: Icons.explore_off_outlined,
        title: context.tr('Page not found', '页面不存在'),
        subtitle: state.uri.toString(),
      ),
    ),
    routes: [
      GoRoute(path: '/welcome', builder: (_, _) => const AddProfilePage(firstRun: true)),
      GoRoute(
        path: '/profiles/add',
        parentNavigatorKey: _rootKey,
        builder: (_, _) => const AddProfilePage(),
      ),
      ShellRoute(
        navigatorKey: _shellKey,
        builder: (context, state, child) => AppShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(path: '/', pageBuilder: (_, _) => const NoTransitionPage(child: HomePage())),
          GoRoute(
            path: '/domains',
            pageBuilder: (_, s) => NoTransitionPage(
              child: DomainsPage(openAdd: s.uri.queryParameters['add'] == '1'),
            ),
          ),
          GoRoute(path: '/settings', pageBuilder: (_, _) => const NoTransitionPage(child: SettingsPage())),
          GoRoute(
            path: '/r/:spec',
            pageBuilder: (context, s) {
              final spec = specById[s.pathParameters['spec']];
              return NoTransitionPage(
                key: s.pageKey,
                child: spec == null
                    ? EmptyView(icon: Icons.help_outline, title: s.pathParameters['spec'] ?? '')
                    : ResourcePage(spec: spec),
              );
            },
            routes: [
              GoRoute(
                path: ':id',
                builder: (context, s) {
                  final spec = specById[s.pathParameters['spec']]!;
                  return ResourceDetailPage(
                    spec: spec,
                    id: s.pathParameters['id']!,
                    initial: s.extra is Map<String, dynamic> ? s.extra as Map<String, dynamic> : null,
                  );
                },
              ),
            ],
          ),
          GoRoute(
            path: '/doc/:id',
            pageBuilder: (context, s) {
              final d = documentById[s.pathParameters['id']];
              return NoTransitionPage(
                key: s.pageKey,
                child: d == null ? EmptyView(icon: Icons.help_outline, title: s.pathParameters['id'] ?? '') : DocumentPage(spec: d),
              );
            },
          ),
          ...featureRoutes,
        ],
      ),
    ],
  );
});
