import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

class BluetoothDeviceInfo {
  final String name;
  final String address;

  BluetoothDeviceInfo({required this.name, required this.address});

  factory BluetoothDeviceInfo.fromMap(Map<dynamic, dynamic> map) {
    return BluetoothDeviceInfo(
      name: map['name']?.toString() ?? 'Dispositivo Desconhecido',
      address: map['address']?.toString() ?? '',
    );
  }
}

/// Serviço Singleton para conexão Bluetooth Classic (RFCOMM / SPP)
/// voltado para conexão sem fio de baixa latência sem cabos nem rede Wi-Fi.
class BluetoothService {
  BluetoothService._internal();
  static final BluetoothService instance = BluetoothService._internal();

  static const MethodChannel _channel = MethodChannel('com.example.mobile_controller/bluetooth');
  static const EventChannel _eventChannel = EventChannel('com.example.mobile_controller/bluetooth_events');

  final ValueNotifier<bool> isConnectedNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isConnectingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<String?> connectedDeviceNameNotifier = ValueNotifier<String?>(null);
  final ValueNotifier<List<BluetoothDeviceInfo>> pairedDevicesNotifier = ValueNotifier<List<BluetoothDeviceInfo>>([]);
  final ValueNotifier<String> orientationNotifier = ValueNotifier<String>('portrait');

  bool get isConnected => isConnectedNotifier.value;
  bool get isConnecting => isConnectingNotifier.value;
  String? get connectedDeviceName => connectedDeviceNameNotifier.value;
  bool get isLandscape => orientationNotifier.value == 'landscape';

  StreamSubscription? _eventSubscription;
  bool _isInitialized = false;

  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;

    try {
      _eventSubscription = _eventChannel.receiveBroadcastStream().listen((dynamic event) {
        if (event is Map) {
          final status = event['status']?.toString();
          if (status == 'connected') {
            isConnectedNotifier.value = true;
            isConnectingNotifier.value = false;
            connectedDeviceNameNotifier.value = event['name']?.toString() ?? 'PC';
            debugPrint('[BluetoothService] Conectado a ${connectedDeviceNameNotifier.value}');
          } else if (status == 'connecting') {
            isConnectingNotifier.value = true;
          } else if (status == 'disconnected') {
            isConnectedNotifier.value = false;
            isConnectingNotifier.value = false;
            connectedDeviceNameNotifier.value = null;
            debugPrint('[BluetoothService] Desconectado.');
          } else if (status == 'orientation') {
            final mode = event['orientation']?.toString() ?? 'portrait';
            if (orientationNotifier.value != mode) {
              orientationNotifier.value = mode;
              debugPrint('[DeviceOrientation] Orientação física via acelerômetro: $mode');
            }
          } else if (status == 'error') {
            isConnectedNotifier.value = false;
            isConnectingNotifier.value = false;
            debugPrint('[BluetoothService] Erro: ${event['message']}');
          }
        }
      }, onError: (dynamic error) {
        debugPrint('[BluetoothService] Erro no EventChannel: $error');
      });

      try {
        final initialOri = await _channel.invokeMethod<String>('getPhysicalOrientation');
        if (initialOri != null) orientationNotifier.value = initialOri;
      } catch (_) {}

      await refreshPairedDevices();
    } catch (e) {
      debugPrint('[BluetoothService] Falha ao inicializar: $e');
    }
  }

  Future<bool> requestPermissions() async {
    try {
      final statuses = await [
        Permission.bluetoothConnect,
        Permission.bluetoothScan,
        Permission.location,
      ].request();

      final connectGranted = statuses[Permission.bluetoothConnect]?.isGranted ?? true;
      return connectGranted;
    } catch (e) {
      debugPrint('[BluetoothService] Erro ao solicitar permissões: $e');
      return true;
    }
  }

  Future<List<BluetoothDeviceInfo>> refreshPairedDevices() async {
    try {
      await requestPermissions();
      final List<dynamic>? result = await _channel.invokeMethod('getPairedDevices');
      if (result != null) {
        final list = result.map((item) => BluetoothDeviceInfo.fromMap(item as Map)).toList();
        pairedDevicesNotifier.value = list;
        return list;
      }
    } catch (e) {
      debugPrint('[BluetoothService] Erro ao listar dispositivos pareados: $e');
    }
    return [];
  }

  Future<bool> connect(String address) async {
    try {
      isConnectingNotifier.value = true;
      final bool success = await _channel.invokeMethod('connect', {'address': address}) ?? false;
      return success;
    } catch (e) {
      isConnectingNotifier.value = false;
      debugPrint('[BluetoothService] Erro ao conectar ao endereço $address: $e');
      return false;
    }
  }

  Future<void> disconnect() async {
    try {
      await _channel.invokeMethod('disconnect');
      isConnectedNotifier.value = false;
      isConnectingNotifier.value = false;
      connectedDeviceNameNotifier.value = null;
    } catch (e) {
      debugPrint('[BluetoothService] Erro ao desconectar: $e');
    }
  }

  bool sendPayload(Map<String, dynamic> payload) {
    if (!isConnected) return false;
    try {
      final jsonString = jsonEncode(payload);
      _channel.invokeMethod('sendPayload', {'data': jsonString});
      return true;
    } catch (e) {
      debugPrint('[BluetoothService] Erro ao enviar payload: $e');
      return false;
    }
  }

  void dispose() {
    _eventSubscription?.cancel();
    disconnect();
  }
}

