# pics-signal-ble

歩行者等支援情報通信システム（高度化 PICS）の路側機が送る BLE アドバタイズを受信し、交差点の位置と歩行者用信号の状態を表示する Flutter アプリ（Android / iOS）。形式の調査結果は [PICS.md](PICS.md) にまとめている。

| ディレクトリ | 役割 |
| --- | --- |
| lib/domain | 純粋なモデル・ロジック（Flutter 非依存） |
| lib/data | 永続化・API クライアント |
| lib/engine | ネイティブ連携（MethodChannel 等） |
| lib/state | Riverpod コントローラ |
| lib/ui | 画面・ウィジェット |
| lib/theme | テーマ |
| tools | 受信ログを記録する PC 用スクリプト |

```sh
flutter pub get
flutter run
flutter test
```

Android では「検索開始」から周辺の PICS 対応交差点を受信する。Bluetooth と位置情報の権限が必要。座標が付属の交差点一覧と一致した場合は名称を表示する。信号状態は受信から5秒を過ぎると表示しない。この時間は暫定値で、表示の正確性を保証するものではない。画面を離れると検索を停止する。

対応する広告は Company ID `0x01CE`、ペイロード先頭が `58 01` のもの。信号表示は参考情報であり、横断時は必ず現地の信号を確認する。iOS の BLE 受信は未対応。

## データの出典

`zenkoku-kousaten.csv` は、警察庁「高度化PICS整備交差点」（[e-Gov データポータル](https://data.e-gov.go.jp/data/dataset/npa_20221124_0054/resource/6f7e83e1-be28-4030-961f-3b489c9f6ad8)）を利用している。
