# 📱 Mobile Controller (Tecnologia Assistiva via IA para Godot 4)

Aplicativo móvel Flutter que atua como **Controle de Acessibilidade via Visão Computacional na Borda (Edge AI)** para o jogo Godot 4 (**Pixel Delivery**).

---

## 🧠 Como Funciona

1. **Captura:** O app utiliza a câmera frontal do smartphone.
2. **Inferência:** Executa o **Google ML Kit Face Detection** com classificação de sorriso e rastreamento de rotação da cabeça (Euler Angle Z).
3. **Mapeamento de Regras:**
   - **Sorriso > 60%** $\rightarrow$ `pular: true` (Acelera / Salta)
   - **Inclinação Z < -15°** (cabeça para direita) $\rightarrow$ `direita: true`
   - **Inclinação Z > +15°** (cabeça para esquerda) $\rightarrow$ `esquerda: true`
4. **Comunicação UDP Zero-Config:**
   - Envia pacotes UDP Broadcast para `255.255.255.255:5000`.
   - Compatível imediatamente com o autoload `HandInputManager` do Godot 4.
   - Não requer digitação de endereço IP.

---

## 🚀 Como Compilar e Rodar no Celular

Com o aparelho conectado via USB e a **Depuração USB** ativada:

```bash
cd mobile_controller
flutter pub get
flutter run --release
```

---

## ⚡ Conexão com o PC (Godot 4)

1. No celular Android, ative a **Ancoragem USB (USB Tethering)** nas configurações de rede.
2. No PC, abra o projeto Godot e execute o jogo (**F5**).
3. O Godot começará a receber os comandos automaticamente na porta 5000!
