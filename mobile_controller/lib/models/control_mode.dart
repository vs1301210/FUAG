import 'package:flutter/material.dart';

/// Modos de controle de acessibilidade suportados pelo aplicativo.
enum ControlMode {
  facial,
  gestual,
  corporal,
  fps,
  fight,
  fpsMesh,
}

extension ControlModeDetails on ControlMode {
  String get title {
    switch (this) {
      case ControlMode.facial:
        return 'Controle Facial';
      case ControlMode.gestual:
        return 'Volante Virtual (Mãos/Braços)';
      case ControlMode.corporal:
        return 'Controle de Corpo Inteiro';
      case ControlMode.fps:
        return 'Modo FPS Tático (Arma)';
      case ControlMode.fight:
        return 'Modo Luta (Stick Fight)';
      case ControlMode.fpsMesh:
        return 'Modo FPS Ocular/Mesh';
    }
  }

  String get shortName {
    switch (this) {
      case ControlMode.facial:
        return 'Facial';
      case ControlMode.gestual:
        return 'Volante';
      case ControlMode.corporal:
        return 'Corporal';
      case ControlMode.fps:
        return 'FPS (Arma)';
      case ControlMode.fight:
        return 'Luta';
      case ControlMode.fpsMesh:
        return 'FPS Ocular';
    }
  }

  String get description {
    switch (this) {
      case ControlMode.facial:
        return 'Sorria para pular e incline a cabeça para virar a moto para esquerda ou direita.';
      case ControlMode.gestual:
        return 'Segure um volante virtual: gire as mãos para curvar e abra as mãos para acelerar!';
      case ControlMode.corporal:
        return 'Pule fisicamente para saltar, incline o tronco para os lados e agache para frear.';
      case ControlMode.fps:
        return 'Gesto de arma: aponte o indicador para mirar, feche o dedo médio para atirar e dedão frontal para zoom.';
      case ControlMode.fight:
        return 'Luta com corpo inteiro: soque com os braços (C), cruze em X para defender (V), mova o corpo para os lados (A/D) e pule (W).';
      case ControlMode.fpsMesh:
        return 'CS 1.6 sem mãos: Movimentação WASD pela inclinação/giro da cabeça, mira pelo olhar e disparos por piscadas intencionais.';
    }
  }

  IconData get icon {
    switch (this) {
      case ControlMode.facial:
        return Icons.face;
      case ControlMode.gestual:
        return Icons.sports_kabaddi;
      case ControlMode.corporal:
        return Icons.accessibility_new;
      case ControlMode.fps:
        return Icons.gps_fixed;
      case ControlMode.fight:
        return Icons.sports_mma;
      case ControlMode.fpsMesh:
        return Icons.remove_red_eye_rounded;
    }
  }

  Color get color {
    switch (this) {
      case ControlMode.facial:
        return const Color(0xFF00FF66);
      case ControlMode.gestual:
        return const Color(0xFF00D4FF);
      case ControlMode.corporal:
        return const Color(0xFFFF9900);
      case ControlMode.fps:
        return const Color(0xFFFF3366);
      case ControlMode.fight:
        return const Color(0xFFFF5722);
      case ControlMode.fpsMesh:
        return const Color(0xFF00E5FF);
    }
  }
}
