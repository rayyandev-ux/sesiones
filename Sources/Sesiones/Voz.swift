import AppKit
import AVFoundation
import Speech
import SwiftUI

/// Dictado como el de Warp: mantén fn (o toca el micrófono), habla, suelta y el texto se escribe en la terminal.
/// Usa el reconocimiento de voz de Apple, en el propio Mac cuando el idioma lo permite. No gasta nada mientras no escuchas.
@MainActor
final class Voz: ObservableObject {
    @Published var escuchando = false
    @Published var parcial = ""
    @Published var nivel: CGFloat = 0
    @Published var error: String?

    var alTerminar: ((String) -> Void)?

    private var motor: AVAudioEngine?
    private var pedido: SFSpeechAudioBufferRecognitionRequest?
    private var tarea: SFSpeechRecognitionTask?
    private var entregado = false
    private var monitorTeclas: [Any] = []
    private var fnDesde: Date?
    private var fnAbierto = false
    private var otraTecla = false

    private lazy var reconocedor: SFSpeechRecognizer? = {
        let locales = ["es-PE", "es-419", "es-MX", "es-US", "es-ES"]
        let todos = locales.compactMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) }
        return todos.first(where: { $0.supportsOnDeviceRecognition }) ?? todos.first
    }()

    // MARK: fn mantenido = hablar (solo con la app al frente)

    func vigilarFn() {
        guard monitorTeclas.isEmpty else { return }
        monitorTeclas.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            if e.keyCode == 63 { self?.cambioFn(e.modifierFlags.contains(.function)) }
            return e
        } as Any)
        // fn + otra tecla (fn+flechas, fn+F1…) no es dictado
        monitorTeclas.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if self?.fnDesde != nil { self?.otraTecla = true }
            return e
        } as Any)
    }

    private func cambioFn(_ abajo: Bool) {
        if abajo {
            fnDesde = Date()
            otraTecla = false
            let marca = fnDesde
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.fnDesde == marca, !self.otraTecla, !self.escuchando else { return }
                self.fnAbierto = true
                self.empezar()
            }
        } else {
            fnDesde = nil
            if fnAbierto { fnAbierto = false; terminar() }
        }
    }

    func alternar() { escuchando ? terminar() : empezar() }

    // MARK: grabar y transcribir

    func empezar() {
        guard !escuchando else { return }
        error = nil
        SFSpeechRecognizer.requestAuthorization { estado in
            DispatchQueue.main.async {
                guard estado == .authorized else {
                    self.error = "Activa el reconocimiento de voz para Sesiones en Ajustes del Sistema → Privacidad."
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    DispatchQueue.main.async {
                        if ok { self.arrancar() } else { self.error = "Activa el micrófono para Sesiones en Ajustes del Sistema → Privacidad." }
                    }
                }
            }
        }
    }

    private func arrancar() {
        guard let reconocedor, reconocedor.isAvailable else { error = "El reconocimiento de voz no está disponible ahora."; return }
        let pedido = SFSpeechAudioBufferRecognitionRequest()
        pedido.shouldReportPartialResults = true
        pedido.addsPunctuation = true
        if reconocedor.supportsOnDeviceRecognition { pedido.requiresOnDeviceRecognition = true }
        let motor = AVAudioEngine()
        let entrada = motor.inputNode
        let formato = entrada.outputFormat(forBus: 0)
        entrada.installTap(onBus: 0, bufferSize: 1024, format: formato) { [weak self] buf, _ in
            pedido.append(buf)
            guard let canal = buf.floatChannelData?[0] else { return }
            var suma: Float = 0
            let n = Int(buf.frameLength)
            for i in stride(from: 0, to: n, by: 8) { suma += abs(canal[i]) }
            let nivel = CGFloat(min(1, suma / Float(max(1, n / 8)) * 12))
            DispatchQueue.main.async { self?.nivel = nivel }
        }
        do {
            motor.prepare()
            try motor.start()
        } catch {
            entrada.removeTap(onBus: 0)
            self.error = "No pude usar el micrófono: \(error.localizedDescription)"
            return
        }
        self.motor = motor
        self.pedido = pedido
        entregado = false
        parcial = ""
        escuchando = true
        tarea = reconocedor.recognitionTask(with: pedido) { [weak self] res, err in
            DispatchQueue.main.async {
                guard let self else { return }
                if let res { self.parcial = res.bestTranscription.formattedString }
                if res?.isFinal == true || (err != nil && !self.escuchando) { self.entregar() }
            }
        }
    }

    func terminar() {
        guard escuchando else { return }
        escuchando = false
        nivel = 0
        motor?.stop()
        motor?.inputNode.removeTap(onBus: 0)
        motor = nil
        pedido?.endAudio()
        // si el resultado final tarda, se entrega lo que ya se oyó
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.entregar() }
    }

    private func entregar() {
        guard !entregado else { return }
        entregado = true
        tarea?.cancel()
        tarea = nil
        pedido = nil
        let texto = parcial.trimmingCharacters(in: .whitespacesAndNewlines)
        parcial = ""
        if !texto.isEmpty { alTerminar?(texto) }
    }
}

// MARK: - barra de abajo de la terminal (como la de Warp)

struct BarraTerminal: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var voz: Voz
    @ObservedObject var term: Term

    var body: some View {
        HStack(spacing: 8) {
            Button { store.nuevaTerminal(en: term.cwd) } label: { Image(systemName: "plus") }
                .buttonStyle(BotonBarra()).help("Terminal nueva en esta carpeta (⌘N)")
            Button { voz.alternar() } label: {
                HStack(spacing: 6) {
                    Image(systemName: voz.escuchando ? "waveform" : "mic")
                        .symbolEffect(.variableColor.iterative, isActive: voz.escuchando)
                    Text(voz.escuchando ? "Escuchando… suelta fn" : "Hablar").font(Letra.fuerte(12))
                    if !voz.escuchando { Text("fn").font(Letra.texto(11)).foregroundColor(Tema.tenue) }
                }
            }
            .buttonStyle(BotonBarra(activo: voz.escuchando))
            .help("Mantén fn y habla; al soltar se escribe en la terminal. También puedes tocar aquí para empezar y parar.")
            if let s = term.sesionId {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(s, forType: .string)
                } label: { Image(systemName: "number") }
                    .buttonStyle(BotonBarra()).help("Copiar el ID de la sesión")
            }
            Spacer(minLength: 8)
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: term.cwd)) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text(term.cwd.replacingOccurrences(of: Datos.home, with: "~")).font(Letra.texto(12)).lineLimit(1).truncationMode(.head)
                }
            }
            .buttonStyle(BotonBarra()).help("Abrir esta carpeta en Finder")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Tema.lado)
        .overlay(alignment: .top) { Rectangle().fill(Tema.linea).frame(height: 1) }
        .overlay(alignment: .bottomLeading) {
            if voz.escuchando || voz.error != nil {
                Dictando().offset(x: 12, y: -48)
            }
        }
    }
}

struct Dictando: View {
    @EnvironmentObject var voz: Voz

    var body: some View {
        HStack(spacing: 10) {
            if let e = voz.error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text(e).font(Letra.texto(12.5)).foregroundColor(Tema.texto)
                Button { voz.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundColor(Tema.gris)
            } else {
                HStack(spacing: 2) {
                    ForEach(0..<5) { i in
                        Forma(cornerRadius: 1)
                            .fill(Color(hex: 0xFF5A5F))
                            .frame(width: 3, height: 4 + voz.nivel * CGFloat([10, 16, 20, 16, 10][i]))
                    }
                }
                .frame(height: 24)
                .animation(.easeOut(duration: 0.08), value: voz.nivel)
                Text(voz.parcial.isEmpty ? "Te escucho…" : voz.parcial)
                    .font(Letra.texto(13))
                    .foregroundColor(voz.parcial.isEmpty ? Tema.gris : Tema.texto)
                    .lineLimit(2)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 560, alignment: .leading)
        .background(Forma(cornerRadius: 12).fill(Tema.tarjeta))
        .overlay(Forma(cornerRadius: 12).stroke(Tema.linea))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct BotonBarra: ButtonStyle {
    var activo = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Letra.texto(12.5))
            .foregroundColor(activo ? .white : Tema.gris)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Forma(cornerRadius: 7).fill(
                activo ? Color(hex: 0xE5484D) : Tema.velo(configuration.isPressed ? 0.12 : 0.06)))
            .overlay(Forma(cornerRadius: 7).stroke(Tema.linea))
    }
}
