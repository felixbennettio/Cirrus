import 'package:flutter/widgets.dart';

/// Inline bilingual strings: `context.tr('Delete', '删除')`.
///
/// Cirrus ships English and Simplified Chinese. Keeping both strings next
/// to each other keeps the very large UI surface in sync without a
/// separate key catalogue.
extension Tr on BuildContext {
  bool get isZh => Localizations.maybeLocaleOf(this)?.languageCode == 'zh';

  String tr(String en, String zh) => isZh ? zh : en;
}

/// A string available in both languages, for tables of static data.
class L10nText {
  const L10nText(this.en, this.zh);

  final String en;
  final String zh;

  String of(BuildContext context) => context.tr(en, zh);
}
