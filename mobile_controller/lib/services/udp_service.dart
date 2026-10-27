import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'bluetooth_service.dart';

/// Serviço Singleton para transmissão assíncrona de comandos via Socket UDP.
/// Topologia "Zero-Config Híbrida":
/// 1. Broadcast Global (255.255.255.255)
/// 2. Detecção automática de dispositivos conectados na Ancoragem USB (leitura de /proc/net/arp)
/// 3. Broadcast de sub-rede em todas as interfaces ativas (Wi-Fi e USB Tethering)
/// 4. Conexão direta Bluetooth RFCOMM/SPP sem fio
class UdpService {
  UdpService._internal();
  static final UdpService instance = UdpService._internal();

  RawDatagramSocket? _socket;
  Socket? _tcpSocket;
  bool _isConnectingTcp = false;
  DateTime _lastTcpAttempt = DateTime.fromMillisecondsSinceEpoch(0);

  static const int port = 5000;

  final Set<String> _targetIpStrings = {
    '255.255.255.255', // Broadcast Global UDP
    '127.0.0.1',       // Túnel USB ADB Reverso
  };
  final List<InternetAddress> _targetAddresses = [];

  DateTime _lastSendTime = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _minInterval = Duration(milliseconds: 16); // ~60 pacotes/s (Zero-delay)

  Map<String, dynamic> _lastSentPayload = {};
  int packetsSent = 0;
  String targetSummary = "Broadcast (255.255.255.255), ADB (127.0.0.1)";

  final ValueNotifier<bool> isConnectedNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<String> connectionInfoNotifier = ValueNotifier<String>("Buscando PC no USB / Wi-Fi / Bluetooth...");

  Future<void> initialize() async {
    // Inicializa módulo Bluetooth nativo
    BluetoothService.instance.initialize();
    BluetoothService.instance.isConnectedNotifier.addListener(() {
      if (BluetoothService.instance.isConnected) {
        isConnectedNotifier.value = true;
        connectionInfoNotifier.value = "Conectado via Bluetooth (${BluetoothService.instance.connectedDeviceName ?? 'PC'})";
      } else if (_tcpSocket == null) {
        isConnectedNotifier.value = false;
        connectionInfoNotifier.value = "Buscando PC no USB / Wi-Fi / Bluetooth...";
      }
    });

    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _socket?.broadcastEnabled = true;
      _socket?.listen(
        (event) {
          if (event == RawSocketEvent.read) {
            final datagram = _socket?.receive();
            if (datagram != null) {
              final text = utf8.decode(datagram.data, allowMalformed: true);
              if (text.contains('"status"') || text.contains('connected')) {
                isConnectedNotifier.value = true;
                connectionInfoNotifier.value = "Conectado via Wi-Fi (${datagram.address.address})";
              }
            }
          }
        },
        onError: (err) {
          debugPrint('[UdpService] Socket UDP info/aviso: $err');
        },
        cancelOnError: false,
      );
      debugPrint('[UdpService] Socket UDP inicializado na porta $port');
      await refreshNetworkTargets();
    } catch (e) {
      debugPrint('[UdpService] Erro ao instanciar RawDatagramSocket: $e');
    }
    // Conecta imediatamente ao túnel TCP via USB se disponível
    _ensureTcpConnected();
  }

  /// Conecta ou reconecta ao túnel USB ADB reverso (localhost:5000)
  Future<void> _ensureTcpConnected() async {
    if (_tcpSocket != null || _isConnectingTcp) return;
    final now = DateTime.now();
    if (now.difference(_lastTcpAttempt) < const Duration(milliseconds: 500)) return;
    _lastTcpAttempt = now;
    _isConnectingTcp = true;

    try {
      final s = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: const Duration(milliseconds: 1500),
      );
      s.setOption(SocketOption.tcpNoDelay, true);
      _tcpSocket = s;
      isConnectedNotifier.value = true;
      connectionInfoNotifier.value = "Conectado via USB ADB (127.0.0.1:$port)";
      debugPrint('[UdpService] SUCESSO: Conexão TCP estabelecida via Túnel USB (127.0.0.1:$port)!');
      s.listen(
        (data) {
          final text = utf8.decode(data, allowMalformed: true);
          if (text.contains('"status"') || text.contains('connected')) {
            isConnectedNotifier.value = true;
            connectionInfoNotifier.value = "Conectado via USB ADB (127.0.0.1:$port)";
          }
        },
        onError: (err) {
          debugPrint('[UdpService] Socket TCP desconectado: $err');
          isConnectedNotifier.value = false;
          try { _tcpSocket?.destroy(); } catch (_) {}
          _tcpSocket = null;
        },
        onDone: () {
          debugPrint('[UdpService] Socket TCP encerrado.');
          isConnectedNotifier.value = false;
          try { _tcpSocket?.destroy(); } catch (_) {}
          _tcpSocket = null;
        },
        cancelOnError: true,
      );
    } catch (_) {
      // Ignora falhas silenciosas de conexão quando o jogo ainda não abriu
      _tcpSocket = null;
    } finally {
      _isConnectingTcp = false;
    }
  }

  /// Descobre automaticamente o IP do PC conectado via Ancoragem USB ou Wi-Fi
  Future<void> refreshNetworkTargets() async {
    final discoveredIps = <String>{'255.255.255.255'};

    // 1. Tenta ler tabela ARP do Android para obter o IP do PC na interface usb0 / rndis0
    try {
      final arpFile = File('/proc/net/arp');
      if (await arpFile.exists()) {
        final lines = await arpFile.readAsLines();
        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.startsWith('IP address') || trimmed.isEmpty) continue;
          final parts = trimmed.split(RegExp(r'\s+'));
          if (parts.isNotEmpty) {
            final ip = parts[0];
            // Verifica se é um IP privado válido (classe A, B ou C)
            if (_isIpv4(ip) && !ip.endsWith('.1') && !ip.endsWith('.255')) {
              discoveredIps.add(ip);
              debugPrint('[UdpService] PC detectado na tabela ARP: $ip');
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[UdpService] Leitura de /proc/net/arp: $e');
    }

    // 2. Calcula broadcasts de sub-rede para cada interface
    try {
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );

      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          final parts = ip.split('.');
          if (parts.length == 4) {
            final subnetBroadcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
            discoveredIps.add(subnetBroadcast);
          }
        }
      }
    } catch (e) {
      debugPrint('[UdpService] Erro ao listar interfaces de rede: $e');
    }

    _targetIpStrings.addAll(discoveredIps);
    _rebuildAddressList();
  }

  void addManualTarget(String ip) {
    if (_isIpv4(ip)) {
      _targetIpStrings.add(ip);
      _rebuildAddressList();
    }
  }

  void _rebuildAddressList() {
    _targetAddresses.clear();
    for (final ip in _targetIpStrings) {
      try {
        _targetAddresses.add(InternetAddress(ip));
      } catch (_) {}
    }
    targetSummary = _targetIpStrings.join(', ');
    debugPrint('[UdpService] Destinos UDP ativos: $targetSummary');
  }

  bool _isIpv4(String ip) {
    final regExp = RegExp(r'^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$');
    return regExp.hasMatch(ip);
  }

  /// Transmite o payload JSON com fail-safe e throttle (UDP e TCP Túnel USB)
  void sendPayload(Map<String, dynamic> payload) {
    final now = DateTime.now();
    final elapsed = now.difference(_lastSendTime);

    final double currentAngle = (payload['angulo'] as num?)?.toDouble() ?? 0.0;
    final double lastAngle = (_lastSentPayload['angulo'] as num?)?.toDouble() ?? 0.0;
    final bool angleMoved = (currentAngle - lastAngle).abs() >= 0.4;

    final bool isFps = payload['modo'] == 'fps';
    final int mouseDx = (payload['mouse_dx'] as num?)?.toInt() ?? 0;
    final int mouseDy = (payload['mouse_dy'] as num?)?.toInt() ?? 0;
    final bool fpsMoved = isFps && (
        mouseDx != 0 ||
        mouseDy != 0 ||
        payload['disparo'] != _lastSentPayload['disparo'] ||
        payload['zoom'] != _lastSentPayload['zoom'] ||
        payload['recarregar'] != _lastSentPayload['recarregar']
    );

    final bool stateChanged =
        fpsMoved ||
        angleMoved ||
        payload['esquerda'] != _lastSentPayload['esquerda'] ||
        payload['direita'] != _lastSentPayload['direita'] ||
        payload['cima'] != _lastSentPayload['cima'] ||
        payload['baixo'] != _lastSentPayload['baixo'] ||
        payload['pular'] != _lastSentPayload['pular'] ||
        payload['polegar_dir'] != _lastSentPayload['polegar_dir'] ||
        payload['polegar_esq'] != _lastSentPayload['polegar_esq'];

    // No modo FPS, envia imediatamente qualquer movimento sem throttling para latência zero
    final bool allowSend = isFps ? (fpsMoved || elapsed.inMilliseconds >= 33) : (stateChanged || elapsed >= _minInterval);

    if (allowSend) {
      _lastSendTime = now;
      _lastSentPayload = Map<String, dynamic>.from(payload);

      try {
        final jsonString = jsonEncode(payload);

        // 1. Se o cabo USB (TCP 127.0.0.1:5000) estiver conectado, envia via cabo USB (latência sub-milisegundo)
        if (_tcpSocket != null) {
          try {
            _tcpSocket!.write('$jsonString\n');
            _tcpSocket!.flush().catchError((_) {});
          } catch (err) {
            debugPrint('[UdpService] Erro no socket TCP: $err');
            try {
              _tcpSocket?.destroy();
            } catch (_) {}
            _tcpSocket = null;
            _ensureTcpConnected();
          }
        } else if (BluetoothService.instance.isConnected) {
          // 2. Se conectado via Bluetooth RFCOMM/SPP, transmite diretamente pelo canal Bluetooth sem fios
          BluetoothService.instance.sendPayload(payload);
        } else {
          // 3. Se não houver cabo USB nem Bluetooth direto, transmite via UDP para rede local / Wi-Fi / Ancoragem
          if (_socket != null) {
            final bytes = utf8.encode(jsonString);
            for (final address in _targetAddresses) {
              try {
                _socket?.send(bytes, address, port);
              } catch (_) {}
            }
          }
          _ensureTcpConnected();
        }

        packetsSent++;
      } catch (e) {
        debugPrint('[UdpService] Erro ao enviar pacote: $e');
      }
    }
  }

  /// Dispara imediatamente a liberação de todas as ações na Bridge / Jogos (fail-safe)
  void sendZeroPayload() {
    sendPayload({
      "esquerda": false,
      "direita": false,
      "cima": false,
      "baixo": false,
      "pular": false,
      "polegar_dir": false,
      "polegar_esq": false,
      "angulo": 0.0,
      "detect": false,
    });
  }

  void dispose() {
    sendZeroPayload();
    _socket?.close();
    _socket = null;
    _tcpSocket?.destroy();
    _tcpSocket = null;
  }
}
