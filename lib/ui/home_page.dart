import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/direction_names.dart';
import '../domain/pics.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final decoder = PicsDecoder();
  Map<String, String> names = {};
  DirectionNames? directions;
  StreamSubscription<dynamic>? subscription;
  Timer? timer;
  String? error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    rootBundle.loadString('zenkoku-kousaten.csv').then((csv) {
      if (mounted) setState(() => names = intersectionNames(csv));
    });
    DirectionNames.load().then((loaded) {
      if (mounted) setState(() => directions = loaded);
    });
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (subscription != null) setState(() {});
    });
  }

  void start() {
    if (subscription != null) return;
    setState(() {
      error = null;
      decoder.intersections.clear();
      subscription = const EventChannel('pics/scan')
          .receiveBroadcastStream()
          .listen(
            (event) {
              final data = event['data'];
              final rssi = event['rssi'];
              if (data is Uint8List &&
                  rssi is int &&
                  decoder.add(data, rssi, DateTime.now())) {
                setState(() {});
              }
            },
            onError: (Object e) {
              final message = e is PlatformException ? e.message : null;
              stop(message ?? '検索を開始できません。この機能は Android で利用できます。');
            },
          );
    });
  }

  void stop([String? message]) {
    final current = subscription;
    subscription = null;
    current?.cancel();
    if (mounted) setState(() => error = message);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && subscription != null) {
      stop('検索を停止しました。再開するには検索開始を押してください。');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    subscription?.cancel();
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final intersections = decoder.intersections.values.toList()
      ..sort((a, b) => b.lastSeen!.compareTo(a.lastSeen!));
    final scanning = subscription != null;
    return Scaffold(
      appBar: AppBar(title: const Text('PICS')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '近くの交差点',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text('信号の表示は参考情報です。横断時は必ず現地の信号を確認してください。'),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: scanning ? () => stop() : start,
            icon: Icon(scanning ? Icons.stop : Icons.bluetooth_searching),
            label: Text(scanning ? '検索を停止' : '検索開始'),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(error!),
            ),
          if (intersections.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                scanning ? '交差点の電波を検索しています。' : '検索を開始すると受信した交差点を表示します。',
              ),
            ),
          for (final intersection in intersections)
            _intersectionCard(intersection, now, scanning),
        ],
      ),
    );
  }

  Widget _intersectionCard(
    PicsIntersection intersection,
    DateTime now,
    bool scanning,
  ) {
    final name = intersection.latitude == null
        ? null
        : names['${intersection.latitude!.toStringAsFixed(6)},${intersection.longitude!.toStringAsFixed(6)}'];
    final freshSignals =
        scanning &&
        intersection.isFresh(
          intersection.signalTime,
          now,
          PicsIntersection.signalValidity,
        );
    final age = now
        .difference(intersection.lastSeen!)
        .inSeconds
        .clamp(0, 999999);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name ?? '交差点 ${intersection.id}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (name != null) Text('交差点 ID ${intersection.id}'),
            Text('最終受信 $age 秒前 · 電波 ${intersection.rssi} dBm'),
            if (intersection.latitude != null)
              Text(
                '座標 ${intersection.latitude!.toStringAsFixed(6)}, ${intersection.longitude!.toStringAsFixed(6)}',
              ),
            const SizedBox(height: 12),
            Text('信号状態', style: Theme.of(context).textTheme.titleSmall),
            if (freshSignals)
              Text(
                '信号状態の受信：${now.difference(intersection.signalTime!).inSeconds} 秒前',
              ),
            if (!freshSignals)
              const Text('受信待ち / 情報が古いため表示できません')
            else ...[
              const Text('行をタップすると方向名を付けられます（この端末だけに保存）'),
              for (var i = 0; i < intersection.signals!.length; i++)
                _signalRow(
                  intersection.id,
                  i + 1,
                  PicsIntersection.signalDescription(intersection.signals![i]),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _signalRow(String id, int no, String state) {
    final label = directions?.get(id, no);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text('${label == null ? '信号$no' : '$label（信号$no）'}：$state'),
      trailing: const Icon(Icons.edit, size: 18, semanticLabel: '方向名を編集'),
      onTap: directions == null ? null : () => _editDirection(id, no, label),
    );
  }

  Future<void> _editDirection(String id, int no, String? current) async {
    var text = current ?? '';
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('信号$no の方向名'),
        content: TextFormField(
          initialValue: current,
          autofocus: true,
          maxLength: 20,
          decoration: const InputDecoration(
            hintText: '例：東西方向',
            helperText: '空にすると番号だけの表示に戻ります',
          ),
          onChanged: (value) => text = value,
          onFieldSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null) return;
    await directions!.set(id, no, result);
    if (mounted) setState(() {});
  }
}
