"""uv run --no-project --with bleak python -I tools/test_pics_logger.py
（リポジトリ直下に ble-pics-viewer を clone しておくこと）"""
import json
import sys
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).parent))  # -I ではスクリプトのディレクトリが sys.path に入らない
from pics_logger import HEADER, adv_rows, load_process_pics, signals_text

process_pics = load_process_pics()

# 共通ヘッダー 10 バイト（type=2, msg_id=5, 交差点 ID=01 02 03 04）+ 信号 6 灯
HDR = bytes([0, 0, 2, 5, 0, 0, 1, 2, 3, 4])


def adv(**kw):
    d = dict(local_name=None, service_uuids=[], service_data={}, manufacturer_data={})
    return SimpleNamespace(**{**d, **kw})


def rows(data, **kw):
    return adv_rows("AA", -60, adv(manufacturer_data={0x01CE: data}, **kw), "t", False, process_pics)


def test_signals():
    # 0x23 = 残り 2+1=3 の青 / 0x84 = 残り不明・対象外
    info = process_pics(list(HDR + bytes([0x23, 0x84, 0x84, 0x84, 0x84, 0x84])))
    assert signals_text(info) == "青(3) 対象外(-) 対象外(-) 対象外(-) 対象外(-) 対象外(-)"
    assert signals_text(process_pics(list(bytes([0, 0, 1, 0, 0, 0, 1, 2, 3, 4]) + b"\0" * 8))) == ""  # Type 1


def test_rows():
    (r,) = rows(HDR + bytes([0x23]))
    assert len(r) == len(HEADER)
    assert (r[3], r[4], r[5], r[6], r[8]) == ("0x01CE", 2, 5, "01020304", "青(3)")
    assert json.loads(r[13])["pedestrian_signals"] == [{"remaining_time": 3, "signal_state": "Green"}]

    # Type 1: 緯度経度が info に入る。足りなければ info だけ空で raw_hex は残る
    lat_lon = (35_861_000).to_bytes(4, "big") + (140_017_000).to_bytes(4, "big")
    (r,) = rows(bytes([0, 0, 1, 7, 0, 0, 1, 2, 3, 4]) + lat_lon)
    assert (json.loads(r[13])["latitude"], json.loads(r[13])["longitude"]) == (35.861, 140.017)
    (r,) = rows(bytes([0, 0, 1, 7, 0, 0, 1, 2, 3, 4, 9]))
    assert (r[4], r[13], r[7]) == ("", "", "00 00 01 07 00 00 01 02 03 04 09")
    (r,) = rows(b"\x00" * 5)  # 短すぎる 0x01CE はデコードしない
    assert (r[4], r[13]) == ("", "")

    other = adv(manufacturer_data={0x004C: b"\x01"}, local_name="phone")
    assert adv_rows("BB", -70, other, "t", False, process_pics) == []
    (r,) = adv_rows("BB", -70, other, "t", True, process_pics)
    assert (r[3], r[4], r[9]) == ("0x004C", "", "phone")

    # メーカーデータなし: --all のときだけ 1 行。サービスデータも残る
    svc = adv(service_uuids=["fe00"], service_data={"fe00": b"\xab"})
    assert adv_rows("CC", -80, svc, "t", False, process_pics) == []
    (r,) = adv_rows("CC", -80, svc, "t", True, process_pics)
    assert (r[3], r[10], r[11]) == ("", "fe00", "fe00:ab")


if __name__ == "__main__":
    test_signals()
    test_rows()
    print("OK")
