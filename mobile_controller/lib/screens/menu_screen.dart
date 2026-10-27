import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../models/control_mode.dart';
import '../services/bluetooth_service.dart';
import '../services/udp_service.dart';
import 'camera_screen.dart';

class MenuScreen extends StatefulWidget {
  final List<CameraDescription> cameras;

  const MenuScreen({super.key, required this.cameras});

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  @override
  void initState() {
    super.initState();
    UdpService.instance.initialize().then((_) {
      if (mounted) setState(() {});
    });
  }

  void _selectMode(ControlMode mode) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CameraScreen(
          mode: mode,
          cameras: widget.cameras,
        ),
      ),
    ).then((_) {
      // Quando retornar do CameraScreen, atualiza o estado
      if (mounted) setState(() {});
    });
  }

  void _showBluetoothDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161824),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setSheetState) {
          final isConnected = BluetoothService.instance.isConnected;
          final isConnecting = BluetoothService.instance.isConnecting;
          final connectedName = BluetoothService.instance.connectedDeviceName;
          final paired = BluetoothService.instance.pairedDevicesNotifier.value;

          return Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 20,
              bottom: MediaQuery.of(context).viewInsets.bottom + 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2979FF).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.bluetooth, color: Color(0xFF2979FF), size: 24),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Conexão Bluetooth Sem Fio',
                            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            'Jogue sem cabos com latência mínima',
                            style: TextStyle(color: Colors.white54, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                if (isConnected) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00FF66).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF00FF66).withValues(alpha: 0.5)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle_rounded, color: Color(0xFF00FF66), size: 24),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('CONECTADO AO PC', style: TextStyle(color: Color(0xFF00FF66), fontSize: 11, fontWeight: FontWeight.bold)),
                              Text(connectedName ?? 'Computador Bluetooth', style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.redAccent.withValues(alpha: 0.2),
                            foregroundColor: Colors.redAccent,
                            side: const BorderSide(color: Colors.redAccent),
                          ),
                          onPressed: () async {
                            await BluetoothService.instance.disconnect();
                            setSheetState(() {});
                            setState(() {});
                          },
                          child: const Text('Desconectar'),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  // Card instrutivo para usuários experientes
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('💡 Instruções (Conexão Sem Fio):', style: TextStyle(color: Color(0xFF2979FF), fontWeight: FontWeight.bold, fontSize: 12)),
                        SizedBox(height: 4),
                        Text('1. No Windows, pareie seu smartphone via Configurações > Bluetooth.', style: TextStyle(color: Colors.white70, fontSize: 11)),
                        Text('2. Abra a Bridge no PC (ela escuta RFCOMM / Serial automaticamente).', style: TextStyle(color: Colors.white70, fontSize: 11)),
                        Text('3. Selecione seu computador na lista abaixo para conectar.', style: TextStyle(color: Colors.white70, fontSize: 11)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'DISPOSITIVOS PAREADOS',
                        style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.8),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.refresh, size: 16, color: Color(0xFF2979FF)),
                        label: const Text('Atualizar', style: TextStyle(color: Color(0xFF2979FF), fontSize: 12)),
                        onPressed: () async {
                          await BluetoothService.instance.refreshPairedDevices();
                          setSheetState(() {});
                        },
                      ),
                    ],
                  ),

                  if (paired.isEmpty) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      alignment: Alignment.center,
                      child: Column(
                        children: [
                          const Icon(Icons.bluetooth_searching, color: Colors.white30, size: 36),
                          const SizedBox(height: 8),
                          const Text(
                            'Nenhum computador pareado encontrado.',
                            style: TextStyle(color: Colors.white54, fontSize: 13),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: () async {
                              await BluetoothService.instance.refreshPairedDevices();
                              setSheetState(() {});
                            },
                            child: const Text('Buscar Dispositivos', style: TextStyle(color: Color(0xFF2979FF))),
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: paired.length,
                        separatorBuilder: (_, __) => const Divider(color: Colors.white10, height: 1),
                        itemBuilder: (ctx, index) {
                          final dev = paired[index];
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            leading: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.laptop_chromebook, color: Colors.white70, size: 20),
                            ),
                            title: Text(dev.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                            subtitle: Text(dev.address, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                            trailing: isConnecting
                                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF2979FF)))
                                : ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF2979FF),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                    ),
                                    onPressed: () async {
                                      final messenger = ScaffoldMessenger.of(context);
                                      setSheetState(() {});
                                      final ok = await BluetoothService.instance.connect(dev.address);
                                      if (!mounted) return;
                                      setSheetState(() {});
                                      setState(() {});
                                      if (ok) {
                                        if (ctx.mounted) Navigator.pop(ctx);
                                        messenger.showSnackBar(
                                          SnackBar(
                                            content: Text('Conectado via Bluetooth a ${dev.name}!'),
                                            backgroundColor: const Color(0xFF00FF66),
                                          ),
                                        );
                                      }
                                    },
                                    child: const Text('Conectar', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                  ),
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  void _showIpDialog() {
    final controller = TextEditingController(text: "");
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Configurar IP do Computador', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Insira o endereço IPv4 do PC na rede Wi-Fi onde a Bridge / Jogo está rodando:',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Color(0xFF00FF66), fontWeight: FontWeight.bold, fontSize: 16),
              decoration: const InputDecoration(
                hintText: 'Ex: 192.168.0.100',
                hintStyle: TextStyle(color: Colors.white30),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF00FF66))),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00FF66)),
            onPressed: () {
              final ip = controller.text.trim();
              if (ip.isNotEmpty) {
                UdpService.instance.addManualTarget(ip);
                setState(() {});
              }
              Navigator.pop(ctx);
            },
            child: const Text('Salvar', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E12),
      body: SafeArea(
        child: Column(
          children: [
            // Cabeçalho
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF00FF66).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.videogame_asset, color: Color(0xFF00FF66), size: 24),
                          ),
                          const SizedBox(width: 12),
                          const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'FUAG',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 18,
                                  letterSpacing: 1.5,
                                ),
                              ),
                              Text(
                                'Controle Adaptativo por IA',
                                style: TextStyle(color: Color(0xFF00FF66), fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ValueListenableBuilder<bool>(
                            valueListenable: BluetoothService.instance.isConnectedNotifier,
                            builder: (context, btConnected, _) {
                              return IconButton(
                                icon: Icon(
                                  btConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                                  color: btConnected ? const Color(0xFF2979FF) : Colors.white70,
                                ),
                                tooltip: 'Conexão Bluetooth Sem Fio',
                                onPressed: _showBluetoothDialog,
                              );
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.settings_ethernet, color: Colors.white70),
                            tooltip: 'Configurar IP',
                            onPressed: _showIpDialog,
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Banner Dinâmico de Conexão com a Bridge do PC
                  ValueListenableBuilder<bool>(
                    valueListenable: UdpService.instance.isConnectedNotifier,
                    builder: (context, isConnected, _) {
                      final isBt = BluetoothService.instance.isConnected;
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          color: isConnected
                              ? (isBt ? const Color(0xFF2979FF).withValues(alpha: 0.15) : const Color(0xFF00FF66).withValues(alpha: 0.12))
                              : const Color(0xFFFFB800).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isConnected
                                ? (isBt ? const Color(0xFF2979FF).withValues(alpha: 0.6) : const Color(0xFF00FF66).withValues(alpha: 0.5))
                                : const Color(0xFFFFB800).withValues(alpha: 0.5),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isConnected
                                  ? (isBt ? Icons.bluetooth_connected : Icons.check_circle_rounded)
                                  : Icons.wifi_find_rounded,
                              color: isConnected
                                  ? (isBt ? const Color(0xFF2979FF) : const Color(0xFF00FF66))
                                  : const Color(0xFFFFB800),
                              size: 17,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                isConnected
                                    ? (isBt
                                        ? 'PC CONECTADO VIA BLUETOOTH: Sem fios, pronto para jogar!'
                                        : 'PC CONECTADO: Bridge ativa e pronta para receber comandos!')
                                    : 'BUSCANDO PC: Aguardando Bridge (USB / Wi-Fi / Bluetooth)...',
                                style: TextStyle(
                                  color: isConnected
                                      ? (isBt ? const Color(0xFF82B1FF) : const Color(0xFF00FF66))
                                      : const Color(0xFFFFB800),
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),

                  const Text(
                    'Selecione o modo de controle:',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ],
              ),
            ),

            // Grade com os Modos de Controle (2 Colunas)
            Expanded(
              child: GridView.count(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 1.15,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                children: [
                  _buildModeGridCard(
                    mode: ControlMode.gestual,
                    title: 'Volante Virtual',
                    accentColor: const Color(0xFF00D4FF),
                    icon: Icons.sports_motorsports,
                  ),
                  _buildModeGridCard(
                    mode: ControlMode.fps,
                    title: 'FPS Tático',
                    accentColor: const Color(0xFFFF3366),
                    icon: Icons.gps_fixed,
                  ),
                  _buildModeGridCard(
                    mode: ControlMode.fpsMesh,
                    title: 'FPS Ocular',
                    accentColor: const Color(0xFF00E5FF),
                    icon: Icons.remove_red_eye_rounded,
                  ),
                  _buildModeGridCard(
                    mode: ControlMode.fight,
                    title: 'Modo Luta',
                    accentColor: const Color(0xFFFF5722),
                    icon: Icons.sports_mma,
                  ),
                  _buildModeGridCard(
                    mode: ControlMode.facial,
                    title: 'Controle Facial',
                    accentColor: const Color(0xFF00FF66),
                    icon: Icons.face,
                  ),
                  _buildModeGridCard(
                    mode: ControlMode.corporal,
                    title: 'Corpo Inteiro',
                    accentColor: const Color(0xFFFF9900),
                    icon: Icons.accessibility_new,
                  ),
                ],
              ),
            ),

            // Rodapé de Conexão UDP
            Container(
              margin: const EdgeInsets.all(14),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.wifi, color: Color(0xFF00FF66), size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Destinos UDP: ${UdpService.instance.targetSummary} (:5000)',
                      style: const TextStyle(color: Colors.white60, fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh, color: Colors.white60, size: 18),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () async {
                      await UdpService.instance.refreshNetworkTargets();
                      if (mounted) setState(() {});
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeGridCard({
    required ControlMode mode,
    required String title,
    required Color accentColor,
    required IconData icon,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _selectMode(mode),
        borderRadius: BorderRadius.circular(16),
        splashColor: accentColor.withValues(alpha: 0.25),
        highlightColor: accentColor.withValues(alpha: 0.10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF16161E),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: accentColor.withValues(alpha: 0.40),
              width: 1.4,
            ),
            boxShadow: [
              BoxShadow(
                color: accentColor.withValues(alpha: 0.12),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: accentColor.withValues(alpha: 0.35),
                    width: 1.2,
                  ),
                ),
                child: Icon(icon, color: accentColor, size: 30),
              ),
              const SizedBox(height: 12),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
