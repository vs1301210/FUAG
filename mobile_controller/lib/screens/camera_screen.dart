import 'dart:io';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:hand_landmarker/hand_landmarker.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/control_mode.dart';
import '../services/bluetooth_service.dart';
import '../services/udp_service.dart';

class CameraScreen extends StatefulWidget {
  final ControlMode mode;
  final List<CameraDescription> cameras;

  const CameraScreen({
    super.key,
    required this.mode,
    required this.cameras,
  });

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _cameraController;

  // Detectores de IA (Google ML Kit e Google MediaPipe Tasks)
  FaceDetector? _faceDetector;
  PoseDetector? _poseDetector;
  HandLandmarkerPlugin? _handLandmarker;

  bool _isProcessing = false;
  bool _cameraPermissionGranted = false;
  bool _hasDetection = false;

  // Estado dos Comandos para envio UDP
  Map<String, dynamic> _currentPayload = {
    "esquerda": false,
    "direita": false,
    "cima": false,
    "baixo": false,
    "pular": false,
  };

  // Telemetria Facial
  double _smileProb = 0.0;
  double _headAngleZ = 0.0;
  double _headAngleY = 0.0;
  double _headAngleX = 0.0;

  // Telemetria Gestual / Volante Virtual
  double _wheelAngle = 0.0;
  double _smoothedWheelAngle = 0.0;
  bool _isRightHandOpen = false;
  bool _isLeftHandOpen = false;
  bool _isRightThumbUp = false;
  bool _isLeftThumbUp = false;
  double _rightThumbScore = 0.0;
  double _leftThumbScore = 0.0;
  int _rightThumbDropFrames = 0;
  int _leftThumbDropFrames = 0;
  int _thumbSensitivityIndex = 1; // 0 = Baixa, 1 = Média, 2 = Alta
  int _wheelSensitivityIndex = 0; // 0 = Suave (45°), 1 = Normal (34°), 2 = Rápida (24°)
  bool _invertSteering = false;
  int _selectedCameraIndex = 0;
  List<Hand> _detectedHands = [];

  // Filtros de persistência e histerese para estabilidade gestual
  int _consecutiveMissingHandFrames = 0;
  int _wheelCenterDwellStartTime = 0;
  String _lastSteerDirection = 'centro';

  String get _thumbSensitivityLabel {
    switch (_thumbSensitivityIndex) {
      case 0:
        return 'BAIXA';
      case 2:
        return 'ALTA';
      default:
        return 'MÉDIA';
    }
  }

  String get _thumbSensitivityShortLabel {
    switch (_thumbSensitivityIndex) {
      case 0:
        return 'PED: BX';
      case 2:
        return 'PED: ALT';
      default:
        return 'PED: MED';
    }
  }

  String get _wheelSensitivityLabel {
    switch (_wheelSensitivityIndex) {
      case 0:
        return 'SUAVE';
      case 2:
        return 'RÁPIDA';
      default:
        return 'NORMAL';
    }
  }

  String get _wheelSensitivityShortLabel {
    switch (_wheelSensitivityIndex) {
      case 0:
        return 'VOL: SUA';
      case 2:
        return 'VOL: RAP';
      default:
        return 'VOL: MED';
    }
  }

  double get _wheelMaxAngle {
    switch (_wheelSensitivityIndex) {
      case 0:
        return 45.0; // Ângulo amplo, suave, controle fino sem puxar bruscamente
      case 2:
        return 24.0; // Ângulo curto, resposta agressiva
      default:
        return 34.0; // Padrão equilibrado
    }
  }

  double get _wheelDeadzone {
    switch (_wheelSensitivityIndex) {
      case 0:
        return 3.5; // Centro limpo e sem tremores
      case 2:
        return 2.0; // Centro ultra-rápido
      default:
        return 2.8; // Padrão
    }
  }

  double get _thumbOnThreshold {
    switch (_thumbSensitivityIndex) {
      case 0:
        return 0.58; // Baixa sensibilidade: requer dedão bem esticado e alto
      case 2:
        return 0.38; // Alta sensibilidade
      default:
        return 0.48; // Média / Padrão equilibrado
    }
  }

  double get _thumbOffThreshold {
    switch (_thumbSensitivityIndex) {
      case 0:
        return 0.35;
      case 2:
        return 0.22;
      default:
        return 0.28;
    }
  }

  // Telemetria Corporal
  double _prevHipY = 0.0;
  double _baselineHipY = 0.0;
  double _hipYDelta = 0.0;
  double _shoulderTilt = 0.0;
  double _legDistance = 0.0;
  double _baselineLegDistance = 0.0;

  // Telemetria e Estado do Modo FPS (Arma Virtual / CS 1.6)
  Offset? _fpsLastIndexPos;
  bool _fpsIsGunActive = false;
  bool _fpsIsZoom = false;
  bool _fpsIsFiring = false;
  bool _fpsIsReloading = false;
  bool _fpsTwoHandsLocked = false;
  int _fpsLockedGripFrames = 0;
  int _fpsLastReloadTime = 0;
  int _fpsRecoilSuppressionFrames = 0;
  Offset _fpsCrosshairPos = const Offset(0.5, 0.5);
  int _fpsSensitivityIndex = 1; // 0 = Baixa, 1 = Média, 2 = Alta
  bool _fpsInvertY = false;

  // Filtro de estabilização e sub-pixel para mira estável (sem flicks nem jitter)
  double _fpsFilteredDx = 0.0;
  double _fpsFilteredDy = 0.0;
  double _fpsSubpixelX = 0.0;
  double _fpsSubpixelY = 0.0;

  // Gatilho no Dedo do Meio (Fechar o dedo -> Disparo)
  bool _fpsMiddleWasOpen = false;
  double _fpsLastMiddleRatio = 1.0;

  // Zoom Frontal Exclusivo do Polegar (Digital apontada para a lente)
  int _fpsZoomOnFrames = 0;
  int _fpsZoomOffFrames = 0;

  // Telemetria e Estado do Modo FPS Mesh / Ocular (Acessibilidade Severa CS 1.6)
  double _fpsMeshBaselinePitch = 0.0;
  double _fpsMeshBaselineYaw = 0.0;
  bool _fpsMeshBaselineCalibrated = false;
  double _fpsMeshFilteredDx = 0.0;
  double _fpsMeshFilteredDy = 0.0;
  double _fpsMeshJoyRx = 0.0;
  double _fpsMeshJoyRy = 0.0;
  double _fpsMeshJoyLx = 0.0;
  double _fpsMeshJoyLy = 0.0;
  double _fpsMeshBlinkLeft = 0.0;
  double _fpsMeshBlinkRight = 0.0;
  bool _fpsMeshIsFiring = false;
  bool _fpsMeshIsZoom = false;
  bool _fpsMeshIsReloading = false;
  bool _fpsMeshCmdW = false;
  bool _fpsMeshCmdA = false;
  bool _fpsMeshCmdS = false;
  bool _fpsMeshCmdD = false;
  List<Face> _fpsMeshDetectedFaces = [];

  // Telemetria e Estado do Modo Luta (Stick Fight The Game)
  bool _fightIsAttacking = false;
  bool _fightIsDefending = false;
  bool _fightIsJumping = false;
  bool _fightIsMovingLeft = false;
  bool _fightIsMovingRight = false;
  double _fightBodySway = 0.0;
  double _fightBaselineHipY = 0.0;
  double _fightPrevHipY = 0.0;
  int _fightLastPunchTime = 0;
  List<Pose> _fightDetectedPoses = [];

  String get _fpsSensitivityLabel {
    switch (_fpsSensitivityIndex) {
      case 0:
        return 'BAIXA';
      case 2:
        return 'ALTA';
      default:
        return 'MÉDIA';
    }
  }

  String get _fpsSensitivityShortLabel {
    switch (_fpsSensitivityIndex) {
      case 0:
        return 'SENS: BX';
      case 2:
        return 'SENS: ALT';
      default:
        return 'SENS: MED';
    }
  }

  double get _fpsSensitivityScale {
    switch (_fpsSensitivityIndex) {
      case 0:
        return 420.0; // Sensibilidade Baixa: Precisão para longa distância / sniper
      case 2:
        return 1100.0; // Sensibilidade Alta: Viradas rápidas e combate próximo
      default:
        return 720.0; // Sensibilidade Média: Padrão balanceado e controlado
    }
  }

  int _frameCounter = 0;

  // Buffers reutilizáveis para conversão de imagem zero-copy
  Uint8List? _reusableNv21Buffer;
  int _lastNv21Size = 0;
  Uint8List? _reusablePlaneBuffer;

  final Map<DeviceOrientation, int> _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  @override
  void initState() {
    super.initState();
    _initSpecificDetector();
    _requestPermissionAndInitCamera();
  }

  /// Instancia EXCLUSIVAMENTE o detector exigido pelo modo ativo
  void _initSpecificDetector() {
    switch (widget.mode) {
      case ControlMode.facial:
        _faceDetector = FaceDetector(
          options: FaceDetectorOptions(
            enableClassification: true,
            enableTracking: true,
            performanceMode: FaceDetectorMode.fast,
            minFaceSize: 0.10,
          ),
        );
        debugPrint('[CameraScreen] Modo FACIAL ativado: FaceDetector inicializado.');
        break;

      case ControlMode.gestual:
        try {
          _handLandmarker = HandLandmarkerPlugin.create(
            numHands: 2,
            minHandDetectionConfidence: 0.40,
            delegate: HandLandmarkerDelegate.gpu,
          );
          debugPrint('[CameraScreen] Modo GESTUAL ativado: Google MediaPipe HandLandmarker (GPU) inicializado.');
        } catch (e) {
          debugPrint('[CameraScreen] Fallback para CPU: $e');
          _handLandmarker = HandLandmarkerPlugin.create(
            numHands: 2,
            minHandDetectionConfidence: 0.40,
            delegate: HandLandmarkerDelegate.cpu,
          );
        }
        break;

      case ControlMode.corporal:
      case ControlMode.fight:
        _poseDetector = PoseDetector(
          options: PoseDetectorOptions(
            model: PoseDetectionModel.base,
            mode: PoseDetectionMode.stream,
          ),
        );
        debugPrint('[CameraScreen] Modo ${widget.mode.name.toUpperCase()} ativado: PoseDetector inicializado.');
        break;

      case ControlMode.fps:
        try {
          _handLandmarker = HandLandmarkerPlugin.create(
            numHands: 2,
            minHandDetectionConfidence: 0.25,
            delegate: HandLandmarkerDelegate.gpu,
          );
          debugPrint('[CameraScreen] Modo FPS ativado: Google MediaPipe HandLandmarker (GPU) inicializado.');
        } catch (e) {
          debugPrint('[CameraScreen] Fallback para CPU: $e');
          _handLandmarker = HandLandmarkerPlugin.create(
            numHands: 2,
            minHandDetectionConfidence: 0.25,
            delegate: HandLandmarkerDelegate.cpu,
          );
        }
        break;

      case ControlMode.fpsMesh:
        _faceDetector = FaceDetector(
          options: FaceDetectorOptions(
            enableClassification: true,
            enableTracking: true,
            enableLandmarks: true,
            enableContours: true,
            performanceMode: FaceDetectorMode.fast,
            minFaceSize: 0.10,
          ),
        );
        debugPrint('[CameraScreen] Modo FPS OCULAR/MESH ativado: FaceDetector inicializado.');
        break;
    }
  }

  Future<void> _requestPermissionAndInitCamera() async {
    final status = await Permission.camera.request();
    if (status.isGranted) {
      if (mounted) setState(() => _cameraPermissionGranted = true);
      await _setupCamera();
    } else {
      if (mounted) setState(() => _cameraPermissionGranted = false);
    }
  }

  Future<void> _setupCamera({int? cameraIndex}) async {
    if (widget.cameras.isEmpty) return;

    if (cameraIndex != null) {
      _selectedCameraIndex = cameraIndex;
    } else {
      // Seleciona preferencialmente a câmera frontal para acessibilidade
      final frontIdx = widget.cameras.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
      );
      _selectedCameraIndex = frontIdx >= 0 ? frontIdx : 0;
    }

    if (_cameraController != null) {
      try {
        await _cameraController!.stopImageStream();
      } catch (_) {}
      await _cameraController!.dispose();
      _cameraController = null;
    }

    _cameraController = CameraController(
      widget.cameras[_selectedCameraIndex],
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.yuv420
          : ImageFormatGroup.bgra8888,
    );

    try {
      await _cameraController!.initialize();
      if (!mounted) return;
      _cameraController!.startImageStream((CameraImage image) async {
        if (_isProcessing) return;
        _isProcessing = true;

        try {
          await _processFrame(image);
        } catch (e) {
          debugPrint('[AI] Erro no processamento de IA: $e');
        } finally {
          _isProcessing = false;
        }
      });
      setState(() {});
    } catch (e) {
      debugPrint('Erro ao inicializar câmera: $e');
    }
  }

  /// Alterna dinamicamente entre câmera frontal e traseira
  Future<void> _toggleCamera() async {
    if (widget.cameras.length <= 1) return;
    final nextIdx = (_selectedCameraIndex + 1) % widget.cameras.length;
    await _setupCamera(cameraIndex: nextIdx);
  }

  // ===========================================================================
  // PROCESSAMENTO DO STREAM DE VÍDEO COM ML KIT (DESPACHANTE POR MODO)
  // ===========================================================================
  Future<void> _processFrame(CameraImage image) async {
    try {
      switch (widget.mode) {
        case ControlMode.facial:
          if (_faceDetector != null) {
            final inputImage = _buildInputImage(image);
            if (inputImage == null) return;
            final faces = await _faceDetector!.processImage(inputImage);
            _processFacialRules(faces);
          }
          break;

        case ControlMode.gestual:
          List<Hand> hands = [];
          if (_handLandmarker != null && image.planes.length >= 3) {
            try {
              final sensorOrientation = _cameraController?.description.sensorOrientation ?? 0;
              // Executa detecção em GPU/C++ nativo diretamente no CameraImage (Zero-copy, latência mínima)
              hands = _handLandmarker!.detect(image, sensorOrientation);
            } catch (err) {
              debugPrint('[HandLandmarker] Erro: $err');
            }
          }

          _processMediaPipeGestualRules(hands);
          break;

        case ControlMode.corporal:
          if (_poseDetector != null) {
            final inputImage = _buildInputImage(image);
            if (inputImage == null) return;
            final poses = await _poseDetector!.processImage(inputImage);
            _processCorporalRules(poses);
          }
          break;

        case ControlMode.fps:
          List<Hand> hands = [];
          if (_handLandmarker != null && image.planes.length >= 3) {
            try {
              final sensorOrientation = _cameraController?.description.sensorOrientation ?? 0;
              hands = _handLandmarker!.detect(image, sensorOrientation);
            } catch (err) {
              debugPrint('[HandLandmarker] Erro FPS: $err');
            }
          }
          _processFpsRules(hands);
          break;

        case ControlMode.fight:
          if (_poseDetector != null) {
            final inputImage = _buildInputImage(image);
            if (inputImage == null) return;
            final poses = await _poseDetector!.processImage(inputImage);
            _processFightRules(poses);
          }
          break;

        case ControlMode.fpsMesh:
          if (_faceDetector != null) {
            final inputImage = _buildInputImage(image);
            if (inputImage == null) return;
            final faces = await _faceDetector!.processImage(inputImage);
            _processFpsMeshRules(faces);
          }
          break;
      }
    } catch (e) {
      debugPrint('[AI] Erro no pipeline: $e');
    }
  }

  // ===========================================================================
  // MODO 1: REGRAS FACIAIS (FaceDetector)
  // ===========================================================================
  void _processFacialRules(List<Face> faces) {
    bool cmdPular = false;
    bool cmdEsquerda = false;
    bool cmdDireita = false;
    bool cmdCima = false;
    bool cmdBaixo = false;

    double smile = 0.0;
    double headZ = 0.0;
    double headY = 0.0;
    double headX = 0.0;
    final bool hasFace = faces.isNotEmpty;

    if (hasFace) {
      final face = faces.first;
      smile = face.smilingProbability ?? 0.0;
      headZ = face.headEulerAngleZ ?? 0.0; // Inclinação lateral (roll)
      headY = face.headEulerAngleY ?? 0.0; // Giro da cabeça (yaw)
      headX = face.headEulerAngleX ?? 0.0; // Pitch (olhar cima/baixo)

      // 1. Sorrir ativa "pular" (limiar acessível de 45%)
      if (smile > 0.45) {
        cmdPular = true;
      }

      // 2. Inclinar cabeça p/ Direita ou virar rosto p/ Direita (Perspectiva da Câmera Frontal)
      if (headZ > 8.0 || headY < -12.0) {
        cmdDireita = true;
      }
      // 3. Inclinar cabeça p/ Esquerda ou virar rosto p/ Esquerda
      else if (headZ < -8.0 || headY > 12.0) {
        cmdEsquerda = true;
      }

      // 4. Olhar para cima / Olhar para baixo
      if (headX > 15.0) {
        cmdCima = true;
      } else if (headX < -15.0) {
        cmdBaixo = true;
      }
    }

    _dispatchPayload(
      hasDetection: hasFace,
      pular: cmdPular,
      esquerda: cmdEsquerda,
      direita: cmdDireita,
      cima: cmdCima,
      baixo: cmdBaixo,
      extraUpdate: () {
        _smileProb = smile;
        _headAngleZ = headZ;
        _headAngleY = headY;
        _headAngleX = headX;
      },
    );
  }

  // ===========================================================================
  // MODO 2: GOOGLE MEDIAPIPE HANDS (21 Landmarks - Volante e Abertura dos Dedos)
  // ===========================================================================
  /// Converte coordenadas de marcos MediaPipe (no espaço do sensor) para
  /// o espaço de coordenadas normalizado da tela do celular (Portrait [0.0, 1.0]).
  Offset _mapLandmarkToScreen(Landmark lm, int sensorOrientation, bool isFrontCamera) {
    double sx;
    double sy;
    if (sensorOrientation == 270) {
      // Sensor montado a 270° (padrão frontal Samsung/Android em retrato):
      sx = isFrontCamera ? (1.0 - lm.y) : lm.y;
      sy = 1.0 - lm.x;
    } else if (sensorOrientation == 90) {
      // Sensor montado a 90° (típico de câmera traseira):
      sx = isFrontCamera ? lm.y : (1.0 - lm.y);
      sy = lm.x;
    } else {
      // 0° ou 180°
      sx = isFrontCamera ? (1.0 - lm.x) : lm.x;
      sy = lm.y;
    }
    return Offset(sx.clamp(0.0, 1.0), sy.clamp(0.0, 1.0));
  }

  /// Avalia com rigor anatômico e geométrico se o polegar está REALMENTE levantado (👍)
  /// ou se está apenas capturado pela câmera / abaixado / em repouso no punho / volante.
  /// Retorna 0.0 imediatamente caso o polegar esteja abaixado, em repouso, fechado, escondido ou com a mão aberta.
  /// Retorna > 0.48 somente se for um "thumbs up" inequívoco.
  double _evaluateThumbUpScore({
    required List<Landmark> lm,
    required int sensorOrientation,
    required bool isFrontCamera,
    required int numOpen,
  }) {
    if (lm.length < 21) return 0.0;

    // REGRA 1: Os outros 4 dedos (indicador, médio, anelar, mínimo) DEVEM estar fechados em punho.
    // Em um "joia" (👍), a mão está fechada em punho. Mão aberta ou espalmada NUNCA é dedão levantado!
    if (numOpen >= 2) {
      return 0.0;
    }

    double dist3D(Landmark a, Landmark b) {
      return sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2) + pow(a.z - b.z, 2));
    }

    final double palmLen3D = max(dist3D(lm[0], lm[9]), 1e-4);

    // Converte marcos anatômicos-chave para a tela em coordenadas normalizadas [0.0, 1.0] (Portrait)
    // 0 = Pulso
    // 2 = MCP Polegar (base), 3 = IP Polegar (junta intermediária), 4 = Ponta Polegar
    // 5 = MCP Indicador (nó da base), 6 = PIP Indicador (nó superior do punho fechado)
    // 9 = MCP Médio (nó da base), 10 = PIP Médio (nó superior do punho fechado)
    final p0 = _mapLandmarkToScreen(lm[0], sensorOrientation, isFrontCamera);
    final p2 = _mapLandmarkToScreen(lm[2], sensorOrientation, isFrontCamera);
    final p3 = _mapLandmarkToScreen(lm[3], sensorOrientation, isFrontCamera);
    final p4 = _mapLandmarkToScreen(lm[4], sensorOrientation, isFrontCamera);
    final p5 = _mapLandmarkToScreen(lm[5], sensorOrientation, isFrontCamera);
    final p6 = _mapLandmarkToScreen(lm[6], sensorOrientation, isFrontCamera);
    final p9 = _mapLandmarkToScreen(lm[9], sensorOrientation, isFrontCamera);
    final p10 = _mapLandmarkToScreen(lm[10], sensorOrientation, isFrontCamera);

    final double palmLen2D = max((p9 - p0).distance, 1e-4);

    // Vetor longitudinal da mão (do pulso até os nós dos dedos)
    final Offset knuckleCenter = Offset((p5.dx + p9.dx) / 2.0, (p5.dy + p9.dy) / 2.0);
    final Offset handVec = knuckleCenter - p0;
    final double handLen = max(handVec.distance, 1e-4);
    final Offset handUp = Offset(handVec.dx / handLen, handVec.dy / handLen);

    // REGRA 2: Crista superior do punho fechado (Articulações PIP 6 e 10).
    // Quando a mão está fechada em punho, p6 (PIP indicador) e p10 (PIP médio) são o topo físico da mão.
    // Quando o dedão está ABAIXADO ou em repouso no volante:
    // A ponta p4 fica nivelada ou abaixo de p6/p10.
    // Quando o dedão está LEVANTADO (👍):
    // A ponta p4 projeta-se nitidamente ACIMA de p6 e p10 ao longo de handUp!
    final Offset fistTop = Offset((p6.dx + p10.dx) / 2.0, (p6.dy + p10.dy) / 2.0);
    final double tipAboveFist = ((p4 - fistTop).dx * handUp.dx + (p4 - fistTop).dy * handUp.dy) / palmLen2D;
    final double tipAboveIndexPip = ((p4 - p6).dx * handUp.dx + (p4 - p6).dy * handUp.dy) / palmLen2D;

    if (tipAboveFist < 0.15 || tipAboveIndexPip < 0.12) {
      // VETO ABSOLUTO: O dedão não ultrapassa a crista do punho fechado (está abaixado / em repouso)
      return 0.0;
    }

    // REGRA 3: Direção vertical na tela (No Flutter/Android, dy < 0 é para CIMA).
    // Para o dedão estar levantado, a ponta (p4) deve estar acima da base (p2) e da junta média (p3).
    // Se o dedão estiver apontando para baixo ou horizontal, a diferença é negativa ou nula.
    final double tipAboveMcpScreen = (p2.dy - p4.dy) / palmLen2D;
    final double tipAboveIpScreen = (p3.dy - p4.dy) / palmLen2D;

    if (tipAboveMcpScreen < 0.25 || tipAboveIpScreen < 0.07) {
      // VETO ABSOLUTO: Dedão apontando para baixo ou para os lados (abaixado)
      return 0.0;
    }

    // REGRA 4: Alinhamento das falanges do polegar com o eixo longitudinal da mão (handUp)
    final Offset thumbVec = p4 - p2;
    final Offset distalVec = p4 - p3;
    final double thumbAlongHand = (thumbVec.dx * handUp.dx + thumbVec.dy * handUp.dy) / palmLen2D;
    final double distalAlongHand = (distalVec.dx * handUp.dx + distalVec.dy * handUp.dy) / palmLen2D;

    if (thumbAlongHand < 0.40 || distalAlongHand < 0.11) {
      // VETO ABSOLUTO: Falange distal não está apontando para cima
      return 0.0;
    }

    // A falange distal não pode apontar para baixo no espaço de tela
    if (distalVec.dy >= -0.015) {
      return 0.0;
    }

    // REGRA 5: Retidão anatômica do polegar (MCP -> IP -> TIP).
    // Dedão levantado fica esticado (straightness > 0.88).
    // Dedão dobrado ou recolhido sobre os dedos fica curvado (< 0.80).
    final double d23_3D = dist3D(lm[2], lm[3]);
    final double d34_3D = dist3D(lm[3], lm[4]);
    final double d24_3D = dist3D(lm[2], lm[4]);
    final double thumbStraightness = d24_3D / max(d23_3D + d34_3D, 1e-4);

    if (thumbStraightness < 0.87) {
      // VETO ABSOLUTO: Dedão dobrado ou curvado
      return 0.0;
    }

    // REGRA 6: Afastamento tridimensional em relação ao dedo indicador (PIP e MCP).
    // Quando o dedão está abaixado / em repouso, ele toca o indicador.
    // Quando está levantado (👍), ele afasta-se da lateral dos dedos (abdução ativa).
    final double dTipIndexPip3D = dist3D(lm[4], lm[6]) / palmLen3D;
    final double dTipIndexMcp3D = dist3D(lm[4], lm[5]) / palmLen3D;

    if (dTipIndexPip3D < 0.32 || dTipIndexMcp3D < 0.36) {
      // VETO ABSOLUTO: Dedão colado ou encostado no indicador (repouso)
      return 0.0;
    }

    // REGRA 7: Profundidade Z (Oclusão quando escondido atrás da mão)
    if ((lm[4].z - lm[5].z) > 0.035) {
      // VETO ABSOLUTO: Dedão escondido atrás dos dedos
      return 0.0;
    }

    // Passou por todos os 7 vetos rigorosos: O dedão está REALMENTE levantado em 👍!
    // Pontuação progressiva calibrada entre 0.50 e 1.0 (sempre acima de _thumbOnThreshold de 0.48)
    final double fFist = ((tipAboveFist - 0.15) / 0.22).clamp(0.0, 1.0);
    final double fScreen = ((tipAboveMcpScreen - 0.25) / 0.25).clamp(0.0, 1.0);
    final double fDistal = ((distalAlongHand - 0.11) / 0.15).clamp(0.0, 1.0);
    final double fClear = ((dTipIndexPip3D - 0.32) / 0.18).clamp(0.0, 1.0);

    return (0.50 + fFist * 0.20 + fScreen * 0.15 + fDistal * 0.10 + fClear * 0.05).clamp(0.0, 1.0);
  }

  void _processMediaPipeGestualRules(List<Hand> hands) {
    bool cmdPular = false;
    bool cmdEsquerda = false;
    bool cmdDireita = false;
    bool cmdCima = false;
    bool cmdBaixo = false;

    double wheelAngleDeg = 0.0;
    double effectiveAngle = 0.0;
    bool rightOpen = false;
    bool leftOpen = false;
    final bool hasValidDetection = hands.isNotEmpty;

    if (hands.isNotEmpty) {
      final List<Map<String, dynamic>> handsData = [];
      final sensorOrientation = _cameraController?.description.sensorOrientation ?? 270;
      final isFrontCamera = _cameraController?.description.lensDirection == CameraLensDirection.front;

      for (final hand in hands) {
        if (hand.landmarks.length < 21) continue;
        final lm = hand.landmarks;
        final wrist = lm[0];

        double dist3D(Landmark a, Landmark b) {
          return sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2) + pow(a.z - b.z, 2));
        }

        // Métrica Geométrica de Retidão (Straightness) invariante à rotação do punho/volante:
        const fingerIndices = [
          [5, 6, 7, 8],     // Indicador: MCP, PIP, DIP, TIP
          [9, 10, 11, 12],  // Médio: MCP, PIP, DIP, TIP
          [13, 14, 15, 16], // Anelar: MCP, PIP, DIP, TIP
          [17, 18, 19, 20], // Mindinho: MCP, PIP, DIP, TIP
        ];

        int numOpen = 0;
        for (final f in fingerIndices) {
          final mcp = lm[f[0]];
          final pip = lm[f[1]];
          final dip = lm[f[2]];
          final tip = lm[f[3]];

          final dTipMcp = dist3D(tip, mcp);
          final boneLen = dist3D(mcp, pip) + dist3D(pip, dip) + dist3D(dip, tip);
          final straightness = dTipMcp / max(boneLen, 1e-4);

          // Critério robusto: retidão elevada E ponta mais distante do pulso que a articulação intermédia (PIP)
          if (straightness > 0.72 && dist3D(tip, wrist) > dist3D(pip, wrist)) {
            numOpen++;
          }
        }

        final bool isOpen = numOpen >= 3;
        final double ratio = numOpen / 4.0;

        // Avaliação rigorosa: Diferenciação absoluta entre "ver o dedão" e "dedão levantado"
        final double handThumbScore = _evaluateThumbUpScore(
          lm: lm,
          sensorOrientation: sensorOrientation,
          isFrontCamera: isFrontCamera,
          numOpen: numOpen,
        );

        final p0 = _mapLandmarkToScreen(lm[0], sensorOrientation, isFrontCamera);
        final p5 = _mapLandmarkToScreen(lm[5], sensorOrientation, isFrontCamera);
        final p9 = _mapLandmarkToScreen(lm[9], sensorOrientation, isFrontCamera);
        final p17 = _mapLandmarkToScreen(lm[17], sensorOrientation, isFrontCamera);

        // Centro da mão na tela (média entre o pulso e nós dos dedos): estável durante o fechamento dos punhos
        final double screenCenterX = (p0.dx + p5.dx + p9.dx + p17.dx) / 4.0;
        final double screenCenterY = (p0.dy + p5.dy + p9.dy + p17.dy) / 4.0;

        handsData.add({
          'wrist': p0,
          'centerX': screenCenterX,
          'centerY': screenCenterY,
          'isOpen': isOpen,
          'ratio': ratio,
          'numOpen': numOpen,
          'thumbScore': handThumbScore,
        });
      }

      // Ordena pelo eixo X da tela visível (da esquerda para a direita na tela)
      handsData.sort((a, b) => (a['centerX'] as double).compareTo(b['centerX'] as double));

      if (handsData.length >= 2) {
        _consecutiveMissingHandFrames = 0;
        // handsData[0] = Mão no lado esquerdo da tela (Menor X)
        // handsData[1] = Mão no lado direito da tela (Maior X)
        final leftHandScreen = handsData[0];
        final rightHandScreen = handsData[1];

        // Mão esquerda e direita do usuário na visualização espelhada da câmera frontal
        final userLeft = isFrontCamera ? leftHandScreen : rightHandScreen;
        final userRight = isFrontCamera ? rightHandScreen : leftHandScreen;

        leftOpen = userLeft['isOpen'] as bool;
        rightOpen = userRight['isOpen'] as bool;

        final double currentLeftScore = userLeft['thumbScore'] as double;
        final double currentRightScore = userRight['thumbScore'] as double;

        // Atualização de estado: Resposta imediata com corte garantido quando abaixado/recolhido
        if (currentRightScore >= _thumbOnThreshold) {
          _rightThumbDropFrames = 0;
          _rightThumbScore = _rightThumbScore * 0.40 + currentRightScore * 0.60;
          _isRightThumbUp = true;
        } else if (currentRightScore < _thumbOffThreshold || currentRightScore == 0.0) {
          _rightThumbDropFrames++;
          _rightThumbScore = 0.0;
          _isRightThumbUp = false;
        } else {
          // Zona intermediária entre On e Off: desliga após 2 frames de estabilização
          _rightThumbDropFrames++;
          if (_rightThumbDropFrames >= 2) {
            _rightThumbScore = 0.0;
            _isRightThumbUp = false;
          }
        }

        if (currentLeftScore >= _thumbOnThreshold) {
          _leftThumbDropFrames = 0;
          _leftThumbScore = _leftThumbScore * 0.40 + currentLeftScore * 0.60;
          _isLeftThumbUp = true;
        } else if (currentLeftScore < _thumbOffThreshold || currentLeftScore == 0.0) {
          _leftThumbDropFrames++;
          _leftThumbScore = 0.0;
          _isLeftThumbUp = false;
        } else {
          _leftThumbDropFrames++;
          if (_leftThumbDropFrames >= 2) {
            _leftThumbScore = 0.0;
            _isLeftThumbUp = false;
          }
        }

        final double lY = leftHandScreen['centerY'] as double;
        final double rY = rightHandScreen['centerY'] as double;
        final double lX = leftHandScreen['centerX'] as double;
        final double rX = rightHandScreen['centerX'] as double;

        // O eixo Y da tela cresce para BAIXO:
        // dy = rY - lY
        // Se mão direita da tela baixar (rY > lY): dy > 0 (giro horário -> DIREITA)
        // Se mão esquerda da tela baixar (lY > rY): dy < 0 (giro anti-horário -> ESQUERDA)
        final double dy = rY - lY;
        final double dx = max(rX - lX, 0.05);

        // Correção suave de aspecto vertical (1.20 evita hiper-sensibilidade de inclinação)
        final double rawAngle = atan2(dy * 1.20, dx) * (180.0 / pi);

        // Filtro responsivo inteligente (Adaptive Alpha EMA):
        // Se há movimento dinâmico (delta > 3°), responde instantaneamente com 85% do novo valor
        // Se mãos estão paradas, suaviza micro-tremores com 60%
        final double angleDelta = (rawAngle - _smoothedWheelAngle).abs();
        final double alpha = angleDelta > 3.0 ? 0.85 : 0.60;
        _smoothedWheelAngle = _smoothedWheelAngle * (1.0 - alpha) + rawAngle * alpha;
        wheelAngleDeg = _smoothedWheelAngle;

        // Freio somente se ambas as mãos forem intencionalmente juntadas no centro do peito (< 12% da tela)
        if (dx < 0.12) {
          cmdBaixo = true;
        }
      } else {
        // Tolerância de até 3 frames (~100ms) para quedas momentâneas de tracking
        _consecutiveMissingHandFrames++;
        if (_consecutiveMissingHandFrames <= 3) {
          // Sustenta o último ângulo e estado durante micro-quedas de detecção
          wheelAngleDeg = _smoothedWheelAngle;
          if (handsData.length == 1) {
            final singleHand = handsData[0];
            final bool isRightHand = (singleHand['centerX'] as double) >= 0.5;
            final double singleScore = singleHand['thumbScore'] as double;
            if (isRightHand) {
              rightOpen = singleHand['isOpen'] as bool;
              if (singleScore >= _thumbOnThreshold) {
                _rightThumbDropFrames = 0;
                _rightThumbScore = _rightThumbScore * 0.40 + singleScore * 0.60;
                _isRightThumbUp = true;
              } else {
                _rightThumbDropFrames++;
                _isRightThumbUp = false;
                _rightThumbScore = 0.0;
              }
              _leftThumbDropFrames = 0;
              _leftThumbScore = 0.0;
              _isLeftThumbUp = false;
            } else {
              leftOpen = singleHand['isOpen'] as bool;
              if (singleScore >= _thumbOnThreshold) {
                _leftThumbDropFrames = 0;
                _leftThumbScore = _leftThumbScore * 0.40 + singleScore * 0.60;
                _isLeftThumbUp = true;
              } else {
                _leftThumbDropFrames++;
                _isLeftThumbUp = false;
                _leftThumbScore = 0.0;
              }
              _rightThumbDropFrames = 0;
              _rightThumbScore = 0.0;
              _isRightThumbUp = false;
            }
          }
        } else {
          // Mais de 3 frames sem 2 mãos: retorna suavemente para neutro
          _smoothedWheelAngle = _smoothedWheelAngle * 0.4;
          if (_smoothedWheelAngle.abs() < 1.0) _smoothedWheelAngle = 0.0;
          wheelAngleDeg = _smoothedWheelAngle;
          _isRightThumbUp = false;
          _isLeftThumbUp = false;
          _rightThumbScore = 0.0;
          _leftThumbScore = 0.0;
          _rightThumbDropFrames = 0;
          _leftThumbDropFrames = 0;
        }
      }

      // CENTRALIZAÇÃO TEMPORAL (TEMPO 0.3s / SEM ZONA MORTA RÍGIDA)
      // Mantenha a linha central como guia, mas ao invés de usar zona morta angular,
      // usamos um timer: se a mão permanecer dentro da faixa central por 0.3s (300ms),
      // a entrada de 'direita/esquerda' é substituída por 'CENTRO'.
      final int nowMs = DateTime.now().millisecondsSinceEpoch;
      final double rawEffective = !_invertSteering ? wheelAngleDeg : -wheelAngleDeg;
      const double centerGuideTolerance = 2.5; // Faixa de tolerância da linha central guia
      const int centerDwellThresholdMs = 300; // 0.3s conforme solicitado

      if (rawEffective.abs() <= centerGuideTolerance) {
        // Mãos dentro da faixa da linha central guia
        if (_wheelCenterDwellStartTime == 0) {
          _wheelCenterDwellStartTime = nowMs;
        }

        final int elapsedInCenter = nowMs - _wheelCenterDwellStartTime;

        if (elapsedInCenter >= centerDwellThresholdMs) {
          // Após 0.3s na linha central: a entrada é substituída por 'CENTRO'!
          cmdDireita = false;
          cmdEsquerda = false;
          _lastSteerDirection = 'centro';
          effectiveAngle = 0.0;
        } else {
          // Janela de transição (< 0.3s): mantém a direção de curva sem travamento abrupto
          if (_lastSteerDirection == 'direita') {
            cmdDireita = true;
            cmdEsquerda = false;
            effectiveAngle = rawEffective;
          } else if (_lastSteerDirection == 'esquerda') {
            cmdEsquerda = true;
            cmdDireita = false;
            effectiveAngle = rawEffective;
          } else {
            cmdDireita = false;
            cmdEsquerda = false;
            effectiveAngle = 0.0;
          }
        }
      } else {
        // Mãos fora da faixa central: resposta imediata 1:1 sem zona morta
        _wheelCenterDwellStartTime = 0;

        if (rawEffective > 0) {
          cmdDireita = true;
          cmdEsquerda = false;
          _lastSteerDirection = 'direita';
          effectiveAngle = rawEffective;
        } else {
          cmdEsquerda = true;
          cmdDireita = false;
          _lastSteerDirection = 'esquerda';
          effectiveAngle = rawEffective;
        }
      }

      // 1. Polegar Direito = Acelerador (W ou UP / RT)
      // 2. Polegar Esquerdo = Freio / Ré (S ou Down / LT)
      // Garante exclusão mútua e NUNCA aciona cmdPular (que ativa freio de mão/Space no PC)
      if (_isRightThumbUp && !_isLeftThumbUp) {
        cmdCima = true;
        cmdBaixo = false;
        cmdPular = false;
      } else if (_isLeftThumbUp && !_isRightThumbUp) {
        cmdBaixo = true;
        cmdCima = false;
        cmdPular = false;
      } else if (_isRightThumbUp && _isLeftThumbUp) {
        // Se ambos levantados, prioriza aceleração sem travar
        cmdCima = true;
        cmdBaixo = false;
        cmdPular = false;
      } else {
        cmdCima = false;
        cmdBaixo = false;
        cmdPular = false;
      }
    } else {
      // Quando hands.isEmpty (nenhuma mão detectada no frame)
      _consecutiveMissingHandFrames++;
      if (_consecutiveMissingHandFrames <= 3) {
        wheelAngleDeg = _smoothedWheelAngle;
        effectiveAngle = !_invertSteering ? wheelAngleDeg : -wheelAngleDeg;
        cmdDireita = _lastSteerDirection == 'direita';
        cmdEsquerda = _lastSteerDirection == 'esquerda';
        cmdPular = false;
        cmdCima = _isRightThumbUp && !_isLeftThumbUp;
        cmdBaixo = _isLeftThumbUp && !_isRightThumbUp;
      } else {
        _smoothedWheelAngle = 0.0;
        wheelAngleDeg = 0.0;
        effectiveAngle = 0.0;
        _wheelCenterDwellStartTime = 0;
        _lastSteerDirection = 'centro';
        _isRightThumbUp = false;
        _isLeftThumbUp = false;
        _rightThumbScore = 0.0;
        _leftThumbScore = 0.0;
      }
    }

    _dispatchPayload(
      hasDetection: hasValidDetection,
      pular: cmdPular,
      esquerda: cmdEsquerda,
      direita: cmdDireita,
      cima: cmdCima,
      baixo: cmdBaixo,
      extraUpdate: () {
        _wheelAngle = effectiveAngle;
        _isRightHandOpen = rightOpen;
        _isLeftHandOpen = leftOpen;
        _detectedHands = hands;
      },
    );
  }



  // ===========================================================================
  // MODO 3: REGRAS CORPORAIS / CORPO INTEIRO (PoseDetector - Torso e Pernas)
  // ===========================================================================
  void _processCorporalRules(List<Pose> poses) {
    bool cmdPular = false;
    bool cmdEsquerda = false;
    bool cmdDireita = false;
    bool cmdCima = false;
    bool cmdBaixo = false;

    double sTilt = 0.0;
    double currentHipY = 0.0;
    double legDist = 0.0;
    final bool hasPose = poses.isNotEmpty;

    if (hasPose) {
      final pose = poses.first;
      final rs = pose.landmarks[PoseLandmarkType.rightShoulder];
      final ls = pose.landmarks[PoseLandmarkType.leftShoulder];
      final rh = pose.landmarks[PoseLandmarkType.rightHip];
      final lh = pose.landmarks[PoseLandmarkType.leftHip];
      final rk = pose.landmarks[PoseLandmarkType.rightKnee];
      final lk = pose.landmarks[PoseLandmarkType.leftKnee];

      double shoulderWidth = 100.0;
      if (rs != null && ls != null) {
        shoulderWidth = (rs.x - ls.x).abs();
        if (shoulderWidth < 20.0) shoulderWidth = 100.0;
      }

      // 1. Pulo Físico: Média Y dos quadris subindo rapidamente (delta negativo)
      if (rh != null && lh != null) {
        currentHipY = (rh.y + lh.y) / 2.0;

        if (_baselineHipY == 0.0) {
          _baselineHipY = currentHipY;
          _prevHipY = currentHipY;
        } else {
          _hipYDelta = currentHipY - _prevHipY;
          // Se o quadril subiu bruscamente (movimento ascendente rápido na tela)
          if (_hipYDelta < -12.0 || currentHipY < _baselineHipY - 22.0) {
            cmdPular = true;
          }
          // Adapta a linha de base suavemente
          _baselineHipY = _baselineHipY * 0.95 + currentHipY * 0.05;
          _prevHipY = currentHipY;
        }
      }

      // 2. Inclinação do Tronco (Ombro caindo)
      if (rs != null && ls != null) {
        sTilt = rs.y - ls.y;
        final double tiltTolerance = (shoulderWidth * 0.16).clamp(10.0, 30.0);

        // Ombro direito cai (Y maior) -> Direita
        if (sTilt > tiltTolerance) {
          cmdDireita = true;
        }
        // Ombro esquerdo cai (Y maior no esquerdo) -> Esquerda
        else if (sTilt < -tiltTolerance) {
          cmdEsquerda = true;
        }
      }

      // 3. Agachamento (Distância Y entre quadril e joelho diminui)
      if (rh != null && rk != null && lh != null && lk != null) {
        legDist = ((rk.y - rh.y) + (lk.y - lh.y)) / 2.0;

        if (_baselineLegDistance == 0.0) {
          _baselineLegDistance = legDist;
        } else {
          // Se a distância encurtou mais de 25% em relação à postura em pé
          if (legDist < _baselineLegDistance * 0.75) {
            cmdBaixo = true;
          }
          _baselineLegDistance = _baselineLegDistance * 0.98 + legDist * 0.02;
        }
      } else if (currentHipY != 0.0 && _baselineHipY != 0.0) {
        // Fallback: se os joelhos estiverem fora do enquadramento, agachar abaixa o quadril
        if (currentHipY > _baselineHipY + 28.0) {
          cmdBaixo = true;
        }
      }
    }

    _dispatchPayload(
      hasDetection: hasPose,
      pular: cmdPular,
      esquerda: cmdEsquerda,
      direita: cmdDireita,
      cima: cmdCima,
      baixo: cmdBaixo,
      extraUpdate: () {
        _shoulderTilt = sTilt;
        _legDistance = legDist;
      },
    );
  }

  // ===========================================================================
  // MODO 4: REGRAS FPS TÁTICO (Arma Virtual / Counter Strike 1.6)
  // ===========================================================================
  void _processFpsRules(List<Hand> hands) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final sensorOrientation = _cameraController?.description.sensorOrientation ?? 270;
    final isFrontCamera = _cameraController?.description.lensDirection == CameraLensDirection.front;

    if (hands.isEmpty) {
      _fpsLastIndexPos = null;
      _fpsFilteredDx = 0.0;
      _fpsFilteredDy = 0.0;
      _fpsSubpixelX = 0.0;
      _fpsSubpixelY = 0.0;
      _fpsIsGunActive = false;
      _fpsIsFiring = false;
      _fpsIsZoom = false;
      _fpsIsReloading = false;
      _fpsTwoHandsLocked = false;
      _fpsLockedGripFrames = 0;
      _fpsMiddleWasOpen = false;
      _fpsZoomOnFrames = 0;
      _fpsZoomOffFrames = 0;
      _detectedHands = [];

      final payload = {
        "modo": "fps",
        "mouse_dx": 0,
        "mouse_dy": 0,
        "disparo": false,
        "zoom": false,
        "recarregar": false,
        "empunhadura_dupla": false,
        "arma_ativa": false,
        "detect": false,
        "sensibilidade": _fpsSensitivityLabel,
      };
      UdpService.instance.sendPayload(payload);
      if (mounted) {
        setState(() {
          _hasDetection = false;
          _currentPayload = payload;
        });
      }
      return;
    }

    _detectedHands = hands;

    // Helper de distância euclidiana tridimensional invariante à câmera
    double dist3D(Landmark a, Landmark b) {
      return sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2) + pow(a.z - b.z, 2));
    }

    // 1. Identificação da Mão da Arma (Gun Hand) e Mão de Apoio na Base (Support Hand)
    Hand? gunHand;
    Hand? supportHand;
    int gunHandIndex = -1;
    double bestGunScore = -1.0;

    for (int i = 0; i < hands.length; i++) {
      final hand = hands[i];
      if (hand.landmarks.length < 21) continue;
      final lm = hand.landmarks;

      final wrist = lm[0];
      final iTip = lm[8], iPip = lm[6], iMcp = lm[5];
      final rTip = lm[16], rMcp = lm[13];
      final pTip = lm[20], pMcp = lm[17];

      final palmLen = max(dist3D(wrist, lm[9]), 1e-4);

      // Indicador esticado para a frente (Cano da Arma)
      final dTipWrist = dist3D(iTip, wrist);
      final dPipWrist = dist3D(iPip, wrist);
      final dTipMcp = dist3D(iTip, iMcp);
      final boneLen = dist3D(iMcp, iPip) + dist3D(iPip, lm[7]) + dist3D(lm[7], iTip);
      final double straightness = dTipMcp / max(boneLen, 1e-4);

      final bool indexExtended = (dTipWrist > dPipWrist * 1.10) && (straightness > 0.60);

      // Dedos anelar e mindinho recolhidos na empunhadura (Grip)
      int gripCurled = 0;
      if (dist3D(rTip, wrist) < dist3D(lm[14], wrist) * 1.30 || dist3D(rTip, rMcp) < palmLen * 0.85) gripCurled++;
      if (dist3D(pTip, wrist) < dist3D(lm[18], wrist) * 1.30 || dist3D(pTip, pMcp) < palmLen * 0.85) gripCurled++;

      // O dedo médio atua como gatilho dinâmico (aberto ou fechado),
      // logo a arma é validada pelo indicador esticado + dedos recolhidos na base
      double gunScore = (indexExtended ? 3.0 : 0.0) + (gripCurled * 1.0);
      if (gunScore > bestGunScore) {
        bestGunScore = gunScore;
        gunHand = hand;
        gunHandIndex = i;
      }
    }

    if (gunHand == null) {
      gunHand = hands.first;
      gunHandIndex = 0;
    }

    _fpsIsGunActive = bestGunScore >= 2.5;

    if (hands.length > 1) {
      final otherIdx = gunHandIndex == 0 ? 1 : 0;
      if (otherIdx < hands.length && hands[otherIdx].landmarks.length >= 21) {
        supportHand = hands[otherIdx];
      }
    }

    final gLm = gunHand.landmarks;
    final pWrist = _mapLandmarkToScreen(gLm[0], sensorOrientation, isFrontCamera);
    final pThumbTip = _mapLandmarkToScreen(gLm[4], sensorOrientation, isFrontCamera);
    final pThumbIp = _mapLandmarkToScreen(gLm[3], sensorOrientation, isFrontCamera);
    final pThumbMcp = _mapLandmarkToScreen(gLm[2], sensorOrientation, isFrontCamera);
    final pIndexMcp = _mapLandmarkToScreen(gLm[5], sensorOrientation, isFrontCamera);
    final pIndexTip = _mapLandmarkToScreen(gLm[8], sensorOrientation, isFrontCamera);

    // 2. Mover o Dedo Indicador -> Move a Câmera / Mira do Mouse
    final currentAim = pIndexTip;

    // Suavização visual da mira na tela (elimina tremores do retículo na HUD)
    _fpsCrosshairPos = Offset(
      _fpsCrosshairPos.dx * 0.35 + currentAim.dx * 0.65,
      _fpsCrosshairPos.dy * 0.35 + currentAim.dy * 0.65,
    );

    double moveX = 0.0;
    double moveY = 0.0;

    if (_fpsLastIndexPos == null || !_fpsIsGunActive) {
      // Primeira detecção ou arma não engajada: ancora a mira sem disparar salto
      _fpsLastIndexPos = currentAim;
      _fpsFilteredDx = 0.0;
      _fpsFilteredDy = 0.0;
      _fpsSubpixelX = 0.0;
      _fpsSubpixelY = 0.0;
    } else {
      final double deltaX = currentAim.dx - _fpsLastIndexPos!.dx;
      final double deltaY = currentAim.dy - _fpsLastIndexPos!.dy;
      final double dist = sqrt(deltaX * deltaX + deltaY * deltaY);

      // Proteção antiflick e antiteleporte:
      // Se a mão saltar mais de 12% da tela em 1 único frame (troca de mão ou ruído de tracking),
      // reancora a posição imediatamente sem enviar movimento falso para o jogo.
      if (dist > 0.12) {
        _fpsLastIndexPos = currentAim;
        _fpsFilteredDx = 0.0;
        _fpsFilteredDy = 0.0;
      } else {
        _fpsLastIndexPos = currentAim;

        // Zona morta contínua para eliminar microtremores e ruído do sensor (0.0032)
        const double deadzone = 0.0032;
        if (dist > deadzone) {
          final double excess = dist - deadzone;
          final double ratio = excess / dist;
          final double rawStepX = deltaX * ratio;
          final double rawStepY = deltaY * ratio;

          // Filtro adaptativo (EMA): microajustes são filtrados para máxima estabilidade,
          // enquanto movimentações rápidas respondem de forma ágil e direta
          final double alpha = (dist > 0.015) ? 0.85 : 0.60;
          _fpsFilteredDx = _fpsFilteredDx * (1.0 - alpha) + rawStepX * alpha;
          _fpsFilteredDy = _fpsFilteredDy * (1.0 - alpha) + rawStepY * alpha;

          moveX = _fpsFilteredDx;
          moveY = _fpsFilteredDy;
        } else {
          // Quando o dedo para, zera o movimento imediatamente sem arrasto inercial
          _fpsFilteredDx = 0.0;
          _fpsFilteredDy = 0.0;
          moveX = 0.0;
          moveY = 0.0;
        }
      }
    }

    // 3. Gatilho de Disparo no Dedo do Meio (Movimento de fechar o dedo -> Mouse 1 / Tiro)
    final mTip = gLm[12], mDip = gLm[11], mPip = gLm[10], mMcp = gLm[9];
    final double palmLen3D = max(dist3D(gLm[0], mMcp), 1e-4);
    final double mTipMcpDist = dist3D(mTip, mMcp);
    final double mBoneLen = dist3D(mMcp, mPip) + dist3D(mPip, mDip) + dist3D(mDip, mTip);
    final double mStraightness = mTipMcpDist / max(mBoneLen, 1e-4);
    final double mTipMcpRatio = mTipMcpDist / palmLen3D;
    final double mTipWristDist = dist3D(mTip, gLm[0]);
    final double mPipWristDist = dist3D(mPip, gLm[0]);

    // O dedo médio está aberto/relaxado (pronto para atirar)
    final bool isMiddleOpen = mStraightness > 0.64 && mTipMcpRatio > 0.68 && mTipWristDist > mPipWristDist * 1.05;
    if (isMiddleOpen) {
      _fpsMiddleWasOpen = true;
      _fpsIsFiring = false;
    }

    // Movimento de fechar o dedo médio (Trigger Pull)
    final bool isMiddleClosed = (mStraightness < 0.52 || mTipMcpRatio < 0.58) || (mTipWristDist < mPipWristDist * 0.96);
    final double closingDelta = _fpsLastMiddleRatio - mTipMcpRatio;
    bool fireTriggered = false;

    if (_fpsMiddleWasOpen && (isMiddleClosed || closingDelta > 0.12)) {
      // Disparo acionado no momento em que o dedo do meio fecha!
      fireTriggered = true;
      _fpsIsFiring = true;
      _fpsRecoilSuppressionFrames = 2; // Estabiliza a mira para o disparo ser preciso
      HapticFeedback.heavyImpact();
    } else if (_fpsIsFiring && (mStraightness < 0.58 || mTipMcpRatio < 0.64)) {
      // Mantém o gatilho pressionado enquanto o dedo continuar fechado (rajada contínua no CS 1.6)
      _fpsIsFiring = true;
    } else {
      _fpsIsFiring = false;
    }
    _fpsLastMiddleRatio = mTipMcpRatio;

    if (_fpsRecoilSuppressionFrames > 0) {
      _fpsRecoilSuppressionFrames--;
      moveX = 0.0;
      moveY = 0.0;
    }

    if (_fpsInvertY) {
      moveY = -moveY;
    }

    // Escala de sensibilidade calibrada e clamp seguro contra flicks repentinos (máx 55px/frame)
    final double scale = _fpsSensitivityScale;
    final double targetDx = (moveX * scale).clamp(-55.0, 55.0);
    final double targetDy = (moveY * scale).clamp(-55.0, 55.0);

    // Acumulador sub-pixel para movimento suave, linear e sem perda de pequenos passos
    int mouseDx = 0;
    int mouseDy = 0;
    if (moveX != 0.0 || moveY != 0.0) {
      final double totalDx = targetDx + _fpsSubpixelX;
      final double totalDy = targetDy + _fpsSubpixelY;
      mouseDx = totalDx.truncate();
      mouseDy = totalDy.truncate();
      _fpsSubpixelX = totalDx - mouseDx;
      _fpsSubpixelY = totalDy - mouseDy;
    } else {
      _fpsSubpixelX = 0.0;
      _fpsSubpixelY = 0.0;
    }

    // 4. Zoom da Arma: Ativa SOMENTE quando o dedão aparece completamente de maneira frontal (digital)
    final p0Screen = _mapLandmarkToScreen(gLm[0], sensorOrientation, isFrontCamera);
    final p9Screen = _mapLandmarkToScreen(gLm[9], sensorOrientation, isFrontCamera);
    final double palmLen2D = max((p9Screen - p0Screen).distance, 1e-4);

    // Critério A: Dedão completamente esticado e visível (retidão e comprimento)
    final double d23 = dist3D(gLm[2], gLm[3]);
    final double d34 = dist3D(gLm[3], gLm[4]);
    final double d24 = dist3D(gLm[2], gLm[4]);
    final double thumbStraightness = d24 / max(d23 + d34, 1e-4);

    final double thumbLen2D = (pThumbTip - pThumbMcp).distance / palmLen2D;
    final double d23_2D = (pThumbIp - pThumbMcp).distance / palmLen2D;
    final double d34_2D = (pThumbTip - pThumbIp).distance / palmLen2D;
    final bool thumbFullyExtended = thumbStraightness >= 0.86 && thumbLen2D >= 0.36 && d23_2D >= 0.12 && d34_2D >= 0.12;

    // Critério B: Orientação Frontal da Digital voltada para a lente
    final double distTipIndex3D = dist3D(gLm[4], gLm[5]) / palmLen3D;
    final double distTipIndex2D = (pThumbTip - pIndexMcp).distance / palmLen2D;
    final bool thumbAbducted = distTipIndex3D >= 0.40 && distTipIndex2D >= 0.34;

    // Ponta do dedão levantada verticalmente em relação à base e junta IP
    final double tipAboveMcpScreen = (pThumbMcp.dy - pThumbTip.dy) / palmLen2D;
    final bool thumbElevated = tipAboveMcpScreen >= 0.18 && (pThumbTip.dy < pThumbIp.dy - 0.010);

    // Não ocluso / Não escondido atrás da mão (Z não negativo/afastado)
    final bool thumbNotOccluded = (gLm[4].z <= gLm[5].z + 0.035) && (gLm[4].z <= gLm[2].z + 0.035);

    // Área do plano frontal do polegar (digital virada de frente para o sensor)
    final double crossZ = ((gLm[2].x - gLm[5].x) * (gLm[4].y - gLm[2].y) - (gLm[2].y - gLm[5].y) * (gLm[4].x - gLm[2].x)).abs();
    final double frontalAreaRatio = crossZ / (palmLen3D * palmLen3D);
    final bool thumbFrontalFacing = frontalAreaRatio >= 0.09;

    final bool isFrontalThumbValid = thumbFullyExtended && thumbAbducted && thumbElevated && thumbNotOccluded && thumbFrontalFacing;

    // Estabilizador Anti-Bugs / Histerese (Exige confirmação de 2 quadros para evitar qualquer oscilação)
    if (isFrontalThumbValid) {
      _fpsZoomOnFrames++;
      _fpsZoomOffFrames = 0;
      if (_fpsZoomOnFrames >= 2 && !_fpsIsZoom) {
        _fpsIsZoom = true;
        HapticFeedback.selectionClick();
      }
    } else {
      _fpsZoomOffFrames++;
      _fpsZoomOnFrames = 0;
      if (_fpsZoomOffFrames >= 2 && _fpsIsZoom) {
        _fpsIsZoom = false;
        HapticFeedback.selectionClick();
      }
    }

    // 5. A Mão na Base ao Soltar a Outra Mão -> Recarregar (Tecla 'R' no CS 1.6)
    bool reloadTriggered = false;

    if (supportHand != null) {
      final sLm = supportHand.landmarks;
      final pSupportWrist = _mapLandmarkToScreen(sLm[0], sensorOrientation, isFrontCamera);
      final double wristDist = (pWrist - pSupportWrist).distance;

      // Mãos juntas na base (empunhadura tática travada)
      if (wristDist < 0.25) {
        _fpsLockedGripFrames++;
        if (_fpsLockedGripFrames >= 3) {
          _fpsTwoHandsLocked = true;
        }
      } else if (wristDist > 0.36 && _fpsTwoHandsLocked) {
        // Soltou a mão da base! Dispara recarga
        if ((now - _fpsLastReloadTime) > 1200) {
          _fpsLastReloadTime = now;
          reloadTriggered = true;
          _fpsIsReloading = true;
          _fpsTwoHandsLocked = false;
          _fpsLockedGripFrames = 0;
          HapticFeedback.mediumImpact();
        }
      }
    } else {
      // Segunda mão saiu do enquadramento / recolheu após estar travada
      if (_fpsTwoHandsLocked) {
        if ((now - _fpsLastReloadTime) > 1200) {
          _fpsLastReloadTime = now;
          reloadTriggered = true;
          _fpsIsReloading = true;
          _fpsTwoHandsLocked = false;
          _fpsLockedGripFrames = 0;
          HapticFeedback.mediumImpact();
        }
      }
    }

    if (now - _fpsLastReloadTime > 200) {
      _fpsIsReloading = false;
    }

    // 6. Transmissão UDP de Telemetria e Comandos FPS
    final payload = {
      "modo": "fps",
      "mouse_dx": mouseDx,
      "mouse_dy": mouseDy,
      "disparo": fireTriggered || _fpsIsFiring,
      "zoom": _fpsIsZoom,
      "recarregar": reloadTriggered || _fpsIsReloading,
      "empunhadura_dupla": _fpsTwoHandsLocked,
      "arma_ativa": _fpsIsGunActive,
      "detect": true,
      "sensibilidade": _fpsSensitivityLabel,
    };

    UdpService.instance.sendPayload(payload);

    _frameCounter++;
    if (_frameCounter % 30 == 0) {
      debugPrint('[CameraScreen] [FPS] dx=$mouseDx, dy=$mouseDy, fire=$_fpsIsFiring, zoom=$_fpsIsZoom, reload=$_fpsIsReloading, grip=$_fpsTwoHandsLocked');
    }

    if (mounted) {
      setState(() {
        _hasDetection = true;
        _currentPayload = payload;
      });
    }
  }

  // ===========================================================================
  // MODO 5: REGRAS MODO LUTA (Stick Fight The Game / Brawler Corporal)
  // ===========================================================================
  bool _doSegmentsIntersect(Offset p1, Offset q1, Offset p2, Offset q2) {
    int orientation(Offset p, Offset q, Offset r) {
      final double val = (q.dy - p.dy) * (r.dx - q.dx) - (q.dx - p.dx) * (r.dy - q.dy);
      if (val.abs() < 1e-6) return 0;
      return (val > 0) ? 1 : 2;
    }
    final int o1 = orientation(p1, q1, p2);
    final int o2 = orientation(p1, q1, q2);
    final int o3 = orientation(p2, q2, p1);
    final int o4 = orientation(p2, q2, q1);
    return (o1 != o2 && o3 != o4);
  }

  void _processFightRules(List<Pose> poses) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final bool hasPose = poses.isNotEmpty;

    if (!hasPose) {
      _fightDetectedPoses = [];
      _fightIsAttacking = false;
      _fightIsDefending = false;
      _fightIsJumping = false;
      _fightIsMovingLeft = false;
      _fightIsMovingRight = false;
      _fightBodySway = 0.0;

      final payload = {
        "modo": "luta",
        "ataque": false,
        "defesa": false,
        "esquerda": false,
        "direita": false,
        "pular": false,
        "detect": false,
        "sway": 0.0,
      };
      UdpService.instance.sendPayload(payload);
      if (mounted) {
        setState(() {
          _hasDetection = false;
          _currentPayload = payload;
        });
      }
      return;
    }

    _fightDetectedPoses = poses;
    final pose = poses.first;

    final rs = pose.landmarks[PoseLandmarkType.rightShoulder];
    final ls = pose.landmarks[PoseLandmarkType.leftShoulder];
    final re = pose.landmarks[PoseLandmarkType.rightElbow];
    final le = pose.landmarks[PoseLandmarkType.leftElbow];
    final rw = pose.landmarks[PoseLandmarkType.rightWrist];
    final lw = pose.landmarks[PoseLandmarkType.leftWrist];
    final rh = pose.landmarks[PoseLandmarkType.rightHip];
    final lh = pose.landmarks[PoseLandmarkType.leftHip];

    if (rs == null || ls == null || rh == null || lh == null) {
      return;
    }

    final sensorOrientation = _cameraController?.description.sensorOrientation ?? 270;
    final isFrontCamera = _cameraController?.description.lensDirection == CameraLensDirection.front;
    final previewSize = _cameraController?.value.previewSize;
    final double imgW = (sensorOrientation == 90 || sensorOrientation == 270)
        ? (previewSize?.height.toDouble() ?? 720.0)
        : (previewSize?.width.toDouble() ?? 1280.0);
    final double imgH = (sensorOrientation == 90 || sensorOrientation == 270)
        ? (previewSize?.width.toDouble() ?? 1280.0)
        : (previewSize?.height.toDouble() ?? 720.0);

    // Helper para converter coordenadas de PoseLandmark em tela normalizada [0.0, 1.0] (coincide com preview)
    Offset toScreen(PoseLandmark lm) {
      final double normX = (lm.x / imgW).clamp(0.0, 1.0);
      final double normY = (lm.y / imgH).clamp(0.0, 1.0);
      final double sx = isFrontCamera ? (1.0 - normX) : normX;
      final double sy = normY;
      return Offset(sx, sy);
    }

    final pRs = toScreen(rs);
    final pLs = toScreen(ls);
    final pRh = toScreen(rh);
    final pLh = toScreen(lh);
    final pRe = re != null ? toScreen(re) : null;
    final pLe = le != null ? toScreen(le) : null;
    final pRw = rw != null ? toScreen(rw) : null;
    final pLw = lw != null ? toScreen(lw) : null;

    final pShoulderCenter = Offset((pRs.dx + pLs.dx) / 2.0, (pRs.dy + pLs.dy) / 2.0);
    final pHipCenter = Offset((pRh.dx + pLh.dx) / 2.0, (pRh.dy + pLh.dy) / 2.0);
    final double shoulderSpan = max((pRs.dx - pLs.dx).abs(), 0.12);

    bool cmdPular = false;
    bool cmdEsquerda = false;
    bool cmdDireita = false;
    bool cmdAtaque = false;
    bool cmdDefesa = false;

    // 1. PULO (W no Stick Fight): Salto Físico Vertical
    final double currentHipY = pHipCenter.dy;
    if (_fightBaselineHipY == 0.0) {
      _fightBaselineHipY = currentHipY;
      _fightPrevHipY = currentHipY;
    } else {
      final double deltaHipY = currentHipY - _fightPrevHipY;
      // dy < 0 é movimento para CIMA na tela
      if (deltaHipY < -0.025 || currentHipY < _fightBaselineHipY - 0.045) {
        cmdPular = true;
        _fightIsJumping = true;
      } else if (currentHipY > _fightBaselineHipY - 0.020) {
        _fightIsJumping = false;
      }
      _fightBaselineHipY = _fightBaselineHipY * 0.96 + currentHipY * 0.04;
      _fightPrevHipY = currentHipY;
    }

    // 2. MOVER O CORPO PARA ESQUERDA OU DIREITA (A e D no Stick Fight):
    // "não é andar, apenas mover o corpo naquela direção, mantendo o eixo central"
    // Mede o deslocamento lateral do centro do tronco em relação à base dos quadris
    final double sway = (pShoulderCenter.dx - pHipCenter.dx) / shoulderSpan;
    _fightBodySway = sway;

    // Zona morta calibrada: inclinar/deslocar tronco além de 16% ativa A ou D
    if (sway < -0.16) {
      cmdEsquerda = true;
      _fightIsMovingLeft = true;
      _fightIsMovingRight = false;
    } else if (sway > 0.16) {
      cmdDireita = true;
      _fightIsMovingRight = true;
      _fightIsMovingLeft = false;
    } else if (sway.abs() <= 0.10) {
      _fightIsMovingLeft = false;
      _fightIsMovingRight = false;
    } else {
      // Histerese de sustentação
      cmdEsquerda = _fightIsMovingLeft;
      cmdDireita = _fightIsMovingRight;
    }

    // 3. DEFESA (V no Stick Fight): Cruzar os braços em formato de "X"
    if (pRw != null && pLw != null && pRe != null && pLe != null) {
      final double wristDist = (pRw - pLw).distance;
      // Ambos os punhos elevados em frente ao tronco (acima dos quadris)
      final bool wristsElevated = pRw.dy < (pHipCenter.dy + 0.02) && pLw.dy < (pHipCenter.dy + 0.02);

      // Verificação geométrica de cruzamento de segmentos dos antebraços
      final bool segmentsCross = _doSegmentsIntersect(pRe, pRw, pLe, pLw);

      // Verificação por inversão lateral dos punhos próximos ao centro
      final bool wristsCrossed = (wristDist < shoulderSpan * 0.50) &&
          ((pRw.dx - pLw.dx).sign != (pRe.dx - pLe.dx).sign);

      if (wristsElevated && (segmentsCross || wristsCrossed)) {
        cmdDefesa = true;
        _fightIsDefending = true;
      } else {
        _fightIsDefending = false;
      }
    }

    // 4. ATAQUE (C no Stick Fight): Mover os braços na forma de soco
    if (!cmdDefesa) {
      bool punchActive = false;

      // Soco com Braço Direito
      if (pRw != null && pRe != null) {
        final double rArmLen = (pRs - pRe).distance + (pRe - pRw).distance;
        final double rExtension = (pRs - pRw).distance / max(rArmLen, 1e-4);
        final bool rElevated = pRw.dy < (pHipCenter.dy - 0.04);
        if (rElevated && rExtension > 0.80) {
          punchActive = true;
        }
      }

      // Soco com Braço Esquerdo
      if (pLw != null && pLe != null) {
        final double lArmLen = (pLs - pLe).distance + (pLe - pLw).distance;
        final double lExtension = (pLs - pLw).distance / max(lArmLen, 1e-4);
        final bool lElevated = pLw.dy < (pHipCenter.dy - 0.04);
        if (lElevated && lExtension > 0.80) {
          punchActive = true;
        }
      }

      if (punchActive) {
        if (!_fightIsAttacking && (now - _fightLastPunchTime) > 180) {
          _fightLastPunchTime = now;
          cmdAtaque = true;
          _fightIsAttacking = true;
          HapticFeedback.mediumImpact();
        } else if (_fightIsAttacking) {
          cmdAtaque = true;
        }
      } else {
        _fightIsAttacking = false;
      }
    }

    final payload = {
      "modo": "luta",
      "ataque": cmdAtaque,
      "defesa": cmdDefesa,
      "esquerda": cmdEsquerda,
      "direita": cmdDireita,
      "pular": cmdPular || _fightIsJumping,
      "detect": true,
      "sway": double.parse(sway.toStringAsFixed(2)),
    };

    UdpService.instance.sendPayload(payload);

    _frameCounter++;
    if (_frameCounter % 30 == 0) {
      debugPrint('[CameraScreen] [LUTA] atk=$cmdAtaque, def=$cmdDefesa, esq=$cmdEsquerda, dir=$cmdDireita, jmp=$cmdPular, sway=${sway.toStringAsFixed(2)}');
    }

    if (mounted) {
      setState(() {
        _hasDetection = true;
        _currentPayload = payload;
      });
    }
  }

  // ===========================================================================
  // MODO 6: REGRAS FPS OCULAR / MESH (Acessibilidade Severa CS 1.6 / Head & Eyes)
  // ===========================================================================
  void _processFpsMeshRules(List<Face> faces) {
    if (faces.isEmpty) {
      _fpsMeshFilteredDx *= 0.5;
      _fpsMeshFilteredDy *= 0.5;
      _fpsMeshJoyRx = 0.0;
      _fpsMeshJoyRy = 0.0;
      _fpsMeshJoyLx = 0.0;
      _fpsMeshJoyLy = 0.0;
      _fpsMeshIsFiring = false;
      _fpsMeshIsZoom = false;
      _fpsMeshIsReloading = false;
      _fpsMeshCmdW = false;
      _fpsMeshCmdA = false;
      _fpsMeshCmdS = false;
      _fpsMeshCmdD = false;
      _fpsMeshDetectedFaces = [];

      final payload = {
        "modo": "fps",
        "detect": false,
        "joy_rx": 0.0,
        "joy_ry": 0.0,
        "joy_lx": 0.0,
        "joy_ly": 0.0,
        "cima": false,
        "baixo": false,
        "esquerda": false,
        "direita": false,
        "mouse_dx": 0,
        "mouse_dy": 0,
        "disparo": false,
        "zoom": false,
        "recarregar": false,
        "sensibilidade": _fpsSensitivityLabel,
      };

      UdpService.instance.sendPayload(payload);
      if (mounted) {
        setState(() {
          _hasDetection = false;
          _currentPayload = payload;
        });
      }
      return;
    }

    final face = faces.first;
    _fpsMeshDetectedFaces = [face];

    // -------------------------------------------------------------------------
    // 1. LOCOMOÇÃO (WASD VIA CABEÇA: PITCH & YAW)
    // -------------------------------------------------------------------------
    final pNose = face.landmarks[FaceLandmarkType.noseBase]?.position;
    final pLeftEye = face.landmarks[FaceLandmarkType.leftEye]?.position;
    final pRightEye = face.landmarks[FaceLandmarkType.rightEye]?.position;
    final pMouth = face.landmarks[FaceLandmarkType.bottomMouth]?.position;

    double pitchRatio = 0.0;
    double yawRatio = 0.0;

    if (pNose != null && pLeftEye != null && pRightEye != null) {
      final double midEyesY = (pLeftEye.y + pRightEye.y) * 0.5;
      final double midEyesX = (pLeftEye.x + pRightEye.x) * 0.5;
      final double faceH = max(20.0, (pMouth != null ? (pMouth.y - midEyesY).toDouble() : face.boundingBox.height * 0.6));
      final double eyeWidth = max(20.0, (pRightEye.x - pLeftEye.x).abs().toDouble());

      pitchRatio = (pNose.y - midEyesY) / faceH;
      yawRatio = (pNose.x - midEyesX) / eyeWidth;
    } else {
      final double eulerX = face.headEulerAngleX ?? 0.0;
      final double eulerY = face.headEulerAngleY ?? 0.0;
      pitchRatio = eulerX / -45.0;
      yawRatio = eulerY / 45.0;
    }

    if (!_fpsMeshBaselineCalibrated) {
      _fpsMeshBaselinePitch = pitchRatio;
      _fpsMeshBaselineYaw = yawRatio;
      _fpsMeshBaselineCalibrated = true;
    }

    final double pitchDiff = pitchRatio - _fpsMeshBaselinePitch;
    final double yawDiff = yawRatio - _fpsMeshBaselineYaw;

    const double pitchDeadzone = 0.055;
    final double eulerX = face.headEulerAngleX ?? 0.0;
    final bool cmdCima = (pitchDiff < -pitchDeadzone) || (eulerX > 11.0);
    final bool cmdBaixo = (pitchDiff > pitchDeadzone) || (eulerX < -11.0);

    const double yawDeadzone = 0.070;
    final double eulerY = face.headEulerAngleY ?? 0.0;
    final bool cmdEsquerda = (yawDiff < -yawDeadzone) || (eulerY > 11.0);
    final bool cmdDireita = (yawDiff > yawDeadzone) || (eulerY < -11.0);

    // -------------------------------------------------------------------------
    // 2. GATILHOS DE AÇÃO (CLIQUES VIA PISCADAS INTENCIONAIS FORTES)
    // -------------------------------------------------------------------------
    final double probL = face.leftEyeOpenProbability ?? 1.0;
    final double probR = face.rightEyeOpenProbability ?? 1.0;
    final double blinkL = (1.0 - probL).clamp(0.0, 1.0);
    final double blinkR = (1.0 - probR).clamp(0.0, 1.0);
    _fpsMeshBlinkLeft = blinkL;
    _fpsMeshBlinkRight = blinkR;

    const double blinkThresh = 0.70;
    final bool isIntentionalLeft = (blinkL >= blinkThresh) && ((blinkL - blinkR) > 0.25);
    final bool isIntentionalRight = (blinkR >= blinkThresh) && ((blinkR - blinkL) > 0.25);
    final bool isDoubleTight = (blinkL >= 0.85) && (blinkR >= 0.85);

    final bool cmdDisparo = isIntentionalLeft;
    final bool cmdZoom = isIntentionalRight;
    final bool cmdRecarregar = isDoubleTight;

    // -------------------------------------------------------------------------
    // 3. MIRA DA CÂMERA (MOUSE DX/DY VIA OLHAR & CONTORNOS OCULARES)
    // -------------------------------------------------------------------------
    final contourL = face.contours[FaceContourType.leftEye]?.points;
    final contourR = face.contours[FaceContourType.rightEye]?.points;

    double lookOutL = 0.0, lookInL = 0.0, lookUpL = 0.0, lookDownL = 0.0;
    double lookOutR = 0.0, lookInR = 0.0, lookUpR = 0.0, lookDownR = 0.0;

    if (contourL != null && contourL.length >= 8 && contourR != null && contourR.length >= 8) {
      double cxL = 0, cyL = 0;
      for (final p in contourL) {
        cxL += p.x;
        cyL += p.y;
      }
      cxL /= contourL.length;
      cyL /= contourL.length;

      double cxR = 0, cyR = 0;
      for (final p in contourR) {
        cxR += p.x;
        cyR += p.y;
      }
      cxR /= contourR.length;
      cyR /= contourR.length;

      final pCanthusOutL = contourL.first;
      final pCanthusInL = contourL[contourL.length ~/ 2];
      final double widthL = max(10.0, (pCanthusOutL.x - pCanthusInL.x).abs().toDouble());
      final double midXL = (pCanthusOutL.x + pCanthusInL.x) * 0.5;

      final pCanthusOutR = contourR.first;
      final pCanthusInR = contourR[contourR.length ~/ 2];
      final double widthR = max(10.0, (pCanthusOutR.x - pCanthusInR.x).abs().toDouble());
      final double midXR = (pCanthusOutR.x + pCanthusInR.x) * 0.5;

      lookInL = max(0.0, (cxL - midXL) / (widthL * 0.5));
      lookOutL = max(0.0, (midXL - cxL) / (widthL * 0.5));
      lookInR = max(0.0, (midXR - cxR) / (widthR * 0.5));
      lookOutR = max(0.0, (cxR - midXR) / (widthR * 0.5));

      final double heightL = max(6.0, (contourL[contourL.length ~/ 4].y - contourL[(3 * contourL.length) ~/ 4].y).abs().toDouble());
      final double midYL = (contourL[contourL.length ~/ 4].y + contourL[(3 * contourL.length) ~/ 4].y) * 0.5;
      lookDownL = max(0.0, (cyL - midYL) / (heightL * 0.5));
      lookUpL = max(0.0, (midYL - cyL) / (heightL * 0.5));

      final double heightR = max(6.0, (contourR[contourR.length ~/ 4].y - contourR[(3 * contourR.length) ~/ 4].y).abs().toDouble());
      final double midYR = (contourR[contourR.length ~/ 4].y + contourR[(3 * contourR.length) ~/ 4].y) * 0.5;
      lookDownR = max(0.0, (cyR - midYR) / (heightR * 0.5));
      lookUpR = max(0.0, (midYR - cyR) / (heightR * 0.5));
    }

    double lookRight, lookLeft, lookUp, lookDown;
    if (blinkL > 0.55 && blinkR < 0.40) {
      lookRight = lookOutR;
      lookLeft = lookInR;
      lookUp = lookUpR;
      lookDown = lookDownR;
    } else if (blinkR > 0.55 && blinkL < 0.40) {
      lookRight = lookInL;
      lookLeft = lookOutL;
      lookUp = lookUpL;
      lookDown = lookDownL;
    } else {
      lookRight = (lookInL + lookOutR) * 0.5;
      lookLeft = (lookOutL + lookInR) * 0.5;
      lookUp = (lookUpL + lookUpR) * 0.5;
      lookDown = (lookDownL + lookDownR) * 0.5;
    }

    // No padrão de joystick: Cima = +Y, Baixo = -Y
    double rawGazeX = lookRight - lookLeft;
    double rawGazeY = lookUp - lookDown;
    if (_fpsInvertY) {
      rawGazeY = -rawGazeY;
    }

    // -------------------------------------------------------------------------
    // 4. FILTRO ANTI-TREMOR & EMULAÇÃO DE JOYSTICK ANALÓGICO
    // -------------------------------------------------------------------------
    final double gazeMag = sqrt(rawGazeX * rawGazeX + rawGazeY * rawGazeY);
    const double gazeDeadzone = 0.065;

    double targetGx = 0.0;
    double targetGy = 0.0;
    if (gazeMag > gazeDeadzone) {
      final double excess = gazeMag - gazeDeadzone;
      final double ratio = excess / gazeMag;
      targetGx = rawGazeX * ratio;
      targetGy = rawGazeY * ratio;
    }

    final double alpha = gazeMag > 0.18 ? 0.28 : 0.16;
    _fpsMeshFilteredDx = _fpsMeshFilteredDx * (1.0 - alpha) + targetGx * alpha;
    _fpsMeshFilteredDy = _fpsMeshFilteredDy * (1.0 - alpha) + targetGy * alpha;

    if (_fpsMeshFilteredDx.abs() < 0.003) _fpsMeshFilteredDx = 0.0;
    if (_fpsMeshFilteredDy.abs() < 0.003) _fpsMeshFilteredDy = 0.0;

    // Emulação de Analógico Direito (Right Stick - Mira / Câmera via Olhos)
    final double joyScale = _fpsSensitivityIndex == 0 ? 1.8 : (_fpsSensitivityIndex == 2 ? 3.5 : 2.5);
    final double filtMag = sqrt(_fpsMeshFilteredDx * _fpsMeshFilteredDx + _fpsMeshFilteredDy * _fpsMeshFilteredDy);
    double joyRx = 0.0;
    double joyRy = 0.0;
    if (filtMag > 0.0) {
      final double curve = pow(filtMag / 0.40, 1.30).toDouble();
      joyRx = (_fpsMeshFilteredDx / filtMag) * curve * joyScale;
      joyRy = (_fpsMeshFilteredDy / filtMag) * curve * joyScale;
    }
    joyRx = joyRx.clamp(-1.0, 1.0);
    joyRy = joyRy.clamp(-1.0, 1.0);

    // Emulação de Analógico Esquerdo (Left Stick - Movimentação via Cabeça)
    double joyLx = 0.0;
    double joyLy = 0.0;
    if (pitchDiff.abs() > pitchDeadzone) {
      final double pExcess = pitchDiff.abs() - pitchDeadzone;
      final double pSign = pitchDiff > 0 ? -1.0 : 1.0;
      joyLy = (pSign * (pExcess / 0.10)).clamp(-1.0, 1.0);
    }
    if (yawDiff.abs() > yawDeadzone) {
      final double yExcess = yawDiff.abs() - yawDeadzone;
      final double ySign = yawDiff > 0 ? 1.0 : -1.0;
      joyLx = (ySign * (yExcess / 0.12)).clamp(-1.0, 1.0);
    }

    // Rate-control de Mouse para compatibilidade com Teclado / DirectInput
    final double rateSens = _fpsSensitivityIndex == 0 ? 16.0 : (_fpsSensitivityIndex == 2 ? 44.0 : 28.0);
    final int mouseDx = (joyRx * rateSens).toInt();
    final int mouseDy = (-joyRy * rateSens).toInt();

    // -------------------------------------------------------------------------
    // 5. ENVIO DO PAYLOAD UDP & ATUALIZAÇÃO DO ESTADO
    // -------------------------------------------------------------------------
    final payload = {
      "modo": "fps",
      "detect": true,
      "joy_rx": double.parse(joyRx.toStringAsFixed(3)),
      "joy_ry": double.parse(joyRy.toStringAsFixed(3)),
      "joy_lx": double.parse(joyLx.toStringAsFixed(3)),
      "joy_ly": double.parse(joyLy.toStringAsFixed(3)),
      "cima": cmdCima,
      "baixo": cmdBaixo,
      "esquerda": cmdEsquerda,
      "direita": cmdDireita,
      "mouse_dx": mouseDx,
      "mouse_dy": mouseDy,
      "disparo": cmdDisparo,
      "zoom": cmdZoom,
      "recarregar": cmdRecarregar,
      "sensibilidade": _fpsSensitivityLabel,
      "blink_esq": double.parse(blinkL.toStringAsFixed(2)),
      "blink_dir": double.parse(blinkR.toStringAsFixed(2)),
    };

    UdpService.instance.sendPayload(payload);

    _frameCounter++;
    if (_frameCounter % 30 == 0) {
      debugPrint('[CameraScreen] [JOYSTICK OCULAR] R-Stick=(${joyRx.toStringAsFixed(2)}, ${joyRy.toStringAsFixed(2)}) L-Stick=(${joyLx.toStringAsFixed(2)}, ${joyLy.toStringAsFixed(2)}) RT=$cmdDisparo LT=$cmdZoom');
    }

    if (mounted) {
      setState(() {
        _hasDetection = true;
        _currentPayload = payload;
        _fpsMeshJoyRx = joyRx;
        _fpsMeshJoyRy = joyRy;
        _fpsMeshJoyLx = joyLx;
        _fpsMeshJoyLy = joyLy;
        _fpsMeshIsFiring = cmdDisparo;
        _fpsMeshIsZoom = cmdZoom;
        _fpsMeshIsReloading = cmdRecarregar;
        _fpsMeshCmdW = cmdCima;
        _fpsMeshCmdA = cmdEsquerda;
        _fpsMeshCmdS = cmdBaixo;
        _fpsMeshCmdD = cmdDireita;
      });
    }
  }

  // ===========================================================================
  // TRANSMISSÃO UDP E ATUALIZAÇÃO DE UI
  // ===========================================================================
  void _dispatchPayload({
    required bool hasDetection,
    required bool pular,
    required bool esquerda,
    required bool direita,
    required bool cima,
    required bool baixo,
    required VoidCallback extraUpdate,
  }) {
    extraUpdate();

    final payload = {
      "esquerda": esquerda,
      "direita": direita,
      "cima": cima,
      "baixo": baixo,
      "pular": pular,
      "angulo": double.parse(_wheelAngle.toStringAsFixed(1)),
      "detect": hasDetection,
      "modo": widget.mode.name,
      "sensib_volante": _wheelSensitivityLabel,
      "sensib_pedal": _thumbSensitivityLabel,
      "max_angulo": _wheelMaxAngle,
      "zona_morta": _wheelDeadzone,
      "mao_dir_aberta": _isRightHandOpen,
      "mao_esq_aberta": _isLeftHandOpen,
      "polegar_dir": _isRightThumbUp,
      "polegar_esq": _isLeftThumbUp,
      "polegar_dir_score": double.parse(_rightThumbScore.toStringAsFixed(2)),
      "polegar_esq_score": double.parse(_leftThumbScore.toStringAsFixed(2)),
    };

    // Dispara via Socket UDP
    UdpService.instance.sendPayload(payload);

    _frameCounter++;
    if (_frameCounter % 30 == 0) {
      debugPrint('[CameraScreen] [${widget.mode.name.toUpperCase()}] detect=$hasDetection, cmd=$payload, pkts=${UdpService.instance.packetsSent}');
    }

    if (mounted) {
      setState(() {
        _hasDetection = hasDetection;
        _currentPayload = payload;
      });
    }
  }

  // ===========================================================================
  // CONVERSÃO DE IMAGEM OFICIAL DO GOOGLE ML KIT (ALTA PERFORMANCE)
  // ===========================================================================
  InputImage? _buildInputImage(CameraImage image) {
    final camera = _cameraController?.description;
    if (camera == null) return null;

    final sensorOrientation = camera.sensorOrientation;
    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    } else if (Platform.isAndroid && _cameraController != null) {
      var rotationCompensation =
          _orientations[_cameraController!.value.deviceOrientation] ?? 0;
      if (camera.lensDirection == CameraLensDirection.front) {
        rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
      } else {
        rotationCompensation =
            (sensorOrientation - rotationCompensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }
    rotation ??= InputImageRotationValue.fromRawValue(sensorOrientation);
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    InputImageFormat resolvedFormat = format ?? InputImageFormat.nv21;
    final Uint8List bytes;

    if (image.planes.length == 1) {
      bytes = image.planes.first.bytes;
    } else if (Platform.isAndroid && image.planes.length == 3) {
      bytes = _convertYUV420ToNV21(image);
      resolvedFormat = InputImageFormat.nv21;
    } else {
      bytes = _concatenatePlanes(image);
    }

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: resolvedFormat,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  Uint8List _convertYUV420ToNV21(CameraImage image) {
    final int width = image.width;
    final int height = image.height;
    final int ySize = width * height;
    final int uvSize = ySize ~/ 2;
    final int requiredSize = ySize + uvSize;

    if (_reusableNv21Buffer == null || _lastNv21Size != requiredSize) {
      _reusableNv21Buffer = Uint8List(requiredSize);
      _lastNv21Size = requiredSize;
    }

    final Uint8List nv21 = _reusableNv21Buffer!;

    // 1. Copia o plano Y linha por linha eliminando eventuais paddings de bytesPerRow
    final Plane yPlane = image.planes[0];
    int destIndex = 0;
    for (int row = 0; row < height; row++) {
      final int srcRowStart = row * yPlane.bytesPerRow;
      nv21.setRange(destIndex, destIndex + width, yPlane.bytes, srcRowStart);
      destIndex += width;
    }

    // 2. Intercala os planos V e U no formato NV21 (VU order)
    final Plane uPlane = image.planes[1];
    final Plane vPlane = image.planes[2];
    final int uvPixelStride = uPlane.bytesPerPixel ?? 1;
    final int vPixelStride = vPlane.bytesPerPixel ?? 1;

    int uvIndex = ySize;
    final int halfHeight = height ~/ 2;
    final int halfWidth = width ~/ 2;

    for (int row = 0; row < halfHeight; row++) {
      final int uRowStart = row * uPlane.bytesPerRow;
      final int vRowStart = row * vPlane.bytesPerRow;

      for (int col = 0; col < halfWidth; col++) {
        final int uIndex = uRowStart + col * uvPixelStride;
        final int vIndex = vRowStart + col * vPixelStride;

        nv21[uvIndex++] = vPlane.bytes[vIndex];
        nv21[uvIndex++] = uPlane.bytes[uIndex];
      }
    }

    return nv21;
  }

  Uint8List _concatenatePlanes(CameraImage image) {
    final int totalBytes = image.planes.fold<int>(
      0,
      (int sum, Plane plane) => sum + plane.bytes.length,
    );

    var buffer = _reusablePlaneBuffer;
    if (buffer == null || buffer.length < totalBytes) {
      buffer = Uint8List(totalBytes);
      _reusablePlaneBuffer = buffer;
    }

    var offset = 0;
    for (final Plane plane in image.planes) {
      final bytes = plane.bytes;
      buffer.setRange(offset, offset + bytes.length, bytes);
      offset += bytes.length;
    }

    if (totalBytes == buffer.length) {
      return buffer;
    }
    return Uint8List.sublistView(buffer, 0, totalBytes);
  }

  // ===========================================================================
  // LIMPEZA TOTAL (PREVENÇÃO DE MEMORY LEAK)
  // ===========================================================================
  Future<void> _cleanExit() async {
    // 1. Envia comando neutro imediatamente para destravar controles na Bridge/jogos
    UdpService.instance.sendZeroPayload();

    // 2. Para a câmera
    try {
      await _cameraController?.stopImageStream();
    } catch (_) {}
    await _cameraController?.dispose();
    _cameraController = null;

    // 3. Libera os detectores ML Kit da memória
    try {
      await _faceDetector?.close();
      _faceDetector = null;
    } catch (_) {}

    try {
      await _poseDetector?.close();
      _poseDetector = null;
    } catch (_) {}

    try {
      _handLandmarker?.dispose();
      _handLandmarker = null;
    } catch (_) {}

    debugPrint('[CameraScreen] Limpeza completa executada com sucesso.');
  }

  @override
  void dispose() {
    _cleanExit();
    super.dispose();
  }

  void _onBackPressed() async {
    await _cleanExit();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  // ===========================================================================
  // INTERFACE VISUAL
  // ===========================================================================
  @override
  Widget build(BuildContext context) {
    if (!_cameraPermissionGranted) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.camera_alt, size: 64, color: Colors.orange),
              const SizedBox(height: 16),
              const Text('Permissão de câmera necessária', style: TextStyle(color: Colors.white)),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _requestPermissionAndInitCamera,
                child: const Text('Conceder Permissão'),
              ),
            ],
          ),
        ),
      );
    }

    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(color: widget.mode.color),
        ),
      );
    }

    final isEsq = _currentPayload['esquerda'] == true;
    final isDir = _currentPayload['direita'] == true;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBackPressed();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // 1. Preview da Câmera em Tela Cheia
            FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _cameraController!.value.previewSize?.height ?? 1,
                height: _cameraController!.value.previewSize?.width ?? 1,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CameraPreview(_cameraController!),
                    if (widget.mode == ControlMode.gestual)
                      CustomPaint(
                        painter: HandOverlayPainter(
                          hands: _detectedHands,
                          isRightOpen: _isRightHandOpen,
                          isLeftOpen: _isLeftHandOpen,
                          isRightThumbUp: _isRightThumbUp,
                          isLeftThumbUp: _isLeftThumbUp,
                          isFrontCamera: _cameraController!.description.lensDirection == CameraLensDirection.front,
                          sensorOrientation: _cameraController!.description.sensorOrientation,
                          wheelAngle: _wheelAngle,
                          isTurningLeft: isEsq,
                          isTurningRight: isDir,
                          isNeutral: !isEsq && !isDir,
                        ),
                      ),
                    if (widget.mode == ControlMode.fps)
                      CustomPaint(
                        painter: FpsOverlayPainter(
                          hands: _detectedHands,
                          crosshairPos: _fpsCrosshairPos,
                          isGunActive: _fpsIsGunActive,
                          isZoom: _fpsIsZoom,
                          isFiring: _fpsIsFiring,
                          isReloading: _fpsIsReloading,
                          twoHandsLocked: _fpsTwoHandsLocked,
                          isFrontCamera: _cameraController!.description.lensDirection == CameraLensDirection.front,
                          sensorOrientation: _cameraController!.description.sensorOrientation,
                        ),
                      ),
                    if (widget.mode == ControlMode.fight)
                      CustomPaint(
                        painter: FightOverlayPainter(
                          poses: _fightDetectedPoses,
                          isAttacking: _fightIsAttacking,
                          isDefending: _fightIsDefending,
                          isJumping: _fightIsJumping,
                          isMovingLeft: _fightIsMovingLeft,
                          isMovingRight: _fightIsMovingRight,
                          bodySway: _fightBodySway,
                          isFrontCamera: _cameraController!.description.lensDirection == CameraLensDirection.front,
                          sensorOrientation: _cameraController!.description.sensorOrientation,
                          previewSize: _cameraController!.value.previewSize,
                        ),
                      ),
                    if (widget.mode == ControlMode.fpsMesh)
                      CustomPaint(
                        painter: FpsMeshOverlayPainter(
                          faces: _fpsMeshDetectedFaces,
                          filteredDx: _fpsMeshFilteredDx,
                          filteredDy: _fpsMeshFilteredDy,
                          joyRx: _fpsMeshJoyRx,
                          joyRy: _fpsMeshJoyRy,
                          joyLx: _fpsMeshJoyLx,
                          joyLy: _fpsMeshJoyLy,
                          isFiring: _fpsMeshIsFiring,
                          isZoom: _fpsMeshIsZoom,
                          isReloading: _fpsMeshIsReloading,
                          cmdW: _fpsMeshCmdW,
                          cmdA: _fpsMeshCmdA,
                          cmdS: _fpsMeshCmdS,
                          cmdD: _fpsMeshCmdD,
                          blinkLeft: _fpsMeshBlinkLeft,
                          blinkRight: _fpsMeshBlinkRight,
                          isFrontCamera: _cameraController!.description.lensDirection == CameraLensDirection.front,
                          sensorOrientation: _cameraController!.description.sensorOrientation,
                          previewSize: _cameraController!.value.previewSize,
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // 2. Vinheta gradiente superior suave (apenas para legibilidade dos controles do topo)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 130,
              child: IgnorePointer(
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                ),
              ),
            ),

            // 3. Controles Dedicados e HUD com Layout Adaptativo (Vertical / Horizontal via Acelerômetro)
            SafeArea(
              child: ValueListenableBuilder<String>(
                valueListenable: BluetoothService.instance.orientationNotifier,
                builder: (context, physicalOrientation, _) {
                  final mediaOrientation = MediaQuery.of(context).orientation;
                  final isLandscape = physicalOrientation == 'landscape' ||
                      mediaOrientation == Orientation.landscape;

                  return Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: isLandscape ? 14 : 10,
                      vertical: isLandscape ? 6 : 8,
                    ),
                    child: isLandscape ? _buildLandscapeLayout() : _buildPortraitLayout(),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Layout para Orientação Vertical (Retrato) - Organizado em 2 linhas limpas sem estouro
  Widget _buildPortraitLayout() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Linha 1: Navegação, Ações Rápidas e Conectividade
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Botão Menu
            _buildDedicatedButton(
              icon: Icons.arrow_back_rounded,
              label: 'MENU',
              onTap: _onBackPressed,
            ),

            const SizedBox(width: 6),

            // Controles Rápidos e Badges à Direita
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ..._buildQuickSettingButtons(),
                    const SizedBox(width: 5),
                    _buildConnectionBadges(),
                  ],
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 6),

        // Linha 2: Telemetria com Caixas de Tamanho Fixo
        Center(
          child: _buildCompactTelemetryBar(),
        ),
      ],
    );
  }

  /// Layout para Orientação Horizontal (Paisagem) - Otimizado em linha panorâmica ampla
  Widget _buildLandscapeLayout() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Botão Menu
        _buildDedicatedButton(
          icon: Icons.arrow_back_rounded,
          label: 'MENU',
          onTap: _onBackPressed,
        ),

        const SizedBox(width: 8),

        // Centro: Barra de Telemetria com Caixas Fixas
        Expanded(
          child: Center(
            child: _buildCompactTelemetryBar(),
          ),
        ),

        const SizedBox(width: 8),

        // Lado Direito: Ações Rápidas e Badges
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ..._buildQuickSettingButtons(),
            const SizedBox(width: 5),
            _buildConnectionBadges(),
          ],
        ),
      ],
    );
  }

  /// Botões de Configuração Rápida por Modo
  List<Widget> _buildQuickSettingButtons() {
    return [
      if (widget.mode == ControlMode.gestual) ...[
        _buildDedicatedButton(
          icon: Icons.sports_esports_rounded,
          label: _wheelSensitivityShortLabel,
          color: Colors.amberAccent,
          borderColor: Colors.amberAccent.withValues(alpha: 0.6),
          onTap: () {
            setState(() {
              _wheelSensitivityIndex = (_wheelSensitivityIndex + 1) % 3;
            });
          },
        ),
        const SizedBox(width: 5),
        _buildDedicatedButton(
          icon: Icons.tune_rounded,
          label: _thumbSensitivityShortLabel,
          color: Colors.cyanAccent,
          borderColor: Colors.cyanAccent.withValues(alpha: 0.6),
          onTap: () {
            setState(() {
              _thumbSensitivityIndex = (_thumbSensitivityIndex + 1) % 3;
            });
          },
        ),
        const SizedBox(width: 5),
        _buildDedicatedButton(
          icon: Icons.swap_horiz_rounded,
          label: _invertSteering ? 'INV' : 'NORM',
          color: _invertSteering ? Colors.orangeAccent : Colors.white70,
          borderColor: _invertSteering
              ? Colors.orangeAccent.withValues(alpha: 0.7)
              : Colors.white24,
          backgroundColor: _invertSteering ? Colors.orange.withValues(alpha: 0.25) : null,
          onTap: () {
            setState(() {
              _invertSteering = !_invertSteering;
            });
          },
        ),
      ],

      if (widget.mode == ControlMode.fps || widget.mode == ControlMode.fpsMesh) ...[
        _buildDedicatedButton(
          icon: Icons.speed_rounded,
          label: _fpsSensitivityShortLabel,
          color: const Color(0xFF00FFCC),
          borderColor: const Color(0xFF00FFCC).withValues(alpha: 0.6),
          onTap: () {
            setState(() {
              _fpsSensitivityIndex = (_fpsSensitivityIndex + 1) % 3;
            });
          },
        ),
        const SizedBox(width: 5),
        _buildDedicatedButton(
          icon: Icons.swap_vert_rounded,
          label: _fpsInvertY ? 'Y:INV' : 'Y:NORM',
          color: _fpsInvertY ? Colors.orangeAccent : Colors.white70,
          borderColor: _fpsInvertY
              ? Colors.orangeAccent.withValues(alpha: 0.7)
              : Colors.white24,
          onTap: () {
            setState(() {
              _fpsInvertY = !_fpsInvertY;
            });
          },
        ),
        if (widget.mode == ControlMode.fpsMesh) ...[
          const SizedBox(width: 5),
          _buildDedicatedButton(
            icon: Icons.filter_center_focus_rounded,
            label: 'CENTRO',
            color: const Color(0xFF00E5FF),
            borderColor: const Color(0xFF00E5FF).withValues(alpha: 0.6),
            onTap: () {
              setState(() {
                _fpsMeshBaselineCalibrated = false;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Centro facial calibrado com sucesso!'),
                  duration: Duration(milliseconds: 700),
                  backgroundColor: Color(0xFF00E5FF),
                ),
              );
            },
          ),
        ],
      ],

      if (widget.cameras.length > 1) ...[
        const SizedBox(width: 5),
        _buildDedicatedButton(
          icon: Icons.flip_camera_android_rounded,
          onTap: _toggleCamera,
        ),
      ],
    ];
  }

  /// Badges de Conexão com Tamanho Fixo e Estável
  Widget _buildConnectionBadges() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Badge Bluetooth (Fixo quando conectado)
        ValueListenableBuilder<bool>(
          valueListenable: BluetoothService.instance.isConnectedNotifier,
          builder: (context, btConnected, _) {
            if (!btConnected) return const SizedBox.shrink();
            return Container(
              margin: const EdgeInsets.only(right: 5),
              width: 44,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFF2979FF).withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF2979FF)),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bluetooth_connected, color: Color(0xFF2979FF), size: 13),
                  SizedBox(width: 3),
                  Text(
                    'BT',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            );
          },
        ),

        // Badge de Pacotes UDP com Tamanho Fixo
        Container(
          width: 70,
          height: 30,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white24),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _hasDetection ? Colors.greenAccent : Colors.orangeAccent,
                ),
              ),
              const SizedBox(width: 4),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '${UdpService.instance.packetsSent} PKT',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 9.5,
                      fontWeight: FontWeight.bold,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Botão de controle dedicado com feedback tátil e dimensões padronizadas
  Widget _buildDedicatedButton({
    required IconData icon,
    String? label,
    required VoidCallback onTap,
    Color color = Colors.white,
    Color? backgroundColor,
    Color? borderColor,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        splashColor: color.withValues(alpha: 0.25),
        highlightColor: color.withValues(alpha: 0.12),
        child: Container(
          height: 30,
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(horizontal: label != null ? 8 : 7),
          decoration: BoxDecoration(
            color: backgroundColor ?? Colors.black.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: borderColor ?? Colors.white24,
              width: 1.1,
            ),
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 14),
              if (label != null) ...[
                const SizedBox(width: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.bold,
                      fontSize: 9.5,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Caixa de Métrica com Dimensão Rígida e Fixa (Garante que a UI nunca trepide ou corte caracteres)
  Widget _buildFixedMetricBox({
    required double width,
    required String text,
    double height = 28.0,
    Color color = Colors.white70,
    Color? backgroundColor,
    Color? borderColor,
    IconData? icon,
    bool isBold = false,
  }) {
    return SizedBox(
      width: width,
      height: height,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: backgroundColor ?? Colors.black.withValues(alpha: 0.60),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: borderColor ?? Colors.white24,
            width: 1.0,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 3.5),
            ],
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  text,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: color,
                    fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
                    fontSize: 9.5,
                    letterSpacing: 0.1,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Barra de telemetria ultra-compacta focada exclusivamente nos dados do jogo (sem título)
  Widget _buildCompactTelemetryBar() {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _hasDetection
              ? widget.mode.color.withValues(alpha: 0.50)
              : Colors.orange.withValues(alpha: 0.50),
          width: 1.0,
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Indicador Luminoso de Detecção Ativa (Dot discreto)
            Container(
              width: 7,
              height: 7,
              margin: const EdgeInsets.only(left: 2, right: 6),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _hasDetection ? widget.mode.color : Colors.orange,
                boxShadow: [
                  BoxShadow(
                    color: (_hasDetection ? widget.mode.color : Colors.orange).withValues(alpha: 0.7),
                    blurRadius: 5,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),

            // Métricas inline com caixas e campos de tamanho fixo
            ..._buildInlineMetrics(),
          ],
        ),
      ),
    );
  }

  /// Informações pontuais de telemetria com caixas de tamanho padronizado
  List<Widget> _buildInlineMetrics() {
    switch (widget.mode) {
      case ControlMode.gestual:
        String volanteText = 'RETO 0°';
        Color volanteColor = Colors.white70;
        Color volanteBorder = Colors.white24;
        Color? volanteBg;
        if (_currentPayload['esquerda'] == true) {
          volanteText = '◀ ESQ ${_wheelAngle.abs().toStringAsFixed(0)}°';
          volanteColor = Colors.greenAccent;
          volanteBorder = Colors.greenAccent.withValues(alpha: 0.7);
          volanteBg = Colors.green.withValues(alpha: 0.25);
        } else if (_currentPayload['direita'] == true) {
          volanteText = 'DIR ${_wheelAngle.abs().toStringAsFixed(0)}° ▶';
          volanteColor = Colors.greenAccent;
          volanteBorder = Colors.greenAccent.withValues(alpha: 0.7);
          volanteBg = Colors.green.withValues(alpha: 0.25);
        }

        return [
          _buildFixedMetricBox(
            width: 84,
            text: volanteText,
            color: volanteColor,
            borderColor: volanteBorder,
            backgroundColor: volanteBg,
            isBold: true,
          ),
          const SizedBox(width: 5),
          _buildFixedMetricBox(
            width: 82,
            icon: Icons.thumb_up,
            text: _isRightThumbUp ? 'ACEL: ON' : 'ACEL: OFF',
            color: _isRightThumbUp ? Colors.greenAccent : Colors.white60,
            borderColor: _isRightThumbUp ? Colors.greenAccent : Colors.white24,
            backgroundColor: _isRightThumbUp ? Colors.green.withValues(alpha: 0.30) : null,
            isBold: _isRightThumbUp,
          ),
          const SizedBox(width: 5),
          _buildFixedMetricBox(
            width: 82,
            icon: Icons.thumb_up,
            text: _isLeftThumbUp ? 'FREIO: ON' : 'FREIO: OFF',
            color: _isLeftThumbUp ? Colors.redAccent : Colors.white60,
            borderColor: _isLeftThumbUp ? Colors.redAccent : Colors.white24,
            backgroundColor: _isLeftThumbUp ? Colors.red.withValues(alpha: 0.30) : null,
            isBold: _isLeftThumbUp,
          ),
        ];

      case ControlMode.fps:
        final mDx = (_currentPayload['mouse_dx'] as num?)?.toInt() ?? 0;
        final mDy = (_currentPayload['mouse_dy'] as num?)?.toInt() ?? 0;
        final aimText = 'X:${mDx >= 0 ? '+' : ''}$mDx Y:${mDy >= 0 ? '+' : ''}$mDy';

        return [
          _buildFixedMetricBox(
            width: 80,
            text: aimText,
            color: Colors.white70,
            isBold: true,
          ),
          const SizedBox(width: 5),
          _buildFixedMetricBox(
            width: 74,
            icon: Icons.zoom_in,
            text: _fpsIsZoom ? 'ZOOM' : 'MIRA',
            color: _fpsIsZoom ? Colors.cyanAccent : Colors.white60,
            borderColor: _fpsIsZoom ? Colors.cyanAccent : Colors.white24,
            backgroundColor: _fpsIsZoom ? Colors.cyan.withValues(alpha: 0.30) : null,
            isBold: _fpsIsZoom,
          ),
          const SizedBox(width: 5),
          _buildFixedMetricBox(
            width: 72,
            icon: Icons.local_fire_department,
            text: _fpsIsFiring ? 'FOGO!' : 'GATILHO',
            color: _fpsIsFiring ? Colors.redAccent : Colors.white60,
            borderColor: _fpsIsFiring ? Colors.redAccent : Colors.white24,
            backgroundColor: _fpsIsFiring ? Colors.red.withValues(alpha: 0.35) : null,
            isBold: _fpsIsFiring,
          ),
          const SizedBox(width: 5),
          _buildFixedMetricBox(
            width: 78,
            icon: _fpsIsReloading ? Icons.autorenew : Icons.link,
            text: _fpsIsReloading ? 'RELOAD' : (_fpsTwoHandsLocked ? 'BASE OK' : 'SOLTA'),
            color: _fpsIsReloading
                ? Colors.amberAccent
                : (_fpsTwoHandsLocked ? Colors.greenAccent : Colors.white60),
            borderColor: _fpsIsReloading
                ? Colors.amberAccent
                : (_fpsTwoHandsLocked ? Colors.greenAccent : Colors.white24),
            backgroundColor: _fpsIsReloading
                ? Colors.amber.withValues(alpha: 0.35)
                : (_fpsTwoHandsLocked ? Colors.green.withValues(alpha: 0.20) : null),
            isBold: _fpsIsReloading || _fpsTwoHandsLocked,
          ),
        ];

      case ControlMode.fpsMesh:
        final bool isMoving = _fpsMeshCmdW || _fpsMeshCmdA || _fpsMeshCmdS || _fpsMeshCmdD;
        final String lStickTxt = 'L:${_fpsMeshJoyLx >= 0 ? "+" : ""}${_fpsMeshJoyLx.toStringAsFixed(1)},${_fpsMeshJoyLy >= 0 ? "+" : ""}${_fpsMeshJoyLy.toStringAsFixed(1)}';
        final String rStickTxt = 'R:${_fpsMeshJoyRx >= 0 ? "+" : ""}${_fpsMeshJoyRx.toStringAsFixed(1)},${_fpsMeshJoyRy >= 0 ? "+" : ""}${_fpsMeshJoyRy.toStringAsFixed(1)}';

        return [
          _buildFixedMetricBox(
            width: 78,
            icon: Icons.sports_esports,
            text: lStickTxt,
            color: isMoving ? const Color(0xFF00E5FF) : Colors.white70,
            borderColor: isMoving ? const Color(0xFF00E5FF) : Colors.white24,
            backgroundColor: isMoving ? const Color(0xFF00E5FF).withValues(alpha: 0.25) : null,
            isBold: isMoving,
          ),
          const SizedBox(width: 4),
          _buildFixedMetricBox(
            width: 78,
            icon: Icons.visibility,
            text: rStickTxt,
            color: Colors.cyanAccent,
            borderColor: Colors.cyanAccent.withValues(alpha: 0.5),
            backgroundColor: Colors.cyan.withValues(alpha: 0.15),
            isBold: true,
          ),
          const SizedBox(width: 4),
          _buildFixedMetricBox(
            width: 72,
            icon: Icons.local_fire_department,
            text: _fpsMeshIsFiring ? 'RT: ON' : 'RT ${(_fpsMeshBlinkLeft * 100).toInt()}%',
            color: _fpsMeshIsFiring ? Colors.redAccent : Colors.white60,
            borderColor: _fpsMeshIsFiring ? Colors.redAccent : Colors.white24,
            backgroundColor: _fpsMeshIsFiring ? Colors.red.withValues(alpha: 0.35) : null,
            isBold: _fpsMeshIsFiring,
          ),
          const SizedBox(width: 4),
          _buildFixedMetricBox(
            width: 72,
            icon: Icons.zoom_in,
            text: _fpsMeshIsZoom ? 'LT: ON' : 'LT ${(_fpsMeshBlinkRight * 100).toInt()}%',
            color: _fpsMeshIsZoom ? Colors.cyanAccent : Colors.white60,
            borderColor: _fpsMeshIsZoom ? Colors.cyanAccent : Colors.white24,
            backgroundColor: _fpsMeshIsZoom ? Colors.cyan.withValues(alpha: 0.30) : null,
            isBold: _fpsMeshIsZoom,
          ),
          const SizedBox(width: 4),
          _buildFixedMetricBox(
            width: 66,
            icon: _fpsMeshIsReloading ? Icons.autorenew : Icons.gamepad,
            text: _fpsMeshIsReloading ? '[X] REL' : 'JOY',
            color: _fpsMeshIsReloading ? Colors.amberAccent : const Color(0xFF00E5FF),
            borderColor: _fpsMeshIsReloading ? Colors.amberAccent : const Color(0xFF00E5FF).withValues(alpha: 0.4),
            backgroundColor: _fpsMeshIsReloading ? Colors.amber.withValues(alpha: 0.35) : null,
            isBold: _fpsMeshIsReloading,
          ),
        ];

      case ControlMode.fight:
        final isAtk = _currentPayload['ataque'] == true;
        final isDef = _currentPayload['defesa'] == true;
        final isEsq = _currentPayload['esquerda'] == true;
        final isDir = _currentPayload['direita'] == true;
        final isJmp = _currentPayload['pular'] == true;
        return [
          _buildFixedMetricBox(
            width: 60,
            text: 'ESQ [A]',
            color: isEsq ? Colors.cyanAccent : Colors.white54,
            borderColor: isEsq ? Colors.cyanAccent : Colors.white24,
            backgroundColor: isEsq ? Colors.cyan.withValues(alpha: 0.35) : null,
            isBold: isEsq,
          ),
          const SizedBox(width: 4),
          _buildFixedMetricBox(
            width: 60,
            text: 'DIR [D]',
            color: isDir ? Colors.cyanAccent : Colors.white54,
            borderColor: isDir ? Colors.cyanAccent : Colors.white24,
            backgroundColor: isDir ? Colors.cyan.withValues(alpha: 0.35) : null,
            isBold: isDir,
          ),
          const SizedBox(width: 4),
          _buildFixedMetricBox(
            width: 62,
            text: 'SOCO [C]',
            color: isAtk ? Colors.orangeAccent : Colors.white54,
            borderColor: isAtk ? Colors.orangeAccent : Colors.white24,
            backgroundColor: isAtk ? Colors.orange.withValues(alpha: 0.35) : null,
            isBold: isAtk,
          ),
          const SizedBox(width: 4),
          _buildFixedMetricBox(
            width: 62,
            text: 'DEF [V]',
            color: isDef ? Colors.blueAccent : Colors.white54,
            borderColor: isDef ? Colors.blueAccent : Colors.white24,
            backgroundColor: isDef ? Colors.blue.withValues(alpha: 0.35) : null,
            isBold: isDef,
          ),
          const SizedBox(width: 4),
          _buildFixedMetricBox(
            width: 62,
            text: 'PULO [W]',
            color: isJmp ? Colors.greenAccent : Colors.white54,
            borderColor: isJmp ? Colors.greenAccent : Colors.white24,
            backgroundColor: isJmp ? Colors.green.withValues(alpha: 0.35) : null,
            isBold: isJmp,
          ),
        ];

      case ControlMode.facial:
        final isSorriso = _currentPayload['pular'] == true;
        final isVirando = _currentPayload['esquerda'] == true || _currentPayload['direita'] == true;
        return [
          _buildFixedMetricBox(
            width: 78,
            text: 'SORR: ${(_smileProb * 100).toInt()}%',
            color: isSorriso ? Colors.greenAccent : Colors.white70,
            borderColor: isSorriso ? Colors.greenAccent : Colors.white24,
            backgroundColor: isSorriso ? Colors.green.withValues(alpha: 0.30) : null,
            isBold: isSorriso,
          ),
          const SizedBox(width: 4),
          _buildFixedMetricBox(
            width: 72,
            text: 'INCL: ${_headAngleZ.toStringAsFixed(0)}°',
            color: isVirando ? Colors.cyanAccent : Colors.white70,
            borderColor: isVirando ? Colors.cyanAccent : Colors.white24,
            backgroundColor: isVirando ? Colors.cyan.withValues(alpha: 0.25) : null,
            isBold: isVirando,
          ),
          const SizedBox(width: 4),
          _buildFixedMetricBox(
            width: 68,
            text: 'GIRO: ${_headAngleY.toStringAsFixed(0)}°',
            color: Colors.white70,
          ),
          const SizedBox(width: 4),
          _buildFixedMetricBox(
            width: 64,
            text: 'C/B: ${_headAngleX.toStringAsFixed(0)}°',
            color: Colors.white70,
          ),
        ];

      case ControlMode.corporal:
        final isSalto = _currentPayload['pular'] == true;
        final isTronco = _currentPayload['esquerda'] == true || _currentPayload['direita'] == true;
        final isAgacho = _currentPayload['baixo'] == true;
        return [
          _buildFixedMetricBox(
            width: 82,
            text: 'SALTO: ${_hipYDelta.toStringAsFixed(1)}',
            color: isSalto ? Colors.greenAccent : Colors.white70,
            borderColor: isSalto ? Colors.greenAccent : Colors.white24,
            backgroundColor: isSalto ? Colors.green.withValues(alpha: 0.30) : null,
            isBold: isSalto,
          ),
          const SizedBox(width: 5),
          _buildFixedMetricBox(
            width: 82,
            text: 'TRONCO: ${_shoulderTilt.toStringAsFixed(0)}',
            color: isTronco ? Colors.cyanAccent : Colors.white70,
            borderColor: isTronco ? Colors.cyanAccent : Colors.white24,
            backgroundColor: isTronco ? Colors.cyan.withValues(alpha: 0.25) : null,
            isBold: isTronco,
          ),
          const SizedBox(width: 5),
          _buildFixedMetricBox(
            width: 82,
            text: 'AGACHO: ${_legDistance.toStringAsFixed(0)}',
            color: isAgacho ? Colors.redAccent : Colors.white70,
            borderColor: isAgacho ? Colors.redAccent : Colors.white24,
            backgroundColor: isAgacho ? Colors.red.withValues(alpha: 0.30) : null,
            isBold: isAgacho,
          ),
        ];
    }
  }
}

/// Pintor do Quadrante com Círculo de Volante Virtual e Esqueleto MediaPipe Hands
class HandOverlayPainter extends CustomPainter {
  final List<Hand> hands;
  final bool isRightOpen;
  final bool isLeftOpen;
  final bool isRightThumbUp;
  final bool isLeftThumbUp;
  final bool isFrontCamera;
  final int sensorOrientation;
  final double wheelAngle;
  final bool isTurningLeft;
  final bool isTurningRight;
  final bool isNeutral;

  HandOverlayPainter({
    required this.hands,
    required this.isRightOpen,
    required this.isLeftOpen,
    this.isRightThumbUp = false,
    this.isLeftThumbUp = false,
    this.isFrontCamera = true,
    this.sensorOrientation = 270,
    this.wheelAngle = 0.0,
    this.isTurningLeft = false,
    this.isTurningRight = false,
    this.isNeutral = true,
  });

  static const List<List<int>> connections = [
    [0, 1], [1, 2], [2, 3], [3, 4],       // Polegar
    [0, 5], [5, 6], [6, 7], [7, 8],       // Indicador
    [5, 9], [9, 10], [10, 11], [11, 12],  // Médio
    [9, 13], [13, 14], [14, 15], [15, 16],// Anelar
    [13, 17], [0, 17], [17, 18], [18, 19], [19, 20], // Mindinho
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.5, size.height * 0.50);
    final radius = min(size.width, size.height) * 0.38;

    // 1. DESENHA O CÍRCULO E EIXO COM QUADRANTES (GUIA CENTRALIZADOR)
    _drawQuadrantWheel(canvas, size, center, radius);

    // 2. DESENHA O ESQUELETO E PROJEÇÃO DAS MÃOS NO QUADRANTE
    _drawHandsAndSkeletons(canvas, size, center, radius);
  }

  void _drawQuadrantWheel(Canvas canvas, Size size, Offset center, double radius) {
    // 1.1 Fundo translúcido do volante
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.22)
        ..style = PaintingStyle.fill,
    );

    // 1.2 Aro externo e secundário
    final ringColor = isNeutral
        ? const Color(0xFF00FF66).withValues(alpha: 0.50)
        : (isTurningLeft
            ? const Color(0xFF00E5FF).withValues(alpha: 0.70)
            : const Color(0xFFFF3366).withValues(alpha: 0.70));

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = ringColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    canvas.drawCircle(
      center,
      radius + 8.0,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.12)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );

    // 1.3 Marcas angulares ao redor do aro (a cada 15° de -75° a +75°)
    for (int deg = -75; deg <= 75; deg += 15) {
      final rad = (deg - 90) * (pi / 180.0);
      final bool isMajor = deg % 30 == 0;
      final tickLen = isMajor ? 12.0 : 6.0;
      final p1 = Offset(center.dx + (radius - tickLen) * cos(rad), center.dy + (radius - tickLen) * sin(rad));
      final p2 = Offset(center.dx + radius * cos(rad), center.dy + radius * sin(rad));
      canvas.drawLine(
        p1,
        p2,
        Paint()
          ..color = isMajor ? Colors.white60 : Colors.white24
          ..strokeWidth = isMajor ? 2.0 : 1.0,
      );
    }

    // 1.5 Eixo Vertical (Divisor de Quadrantes)
    final vAxisPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.20)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(center.dx, center.dy - radius - 15.0),
      Offset(center.dx, center.dy + radius + 15.0),
      vAxisPaint,
    );

    // 1.6 Eixo Horizontal (LINHA NEUTRA DO VOLANTE)
    final pLeftAxis = Offset(center.dx - radius - 30.0, center.dy);
    final pRightAxis = Offset(center.dx + radius + 30.0, center.dy);

    if (isNeutral) {
      // Quando em estado neutro: Eixo horizontal brilha intensamente em Verde Neon
      final glowPaint = Paint()
        ..color = const Color(0x9900FF66)
        ..strokeWidth = 6.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 4.0);
      canvas.drawLine(pLeftAxis, pRightAxis, glowPaint);

      final corePaint = Paint()
        ..color = const Color(0xFF00FF66)
        ..strokeWidth = 3.0;
      canvas.drawLine(pLeftAxis, pRightAxis, corePaint);

      _drawDiamond(canvas, pLeftAxis, 7.0, const Color(0xFF00FF66));
      _drawDiamond(canvas, pRightAxis, 7.0, const Color(0xFF00FF66));

      _drawCenterBadge(canvas, center, "● CENTRO (0.0°)", const Color(0xFF00FF66), Colors.black87);
    } else {
      // Em curva: Mantém a linha horizontal de referência suave visível para o usuário saber o centro
      final refAxisPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.35)
        ..strokeWidth = 1.5;
      canvas.drawLine(pLeftAxis, pRightAxis, refAxisPaint);
      _drawDiamond(canvas, pLeftAxis, 5.0, Colors.white38);
      _drawDiamond(canvas, pRightAxis, 5.0, Colors.white38);

      // Barra rotacionada do volante virtual acompanhando a inclinação das mãos
      final double angleRad = wheelAngle * (pi / 180.0);
      final double rotCos = cos(angleRad);
      final double rotSin = sin(angleRad);

      final pRotLeft = Offset(center.dx - (radius - 8.0) * rotCos, center.dy - (radius - 8.0) * rotSin);
      final pRotRight = Offset(center.dx + (radius - 8.0) * rotCos, center.dy + (radius - 8.0) * rotSin);

      final activeColor = isTurningLeft ? const Color(0xFF00E5FF) : const Color(0xFFFF3366);

      final barGlow = Paint()
        ..color = activeColor.withValues(alpha: 0.65)
        ..strokeWidth = 7.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 4.0);
      canvas.drawLine(pRotLeft, pRotRight, barGlow);

      final barCore = Paint()
        ..color = Colors.white
        ..strokeWidth = 3.0;
      canvas.drawLine(pRotLeft, pRotRight, barCore);

      _drawDiamond(canvas, pRotLeft, 8.0, activeColor);
      _drawDiamond(canvas, pRotRight, 8.0, activeColor);

      final label = isTurningLeft
          ? "◀ ESQUERDA (${wheelAngle.abs().toStringAsFixed(0)}°)"
          : "DIREITA (${wheelAngle.abs().toStringAsFixed(0)}°) ▶";
      _drawCenterBadge(canvas, center, label, activeColor, Colors.black87);
    }

    // Cubo central do volante
    canvas.drawCircle(center, 18.0, Paint()..color = const Color(0xFF1E2230)..style = PaintingStyle.fill);
    canvas.drawCircle(center, 18.0, Paint()..color = Colors.white60..style = PaintingStyle.stroke..strokeWidth = 2.0);
    canvas.drawCircle(
      center,
      5.0,
      Paint()
        ..color = isNeutral ? const Color(0xFF00FF66) : (isTurningLeft ? const Color(0xFF00E5FF) : const Color(0xFFFF3366)),
    );

    // Texto de orientação quando nenhuma mão for detectada
    if (hands.isEmpty) {
      _drawText(
        canvas,
        Offset(center.dx, center.dy - radius - 35.0),
        "POSICIONE AS MÃOS NO EIXO HORIZONTAL",
        Colors.white70,
        11.0,
      );
    }
  }

  void _drawHandsAndSkeletons(Canvas canvas, Size size, Offset center, double radius) {
    if (hands.isEmpty) return;

    final linePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.65)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    final openPaint = Paint()
      ..color = const Color(0xFF00FF66)
      ..style = PaintingStyle.fill;

    final closedPaint = Paint()
      ..color = const Color(0xFFFF9900)
      ..style = PaintingStyle.fill;

    final wristPaint = Paint()
      ..color = const Color(0xFF00E5FF)
      ..style = PaintingStyle.fill;

    Offset getPoint(Landmark lm) {
      double sx;
      double sy;
      if (sensorOrientation == 270) {
        sx = isFrontCamera ? (1.0 - lm.y) : lm.y;
        sy = 1.0 - lm.x;
      } else if (sensorOrientation == 90) {
        sx = isFrontCamera ? lm.y : (1.0 - lm.y);
        sy = lm.x;
      } else {
        sx = isFrontCamera ? (1.0 - lm.x) : lm.x;
        sy = lm.y;
      }
      return Offset(sx.clamp(0.0, 1.0) * size.width, sy.clamp(0.0, 1.0) * size.height);
    }

    final List<Offset> handCenters = [];

    for (final hand in hands) {
      if (hand.landmarks.length < 21) continue;

      // Desenha conexões ósseas
      for (final conn in connections) {
        final p1 = getPoint(hand.landmarks[conn[0]]);
        final p2 = getPoint(hand.landmarks[conn[1]]);
        canvas.drawLine(p1, p2, linePaint);
      }

      final ptWrist = getPoint(hand.landmarks[0]);
      final p5 = getPoint(hand.landmarks[5]);
      final p9 = getPoint(hand.landmarks[9]);
      final p17 = getPoint(hand.landmarks[17]);
      final handCenter = Offset(
        (ptWrist.dx + p5.dx + p9.dx + p17.dx) / 4.0,
        (ptWrist.dy + p5.dy + p9.dy + p17.dy) / 4.0,
      );
      handCenters.add(handCenter);

      final isRight = ptWrist.dx >= (size.width / 2.0);
      final isOpen = isRight ? isRightOpen : isLeftOpen;
      final isThumbActive = isRight ? isRightThumbUp : isLeftThumbUp;
      final pointPaint = isOpen ? openPaint : closedPaint;

      // Articulações
      for (int i = 0; i < hand.landmarks.length; i++) {
        final pt = getPoint(hand.landmarks[i]);
        if (i == 0) {
          canvas.drawCircle(pt, 7.0, wristPaint);
        } else if (i == 4) {
          // Polegar (Ponta - Landmark 4)
          if (isThumbActive) {
            final Color thumbColor = isRight ? const Color(0xFF00FF66) : const Color(0xFFFF3366);
            canvas.drawCircle(
              pt,
              13.0,
              Paint()
                ..color = thumbColor.withValues(alpha: 0.40)
                ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 4.0),
            );
            canvas.drawCircle(pt, 7.5, Paint()..color = thumbColor);
            canvas.drawCircle(pt, 7.5, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5);
          } else {
            canvas.drawCircle(pt, 6.5, pointPaint);
          }
        } else if (i == 8 || i == 12 || i == 16 || i == 20) {
          canvas.drawCircle(pt, 6.5, pointPaint);
        } else {
          canvas.drawCircle(pt, 3.5, linePaint);
        }
      }

      // Rótulo visual flutuante sobre o polegar ativo
      if (isThumbActive) {
        final thumbPt = getPoint(hand.landmarks[4]);
        final String actionLabel = isRight ? "👍 ACEL (W/UP)" : "👍 FREIO (S/DN)";
        final Color actionColor = isRight ? const Color(0xFF00FF66) : const Color(0xFFFF3366);
        _drawText(
          canvas,
          Offset(thumbPt.dx, thumbPt.dy - 18.0),
          actionLabel,
          actionColor,
          10.0,
        );
      }

      // Linha guia vertical conectando a mão ao eixo horizontal neutro
      final guidePaint = Paint()
        ..color = isNeutral ? const Color(0x6600FF66) : Colors.white24
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke;
      canvas.drawLine(handCenter, Offset(handCenter.dx, center.dy), guidePaint);
      canvas.drawCircle(
        Offset(handCenter.dx, center.dy),
        3.5,
        Paint()..color = isNeutral ? const Color(0xFF00FF66) : Colors.white54,
      );

      // Alvo circular na palma da mão
      canvas.drawCircle(
        handCenter,
        18.0,
        Paint()
          ..color = (isOpen ? const Color(0xFF00FF66) : const Color(0xFF00E5FF)).withValues(alpha: 0.70)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0,
      );
    }

    // Se ambas as mãos foram detectadas, conecta os centros passando pelo quadrante
    if (handCenters.length >= 2) {
      handCenters.sort((a, b) => a.dx.compareTo(b.dx));
      final pL = handCenters[0];
      final pR = handCenters[1];
      canvas.drawLine(
        pL,
        pR,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.40)
          ..strokeWidth = 1.5,
      );
    }
  }

  void _drawDiamond(Canvas canvas, Offset pt, double size, Color color) {
    final path = Path()
      ..moveTo(pt.dx, pt.dy - size)
      ..lineTo(pt.dx + size, pt.dy)
      ..lineTo(pt.dx, pt.dy + size)
      ..lineTo(pt.dx - size, pt.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.fill);
  }

  void _drawCenterBadge(Canvas canvas, Offset center, String text, Color textColor, Color bgColor) {
    final textSpan = TextSpan(
      text: text,
      style: TextStyle(
        color: textColor,
        fontSize: 12,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.5,
      ),
    );
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    )..layout();

    final badgeRect = Rect.fromCenter(
      center: Offset(center.dx, center.dy + 42.0),
      width: textPainter.width + 18.0,
      height: textPainter.height + 8.0,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(badgeRect, const Radius.circular(8)),
      Paint()..color = bgColor.withValues(alpha: 0.85)..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(badgeRect, const Radius.circular(8)),
      Paint()..color = textColor.withValues(alpha: 0.70)..style = PaintingStyle.stroke..strokeWidth = 1.5,
    );
    textPainter.paint(
      canvas,
      Offset(center.dx - textPainter.width / 2.0, center.dy + 42.0 - textPainter.height / 2.0),
    );
  }

  void _drawText(Canvas canvas, Offset center, String text, Color color, double fontSize) {
    final textSpan = TextSpan(
      text: text,
      style: TextStyle(
        color: color,
        fontSize: fontSize,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.8,
      ),
    );
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      Offset(center.dx - textPainter.width / 2.0, center.dy - textPainter.height / 2.0),
    );
  }

  @override
  bool shouldRepaint(covariant HandOverlayPainter oldDelegate) => true;
}

/// Pintor do Modo FPS Tático (Mira Reticular, Luneta Sniper, Cano da Arma e Efeitos de Tiro)
class FpsOverlayPainter extends CustomPainter {
  final List<Hand> hands;
  final Offset crosshairPos;
  final bool isGunActive;
  final bool isZoom;
  final bool isFiring;
  final bool isReloading;
  final bool twoHandsLocked;
  final bool isFrontCamera;
  final int sensorOrientation;

  FpsOverlayPainter({
    required this.hands,
    required this.crosshairPos,
    required this.isGunActive,
    required this.isZoom,
    required this.isFiring,
    required this.isReloading,
    required this.twoHandsLocked,
    this.isFrontCamera = true,
    this.sensorOrientation = 270,
  });

  static const List<List<int>> connections = [
    [0, 1], [1, 2], [2, 3], [3, 4],       // Polegar
    [0, 5], [5, 6], [6, 7], [7, 8],       // Indicador (Cano da arma)
    [5, 9], [9, 10], [10, 11], [11, 12],  // Médio
    [9, 13], [13, 14], [14, 15], [15, 16],// Anelar
    [13, 17], [0, 17], [17, 18], [18, 19], [19, 20], // Mindinho
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final aimPoint = Offset(
      crosshairPos.dx * size.width,
      crosshairPos.dy * size.height,
    );

    // 1. Desenha o esqueleto das mãos (destacando o indicador da arma e dedão)
    _drawHandSkeletons(canvas, size);

    // 2. Retículo Tático / Mira FPS
    _drawCrosshair(canvas, size, aimPoint);

    // 3. Se Zoom estiver ativo (👍), desenha Luneta / Sniper Scope
    if (isZoom) {
      _drawSniperScope(canvas, size, aimPoint);
    }

    // 4. Se houver Disparo / Tiro, desenha Flash de Fogo (Muzzle Flash)
    if (isFiring) {
      _drawMuzzleFlash(canvas, aimPoint);
    }

    // 5. Se estiver Recarregando, desenha Badge de Recarga (R)
    if (isReloading) {
      _drawReloadBadge(canvas, aimPoint);
    }
  }

  void _drawHandSkeletons(Canvas canvas, Size size) {
    final List<Offset> wrists = [];

    for (int hIdx = 0; hIdx < hands.length; hIdx++) {
      final hand = hands[hIdx];
      if (hand.landmarks.length < 21) continue;

      final pts = hand.landmarks.map((lm) {
        double sx;
        double sy;
        if (sensorOrientation == 270) {
          sx = isFrontCamera ? (1.0 - lm.y) : lm.y;
          sy = 1.0 - lm.x;
        } else if (sensorOrientation == 90) {
          sx = isFrontCamera ? lm.y : (1.0 - lm.y);
          sy = lm.x;
        } else {
          sx = isFrontCamera ? (1.0 - lm.x) : lm.x;
          sy = lm.y;
        }
        return Offset(sx * size.width, sy * size.height);
      }).toList();

      wrists.add(pts[0]);

      // Conexões ósseas
      for (final conn in connections) {
        final pA = pts[conn[0]];
        final pB = pts[conn[1]];

        Color boneColor;
        double boneWidth = 2.0;

        // Destaque para o dedo indicador (Cano da Arma e Mira)
        if ((conn[0] >= 5 && conn[0] <= 8) && (conn[1] >= 5 && conn[1] <= 8)) {
          boneColor = const Color(0xFF00FFCC); // Ciano neon brilhante
          boneWidth = 3.5;
        }
        // Destaque para o dedo médio (Gatilho de Tiro - Fechar o dedo)
        else if ((conn[0] >= 9 && conn[0] <= 12) && (conn[1] >= 9 && conn[1] <= 12)) {
          boneColor = isFiring ? const Color(0xFFFF3300) : const Color(0xFFFF9900);
          boneWidth = isFiring ? 4.0 : 2.5;
        }
        // Destaque para o dedão (Zoom Frontal)
        else if ((conn[0] >= 1 && conn[0] <= 4) && (conn[1] >= 1 && conn[1] <= 4)) {
          boneColor = isZoom ? const Color(0xFF00E5FF) : Colors.amberAccent.withValues(alpha: 0.6);
          boneWidth = isZoom ? 4.0 : 2.0;
        } else {
          boneColor = Colors.white.withValues(alpha: 0.35);
        }

        canvas.drawLine(
          pA,
          pB,
          Paint()
            ..color = boneColor
            ..strokeWidth = boneWidth
            ..strokeCap = StrokeCap.round,
        );
      }

      // Pontas dos dedos
      for (int i = 0; i < pts.length; i++) {
        Color dotColor = Colors.white54;
        double dotRadius = 3.0;

        if (i == 8) {
          // Ponta da mira (Indicador)
          dotColor = const Color(0xFF00FFCC);
          dotRadius = 6.0;
        } else if (i == 12) {
          // Ponta do gatilho (Dedo Médio)
          dotColor = isFiring ? const Color(0xFFFF3300) : const Color(0xFFFF9900);
          dotRadius = isFiring ? 7.0 : 4.5;
        } else if (i == 4) {
          // Ponta do zoom (Dedão Frontal)
          dotColor = isZoom ? const Color(0xFF00E5FF) : Colors.amberAccent;
          dotRadius = isZoom ? 7.0 : 4.0;
        }

        canvas.drawCircle(pts[i], dotRadius, Paint()..color = dotColor);
      }
    }

    // Se as duas mãos estiverem conectadas na base, desenha o elo de combate
    if (wrists.length >= 2) {
      final p1 = wrists[0];
      final p2 = wrists[1];

      final lockColor = twoHandsLocked
          ? const Color(0xFF00FF66).withValues(alpha: 0.8)
          : Colors.white24;

      canvas.drawLine(
        p1,
        p2,
        Paint()
          ..color = lockColor
          ..strokeWidth = twoHandsLocked ? 3.0 : 1.5
          ..strokeCap = StrokeCap.round,
      );

      final mid = Offset((p1.dx + p2.dx) / 2.0, (p1.dy + p2.dy) / 2.0);
      canvas.drawCircle(
        mid,
        5.0,
        Paint()..color = lockColor,
      );
    }
  }

  void _drawCrosshair(Canvas canvas, Size size, Offset aim) {
    final reticleColor = isFiring
        ? const Color(0xFFFF3333)
        : (isZoom ? const Color(0xFF00E5FF) : const Color(0xFF00FF66));

    final paintStroke = Paint()
      ..color = reticleColor
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    // Círculo central da mira
    canvas.drawCircle(aim, 14.0, paintStroke);

    // Ponto central vermelho/verde
    canvas.drawCircle(aim, 2.5, Paint()..color = reticleColor..style = PaintingStyle.fill);

    // Retículo em cruz: 4 traços externos
    const double gap = 16.0;
    const double len = 12.0;

    canvas.drawLine(Offset(aim.dx - gap - len, aim.dy), Offset(aim.dx - gap, aim.dy), paintStroke);
    canvas.drawLine(Offset(aim.dx + gap, aim.dy), Offset(aim.dx + gap + len, aim.dy), paintStroke);
    canvas.drawLine(Offset(aim.dx, aim.dy - gap - len), Offset(aim.dx, aim.dy - gap), paintStroke);
    canvas.drawLine(Offset(aim.dx, aim.dy + gap), Offset(aim.dx, aim.dy + gap + len), paintStroke);
  }

  void _drawSniperScope(Canvas canvas, Size size, Offset aim) {
    // Círculo maior simulando luneta telescópica
    canvas.drawCircle(
      aim,
      65.0,
      Paint()
        ..color = const Color(0xFF00E5FF).withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );

    // Linhas finas de medição mil-dot
    final scopeLinePaint = Paint()
      ..color = const Color(0xFF00E5FF).withValues(alpha: 0.5)
      ..strokeWidth = 1.0;

    canvas.drawLine(Offset(aim.dx - 65, aim.dy), Offset(aim.dx + 65, aim.dy), scopeLinePaint);
    canvas.drawLine(Offset(aim.dx, aim.dy - 65), Offset(aim.dx, aim.dy + 65), scopeLinePaint);

    // Texto ZOOM [M2]
    const span = TextSpan(
      text: 'ZOOM [M2]',
      style: TextStyle(
        color: Color(0xFF00E5FF),
        fontSize: 10,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.0,
      ),
    );
    final tp = TextPainter(text: span, textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, Offset(aim.dx - tp.width / 2.0, aim.dy - 82.0));
  }

  void _drawMuzzleFlash(Canvas canvas, Offset aim) {
    // Efeito de flash de disparo com anéis em expansão
    canvas.drawCircle(
      aim,
      28.0,
      Paint()
        ..color = const Color(0xFFFF3300).withValues(alpha: 0.6)
        ..style = PaintingStyle.fill,
    );

    canvas.drawCircle(
      aim,
      38.0,
      Paint()
        ..color = const Color(0xFFFFCC00).withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0,
    );
  }

  void _drawReloadBadge(Canvas canvas, Offset aim) {
    const span = TextSpan(
      text: 'RELOAD [R]',
      style: TextStyle(
        color: Colors.amberAccent,
        fontSize: 12,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
      ),
    );
    final tp = TextPainter(text: span, textDirection: TextDirection.ltr)..layout();

    final r = Rect.fromCenter(
      center: Offset(aim.dx, aim.dy + 42.0),
      width: tp.width + 20.0,
      height: tp.height + 8.0,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(r, const Radius.circular(8)),
      Paint()..color = Colors.black.withValues(alpha: 0.85)..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(r, const Radius.circular(8)),
      Paint()..color = Colors.amberAccent..style = PaintingStyle.stroke..strokeWidth = 1.5,
    );

    tp.paint(canvas, Offset(aim.dx - tp.width / 2.0, aim.dy + 42.0 - tp.height / 2.0));
  }

  @override
  bool shouldRepaint(covariant FpsOverlayPainter oldDelegate) => true;
}

/// Pintor do Modo Luta (Esqueleto Corporal, Guias de Deslocamento Lateral A/D, Efeitos de Soco e Escudo X)
class FightOverlayPainter extends CustomPainter {
  final List<Pose> poses;
  final bool isAttacking;
  final bool isDefending;
  final bool isJumping;
  final bool isMovingLeft;
  final bool isMovingRight;
  final double bodySway;
  final bool isFrontCamera;
  final int sensorOrientation;
  final Size? previewSize;

  FightOverlayPainter({
    required this.poses,
    required this.isAttacking,
    required this.isDefending,
    required this.isJumping,
    required this.isMovingLeft,
    required this.isMovingRight,
    required this.bodySway,
    this.isFrontCamera = true,
    this.sensorOrientation = 270,
    this.previewSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Eixo Central e Zonas de Movimento Lateral (A e D)
    _drawSwayGuides(canvas, size);

    if (poses.isEmpty) return;
    final pose = poses.first;

    final double imgW = (sensorOrientation == 90 || sensorOrientation == 270)
        ? (previewSize?.height.toDouble() ?? size.width)
        : (previewSize?.width.toDouble() ?? size.width);
    final double imgH = (sensorOrientation == 90 || sensorOrientation == 270)
        ? (previewSize?.width.toDouble() ?? size.height)
        : (previewSize?.height.toDouble() ?? size.height);

    final double scaleX = size.width / imgW;
    final double scaleY = size.height / imgH;

    // Helper de conversão para espaço de tela em pixels
    Offset? pt(PoseLandmarkType type) {
      final lm = pose.landmarks[type];
      if (lm == null) return null;

      final double px = lm.x * scaleX;
      final double py = lm.y * scaleY;

      // Se câmera frontal, espelha horizontalmente para coincidir com a CameraPreview espelhada
      final double sx = isFrontCamera ? (size.width - px) : px;
      final double sy = py;

      return Offset(sx.clamp(0.0, size.width), sy.clamp(0.0, size.height));
    }

    final pNose = pt(PoseLandmarkType.nose);
    final pRs = pt(PoseLandmarkType.rightShoulder);
    final pLs = pt(PoseLandmarkType.leftShoulder);
    final pRe = pt(PoseLandmarkType.rightElbow);
    final pLe = pt(PoseLandmarkType.leftElbow);
    final pRw = pt(PoseLandmarkType.rightWrist);
    final pLw = pt(PoseLandmarkType.leftWrist);
    final pRh = pt(PoseLandmarkType.rightHip);
    final pLh = pt(PoseLandmarkType.leftHip);
    final pRk = pt(PoseLandmarkType.rightKnee);
    final pLk = pt(PoseLandmarkType.leftKnee);
    final pRa = pt(PoseLandmarkType.rightAnkle);
    final pLa = pt(PoseLandmarkType.leftAnkle);

    final bonePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;

    void drawBone(Offset? a, Offset? b, [Paint? customPaint]) {
      if (a != null && b != null) {
        canvas.drawLine(a, b, customPaint ?? bonePaint);
      }
    }

    // Torso e Cabeça
    if (pNose != null) {
      canvas.drawCircle(
        pNose,
        14.0,
        Paint()..color = const Color(0xFFFF5722).withValues(alpha: 0.35)..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        pNose,
        14.0,
        Paint()..color = const Color(0xFFFF5722)..style = PaintingStyle.stroke..strokeWidth = 2.0,
      );
    }
    drawBone(pRs, pLs);
    drawBone(pRh, pLh);
    if (pRs != null && pLs != null && pRh != null && pLh != null) {
      final sMid = Offset((pRs.dx + pLs.dx) / 2, (pRs.dy + pLs.dy) / 2);
      final hMid = Offset((pRh.dx + pLh.dx) / 2, (pRh.dy + pLh.dy) / 2);
      drawBone(sMid, hMid, Paint()..color = const Color(0xFFFF5722)..strokeWidth = 4.0..strokeCap = StrokeCap.round);
    }

    // Pernas
    drawBone(pRh, pRk);
    drawBone(pRk, pRa);
    drawBone(pLh, pLk);
    drawBone(pLk, pLa);

    // Braços com Estados Dinâmicos de Combate:
    if (isDefending) {
      // Efeito de Defesa com Braços em X (Aura de Escudo Azul/Índigo)
      final shieldPaint = Paint()
        ..color = const Color(0xFF2979FF)
        ..strokeWidth = 5.0
        ..strokeCap = StrokeCap.round;
      drawBone(pRs, pRe, shieldPaint);
      drawBone(pRe, pRw, shieldPaint);
      drawBone(pLs, pLe, shieldPaint);
      drawBone(pLe, pLw, shieldPaint);

      // Círculo de Escudo Protetor no ponto de cruzamento dos braços
      if (pRw != null && pLw != null) {
        final shieldCenter = Offset((pRw.dx + pLw.dx) / 2, (pRw.dy + pLw.dy) / 2);
        canvas.drawCircle(
          shieldCenter,
          48.0,
          Paint()
            ..color = const Color(0xFF2979FF).withValues(alpha: 0.30)
            ..style = PaintingStyle.fill
            ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 8.0),
        );
        canvas.drawCircle(
          shieldCenter,
          48.0,
          Paint()
            ..color = const Color(0xFF2979FF)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3.0,
        );

        // Ícone / Texto de Defesa [V]
        final tp = TextPainter(
          text: const TextSpan(
            text: 'DEFESA [V]',
            style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(shieldCenter.dx - tp.width / 2, shieldCenter.dy - tp.height / 2));
      }
    } else if (isAttacking) {
      // Efeito de Ataque com Soco (Brilho Laranja/Vermelho Fogo)
      final punchPaint = Paint()
        ..color = const Color(0xFFFF3D00)
        ..strokeWidth = 5.0
        ..strokeCap = StrokeCap.round;
      drawBone(pRs, pRe, punchPaint);
      drawBone(pRe, pRw, punchPaint);
      drawBone(pLs, pLe, punchPaint);
      drawBone(pLe, pLw, punchPaint);

      // Ondas de Impacto no Punho de Ataque
      final punchFist = (pRw != null && pRs != null && (pRw.dy < pRs.dy + 40)) ? pRw : pLw;
      if (punchFist != null) {
        canvas.drawCircle(
          punchFist,
          26.0,
          Paint()
            ..color = const Color(0xFFFF9100).withValues(alpha: 0.50)
            ..style = PaintingStyle.fill,
        );
        canvas.drawCircle(
          punchFist,
          34.0,
          Paint()
            ..color = const Color(0xFFFF3D00)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3.0,
        );
      }
    } else {
      // Guarda Padrão
      final guardPaint = Paint()
        ..color = const Color(0xFFFFAB91)
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round;
      drawBone(pRs, pRe, guardPaint);
      drawBone(pRe, pRw, guardPaint);
      drawBone(pLs, pLe, guardPaint);
      drawBone(pLe, pLw, guardPaint);
    }

    // Desenha articulações corporais com feedback visual nítido
    final jointFill = Paint()..color = const Color(0xFFFF5722)..style = PaintingStyle.fill;
    final jointStroke = Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5;
    for (final p in [pRs, pLs, pRe, pLe, pRw, pLw, pRh, pLh, pRk, pLk, pRa, pLa]) {
      if (p != null) {
        canvas.drawCircle(p, 5.0, jointFill);
        canvas.drawCircle(p, 5.0, jointStroke);
      }
    }

    // Indicador de Pulo no topo
    if (isJumping) {
      final jumpCenter = Offset(size.width * 0.5, size.height * 0.22);
      final jumpPath = Path()
        ..moveTo(jumpCenter.dx, jumpCenter.dy - 24)
        ..lineTo(jumpCenter.dx + 20, jumpCenter.dy)
        ..lineTo(jumpCenter.dx - 20, jumpCenter.dy)
        ..close();
      canvas.drawPath(jumpPath, Paint()..color = const Color(0xFF00E676)..style = PaintingStyle.fill);

      final tp = TextPainter(
        text: const TextSpan(
          text: 'PULO [W]',
          style: TextStyle(
            color: Color(0xFF00E676),
            fontSize: 14,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.0,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(jumpCenter.dx - tp.width / 2, jumpCenter.dy + 8));
    }
  }

  void _drawSwayGuides(Canvas canvas, Size size) {
    final centerX = size.width * 0.5;
    final bottomY = size.height * 0.85;

    // Linha de Eixo Central
    final axisPaint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(centerX, size.height * 0.20), Offset(centerX, bottomY), axisPaint);

    // Corredor de Zona Morta (±12% da largura)
    final corridorW = size.width * 0.12;
    canvas.drawRect(
      Rect.fromLTRB(centerX - corridorW, size.height * 0.25, centerX + corridorW, bottomY),
      Paint()..color = Colors.white.withValues(alpha: 0.03)..style = PaintingStyle.fill,
    );

    // Setas e Indicadores de Direção Lateral:
    final leftColor = isMovingLeft ? Colors.cyanAccent : Colors.white30;
    final rightColor = isMovingRight ? Colors.cyanAccent : Colors.white30;

    // Indicador Esquerda [A]
    final leftTp = TextPainter(
      text: TextSpan(
        text: '◄ A (ESQUERDA)',
        style: TextStyle(
          color: leftColor,
          fontSize: 12,
          fontWeight: isMovingLeft ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    leftTp.paint(canvas, Offset(size.width * 0.08, bottomY - 30));

    // Indicador Direita [D]
    final rightTp = TextPainter(
      text: TextSpan(
        text: 'D (DIREITA) ►',
        style: TextStyle(
          color: rightColor,
          fontSize: 12,
          fontWeight: isMovingRight ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    rightTp.paint(canvas, Offset(size.width * 0.92 - rightTp.width, bottomY - 30));
  }

  @override
  bool shouldRepaint(covariant FightOverlayPainter oldDelegate) => true;
}

/// Pintor HUD Futurista para o Modo FPS Ocular / Mesh (CS 1.6 / Head & Eye Tracking)
class FpsMeshOverlayPainter extends CustomPainter {
  final List<Face> faces;
  final double filteredDx;
  final double filteredDy;
  final double joyRx;
  final double joyRy;
  final double joyLx;
  final double joyLy;
  final bool isFiring;
  final bool isZoom;
  final bool isReloading;
  final bool cmdW;
  final bool cmdA;
  final bool cmdS;
  final bool cmdD;
  final double blinkLeft;
  final double blinkRight;
  final bool isFrontCamera;
  final int sensorOrientation;
  final Size? previewSize;

  FpsMeshOverlayPainter({
    required this.faces,
    required this.filteredDx,
    required this.filteredDy,
    this.joyRx = 0.0,
    this.joyRy = 0.0,
    this.joyLx = 0.0,
    this.joyLy = 0.0,
    required this.isFiring,
    required this.isZoom,
    required this.isReloading,
    required this.cmdW,
    required this.cmdA,
    required this.cmdS,
    required this.cmdD,
    required this.blinkLeft,
    required this.blinkRight,
    this.isFrontCamera = true,
    this.sensorOrientation = 270,
    this.previewSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.5, size.height * 0.5);

    // 1. Linhas Guias e Indicadores Direcionais WASD (Movimentação da Cabeça)
    _drawWasdHud(canvas, size, center);

    // 2. Retículo Central de Mira Ocular
    _drawEyeGazeReticle(canvas, size, center);

    // 3. HUD de Joysticks Virtuais Analógicos Duplos (L-Stick Cabeça e R-Stick Olhos)
    _drawDualVirtualJoysticks(canvas, size);

    if (faces.isEmpty) return;
    final face = faces.first;

    final double imgW = (sensorOrientation == 90 || sensorOrientation == 270)
        ? (previewSize?.height.toDouble() ?? size.width)
        : (previewSize?.width.toDouble() ?? size.width);
    final double imgH = (sensorOrientation == 90 || sensorOrientation == 270)
        ? (previewSize?.width.toDouble() ?? size.height)
        : (previewSize?.height.toDouble() ?? size.height);

    final double scaleX = size.width / imgW;
    final double scaleY = size.height / imgH;

    Offset? mapPt(Point<int>? p) {
      if (p == null) return null;
      final double px = p.x * scaleX;
      final double py = p.y * scaleY;
      final double sx = isFrontCamera ? (size.width - px) : px;
      return Offset(sx.clamp(0.0, size.width), py.clamp(0.0, size.height));
    }

    // 4. Contornos Faciais / Malha Sci-Fi
    final meshPaint = Paint()
      ..color = const Color(0xFF00E5FF).withValues(alpha: 0.35)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    void drawContour(FaceContourType type, {bool close = false, Paint? customPaint}) {
      final contour = face.contours[type];
      if (contour == null || contour.points.length < 2) return;
      final path = Path();
      final p0 = mapPt(contour.points.first);
      if (p0 == null) return;
      path.moveTo(p0.dx, p0.dy);
      for (int i = 1; i < contour.points.length; i++) {
        final pt = mapPt(contour.points[i]);
        if (pt != null) path.lineTo(pt.dx, pt.dy);
      }
      if (close) path.close();
      canvas.drawPath(path, customPaint ?? meshPaint);
    }

    drawContour(FaceContourType.face);
    drawContour(FaceContourType.leftEyebrowTop);
    drawContour(FaceContourType.rightEyebrowTop);
    drawContour(FaceContourType.noseBridge);
    drawContour(FaceContourType.noseBottom);
    drawContour(FaceContourType.upperLipTop);
    drawContour(FaceContourType.lowerLipBottom);

    // 5. Olhos em Alta Evidência (Ações de Tiro e Zoom)
    final eyeLeftPaint = Paint()
      ..color = isFiring ? Colors.redAccent : const Color(0xFF00FF66).withValues(alpha: 0.7)
      ..strokeWidth = isFiring ? 2.5 : 1.5
      ..style = isFiring ? PaintingStyle.fill : PaintingStyle.stroke;

    final eyeRightPaint = Paint()
      ..color = isZoom ? Colors.cyanAccent : const Color(0xFF00FF66).withValues(alpha: 0.7)
      ..strokeWidth = isZoom ? 2.5 : 1.5
      ..style = isZoom ? PaintingStyle.fill : PaintingStyle.stroke;

    drawContour(FaceContourType.leftEye, close: true, customPaint: eyeLeftPaint);
    drawContour(FaceContourType.rightEye, close: true, customPaint: eyeRightPaint);

    // 6. Marcador no Nariz (Ponto Central de Equilíbrio da Cabeça)
    final pNose = mapPt(face.landmarks[FaceLandmarkType.noseBase]?.position);
    if (pNose != null) {
      canvas.drawCircle(
        pNose,
        4.0,
        Paint()..color = const Color(0xFF00E5FF)..style = PaintingStyle.fill,
      );
    }
  }

  void _drawWasdHud(Canvas canvas, Size size, Offset center) {
    // Zona morta central de repouso da cabeça e olhar
    final deadzonePaint = Paint()
      ..color = Colors.white12
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(center, 0.075 * 200.0, deadzonePaint);

    // Indicadores WASD ao redor da tela
    void drawWasdLabel(String text, Offset pos, bool active, Color activeColor) {
      final color = active ? activeColor : Colors.white30;
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: color,
            fontSize: 13,
            fontWeight: active ? FontWeight.bold : FontWeight.w600,
            shadows: active
                ? [
                    Shadow(color: activeColor.withValues(alpha: 0.8), blurRadius: 10),
                  ]
                : null,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(pos.dx - tp.width * 0.5, pos.dy - tp.height * 0.5));
    }

    const double margin = 48.0;
    // CIMA: W (Pitch para cima)
    drawWasdLabel('▲ W (FRENTE)', Offset(center.dx, center.dy - 110.0), cmdW, const Color(0xFF00E5FF));
    // BAIXO: S (Pitch para baixo)
    drawWasdLabel('▼ S (RÉ)', Offset(center.dx, center.dy + 110.0), cmdS, const Color(0xFF00E5FF));
    // ESQUERDA: A
    drawWasdLabel('◄ A (ESQ)', Offset(margin + 20, center.dy), cmdA, const Color(0xFF00E5FF));
    // DIREITA: D
    drawWasdLabel('D (DIR) ►', Offset(size.width - margin - 20, center.dy), cmdD, const Color(0xFF00E5FF));
  }

  void _drawEyeGazeReticle(Canvas canvas, Size size, Offset center) {
    // Posição dinâmica da mira guiada pelo olhar com filtro anti-tremor
    final reticlePos = Offset(
      (center.dx + filteredDx * 240.0).clamp(20.0, size.width - 20.0),
      (center.dy + filteredDy * 240.0).clamp(20.0, size.height - 20.0),
    );

    final reticleColor = isFiring
        ? Colors.redAccent
        : (isZoom
            ? Colors.cyanAccent
            : (isReloading ? Colors.amberAccent : const Color(0xFF00FFCC)));

    final reticlePaint = Paint()
      ..color = reticleColor
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    // Círculo central da mira
    canvas.drawCircle(reticlePos, 14.0, reticlePaint);
    canvas.drawCircle(
      reticlePos,
      2.5,
      Paint()..color = reticleColor..style = PaintingStyle.fill,
    );

    // Crosshairs clássicos do Counter-Strike
    const chLen = 18.0;
    const chGap = 6.0;
    canvas.drawLine(
      Offset(reticlePos.dx - chGap - chLen, reticlePos.dy),
      Offset(reticlePos.dx - chGap, reticlePos.dy),
      reticlePaint,
    );
    canvas.drawLine(
      Offset(reticlePos.dx + chGap, reticlePos.dy),
      Offset(reticlePos.dx + chGap + chLen, reticlePos.dy),
      reticlePaint,
    );
    canvas.drawLine(
      Offset(reticlePos.dx, reticlePos.dy - chGap - chLen),
      Offset(reticlePos.dx, reticlePos.dy - chGap),
      reticlePaint,
    );
    canvas.drawLine(
      Offset(reticlePos.dx, reticlePos.dy + chGap),
      Offset(reticlePos.dx, reticlePos.dy + chGap + chLen),
      reticlePaint,
    );

    // Se estiver atirando ou com zoom, desenha anel pulsante extra
    if (isFiring || isZoom) {
      canvas.drawCircle(
        reticlePos,
        22.0,
        Paint()
          ..color = reticleColor.withValues(alpha: 0.45)
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke,
      );
    }
  }

  void _drawDualVirtualJoysticks(Canvas canvas, Size size) {
    const double podRadius = 38.0;
    const double stickTravel = 22.0;

    // Pod Esquerdo: L-Stick (Movimentação / WASD via Cabeça)
    final lPodCenter = Offset(62.0, size.height - 110.0);
    final lStickOffset = Offset(
      lPodCenter.dx + (joyLx * stickTravel).clamp(-stickTravel, stickTravel),
      lPodCenter.dy - (joyLy * stickTravel).clamp(-stickTravel, stickTravel),
    );

    // Pod Direito: R-Stick (Mira / Look via Olhos)
    final rPodCenter = Offset(size.width - 62.0, size.height - 110.0);
    final rStickOffset = Offset(
      rPodCenter.dx + (joyRx * stickTravel).clamp(-stickTravel, stickTravel),
      rPodCenter.dy - (joyRy * stickTravel).clamp(-stickTravel, stickTravel),
    );

    void drawPodBase(Offset center, String label, String sub, Color accent) {
      // Base circle
      canvas.drawCircle(
        center,
        podRadius,
        Paint()
          ..color = Colors.black54
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        center,
        podRadius,
        Paint()
          ..color = accent.withValues(alpha: 0.40)
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke,
      );
      // Deadzone ring
      canvas.drawCircle(
        center,
        podRadius * 0.32,
        Paint()
          ..color = Colors.white12
          ..strokeWidth = 1.0
          ..style = PaintingStyle.stroke,
      );
      // Cross axes
      final axisPaint = Paint()
        ..color = Colors.white12
        ..strokeWidth = 1.0;
      canvas.drawLine(Offset(center.dx - podRadius, center.dy), Offset(center.dx + podRadius, center.dy), axisPaint);
      canvas.drawLine(Offset(center.dx, center.dy - podRadius), Offset(center.dx, center.dy + podRadius), axisPaint);

      // Sublabel
      final tp = TextPainter(
        text: TextSpan(
          text: '$label\n$sub',
          style: TextStyle(
            color: accent,
            fontSize: 9.5,
            fontWeight: FontWeight.bold,
            height: 1.1,
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(center.dx - tp.width * 0.5, center.dy + podRadius + 4.0));
    }

    void drawThumbKnob(Offset stickPos, Color color, bool active) {
      canvas.drawCircle(
        stickPos,
        14.0,
        Paint()
          ..color = (active ? color : Colors.white70).withValues(alpha: 0.85)
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        stickPos,
        14.0,
        Paint()
          ..color = Colors.white
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke,
      );
      canvas.drawCircle(
        stickPos,
        3.0,
        Paint()
          ..color = Colors.black87
          ..style = PaintingStyle.fill,
      );
    }

    // Desenha L-Stick
    final bool lActive = joyLx.abs() > 0.05 || joyLy.abs() > 0.05;
    drawPodBase(lPodCenter, 'L-STICK', 'CABEÇA', const Color(0xFF00E5FF));
    drawThumbKnob(lStickOffset, const Color(0xFF00E5FF), lActive);

    // Desenha R-Stick
    final bool rActive = joyRx.abs() > 0.05 || joyRy.abs() > 0.05;
    drawPodBase(rPodCenter, 'R-STICK', 'OLHOS', const Color(0xFF00FFCC));
    drawThumbKnob(rStickOffset, const Color(0xFF00FFCC), rActive);

    // Badges de Gatilhos Superiores (LT / RT)
    void drawTriggerBadge(Offset pos, String text, bool triggered, Color trigColor) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: triggered ? Colors.white : trigColor,
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: pos, width: tp.width + 12, height: tp.height + 6),
        const Radius.circular(4),
      );
      canvas.drawRRect(
        rect,
        Paint()
          ..color = triggered ? trigColor.withValues(alpha: 0.85) : Colors.black45
          ..style = PaintingStyle.fill,
      );
      canvas.drawRRect(
        rect,
        Paint()
          ..color = trigColor
          ..strokeWidth = 1.0
          ..style = PaintingStyle.stroke,
      );
      tp.paint(canvas, Offset(pos.dx - tp.width * 0.5, pos.dy - tp.height * 0.5));
    }

    drawTriggerBadge(
      Offset(lPodCenter.dx, lPodCenter.dy - podRadius - 14.0),
      isZoom ? 'LT [ZOOM]' : 'LT PISCA D',
      isZoom,
      Colors.cyanAccent,
    );

    drawTriggerBadge(
      Offset(rPodCenter.dx, rPodCenter.dy - podRadius - 14.0),
      isFiring ? 'RT [FOGO]' : 'RT PISCA E',
      isFiring,
      Colors.redAccent,
    );
  }

  @override
  bool shouldRepaint(covariant FpsMeshOverlayPainter oldDelegate) => true;
}


