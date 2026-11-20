import 'dart:convert';

// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme_provider.dart';

/// 读取本机追觅名单，供关注动态引导和关注列表查看。
/// 记录本机是否使用过追觅及其保存的用户名单。
class FollowingFeedMigration {
  const FollowingFeedMigration({
    required this.usedSeeking,
    required this.users,
    required this.dismissed,
  });
  final bool usedSeeking;
  final List<String> users;
  final bool dismissed;
  bool get showGuide => usedSeeking && !dismissed;

  factory FollowingFeedMigration.read(SharedPreferences prefs) {
    var users = <String>[];
    final raw = prefs.getString('seeking_config');
    try {
      if (raw != null) {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        users = (data['users'] as List? ?? [])
            .whereType<String>()
            .where((name) => name.trim().isNotEmpty)
            .toSet()
            .toList();
      }
    } catch (_) {
      // 损坏的旧配置不应阻止进入动态页。
    }
    return FollowingFeedMigration(
      usedSeeking:
          raw != null ||
          prefs.getBool('seeking_enabled') == true ||
          (prefs.getStringList('pref_bottom_nav_ids') ?? []).contains(
            'seeking',
          ),
      users: users,
      dismissed: prefs.getBool('following_feed_migration_seen') ?? false,
    );
  }
}

class FollowingFeedMigrationNotifier
    extends StateNotifier<FollowingFeedMigration> {
  FollowingFeedMigrationNotifier(this.prefs)
    : super(FollowingFeedMigration.read(prefs));
  final SharedPreferences prefs;
  Future<void> markSeen() async {
    // 同步更新，多个动态入口在同一帧打开时也只展示一次。
    state = FollowingFeedMigration(
      usedSeeking: state.usedSeeking,
      users: state.users,
      dismissed: true,
    );
    await prefs.setBool('following_feed_migration_seen', true);
  }
}

final followingFeedMigrationProvider =
    StateNotifierProvider<
      FollowingFeedMigrationNotifier,
      FollowingFeedMigration
    >(
      (ref) =>
          FollowingFeedMigrationNotifier(ref.watch(sharedPreferencesProvider)),
    );
