import AppKit
import AVFoundation
import Speech
import SwiftUI

/// Dictado como el de Warp: mantén fn (o toca Hablar), habla, suelta y el texto se escribe en la terminal.
/// En macOS 26 usa SpeechAnalyzer (modelo de Apple en el propio Mac; no necesita el Dictado del sistema activado).
/// En macOS anteriores usa SFSpeechRecognizer, que sí lo necesita. No gasta nada mientras no escuchas.
@MainActor
final class Voz: ObservableObject {
    @Published var escuchando = false
    @Published var preparando = false
    @Published var parcial = ""
    @Published var nivel: CGFloat = 0
    @Published var error: String?
    @Published var errorAjustes = false

    var alTerminar: ((String) -> Void)?

    private var motor: AVAudioEngine?
    private var entregado = true
    private var monitorTeclas: [Any] = []
    private var fnDesde: Date?
    private var fnAbierto = false
    private var otraTecla = false
    private var sesionNueva: AnyObject?          // SesionVoz26 en macOS 26
    private var pedido: SFSpeechAudioBufferRecognitionRequest?
    private var tarea: SFSpeechRecognitionTask?

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

    private func falla(_ texto: String, ajustes: Bool = false) {
        error = texto
        errorAjustes = ajustes
        escuchando = false
        preparando = false
        nivel = 0
        apagarMicrofono()
    }

    func abrirAjustes() {
        let url = errorAjustes ? "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
                               : "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    // MARK: empezar / terminar

    func empezar() {
        guard !escuchando, !preparando else { return }
        error = nil
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                guard ok else { self.falla("Sesiones no tiene permiso para el micrófono. Actívalo en Ajustes del Sistema → Privacidad → Micrófono."); return }
                if #available(macOS 26.0, *) { self.arrancarNuevo() } else { self.arrancarClasico() }
            }
        }
    }

    func terminar() {
        if preparando { preparando = false; fnAbierto = false; apagarMicrofono(); return }
        guard escuchando else { return }
        escuchando = false
        nivel = 0
        apagarMicrofono()
        if #available(macOS 26.0, *), let s = sesionNueva as? SesionVoz26 {
            Task {
                await s.cerrar()
                self.entregar()
            }
        } else {
            pedido?.endAudio()
            // si el resultado final tarda, se entrega lo que ya se oyó
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.entregar() }
        }
    }

    private func entregar() {
        guard !entregado else { return }
        entregado = true
        tarea?.cancel(); tarea = nil; pedido = nil
        sesionNueva = nil
        let texto = parcial.trimmingCharacters(in: .whitespacesAndNewlines)
        parcial = ""
        if !texto.isEmpty { alTerminar?(texto) }
    }

    // MARK: micrófono

    /// Abre el micrófono y entrega cada pedazo de audio (y su volumen) a `alAudio`.
    private func prenderMicrofono(_ alAudio: @escaping (AVAudioPCMBuffer) -> Void) -> Bool {
        let motor = AVAudioEngine()
        let entrada = motor.inputNode
        let formato = entrada.outputFormat(forBus: 0)
        guard formato.sampleRate > 0 else { falla("No encontré un micrófono."); return false }
        entrada.installTap(onBus: 0, bufferSize: 2048, format: formato) { [weak self] buf, _ in
            alAudio(buf)
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
            falla("No pude usar el micrófono: \(error.localizedDescription)")
            return false
        }
        self.motor = motor
        return true
    }

    private func apagarMicrofono() {
        motor?.stop()
        motor?.inputNode.removeTap(onBus: 0)
        motor = nil
    }

    // MARK: macOS 26: SpeechAnalyzer

    @available(macOS 26.0, *)
    private func arrancarNuevo() {
        preparando = true
        parcial = ""
        entregado = false
        Task {
            do {
                let s = try await SesionVoz26.crear(alAvisar: { [weak self] texto in
                    Task { @MainActor in self?.parcial = texto }
                }, descargando: { [weak self] in
                    Task { @MainActor in self?.parcial = "Bajando el modelo de voz de Apple (solo la primera vez)…" }
                })
                guard self.preparando else { await s.cerrar(); return } // soltaste fn mientras preparaba
                self.sesionNueva = s
                self.preparando = false
                self.parcial = ""
                guard self.prenderMicrofono({ s.recibir($0) }) else { await s.cerrar(); return }
                self.escuchando = true
            } catch {
                self.falla("No pude preparar el reconocimiento de voz: \(error.localizedDescription)")
            }
        }
    }

    // MARK: macOS anteriores: SFSpeechRecognizer (necesita el Dictado del sistema)

    private func arrancarClasico() {
        SFSpeechRecognizer.requestAuthorization { estado in
            DispatchQueue.main.async {
                guard estado == .authorized else {
                    self.falla("Activa el reconocimiento de voz para Sesiones en Ajustes del Sistema → Privacidad.")
                    return
                }
                let locales = [Locale.current.identifier, "es-MX", "es-US", "es-ES"]
                let todos = locales.compactMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) }
                guard let rec = todos.first(where: { $0.supportsOnDeviceRecognition }) ?? todos.first, rec.isAvailable else {
                    self.falla("El reconocimiento de voz no está disponible ahora."); return
                }
                let pedido = SFSpeechAudioBufferRecognitionRequest()
                pedido.shouldReportPartialResults = true
                pedido.addsPunctuation = true
                if rec.supportsOnDeviceRecognition { pedido.requiresOnDeviceRecognition = true }
                guard self.prenderMicrofono({ pedido.append($0) }) else { return }
                self.pedido = pedido
                self.entregado = false
                self.parcial = ""
                self.escuchando = true
                self.tarea = rec.recognitionTask(with: pedido) { [weak self] res, err in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if let res { self.parcial = res.bestTranscription.formattedString }
                        if let err = err as NSError?, self.escuchando {
                            if err.localizedDescription.localizedCaseInsensitiveContains("dictation") {
                                self.falla("Para hablar, activa el Dictado de macOS en Ajustes del Sistema → Teclado → Dictado.", ajustes: true)
                            } else if err.code != 1110 { // 1110 = no se oyó nada
                                self.falla("No pude transcribir: \(err.localizedDescription)")
                            }
                            return
                        }
                        if res?.isFinal == true || (err != nil && !self.escuchando) { self.entregar() }
                    }
                }
            }
        }
    }
}

/// Una sesión de dictado con SpeechAnalyzer: recibe audio del micrófono, lo convierte al formato del modelo
/// y va armando el texto (lo confirmado + lo que todavía puede cambiar).
@available(macOS 26.0, *)
final class SesionVoz26: @unchecked Sendable {
    private let analizador: SpeechAnalyzer
    private let entrada: AsyncStream<AnalyzerInput>.Continuation
    private let formato: AVAudioFormat
    private var conversor: AVAudioConverter?
    private var lector: Task<Void, Never>?
    private let lock = NSLock()

    private init(analizador: SpeechAnalyzer, entrada: AsyncStream<AnalyzerInput>.Continuation, formato: AVAudioFormat) {
        self.analizador = analizador
        self.entrada = entrada
        self.formato = formato
    }

    static func crear(alAvisar: @escaping @Sendable (String) -> Void, descargando: @escaping @Sendable () -> Void) async throws -> SesionVoz26 {
        // el idioma preferido del sistema (Locale.current en una app sin traducciones devuelve inglés)
        var idioma: Locale?
        for id in Locale.preferredLanguages + ["es-MX"] where idioma == nil {
            idioma = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id))
        }
        let transcriptorIdioma = idioma ?? Locale(identifier: "es-MX")
        if ProcessInfo.processInfo.environment["SESIONES_DEBUG"] != nil { FileHandle.standardError.write("idioma: \(transcriptorIdioma.identifier)\n".data(using: .utf8)!) }
        let transcriptor = SpeechTranscriber(locale: transcriptorIdioma, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        if let pedido = try await AssetInventory.assetInstallationRequest(supporting: [transcriptor]) {
            descargando()
            try await pedido.downloadAndInstall()
        }
        guard let formato = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriptor]) else {
            throw NSError(domain: "Sesiones", code: 1, userInfo: [NSLocalizedDescriptionKey: "no hay formato de audio compatible"])
        }
        let analizador = SpeechAnalyzer(modules: [transcriptor])
        let (flujo, entrada) = AsyncStream<AnalyzerInput>.makeStream()
        let s = SesionVoz26(analizador: analizador, entrada: entrada, formato: formato)
        s.lector = Task {
            var confirmado = ""
            do {
                for try await r in transcriptor.results {
                    let t = String(r.text.characters)
                    if r.isFinal { confirmado += t; alAvisar(confirmado) } else { alAvisar(confirmado + t) }
                }
            } catch {}
        }
        try await analizador.start(inputSequence: flujo)
        return s
    }

    /// Llamado desde el hilo de audio.
    func recibir(_ buf: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if conversor == nil || conversor?.inputFormat != buf.format { conversor = AVAudioConverter(from: buf.format, to: formato) }
        guard let conversor else { return }
        let capacidad = AVAudioFrameCount(Double(buf.frameLength) * formato.sampleRate / buf.format.sampleRate) + 256
        guard let salida = AVAudioPCMBuffer(pcmFormat: formato, frameCapacity: capacidad) else { return }
        var dado = false
        conversor.convert(to: salida, error: nil) { _, estado in
            if dado { estado.pointee = .noDataNow; return nil }
            dado = true
            estado.pointee = .haveData
            return buf
        }
        if salida.frameLength > 0 { entrada.yield(AnalyzerInput(buffer: salida)) }
    }

    func cerrar() async {
        entrada.finish()
        try? await analizador.finalizeAndFinishThroughEndOfInput()
        _ = await lector?.value
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
            if voz.escuchando || voz.preparando || voz.error != nil {
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
                if e.contains("Ajustes") { Button("Abrir Ajustes") { voz.abrirAjustes() }.buttonStyle(.link) }
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
                Text(voz.parcial.isEmpty ? (voz.preparando ? "Preparando…" : "Te escucho…") : voz.parcial)
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
