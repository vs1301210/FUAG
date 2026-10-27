package com.example.mobile_controller

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.hardware.SensorManager
import android.os.Handler
import android.os.Looper
import android.view.OrientationEventListener
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val METHOD_CHANNEL = "com.example.mobile_controller/bluetooth"
    private val EVENT_CHANNEL = "com.example.mobile_controller/bluetooth_events"

    // UUID Padrão Serial Port Profile (SPP / RFCOMM)
    private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var eventSink: EventChannel.EventSink? = null
    private var bluetoothSocket: BluetoothSocket? = null
    private var outputStream: OutputStream? = null
    private var connectedDeviceName: String? = null
    private var isConnected = false

    private var orientationListener: OrientationEventListener? = null
    private var currentPhysicalOrientation: String = "portrait"

    private val bluetoothAdapter: BluetoothAdapter? by lazy {
        val manager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        manager?.adapter ?: BluetoothAdapter.getDefaultAdapter()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            }
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isBluetoothAvailable" -> {
                    result.success(bluetoothAdapter != null)
                }
                "isBluetoothEnabled" -> {
                    result.success(bluetoothAdapter?.isEnabled == true)
                }
                "getPairedDevices" -> {
                    try {
                        val adapter = bluetoothAdapter
                        if (adapter == null || !adapter.isEnabled) {
                            result.success(emptyList<Map<String, String>>())
                            return@setMethodCallHandler
                        }
                        val paired = adapter.bondedDevices
                        val list = paired.map { device ->
                            mapOf(
                                "name" to (device.name ?: "Dispositivo Desconhecido"),
                                "address" to device.address
                            )
                        }
                        result.success(list)
                    } catch (e: SecurityException) {
                        result.error("PERMISSION_DENIED", "Permissão Bluetooth não concedida: ${e.message}", null)
                    } catch (e: Exception) {
                        result.error("ERROR", e.message, null)
                    }
                }
                "connect" -> {
                    val address = call.argument<String>("address")
                    if (address == null) {
                        result.error("INVALID_ARGUMENT", "Endereço Bluetooth nulo", null)
                        return@setMethodCallHandler
                    }
                    connectToDevice(address, result)
                }
                "disconnect" -> {
                    disconnect()
                    result.success(true)
                }
                "sendPayload" -> {
                    val data = call.argument<String>("data")
                    if (data == null) {
                        result.error("INVALID_ARGUMENT", "Payload nulo", null)
                        return@setMethodCallHandler
                    }
                    val sent = sendData(data)
                    result.success(sent)
                }
                "isConnected" -> {
                    result.success(isConnected)
                }
                "getConnectedDevice" -> {
                    result.success(connectedDeviceName)
                }
                "getPhysicalOrientation" -> {
                    result.success(currentPhysicalOrientation)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        try {
            orientationListener = object : OrientationEventListener(this, SensorManager.SENSOR_DELAY_UI) {
                override fun onOrientationChanged(orientation: Int) {
                    if (orientation == ORIENTATION_UNKNOWN) return
                    val isLandscape = (orientation in 55..125) || (orientation in 235..305)
                    val newMode = if (isLandscape) "landscape" else "portrait"
                    if (newMode != currentPhysicalOrientation) {
                        currentPhysicalOrientation = newMode
                        notifyEvent(mapOf("status" to "orientation", "orientation" to newMode, "angle" to orientation))
                    }
                }
            }
            if (orientationListener?.canDetectOrientation() == true) {
                orientationListener?.enable()
            }
        } catch (_: Exception) {}
    }

    private fun connectToDevice(address: String, result: MethodChannel.Result) {
        val adapter = bluetoothAdapter
        if (adapter == null || !adapter.isEnabled) {
            result.error("BLUETOOTH_DISABLED", "Bluetooth desativado", null)
            return
        }

        executor.execute {
            try {
                notifyEvent(mapOf("status" to "connecting", "address" to address))
                disconnect()

                val device = adapter.getRemoteDevice(address)
                val deviceName = try { device.name ?: address } catch (_: SecurityException) { address }

                var socket: BluetoothSocket? = null
                var lastException: Exception? = null

                // Estratégia 1: Conectar diretamente pelo Canal RFCOMM 4 (Winsock RFCOMM padrão)
                try {
                    val method = device.javaClass.getMethod("createInsecureRfcommSocket", Int::class.javaPrimitiveType)
                    socket = method.invoke(device, 4) as? BluetoothSocket
                    socket?.connect()
                } catch (e: Exception) {
                    lastException = e
                    socket = null
                }

                // Estratégia 2: Fallback Canal RFCOMM 4 Seguro
                if (socket == null || !socket.isConnected) {
                    try {
                        val method = device.javaClass.getMethod("createRfcommSocket", Int::class.javaPrimitiveType)
                        socket = method.invoke(device, 4) as? BluetoothSocket
                        socket?.connect()
                    } catch (e: Exception) {
                        lastException = e
                        socket = null
                    }
                }

                // Estratégia 3: Standard Serial Port Profile (SPP UUID) Insecure
                if (socket == null || !socket.isConnected) {
                    try {
                        socket = device.createInsecureRfcommSocketToServiceRecord(SPP_UUID)
                        socket.connect()
                    } catch (e: Exception) {
                        lastException = e
                        socket = null
                    }
                }

                // Estratégia 4: Standard SPP UUID Secure
                if (socket == null || !socket.isConnected) {
                    try {
                        socket = device.createRfcommSocketToServiceRecord(SPP_UUID)
                        socket.connect()
                    } catch (e: Exception) {
                        lastException = e
                        socket = null
                    }
                }

                if (socket != null && socket.isConnected) {
                    bluetoothSocket = socket
                    outputStream = socket.outputStream
                    connectedDeviceName = deviceName
                    isConnected = true

                    mainHandler.post {
                        result.success(true)
                    }

                    notifyEvent(mapOf(
                        "status" to "connected",
                        "name" to deviceName,
                        "address" to address
                    ))

                    // Inicia thread de escuta do PC
                    startSocketReader(socket)
                } else {
                    val err = lastException?.message ?: "Falha ao conectar via RFCOMM/SPP"
                    mainHandler.post {
                        result.error("CONNECT_FAILED", err, null)
                    }
                    notifyEvent(mapOf("status" to "error", "message" to err))
                }
            } catch (e: SecurityException) {
                mainHandler.post {
                    result.error("PERMISSION_DENIED", "Permissão Bluetooth negada: ${e.message}", null)
                }
                notifyEvent(mapOf("status" to "error", "message" to (e.message ?: "Permissão negada")))
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("CONNECT_ERROR", e.message, null)
                }
                notifyEvent(mapOf("status" to "error", "message" to (e.message ?: "Erro desconhecido")))
            }
        }
    }

    private fun startSocketReader(socket: BluetoothSocket) {
        executor.execute {
            try {
                val reader = BufferedReader(InputStreamReader(socket.inputStream))
                while (isConnected && socket.isConnected) {
                    val line = reader.readLine() ?: break
                    if (line.isNotEmpty()) {
                        mainHandler.post {
                            notifyEvent(mapOf("status" to "data", "payload" to line))
                        }
                    }
                }
            } catch (_: Exception) {
            } finally {
                if (isConnected) {
                    disconnect()
                    notifyEvent(mapOf("status" to "disconnected"))
                }
            }
        }
    }

    private fun sendData(data: String): Boolean {
        return try {
            val out = outputStream
            if (out != null && isConnected) {
                val bytes = (data + "\n").toByteArray(Charsets.UTF_8)
                out.write(bytes)
                out.flush()
                true
            } else {
                false
            }
        } catch (_: Exception) {
            disconnect()
            notifyEvent(mapOf("status" to "disconnected"))
            false
        }
    }

    private fun disconnect() {
        isConnected = false
        connectedDeviceName = null
        try {
            outputStream?.close()
        } catch (_: Exception) {}
        outputStream = null

        try {
            bluetoothSocket?.close()
        } catch (_: Exception) {}
        bluetoothSocket = null
    }

    private fun notifyEvent(event: Map<String, Any?>) {
        mainHandler.post {
            eventSink?.success(event)
        }
    }

    override fun onDestroy() {
        try {
            orientationListener?.disable()
            orientationListener = null
        } catch (_: Exception) {}
        disconnect()
        executor.shutdown()
        super.onDestroy()
    }
}

