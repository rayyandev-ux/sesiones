import AppKit
import SwiftUI

// Configuración: el engranaje arriba de la barra lateral (y ⌘, en el menú de la app).
// Cada uno elige lo suyo: el tema y si quiere ver Recientes en la barra lateral (a Rayyan le sirve, a Hugo no).

struct ConfiguracionVista: View {
    @EnvironmentObject var apariencia: Apariencia
    /// Recientes en la barra lateral; prendido por defecto para que nadie lo pierda sin querer
    @AppStorage("verRecientes") private var verRecientes = true
    /// la ventana ocupa toda la pantalla al abrir, como Warp; apagado por defecto (pedido de Hugo, 2026-11-17)
    @AppStorage("ventanaGrande") private var ventanaGrande = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configuración").font(Letra.titulo(15)).foregroundColor(Tema.texto)

            VStack(alignment: .leading, spacing: 9) {
                Text("Tema").font(Letra.fuerte(12)).foregroundColor(Tema.gris)
                ForEach(TemaId.allCases) { t in
                    Button { apariencia.eleccion = t } label: {
                        HStack(spacing: 9) {
                            Image(systemName: apariencia.eleccion == t ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 13))
                                .foregroundColor(apariencia.eleccion == t ? Tema.azul : Tema.tenue)
                            Text(t.nombre).font(Letra.texto(13)).foregroundColor(Tema.texto)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Rectangle().fill(Tema.linea).frame(height: 1)

            VStack(alignment: .leading, spacing: 9) {
                Text("Barra lateral").font(Letra.fuerte(12)).foregroundColor(Tema.gris)
                Toggle(isOn: $verRecientes) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mostrar Recientes").font(Letra.texto(13)).foregroundColor(Tema.texto)
                        Text("Tus últimas 5 sesiones, arriba de las pestañas").font(Letra.texto(11)).foregroundColor(Tema.tenue)
                    }
                }
                .toggleStyle(.switch)
                .tint(Tema.azul)
            }

            Rectangle().fill(Tema.linea).frame(height: 1)

            VStack(alignment: .leading, spacing: 9) {
                Text("Ventana").font(Letra.fuerte(12)).foregroundColor(Tema.gris)
                Toggle(isOn: $ventanaGrande) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pantalla completa").font(Letra.texto(13)).foregroundColor(Tema.texto)
                        Text("Ocupa toda la pantalla al abrir, como Warp (sin tapar el menú ni el Dock)").font(Letra.texto(11)).foregroundColor(Tema.tenue)
                    }
                }
                .toggleStyle(.switch)
                .tint(Tema.azul)
                .onChange(of: ventanaGrande) { _, grande in
                    if grande { Ventana.agrandar() } else { Ventana.tamanoNormal() }
                }
            }
        }
        .padding(18)
        .frame(width: 310, alignment: .leading)
        .background(Tema.lado)
    }
}

/// El engranaje arriba de la barra lateral: abre la configuración al lado.
struct BotonConfiguracion: View {
    @EnvironmentObject var apariencia: Apariencia
    @State private var abierta = false

    var body: some View {
        Button { abierta.toggle() } label: {
            Image(systemName: "gearshape").font(Letra.fuerte(12.5)).foregroundColor(Tema.gris)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Configuración (⌘,)")
        .popover(isPresented: $abierta, arrowEdge: .bottom) {
            ConfiguracionVista().environmentObject(apariencia)
        }
    }
}

// MARK: - tamaño de la ventana

@MainActor
enum Ventana {
    /// la ventana principal (la de las carpetas y terminales, no la de Ajustes)
    static weak var principal: NSWindow?
    private static var yaAbrio = false

    /// Llena la pantalla donde está la ventana, sin tapar la barra de menú ni el Dock, como Warp.
    static func agrandar() {
        guard let w = principal, !w.styleMask.contains(.fullScreen), let pantalla = w.screen ?? NSScreen.main else { return }
        w.setFrame(pantalla.visibleFrame, display: true, animate: true)
    }

    /// Vuelve al tamaño de siempre (1280 × 820), centrada.
    static func tamanoNormal() {
        guard let w = principal, !w.styleMask.contains(.fullScreen), let pantalla = w.screen ?? NSScreen.main else { return }
        let v = pantalla.visibleFrame
        let tam = NSSize(width: min(1280, v.width), height: min(820, v.height))
        w.setFrame(NSRect(x: v.midX - tam.width / 2, y: v.midY - tam.height / 2, width: tam.width, height: tam.height), display: true, animate: true)
    }

    /// Al abrir la app (una sola vez: al cambiar de tema la vista se vuelve a crear y no debe moverla).
    fileprivate static func alAbrir(_ w: NSWindow) {
        principal = w
        guard !yaAbrio else { return }
        yaAbrio = true
        if UserDefaults.standard.bool(forKey: "ventanaGrande") { DispatchQueue.main.async { agrandar() } }
    }
}

/// Se pone de fondo en la ventana principal para saber cuál es.
struct AccesoVentana: NSViewRepresentable {
    final class Vista: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { Ventana.alAbrir(w) }
        }
    }
    func makeNSView(context: Context) -> Vista { Vista() }
    func updateNSView(_ v: Vista, context: Context) {}
}
