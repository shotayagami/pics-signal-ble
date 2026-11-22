import 'package:shared_preferences/shared_preferences.dart';

/// 利用者が端末内で付けた方向名。信号番号と方角の対応は交差点ごとに違うため、交差点 ID と信号番号（1 始まり）で持つ。
class DirectionNames {
  DirectionNames(this._prefs);

  final SharedPreferences _prefs;

  static Future<DirectionNames> load() async =>
      DirectionNames(await SharedPreferences.getInstance());

  static String _key(String id, int no) => 'direction/$id/$no';

  String? get(String id, int no) => _prefs.getString(_key(id, no));

  /// 空白だけの名前は削除として扱い、番号表示に戻す。
  Future<void> set(String id, int no, String name) {
    final trimmed = name.trim();
    return trimmed.isEmpty
        ? _prefs.remove(_key(id, no))
        : _prefs.setString(_key(id, no), trimmed);
  }
}
