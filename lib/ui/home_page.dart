import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';

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
  String? selectedId;
  final FlutterTts _tts = FlutterTts();
  bool _ttsReady = false;
  bool speakOnChange = false;
  // 自動読み上げ用：表示中の信号と、前回読み上げた状態。
  String? _snapshotId;
  List<({int no, String label, String state})> _snapshot = const [];
  String? _spokenId;
  Map<int, String> _spokenStates = {};
  // 既定選択（電波強度＋GPS＋ヒステリシス）用。
  String? _autoId;
  double? _hereLat;
  double? _hereLon;
  StreamSubscription<Position>? _geo;

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
      if (subscription == null) return;
      setState(() {});
      if (!speakOnChange || _snapshotId == null) return;
      final changed = _snapshotId != _spokenId
          ? _snapshot
          : _snapshot.where((s) => _spokenStates[s.no] != s.state).toList();
      if (changed.isNotEmpty) {
        _speak(changed.map((s) => '${s.label}、${s.state}').join('。'));
      }
      _spokenId = _snapshotId;
      _spokenStates = {for (final s in _snapshot) s.no: s.state};
    });
  }

  Future<void> _startLocation() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      _geo = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 1,
        ),
      ).listen((position) {
        _hereLat = position.latitude;
        _hereLon = position.longitude;
      });
    } catch (_) {
      // 位置が取れなくても電波強度だけで選ぶので、検索は続ける。
    }
  }

  void start() {
    if (subscription != null) return;
    _startLocation();
    setState(() {
      error = null;
      decoder.intersections.clear();
      selectedId = null;
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
    _snapshotId = null;
    _snapshot = const [];
    _spokenId = null;
    _spokenStates = {};
    _autoId = null;
    _geo?.cancel();
    _geo = null;
    _tts.stop();
    if (mounted) setState(() => error = message);
  }

  Future<void> _speak(String text) async {
    try {
      if (!_ttsReady) {
        await _tts.setLanguage('ja-JP');
        _ttsReady = true;
      }
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {
      if (mounted) setState(() => error = '音声を再生できません。');
    }
  }

  /// 読み上げ対象の信号（方向名と状態）。信号なし・対象なし・不明は除く。
  List<({int no, String label, String state})> _spokenSignals(
    PicsIntersection intersection,
  ) {
    final signals = intersection.signals;
    if (signals == null) return const [];
    final out = <({int no, String label, String state})>[];
    for (var i = 0; i < signals.length; i++) {
      final signal = PicsIntersection.signalParts(signals[i]);
      if (signal.state == '信号なし' ||
          signal.state == '対象なし' ||
          signal.state == '不明') {
        continue;
      }
      final label = directions?.get(intersection.id, i + 1) ?? '信号${i + 1}';
      out.add((no: i + 1, label: label, state: signal.state));
    }
    return out;
  }

  /// 表示中の全信号を「交差点名。方向名、状態。…」の読み上げ文にする。
  String? _announcement(PicsIntersection intersection, {bool withName = true}) {
    final signals = _spokenSignals(intersection);
    if (signals.isEmpty) return null;
    final body = signals.map((s) => '${s.label}、${s.state}').join('。');
    if (!withName) return body;
    final name =
        (intersection.latitude == null
            ? null
            : names['${intersection.latitude!.toStringAsFixed(6)},${intersection.longitude!.toStringAsFixed(6)}']) ??
        '交差点 ${intersection.id}';
    return '$name。$body';
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
    _geo?.cancel();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final intersections = decoder.intersections.values.toList()
      ..sort((a, b) => b.lastSeen!.compareTo(a.lastSeen!));
    final scanning = subscription != null;
    // 既定は、いま受信中の交差点から電波強度・GPS・ヒステリシスで1つ選ぶ。
    // 手動でチップを選んだときはそれを優先する。
    final fresh = [
      for (final item in intersections)
        if (item.isFresh(item.lastSeen, now, PicsIntersection.signalValidity))
          item,
    ];
    _autoId = chooseIntersection(
      fresh,
      hereLat: _hereLat,
      hereLon: _hereLon,
      currentId: _autoId,
    );
    final auto = fresh.where((item) => item.id == _autoId).firstOrNull;
    final selected =
        intersections.where((item) => item.id == selectedId).firstOrNull ??
        auto ??
        (intersections.isEmpty ? null : intersections.first);
    if (selected == null) {
      _snapshotId = null;
      _snapshot = const [];
    }
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
          const SizedBox(height: 12),
          if (intersections.length > 1) ...[
            const Text('交差点を選択', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final item in intersections)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(_intersectionName(item)),
                        selected: item.id == selected?.id,
                        onSelected: (_) => setState(() {
                          selectedId = item.id;
                          _spokenId = null;
                          _spokenStates = {};
                        }),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (selected == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                scanning ? '交差点の電波を検索しています。' : '検索を開始すると受信した交差点を表示します。',
              ),
            )
          else
            _intersectionCard(selected, now, scanning),
        ],
      ),
    );
  }

  String _intersectionName(PicsIntersection intersection) {
    final lat = intersection.latitude;
    final lon = intersection.longitude;
    return lat == null || lon == null
        ? '交差点 ${intersection.id}'
        : names['${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}'] ??
              '交差点 ${intersection.id}';
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
    if (freshSignals) {
      _snapshotId = intersection.id;
      _snapshot = _spokenSignals(intersection);
    } else {
      _snapshotId = null;
      _snapshot = const [];
    }
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
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '信号状態',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Text(
                  '変化で自動',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Switch(
                  value: speakOnChange,
                  onChanged: (value) {
                    setState(() => speakOnChange = value);
                    if (!value) {
                      _tts.stop();
                      return;
                    }
                    final signals = _spokenSignals(intersection);
                    if (signals.isNotEmpty) {
                      _speak(
                        signals.map((s) => '${s.label}、${s.state}').join('。'),
                      );
                    }
                    _spokenId = intersection.id;
                    _spokenStates = {for (final s in signals) s.no: s.state};
                  },
                ),
              ],
            ),
            FilledButton.tonalIcon(
              onPressed: freshSignals
                  ? () {
                      final text = _announcement(intersection);
                      if (text != null) _speak(text);
                    }
                  : null,
              icon: const Icon(Icons.volume_up, size: 18),
              label: const Text('音声で確認'),
            ),
            const SizedBox(height: 4),
            if (freshSignals)
              Text(
                '信号状態の受信：${now.difference(intersection.signalTime!).inSeconds} 秒前',
              ),
            if (!freshSignals)
              const Text('受信待ち / 情報が古いため表示できません')
            else ...[
              const Text('行をタップすると方向名を付けられます（この端末だけに保存）'),
              for (var i = 0; i < intersection.signals!.length; i++)
                _signalRow(intersection.id, i + 1, intersection.signals![i]),
            ],
            const SizedBox(height: 4),
            Theme(
              data: Theme.of(
                context,
              ).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 4),
                title: Text(
                  '受信の詳細',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (name != null) Text('交差点 ID ${intersection.id}'),
                        Text('最終受信 $age 秒前 · 電波 ${intersection.rssi} dBm'),
                        if (intersection.latitude != null)
                          Text(
                            '座標 ${intersection.latitude!.toStringAsFixed(6)}, ${intersection.longitude!.toStringAsFixed(6)}',
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _signalRow(String id, int no, int value) {
    final label = directions?.get(id, no);
    final name = label == null ? '信号$no' : '$label（信号$no）';
    final signal = PicsIntersection.signalParts(value);
    final color = signal.state.startsWith('赤')
        ? Colors.red.shade700
        : signal.state.startsWith('青')
        ? Colors.green.shade700
        : Theme.of(context).hintColor;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: directions == null ? null : () => _editDirection(id, no, label),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              width: 58,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                signal.state,
                textAlign: TextAlign.center,
                style: TextStyle(color: color, fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (signal.remaining != null) ...[
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: signal.remaining! / 8,
                              minHeight: 8,
                              color: color,
                              backgroundColor: Theme.of(
                                context,
                              ).dividerColor,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '残り値 ${signal.remaining}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.edit,
              size: 18,
              color: Theme.of(context).hintColor,
              semanticLabel: '方向名を編集',
            ),
          ],
        ),
      ),
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
