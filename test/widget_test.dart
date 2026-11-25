import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pics/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('起動して PICS が出る', (t) async {
    await t.pumpWidget(const ProviderScope(child: App()));
    expect(find.text('PICS'), findsOneWidget);
  });

  testWidgets('受信した信号状態を表示する', (t) async {
    const channel = MethodChannel('pics/scan');
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => null,
    );
    await t.pumpWidget(const ProviderScope(child: App()));
    await t.tap(find.text('検索開始'));
    await t.pump();
    Future<void> receive(List<int> data) async {
      final message = const StandardMethodCodec().encodeSuccessEnvelope({
        'data': Uint8List.fromList(data),
        'rssi': -70,
      });
      await t.binding.defaultBinaryMessenger.handlePlatformMessage(
        'pics/scan',
        message,
        (_) {},
      );
      await t.pump();
    }

    final marker = [
      0x58,
      1,
      0,
      1,
      0,
      0,
      0x12,
      0x34,
      0x56,
      0x78,
      ...'UTMS_PICS0001\x00'.codeUnits,
    ];
    await receive(marker);
    final location = [
      0x58,
      1,
      1,
      2,
      0,
      0,
      0x12,
      0x34,
      0x56,
      0x78,
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
    ];
    await receive(location);
    final signal = [
      0x58,
      1,
      2,
      3,
      0,
      0,
      0x12,
      0x34,
      0x56,
      0x78,
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
    ];
    await receive(signal);
    // 信号行は方向名・状態・残り値を別々の表示に分けた。
    expect(find.text('信号1'), findsOneWidget);
    expect(find.text('残り値 7'), findsOneWidget);
    expect(find.text('信号2'), findsOneWidget);
    expect(find.text('残り値 6'), findsOneWidget);

    await t.tap(find.text('信号2'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextFormField), ' 東西方向 ');
    await t.tap(find.text('保存'));
    await t.pumpAndSettle();
    expect(find.text('東西方向（信号2）'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('direction/12345678/2'), '東西方向');

    await t.tap(find.text('東西方向（信号2）'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextFormField), '');
    await t.tap(find.text('保存'));
    await t.pumpAndSettle();
    expect(find.text('信号2'), findsOneWidget);
    expect(prefs.getString('direction/12345678/2'), isNull);
    await t.pumpWidget(const SizedBox());
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });
}
