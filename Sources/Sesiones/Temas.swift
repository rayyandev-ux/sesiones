import AppKit
import SwiftUI

// Temas de la app. "Noche pixel" es el diseño original (cielo pixel azul).
// "Consola" sale de la marca de Hugo (hugorocha.pe): morado #8847FF, Pixelify Sans para títulos,
// Chakra Petch para el resto y los números, esquinas de píxel en escalón, carpetas como cartuchos.
// Como en su web: crema de día y morado de noche, y lo que es pantalla (la terminal, "la tele") siempre oscuro.

enum TemaId: String, CaseIterable, Identifiable {
    case consola, consolaDia, consolaNoche, noche
    var id: String { rawValue }

    /// El tema elegido (o el de SESIONES_TEMA, solo para pruebas). Por defecto, Consola.
    static var guardado: TemaId {
        let prueba = ProcessInfo.processInfo.environment["SESIONES_TEMA"].flatMap(TemaId.init(rawValue:))
        return prueba ?? UserDefaults.standard.string(forKey: "tema").flatMap(TemaId.init(rawValue:)) ?? .consola
    }

    var nombre: String {
        switch self {
        case .consola: return "Consola (cambia con la hora)"
        case .consolaDia: return "Consola · día"
        case .consolaNoche: return "Consola · noche"
        case .noche: return "Noche pixel (el original)"
        }
    }
}

enum Estilo { case noche, consola }

struct Paleta {
    let clave: String
    let estilo: Estilo
    let oscuro: Bool
    let fondo, lado, linea, texto, gris, tenue, azul, sel, hover, tarjeta, tarjetaHover, punto: Color
    /// tinte para rellenos y bordes suaves (blanco en temas oscuros, tinta en los claros)
    let tinte: Color
    let sombraTexto: Color
    let terminalFondo, terminalTexto, cursor: NSColor

    static let noche = Paleta(
        clave: "noche", estilo: .noche, oscuro: true,
        fondo: Color(hex: 0x0E1730), lado: Color(hex: 0x0A1126), linea: Color(hex: 0x8CAAE6, 0.13),
        texto: Color(hex: 0xEEF2FB), gris: Color(hex: 0x93A6CC), tenue: Color(hex: 0x5E7099),
        azul: Color(hex: 0x4D8AE6), sel: Color(hex: 0x4D8AE6, 0.20), hover: Color(hex: 0xFFFFFF, 0.05),
        tarjeta: Color(hex: 0x16244A, 0.72), tarjetaHover: Color(hex: 0x1D2F5E, 0.85), punto: .clear,
        tinte: .white, sombraTexto: .black,
        terminalFondo: NSColor(hex: 0x0E1730), terminalTexto: NSColor(hex: 0xE6ECF7), cursor: NSColor(hex: 0x4D8AE6))

    /// la "tele" de la consola: oscura en los dos modos
    private static let tele = NSColor(hex: 0x120A22)

    static let consolaNoche = Paleta(
        clave: "consola-noche", estilo: .consola, oscuro: true,
        fondo: Color(hex: 0x0F0920), lado: Color(hex: 0x0A0612), linea: Color(hex: 0xCEBEFF, 0.11),
        texto: Color(hex: 0xF5F1FF), gris: Color(hex: 0xB4A9D6), tenue: Color(hex: 0x7F74A3),
        azul: Color(hex: 0x8847FF), sel: Color(hex: 0x8847FF, 0.24), hover: Color(hex: 0xFFFFFF, 0.05),
        tarjeta: Color(hex: 0x150C26), tarjetaHover: Color(hex: 0x1F1338), punto: Color(hex: 0xCEBEFF, 0.075),
        tinte: .white, sombraTexto: .clear,
        terminalFondo: tele, terminalTexto: NSColor(hex: 0xF5F1FF), cursor: NSColor(hex: 0x8847FF))

    static let consolaDia = Paleta(
        clave: "consola-dia", estilo: .consola, oscuro: false,
        fondo: Color(hex: 0xF3EEE2), lado: Color(hex: 0xEBE3D3), linea: Color(hex: 0x3A2612, 0.12),
        texto: Color(hex: 0x1B1520), gris: Color(hex: 0x5A5049), tenue: Color(hex: 0x8C8073),
        azul: Color(hex: 0x8847FF), sel: Color(hex: 0x8847FF, 0.15), hover: Color(hex: 0x3A2612, 0.05),
        tarjeta: Color(hex: 0xFFFDF7), tarjetaHover: Color(hex: 0xFFFFFF), punto: Color(hex: 0x3A2612, 0.10),
        tinte: Color(hex: 0x3A2612), sombraTexto: .clear,
        terminalFondo: tele, terminalTexto: NSColor(hex: 0xF5F1FF), cursor: NSColor(hex: 0x8847FF))

    /// De 6:00 a 17:59 es de día, como hugorocha.pe.
    static func de(_ t: TemaId, _ fecha: Date = Date()) -> Paleta {
        switch t {
        case .noche: return .noche
        case .consolaDia: return .consolaDia
        case .consolaNoche: return .consolaNoche
        case .consola:
            let h = Calendar.current.component(.hour, from: fecha)
            return h >= 6 && h < 18 ? .consolaDia : .consolaNoche
        }
    }
}

/// Los colores que usa toda la app. Siempre leen la paleta del tema elegido.
enum Tema {
    /// Arranca ya con el tema elegido: las pestañas se crean al abrir la app, antes que la ventana,
    /// y si leían un tema por defecto la terminal quedaba con el color de otro tema (bug del 2026-11-15).
    nonisolated(unsafe) static var p: Paleta = Paleta.de(TemaId.guardado)

    static var fondo: Color { p.fondo }
    static var lado: Color { p.lado }
    static var linea: Color { p.linea }
    static var texto: Color { p.texto }
    static var gris: Color { p.gris }
    static var tenue: Color { p.tenue }
    /// el color de acento: azul cielo en el original, morado #8847FF en la consola
    static var azul: Color { p.azul }
    static var sel: Color { p.sel }
    static var hover: Color { p.hover }
    static var tarjeta: Color { p.tarjeta }
    static var tarjetaHover: Color { p.tarjetaHover }
    static var sombraTexto: Color { p.sombraTexto }
    static var consola: Bool { p.estilo == .consola }

    /// relleno suave para botones y campos (antes: blanco con transparencia)
    static func velo(_ a: Double) -> Color { p.tinte.opacity(p.oscuro ? a : a * 0.9) }
    /// fondo del campo donde se escribe un nombre
    static var campo: Color { p.oscuro ? Color.black.opacity(0.35) : Color.white }
}

/// Elige el tema, lo recuerda y, en "Consola", cambia de día a noche a las 18:00 y de noche a día a las 6:00.
@MainActor
final class Apariencia: ObservableObject {
    @Published var eleccion: TemaId {
        didSet {
            UserDefaults.standard.set(eleccion.rawValue, forKey: "tema")
            aplicar()
        }
    }
    @Published private(set) var paleta: Paleta
    /// la app recolorea las terminales abiertas
    var alCambiar: (() -> Void)?
    private var timer: Timer?

    init() {
        let e = TemaId.guardado
        eleccion = e
        paleta = Paleta.de(e)
        Tema.p = paleta
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.aplicar() }
        }
    }

    func aplicar() {
        let nueva = Paleta.de(eleccion)
        guard nueva.clave != paleta.clave else { return }
        Tema.p = nueva // primero el global, para que las vistas que se redibujan lean el nuevo
        paleta = nueva
        alCambiar?()
    }
}

// MARK: - esquinas: redondeadas en el original, en escalón de píxel en la consola (el motivo de hugorocha.pe)

struct Forma: InsettableShape {
    var cornerRadius: CGFloat
    var inset: CGFloat = 0

    init(cornerRadius: CGFloat) { self.cornerRadius = cornerRadius }

    func path(in r0: CGRect) -> Path {
        let r = r0.insetBy(dx: inset, dy: inset)
        guard Tema.consola else { return RoundedRectangle(cornerRadius: max(0, cornerRadius - inset)).path(in: r) }
        // dos escalones por esquina, del tamaño de un "píxel" según el radio
        let s = max(1.5, min(cornerRadius / 2.6, min(r.width, r.height) / 5)).rounded()
        var p = Path()
        p.move(to: CGPoint(x: r.minX + 2 * s, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - 2 * s, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - 2 * s, y: r.minY + s))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + s))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + 2 * s))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + 2 * s))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - 2 * s))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.maxY - 2 * s))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.maxX - 2 * s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.maxX - 2 * s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 2 * s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 2 * s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - 2 * s))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - 2 * s))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + 2 * s))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.minY + 2 * s))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.minY + s))
        p.addLine(to: CGPoint(x: r.minX + 2 * s, y: r.minY + s))
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> Forma {
        var f = self
        f.inset += amount
        return f
    }
}

// MARK: - fondo de la pantalla de carpetas

struct FondoTema: View {
    var body: some View {
        if Tema.consola { FondoConsola() } else { FondoNoche() }
    }
}

/// La grilla de puntos de hugorocha.pe.
struct FondoConsola: View {
    var body: some View {
        Canvas { ctx, size in
            let paso: CGFloat = 18
            var y: CGFloat = paso / 2
            while y < size.height {
                var x: CGFloat = paso / 2
                while x < size.width {
                    ctx.fill(Path(CGRect(x: x, y: y, width: 2, height: 2)), with: .color(Tema.p.punto))
                    x += paso
                }
                y += paso
            }
        }
        .background(Tema.fondo)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - selector de tema

struct MenuTema: View {
    @EnvironmentObject var apariencia: Apariencia

    var body: some View {
        Menu {
            Picker("Tema", selection: $apariencia.eleccion) {
                ForEach(TemaId.allCases) { t in Text(t.nombre).tag(t) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "paintpalette").font(Letra.fuerte(12)).foregroundColor(Tema.gris)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Tema: \(apariencia.eleccion.nombre)")
    }
}
