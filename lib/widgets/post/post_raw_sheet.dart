import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/s.dart';
import '../../models/topic.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/toast_service.dart';
import '../common/app_bottom_sheet.dart';

Future<void> showPostRawSheet(BuildContext context, Post post) {
  return AppBottomSheet.show<void>(
    context: context,
    title: '${S.current.composerView_source} #${post.postNumber}',
    builder: (_) => _PostRawSheetBody(postId: post.id),
  );
}

class _PostRawSheetBody extends StatefulWidget {
  const _PostRawSheetBody({required this.postId});

  final int postId;

  @override
  State<_PostRawSheetBody> createState() => _PostRawSheetBodyState();
}

class _PostRawSheetBodyState extends State<_PostRawSheetBody> {
  String? _raw;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final raw = await DiscourseService().getPostRaw(widget.postId);
    if (!mounted) return;
    setState(() {
      _raw = raw;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final raw = _raw;
    if (raw == null || raw.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Center(
          child: Text(
            S.current.common_loadFailed,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            tooltip: S.current.common_copy,
            icon: const Icon(Symbols.content_copy_rounded, size: 20),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: raw));
              ToastService.showSuccess(S.current.common_copiedToClipboard);
            },
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              raw,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
