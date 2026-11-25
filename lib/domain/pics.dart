import 'dart:math';
import 'dart:typed_data';

double _distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final dLat = (lat2 - lat1) * pi / 180;
  final dLon = (lon2 - lon1) * pi / 180;
  final a =
      sin(dLat / 2) * sin(dLat / 2) +
      cos(lat1 * pi / 180) *
          cos(lat2 * pi / 180) *
          sin(dLon / 2) *
          sin(dLon / 2);
  return 2 * r * asin(min(1.0, sqrt(a)));
}

/// 受信中の交差点から1つ選ぶ。電波が明らかに強いものを優先し、拮抗する
/// ときは GPS で近いものを選ぶ。今の選択 [currentId] は、挑戦側がマージンを
/// 超えて上回るまで維持する（ヒステリシス）。選んだ交差点の ID を返す。
String? chooseIntersection(
  List<PicsIntersection> candidates, {
  double? hereLat,
  double? hereLon,
  String? currentId,
  double rssiBand = 6,
  double rssiMargin = 8,
  double distMargin = 20,
}) {
  if (candidates.isEmpty) return null;
  double? distance(PicsIntersection x) {
    if (hereLat == null ||
        hereLon == null ||
        x.latitude == null ||
        x.longitude == null) {
      return null;
    }
    return _distanceMeters(hereLat, hereLon, x.latitude!, x.longitude!);
  }

  bool better(PicsIntersection a, PicsIntersection b) {
    if ((a.rssi - b.rssi).abs() >= rssiBand) return a.rssi > b.rssi;
    final da = distance(a);
    final db = distance(b);
    if (da != null && db != null && (da - db).abs() >= 1) return da < db;
    return a.rssi > b.rssi;
  }

  var best = candidates.first;
  for (final x in candidates.skip(1)) {
    if (better(x, best)) best = x;
  }
  final current = currentId == null
      ? null
      : candidates.where((x) => x.id == currentId).firstOrNull;
  if (current != null && best.id != current.id) {
    final stronger = best.rssi > current.rssi + rssiMargin;
    final dc = distance(current);
    final db = distance(best);
    final closer = dc != null && db != null && db < dc - distMargin;
    if (!stronger && !closer) return current.id;
  }
  return best.id;
}

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

  /// 信号1バイトを状態と残り値に分ける。残り値は 1〜8、なし・不明は null。
  static ({String state, int? remaining}) signalParts(int value) {
    final state = switch (value & 0xf) {
      0 => '信号なし',
      1 => '赤',
      2 => '青点滅',
      3 => '青',
      4 => '対象なし',
      _ => '不明',
    };
    final remaining = value >> 4;
    return (state: state, remaining: remaining < 8 ? remaining + 1 : null);
  }

  static String signalDescription(int value) {
    final parts = signalParts(value);
    return parts.remaining == null
        ? parts.state
        : '${parts.state}（残り値 ${parts.remaining}）';
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
