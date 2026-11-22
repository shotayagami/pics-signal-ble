package com.yagamin.pics

import android.Manifest
import android.bluetooth.BluetoothManager
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

class MainActivity : FlutterActivity() {
    private var sink: EventChannel.EventSink? = null
    private var scanner: BluetoothLeScanner? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val permissions: Array<String>
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION)
        } else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)

    private val callback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val data = result.scanRecord?.getManufacturerSpecificData(0x01ce) ?: return
            val source = try { result.device.address } catch (_: SecurityException) { return }
            mainHandler.post { sink?.success(mapOf("data" to data, "rssi" to result.rssi, "source" to source)) }
        }

        override fun onScanFailed(errorCode: Int) {
            mainHandler.post { sink?.error("scan_failed", "Bluetooth の検索に失敗しました ($errorCode)", null) }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "pics/scan").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                sink = events
                if (permissions.any { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }) {
                    requestPermissions(permissions, 1)
                } else startScan()
            }

            override fun onCancel(arguments: Any?) {
                stopScan()
                sink = null
            }
        })
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 1 || sink == null) return
        if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }) startScan()
        else sink?.error("permission", "Bluetooth と位置情報の権限が必要です。設定から許可して再試行してください。", null)
    }

    private fun startScan() {
        try {
            val adapter = (getSystemService(BLUETOOTH_SERVICE) as BluetoothManager).adapter
            if (adapter == null || !adapter.isEnabled) {
                sink?.error("bluetooth", "Bluetooth をオンにして再試行してください。", null)
                return
            }
            scanner = adapter.bluetoothLeScanner
            if (scanner == null) {
                sink?.error("bluetooth", "Bluetooth の検索を開始できません。", null)
                return
            }
            val filter = ScanFilter.Builder().setManufacturerData(0x01ce, byteArrayOf()).build()
            val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
            scanner?.startScan(listOf(filter), settings, callback)
        } catch (e: SecurityException) {
            sink?.error("permission", "Bluetooth の権限がありません。", null)
        } catch (e: IllegalStateException) {
            sink?.error("bluetooth", "Bluetooth の検索を開始できません。", null)
        }
    }

    private fun stopScan() {
        try { scanner?.stopScan(callback) } catch (_: SecurityException) { }
        scanner = null
    }

    override fun onDestroy() {
        stopScan()
        super.onDestroy()
    }
}
