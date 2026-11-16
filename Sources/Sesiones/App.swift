import AVFoundation
import AppKit
import SwiftUI

final class Delegado: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if ProcessInfo.processInfo.environment["SESIONES_FONDO"] == nil { NSApp.activate(ignoringOtherApps: true) }
    }
}

/// `Sesiones --lista` imprime las carpetas y sus sesiones sin abrir ventana.
func listarYSalir() {
    let r = Datos.todo()
    for c in r.carpetas {
        print("\(c.nombre)\(c.auto ? " (automática)" : "") — \(c.sesiones.count)")
        for s in c.sesiones.prefix(3) { print("   \(hace(s.mtime))  \(s.motor.nombre)  \(s.titulo.prefix(70))") }
    }
    print("Total: \(r.total)")
    exit(0)
}

/// `Sesiones --probar-voz audio.wav` pasa un audio por el mismo camino que el micrófono (en pedazos) y muestra el texto.
func probarVozYSalir(_ ruta: String) {
    guard #available(macOS 26.0, *) else { print("necesita macOS 26"); exit(1) }
    Task {
        do {
            let s = try await SesionVoz26.crear(alAvisar: { print("… \($0)") }, descargando: { print("bajando modelo…") })
            let f = try AVAudioFile(forReading: URL(fileURLWithPath: ruta))
            while f.framePosition < f.length {
                let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 2048)!
                try f.read(into: b, frameCount: 2048)
                s.recibir(b)
            }
            await s.cerrar()
            print("FIN")
        } catch { print("ERROR: \(error)") }
        exit(0)
    }
    RunLoop.main.run()
}

@main
struct SesionesApp: App {
    @NSApplicationDelegateAdaptor(Delegado.self) var delegado
    @StateObject private var store = Store()
    @StateObject private var voz = Voz()

    init() {
        if CommandLine.arguments.contains("--lista") { listarYSalir() }
        if let i = CommandLine.arguments.firstIndex(of: "--probar-voz"), i + 1 < CommandLine.arguments.count { probarVozYSalir(CommandLine.arguments[i + 1]) }
        Letra.registrar()
    }

    var body: some Scene {
        Window("Sesiones", id: "principal") {
            Raiz()
                .environmentObject(store)
                .environmentObject(voz)
                .frame(minWidth: 780, minHeight: 480)
                .onAppear {
                    AtajoGlobal.registrar { [weak store] in store?.alternarVentana() }
                    voz.vigilarFn()
                    voz.alTerminar = { [weak store] texto in store?.escribirDictado(texto) }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Carpetas") { store.query = ""; store.vista = .inicio }.keyboardShortcut("t")
                Button("Terminal nueva") { store.nuevaTerminal() }.keyboardShortcut("n")
                Button("Nueva carpeta…") { store.pideNuevaCarpeta = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Buscar") {
                    if case .terminal = store.vista { store.buscarEnTerminal() } else { store.pideBusqueda += 1 }
                }.keyboardShortcut("f")
                Button("Buscar sesiones") {
                    if case .terminal = store.vista { store.vista = .inicio }
                    store.pideBusqueda += 1
                }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Recargar sesiones") { store.recargar() }.keyboardShortcut("r")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Cerrar pestaña") { store.cerrarActiva() }.keyboardShortcut("w")
            }
            CommandMenu("Pestañas") {
                Button("Dividir pantalla") { store.dividir() }.keyboardShortcut("d")
                Divider()
                Button("Anterior") { store.pestana(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Siguiente") { store.pestana(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
                Divider()
                ForEach(1..<10) { n in
                    Button("Pestaña \(n)") { store.irA(n - 1) }.keyboardShortcut(KeyEquivalent(Character("\(n)")))
                }
                Divider()
                Button("Agrandar texto") { store.fuente(1) }.keyboardShortcut("+")
                Button("Achicar texto") { store.fuente(-1) }.keyboardShortcut("-")
                Button("Tamaño normal") { store.fuente(0) }.keyboardShortcut("0")
            }
        }
    }
}
