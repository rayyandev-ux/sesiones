import AppKit
import CoreText
import SwiftUI

// Tema "noche pixelada": un cielo pixel de noche.
// El paisaje se genera UNA vez como una imagen chiquita (192×120 px) y se agranda sin suavizar:
// pesa ~90 KB en memoria y no se vuelve a dibujar.

extension Color {
    init(hex: UInt32, _ a: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255, opacity: a)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

// MARK: - tipografías de la marca (Manrope para títulos, DM Sans para el resto)

enum Letra {
    static func registrar() {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r) }
        dirs.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/recursos/fuentes"))
        for d in dirs {
            let fuentes = ((try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "ttf" }
            guard !fuentes.isEmpty else { continue }
            for f in fuentes { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
            break
        }
        hay = NSFont(name: "DMSans-Regular", size: 12) != nil
    }

    nonisolated(unsafe) private static var hay = false

    static func titulo(_ t: CGFloat) -> Font { hay ? .custom("Manrope-ExtraBold", fixedSize: t) : .system(size: t, weight: .heavy) }
    static func fuerte(_ t: CGFloat) -> Font { hay ? .custom("DMSans-SemiBold", fixedSize: t) : .system(size: t, weight: .semibold) }
    static func texto(_ t: CGFloat) -> Font { hay ? .custom("DMSans-Regular", fixedSize: t) : .system(size: t) }
}

// MARK: - paisaje de noche

enum Paisaje {
    static let ancho = 192, alto = 120

    static let imagen: CGImage = {
        var px = [UInt8](repeating: 0, count: ancho * alto * 4)
        var semilla: UInt64 = 0x5E51_0E5
        func azar() -> Double {
            semilla = semilla &* 6364136223846793005 &+ 1442695040888963407
            return Double((semilla >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
        }
        func pon(_ x: Int, _ y: Int, _ c: UInt32) {
            guard x >= 0, y >= 0, x < ancho, y < alto else { return }
            let i = (y * ancho + x) * 4
            px[i] = UInt8((c >> 16) & 255); px[i + 1] = UInt8((c >> 8) & 255); px[i + 2] = UInt8(c & 255); px[i + 3] = 255
        }
        let bayer: [[Double]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]].map { $0.map { $0 / 16 } }

        // cielo: degradado en escalones con tramado
        let cielo: [UInt32] = [0x0A1230, 0x0D1840, 0x112050, 0x152962, 0x1A3375, 0x203E88]
        for y in 0..<alto {
            let t = Double(y) / Double(alto - 1) * Double(cielo.count - 1)
            for x in 0..<ancho {
                let k = min(cielo.count - 1, Int(t + bayer[y % 4][x % 4] - 0.5 + 0.5))
                pon(x, y, cielo[max(0, k)])
            }
        }
        // cuadritos más claros en la grilla (el patrón del cielo de la referencia)
        for y in stride(from: 1, to: alto - 30, by: 3) {
            for x in stride(from: 1, to: ancho, by: 3) where azar() < 0.22 {
                pon(x, y, y < 40 ? 0x1B3570 : 0x2A4C99)
            }
        }
        // estrellas
        for _ in 0..<70 {
            let x = Int(azar() * Double(ancho)), y = Int(azar() * 70)
            pon(x, y, azar() < 0.7 ? 0x8FB0EE : 0xE6EEFF)
        }
        for _ in 0..<5 { // estrellas en cruz
            let x = Int(azar() * Double(ancho - 4)) + 2, y = Int(azar() * 50) + 2
            for (dx, dy) in [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)] { pon(x + dx, y + dy, dx == 0 && dy == 0 ? 0xFFFFFF : 0xA9C3F5) }
        }
        // luna pixel arriba a la derecha
        let (lx, ly, lr) = (ancho - 22, 16, 7.0)
        for y in -8...8 { for x in -8...8 where Double(x * x + y * y) <= lr * lr {
            let sombra = Double((x + 3) * (x + 3) + (y - 1) * (y - 1)) <= 20
            pon(lx + x, ly + y, sombra ? 0xC9D6F2 : 0xEDF2FF)
        } }
        // colina lejana (izquierda) y colina principal, escalonadas
        func colina(_ cx: Double, _ cima: Double, _ ancho_: Double, _ color: UInt32, _ borde: UInt32) {
            for x in 0..<ancho {
                let d = (Double(x) - cx) / ancho_
                let top = Int((cima + d * d * Double(alto) * 0.9).rounded(.down))
                guard top < alto else { continue }
                for y in max(0, top)..<alto { pon(x, y, y == top ? borde : color) }
            }
        }
        colina(30, Double(alto) * 0.70, 60, 0x1F5634, 0x2A6E42)
        colina(118, Double(alto) * 0.53, 78, 0x2E7D46, 0x46A160)
        // brillitos en la colina
        for y in Int(Double(alto) * 0.58)..<alto { for x in 0..<ancho where (x + y) % 4 == 0 && azar() < 0.08 { pon(x, y, 0x3A9156) } }
        // campo amarillo verdoso abajo, con borde irregular
        var borde = Int(Double(alto) * 0.86)
        for x in 0..<ancho {
            if azar() < 0.3 { borde += azar() < 0.5 ? -1 : 1 }
            borde = min(alto - 6, max(Int(Double(alto) * 0.83), borde))
            for y in borde..<alto {
                let t = bayer[y % 4][x % 4]
                pon(x, y, y == borde ? 0x8E9A30 : (t < 0.3 ? 0x5F6A1C : 0x6D7922))
            }
        }
        let espacio = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &px, width: ancho, height: alto, bitsPerComponent: 8, bytesPerRow: ancho * 4,
                            space: espacio, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }()
}

/// Fondo de la pantalla de carpetas: cielo pixel de noche con la colina abajo y "Sesiones" grande encima.
struct FondoNoche: View {
    var body: some View {
        GeometryReader { g in
            let escala = max(g.size.width / CGFloat(Paisaje.ancho), g.size.height / CGFloat(Paisaje.alto))
            let w = CGFloat(Paisaje.ancho) * escala, h = CGFloat(Paisaje.alto) * escala
            ZStack(alignment: .bottom) {
                Image(decorative: Paisaje.imagen, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: w, height: h)
                    .frame(width: g.size.width, height: g.size.height, alignment: .bottom)
                    .clipped()
                // velo arriba para que el texto se lea sobre el cielo
                LinearGradient(colors: [Tema.fondo.opacity(0.92), Tema.fondo.opacity(0.55), .clear],
                               startPoint: .top, endPoint: .center)
                Text("Sesiones")
                    .font(Letra.titulo(min(g.size.width * 0.19, 260)))
                    .tracking(-min(g.size.width * 0.19, 260) * 0.05)
                    .foregroundColor(Color(hex: 0xEEF2FB, 0.16))
                    .lineLimit(1)
                    .fixedSize()
                    .offset(y: min(g.size.width * 0.19, 260) * 0.18)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - carpeta en pixel art (azul cielo)

struct CarpetaPixel: View {
    var abierta = false

    // 20 × 15 celdas: t = pestaña/fondo, p = hoja, f = frente, h = brillo del frente, s = sombra (tramado)
    static let mapa: [String] = [
        ".tttttttt...........",
        "tttttttttttttttttttt",
        "ttpppppppppppppppptt",
        "ttpppppppppppppppptt",
        ".hhhhhhhhhhhhhhhhhh.",
        "ffffffffffffffffffff",
        "ffffffffffffffffffff",
        "ffffffffffffffffffff",
        "ffffffffffffffffffff",
        "ffffffffffffffffffff",
        "fsfsfsfsfsfsfsfsfsfs",
        "sfsfsfsfsfsfsfsfsfsf",
        "ssssssssssssssssssss",
        "ssssssssssssssssssss",
        ".ssssssssssssssssss.",
    ]

    var body: some View {
        Canvas { ctx, size in
            let filas = CarpetaPixel.mapa
            let cw = size.width / 20, ch = size.height / CGFloat(filas.count)
            for (y, fila) in filas.enumerated() {
                for (x, c) in fila.enumerated() {
                    let color: Color
                    switch c {
                    case "t": color = Color(hex: 0x2B4F9C)
                    case "p": color = abierta ? Color(hex: 0xFFFFFF) : Color(hex: 0xE6EDFB)
                    case "h": color = Color(hex: 0x7FB0F4)
                    case "f": color = Color(hex: 0x4D8AE6)
                    case "s": color = Color(hex: 0x3D74CB)
                    default: continue
                    }
                    ctx.fill(Path(CGRect(x: CGFloat(x) * cw, y: CGFloat(y) * ch, width: cw + 0.5, height: ch + 0.5)), with: .color(color))
                }
            }
        }
    }
}
