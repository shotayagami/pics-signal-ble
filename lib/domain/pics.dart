import 'dart:typed_data';

Map<String, String> intersectionNames(String csv) {
  // shortcut: 項目内のカンマに未対応、引用符付きデータが追加されたら CSV パーサーに変更。
  final names = <String, String>{};
  for (final line in csv.split('\n').skip(1)) {
    final fields = line.split(',');
    if (fields.length < 7) continue;
    final latitude = double.tryParse(fields[5]);
    final longitude = double.tryParse(fields[6]);
    if (latitude == null || longitude == null) continue;
    final key =
        '${latitude.toStringAsFixed(6)},${longitude.toStringAsFixed(6)}';
    names.putIfAbsent(key, () => fields[2]);
  }
  return names;
}

class PicsIntersection {
  PicsIntersection(this.id);

  final String id;
  int rssi = 0;
  double? latitude;
  double? longitude;
  List<int>? signals;
  DateTime? lastSeen;
  DateTime? signalTime;

  static const signalValidity = Duration(seconds: 5);

  bool isFresh(DateTime? time, DateTime now, Duration validity) =>
      time != null && !now.isBefore(time) && now.difference(time) < validity;

  static String signalDescription(int value) {
    final state = switch (value & 0xf) {
      0 => '信号なし',
      1 => '赤',
      2 => '青点滅',
      3 => '青',
      4 => '対象なし',
      _ => '不明',
    };
    final remaining = value >> 4;
    return remaining < 8 ? '$state（残り値 ${remaining + 1}）' : state;
  }
}

class PicsDecoder {
  final intersections = <String, PicsIntersection>{};

  bool add(Uint8List data, int rssi, DateTime now) {
    // shortcut: 実測した製品 ID と24バイト形式のみ、別形式を確認したら対応を拡張する。
    if (data.length != 24 ||
        data[0] != 0x58 ||
        data[1] != 0x01 ||
        data[2] > 2) {
      return false;
    }
    final id = data
        .sublist(6, 10)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    final intersection = intersections.putIfAbsent(
      id,
      () => PicsIntersection(id),
    );
    intersection
      ..lastSeen = now
      ..rssi = rssi;
    if (data[2] == 1) {
      final bytes = ByteData.sublistView(data);
      intersection
        ..latitude = bytes.getInt32(10, Endian.big) / 1000000
        ..longitude = bytes.getInt32(14, Endian.big) / 1000000;
    } else if (data[2] == 2) {
      intersection
        ..signals = data.sublist(10, 16)
        ..signalTime = now;
    }
    return true;
  }
}
