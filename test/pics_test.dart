import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pics/domain/pics.dart';

Uint8List packet(int type, int id) {
  final data = Uint8List.fromList([
    0x58,
    1,
    type,
    id,
    0,
    0,
    0x12,
    0x34,
    0x56,
    0x78,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
  ]);
  if (type == 0) data.setRange(10, 24, 'UTMS_PICS0001\x00'.codeUnits);
  if (type == 1) {
    data.setRange(10, 24, [
      2,
      0x91,
      0x25,
      0x90,
      8,
      0x6c,
      0xd6,
      0xb6,
      0x22,
      4,
      0x82,
      0,
      0,
      1,
    ]);
  }
  if (type == 2) {
    data.setRange(10, 24, [
      0x63,
      0x51,
      0xff,
      0xff,
      0xff,
      0xff,
      8,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ]);
  }
  return data;
}

void main() {
  final now = DateTime(2026, 11, 21, 23, 25);
  test('座標が一致する交差点名を取得する', () {
    final names = intersectionNames(
      'header\n北海道,札幌市,北５条通り札幌駅前交差点,よみ,所在地,43.066768,141.350582,,,\n',
    );
    expect(names['43.066768,141.350582'], '北５条通り札幌駅前交差点');
  });

  test('位置と信号状態を取り出す', () {
    final decoder = PicsDecoder();
    decoder.add(packet(1, 2), -70, now);
    final intersection = decoder.intersections['12345678']!;
    expect(intersection.latitude, 43.066768);
    expect(intersection.longitude, 141.350582);
    expect(intersection.signals, isNull);
    decoder.add(packet(2, 3), -71, now);
    expect(intersection.rssi, -71);
    expect(
      PicsIntersection.signalDescription(intersection.signals![0]),
      '青（残り値 7）',
    );
    expect(PicsIntersection.signalDescription(0x51), '赤（残り値 6）');
    expect(PicsIntersection.signalDescription(0xff), '不明');
  });

  test('別製品や不正な長さを無視する', () {
    final decoder = PicsDecoder();
    expect(decoder.add(Uint8List(3), -70, now), isFalse);
    expect(decoder.add(packet(1, 1)..[0] = 0, -70, now), isFalse);
    expect(decoder.add(packet(1, 1)..[2] = 3, -70, now), isFalse);
    expect(decoder.intersections, isEmpty);
  });
}
