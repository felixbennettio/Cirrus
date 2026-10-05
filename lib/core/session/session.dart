import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/cf_client.dart';
import '../auth/credential.dart';
import '../auth/credential_store.dart';
import '../cache/query_cache.dart';
import '../catalog/catalog.dart';
import '../settings/app_settings.dart';

typedef Json = Map<String, dynamic>;

final credentialStoreProvider = Provider<CredentialStore>((ref) => CredentialStore());

/// All saved credential profiles.
class ProfilesController extends AsyncNotifier<List<Profile>> {
  @override
  Future<List<Profile>> build() => ref.read(credentialStoreProvider).load();

  Future<void> _persist(List<Profile> list) async {
    await ref.read(credentialStoreProvider).save(list);
    state = AsyncData(list);
  }

  Future<void> upsert(Profile p, {bool activate = true}) async {
    final list = [...(state.value ?? const <Profile>[])];
    final i = list.indexWhere((e) => e.id == p.id);
    if (i >= 0) {
      list[i] = p;
    } else {
      list.add(p);
    }
    await _persist(list);
    if (activate) ref.read(settingsProvider.notifier).setActiveProfile(p.id);
  }

  Future<void> remove(String id) async {
    final list = [...(state.value ?? const <Profile>[])]..removeWhere((e) => e.id == id);
    await _persist(list);
    QueryCache.instance.clear();
    await DiskCache.clear();
    final settings = ref.read(settingsProvider);
    if (settings.activeProfileId == id && list.isNotEmpty) {
      ref.read(settingsProvider.notifier).setActiveProfile(list.first.id);
    }
  }
}

final profilesProvider = AsyncNotifierProvider<ProfilesController, List<Profile>>(ProfilesController.new);

final activeProfileProvider = Provider<Profile?>((ref) {
  final profiles = ref.watch(profilesProvider).value ?? const <Profile>[];
  final id = ref.watch(settingsProvider.select((s) => s.activeProfileId));
  return profiles.firstWhereOrNull((p) => p.id == id) ?? profiles.firstOrNull;
});

final clientProvider = Provider<CfClient?>((ref) {
  final p = ref.watch(activeProfileProvider);
  if (p == null) return null;
  return CfClient(p);
});

/// Cache key prefix so different profiles never share cached data.
final cacheScopeProvider = Provider<String>((ref) => ref.watch(activeProfileProvider)?.id ?? '-');

/// Accounts visible to the active credential. Renders from the disk cache
/// first and refreshes in the background.
class AccountsController extends AsyncNotifier<List<Json>> {
  @override
  Future<List<Json>> build() async {
    final client = ref.watch(clientProvider);
    if (client == null) return const [];
    final key = 'accounts:${client.profile.id}';
    final cached = await DiskCache.read(key);
    if (cached is List && cached.isNotEmpty) {
      Future<void>.microtask(() => _refresh(client, key));
      return cached.whereType<Map>().map((e) => Json.from(e)).toList();
    }
    return _fetch(client, key);
  }

  Future<List<Json>> _fetch(CfClient client, String key) async {
    final list = await client.list('/accounts', perPage: 50, maxItems: 1000);
    list.sort(
      (a, b) => (a['name'] as String? ?? '').toLowerCase().compareTo((b['name'] as String? ?? '').toLowerCase()),
    );
    await DiskCache.write(key, list);
    return list;
  }

  Future<void> _refresh(CfClient client, String key) async {
    try {
      final fresh = await _fetch(client, key);
      if (ref.mounted) state = AsyncData(fresh);
    } catch (_) {}
  }

  Future<void> refresh() async {
    final client = ref.read(clientProvider);
    if (client == null) return;
    state = AsyncData(await _fetch(client, 'accounts:${client.profile.id}'));
  }
}

final accountsProvider = AsyncNotifierProvider<AccountsController, List<Json>>(AccountsController.new);

final currentAccountProvider = Provider<Json?>((ref) {
  final accounts = ref.watch(accountsProvider).value ?? const <Json>[];
  final profile = ref.watch(activeProfileProvider);
  if (profile == null || accounts.isEmpty) return null;
  final id = ref.watch(settingsProvider.select((s) => s.activeAccount[profile.id]));
  return accounts.firstWhereOrNull((a) => a['id'] == id) ??
      accounts.firstWhereOrNull((a) => a['id'] == profile.accountId) ??
      accounts.first;
});

final currentAccountIdProvider = Provider<String?>((ref) => ref.watch(currentAccountProvider)?['id'] as String?);

/// Zones of the current account.
class ZonesController extends AsyncNotifier<List<Json>> {
  @override
  Future<List<Json>> build() async {
    final client = ref.watch(clientProvider);
    final accountId = ref.watch(currentAccountIdProvider);
    if (client == null) return const [];
    final key = 'zones:${client.profile.id}:$accountId';
    final cached = await DiskCache.read(key);
    if (cached is List && cached.isNotEmpty) {
      Future<void>.microtask(() => _refresh(client, accountId, key));
      return cached.whereType<Map>().map((e) => Json.from(e)).toList();
    }
    return _fetch(client, accountId, key);
  }

  Future<List<Json>> _fetch(CfClient client, String? accountId, String key) async {
    final list = await client.list(
      '/zones',
      query: {'account.id': ?accountId, 'order': 'name', 'direction': 'asc'},
      perPage: 50,
      maxItems: 5000,
    );
    await DiskCache.write(key, list);
    return list;
  }

  Future<void> _refresh(CfClient client, String? accountId, String key) async {
    try {
      final fresh = await _fetch(client, accountId, key);
      if (ref.mounted) state = AsyncData(fresh);
    } catch (_) {}
  }

  Future<void> refresh() async {
    final client = ref.read(clientProvider);
    if (client == null) return;
    final accountId = ref.read(currentAccountIdProvider);
    state = AsyncData(await _fetch(client, accountId, 'zones:${client.profile.id}:$accountId'));
  }
}

final zonesProvider = AsyncNotifierProvider<ZonesController, List<Json>>(ZonesController.new);

final currentZoneProvider = Provider<Json?>((ref) {
  final zones = ref.watch(zonesProvider).value ?? const <Json>[];
  final accountId = ref.watch(currentAccountIdProvider);
  if (zones.isEmpty) return null;
  final id = ref.watch(settingsProvider.select((s) => s.activeZone[accountId ?? '-']));
  return zones.firstWhereOrNull((z) => z['id'] == id) ?? zones.first;
});

final currentZoneIdProvider = Provider<String?>((ref) => ref.watch(currentZoneProvider)?['id'] as String?);

/// Context values used to fill `{account_id}` / `{zone_id}` in paths.
final scopeIdsProvider = Provider<Map<String, String?>>((ref) {
  final accountId = ref.watch(currentAccountIdProvider);
  final zoneId = ref.watch(currentZoneIdProvider);
  return {
    'account_id': accountId,
    'account_identifier': accountId,
    'account_tag': accountId,
    'zone_id': zoneId,
    'zone_identifier': zoneId,
  };
});

final catalogProvider = FutureProvider<ApiCatalog>((ref) => CatalogLoader.load());
