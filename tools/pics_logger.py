"""高度化PICS の BLE アドバタイズを CSV に記録する（受信専用。送信はしない）。

使い方:
    pip install bleak
    python tools/pics_logger.py            # logs/pics_YYYYMMDD_HHMMSS.csv に保存。0x01CE のみ
    python tools/pics_logger.py --all      # 全ての広告を記録（スマホの延長要求を拾う用）

--all では 0x01CE 以外のメーカーデータ、メーカーデータなしの広告（名前・サービス UUID・サービスデータだけのもの）も残す。
スマホが延長要求を「広告」で出す場合はこれで拾える。GATT 接続での書き込みは PC のアダプターには見えない（末尾の注を参照）。

実行中に何かキーを押すと、その時刻に note=MARK の行を入れる（Windows のみ）。
スマホで延長ボタンを押した瞬間に押すと、CSV 上で前後の広告を探しやすい。

画面には時計（ミリ秒）と最新の信号状態を表示する。信号機と一緒に撮影すれば、動画と CSV の時刻を合わせられる。
デコードは ble-pics-viewer の process_pics() をそのまま使う（PICS.md 5章）。結果は info 列に JSON で残す
（Type 0 の識別子、Type 1 の緯度経度、Type 2 の信号）。ライブラリはリポジトリ直下に置く:
    git clone https://github.com/yumu19/ble-pics-viewer.git
別の場所に置いたときは --viewer でファイルを指定する。

注: 延長要求の中身を確実に取るなら、Android の開発者オプション「Bluetooth HCI スヌープログ」を有効にして
操作し、btsnoop_hci.log を Wireshark で開く。スマホ側の送信が GATT 書き込みでも見える。
"""
import argparse
import asyncio
import csv
import importlib.util
import json
import struct
import sys
from datetime import datetime
from pathlib import Path

try:
    import msvcrt  # キー入力の検出用。Windows 以外では MARK 機能なし
except ImportError:
    msvcrt = None

PICS_COMPANY_ID = 0x01CE
VIEWER = Path(__file__).resolve().parents[1] / "ble-pics-viewer" / "ble-pics-viewer.py"
STATES = {"NoSignal": "なし", "Red": "赤", "BlinkGreen": "青点滅", "Green": "青", "None": "対象外"}
HEADER = ["time", "address", "rssi", "company_id", "type", "msg_id", "intersection_id",
          "raw_hex", "signals", "name", "service_uuids", "service_data", "note", "info"]


def load_process_pics(path: Path = VIEWER):
    """ble-pics-viewer.py（ファイル名にハイフンがあり import 文では読めない）から process_pics を取り出す。"""
    if not path.is_file():
        sys.exit(f"{path} がありません。git clone https://github.com/yumu19/ble-pics-viewer.git で取得するか --viewer で指定してください")
    spec = importlib.util.spec_from_file_location("ble_pics_viewer", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.process_pics


def signals_text(info: dict) -> str:
    """process_pics の pedestrian_signals を '赤(3) 青(-)' のような文字列にする。無ければ空文字。"""
    return " ".join(
        f"{STATES.get(s['signal_state'], '?')}({s['remaining_time'] if s['remaining_time'] >= 0 else '-'})"
        for s in info.get("pedestrian_signals", [])
    )


def adv_rows(address: str, rssi: int, adv, now: str, all_ads: bool, process_pics) -> list[list]:
    """広告 1 件を CSV の行にする。all_ads でなければ 0x01CE 以外は捨てる。"""
    extra = [
        adv.local_name or "",
        " ".join(adv.service_uuids),
        " ".join(f"{u}:{d.hex()}" for u, d in adv.service_data.items()),
    ]
    items = list(adv.manufacturer_data.items())
    if not items and all_ads:
        items = [(None, b"")]  # メーカーデータなしの広告も 1 行残す
    rows = []
    for cid, data in items:
        if cid != PICS_COMPANY_ID and not all_ads:
            continue
        info = {}
        if cid == PICS_COMPANY_ID and len(data) >= 10:
            try:
                info = process_pics(list(data))
            except struct.error:  # Type 1 で緯度経度のバイトが足りない。生データは raw_hex に残る
                pass
        rows.append([
            now, address, rssi, f"0x{cid:04X}" if cid is not None else "",
            info.get("message_type", ""), info.get("message_id", ""), info.get("intersection_id", ""),
            data.hex(" ").upper(), signals_text(info),
            *extra, "", json.dumps(info, ensure_ascii=False) if info else "",
        ])
    return rows


def main() -> None:
    from bleak import BleakScanner  # テストで bleak なしでも import できるように遅延

    ap = argparse.ArgumentParser()
    ap.add_argument("--all", action="store_true", help="全ての広告を記録する（0x01CE 以外・メーカーデータなしも）")
    ap.add_argument("--out", type=Path, help="出力する CSV のパス")
    ap.add_argument("--viewer", type=Path, default=VIEWER, help="ble-pics-viewer.py のパス")
    args = ap.parse_args()
    process_pics = load_process_pics(args.viewer)

    out = args.out or Path("logs") / f"pics_{datetime.now():%Y%m%d_%H%M%S}.csv"
    out.parent.mkdir(parents=True, exist_ok=True)
    f = out.open("w", newline="", encoding="utf-8")
    w = csv.writer(f)
    w.writerow(HEADER)
    count = marks = 0
    latest = "(受信待ち)"

    def on_adv(device, adv):
        nonlocal count, latest
        now = datetime.now().isoformat(timespec="milliseconds")
        for row in adv_rows(device.address, adv.rssi, adv, now, args.all, process_pics):
            w.writerow(row)
            count += 1
            if row[8]:
                latest = f"{row[6]}  {row[8]}"
        f.flush()  # 途中で止めてもデータを失わない

    async def run():
        nonlocal marks
        async with BleakScanner(on_adv):
            while True:
                if msvcrt and msvcrt.kbhit():
                    while msvcrt.kbhit():
                        msvcrt.getwch()
                    marks += 1
                    w.writerow([datetime.now().isoformat(timespec="milliseconds")] + [""] * 11 + ["MARK", ""])
                    f.flush()
                # 撮影用の表示: 時計(ms) / 受信件数 / マーク数 / 最新の信号状態
                sys.stdout.write(f"\r{datetime.now():%H:%M:%S.%f}"[:-3] + f"  受信 {count:6d}  MARK {marks:2d}  {latest:<60}")
                sys.stdout.flush()
                await asyncio.sleep(0.05)

    print(f"記録先: {out}  (Ctrl+C で停止{'、何かキーで MARK' if msvcrt else ''})")
    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        pass
    finally:
        f.close()
        print(f"\n停止しました。{count} 件を {out} に保存しました。")


if __name__ == "__main__":
    main()
