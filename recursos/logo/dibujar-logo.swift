// Dibuja el logo de Sesiones (la "A": cartucho ›_) y las otras dos ideas que se probaron (B la consola, C carpeta con rótulo).
// Uso: swiftc -O recursos/logo/dibujar-logo.swift -o /tmp/logo && /tmp/logo <carpeta>
// Deja logo-A.png, logo-B.png, logo-C.png (1024 px) y hoja.png (comparación a tamaño Dock).
// El ícono de la app es logo-A.png → recursos/icono-1024.png y, con iconutil, recursos/Sesiones.icns.

import AppKit
import CoreGraphics

func col(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}

/// Lienzo de 1024 con el cuadrado redondeado de macOS (824 px, centrado) y una grilla de píxeles.
final class Icono {
    let ctx: CGContext
    var cel: CGFloat = 30, ox: CGFloat = 0, oy: CGFloat = 0
    init() {
        ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: 1024); ctx.scaleBy(x: 1, y: -1) // y hacia abajo
    }
    var forma: CGPath { CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil) }
    func fondo(_ arriba: UInt32, _ abajo: UInt32, puntos: CGColor?) {
        ctx.saveGState(); ctx.addPath(forma); ctx.clip()
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [col(arriba), col(abajo)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
        if let p = puntos {
            ctx.setFillColor(p)
            var y: CGFloat = 118; while y < 924 { var x: CGFloat = 118; while x < 924 { ctx.fill(CGRect(x: x, y: y, width: 6, height: 6)); x += 36 }; y += 36 }
        }
        ctx.restoreGState()
    }
    /// grilla de cols×filas centrada, con celdas de `c` px (y un corrimiento opcional)
    func grilla(_ cols: Int, _ filas: Int, _ c: CGFloat, dy: CGFloat = 0) {
        cel = c; ox = 512 - CGFloat(cols) * c / 2; oy = 512 - CGFloat(filas) * c / 2 + dy
    }
    func px(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ h: UInt32, _ a: CGFloat = 1) {
        ctx.setFillColor(col(h, a))
        ctx.fill(CGRect(x: ox + CGFloat(x0) * cel, y: oy + CGFloat(y0) * cel, width: CGFloat(x1 - x0 + 1) * cel, height: CGFloat(y1 - y0 + 1) * cel))
    }
    func sombra(_ dx: CGFloat, _ dy: CGFloat, _ blur: CGFloat, _ a: CGFloat) { ctx.setShadow(offset: CGSize(width: dx, height: -dy), blur: blur, color: col(0x000000, a)) }
    func sinSombra() { ctx.setShadow(offset: .zero, blur: 0, color: nil) }
    func imagen() -> CGImage { ctx.makeImage()! }
}

// A · Cartucho ›_  (consola de Hugo + terminal)
func cartucho() -> CGImage {
    let i = Icono()
    i.fondo(0x1C1036, 0x0A0612, puntos: col(0xCEBEFF, 0.07))
    i.grilla(20, 16, 31, dy: 4)
    i.sombra(0, 22, 40, 0.55)
    i.px(1, 0, 18, 15, 0x0A0612); i.px(0, 1, 19, 14, 0x0A0612)           // contorno
    i.sinSombra()
    i.px(1, 1, 18, 14, 0x4A2A8F)                                          // carcasa
    i.px(1, 1, 18, 1, 0x7B52E8)                                           // brillo de arriba
    i.px(1, 12, 18, 14, 0x351E6E)                                         // sombra de abajo
    for x in stride(from: 3, through: 16, by: 2) { i.px(x, 12, x, 13, 0x24124F) } // estrías
    i.px(2, 2, 17, 10, 0xD9CCB4)                                          // marco de la etiqueta
    i.px(3, 3, 16, 9, 0x120A22)                                           // pantalla
    i.px(5, 4, 5, 4, 0xB89CFF); i.px(6, 5, 6, 5, 0xB89CFF); i.px(5, 6, 5, 6, 0xB89CFF) // ›
    i.px(8, 6, 10, 6, 0xD97757)                                           // cursor _
    i.px(5, 8, 11, 8, 0x8847FF, 0.55)                                     // línea anterior
    i.px(13, 8, 14, 8, 0xE4AE39, 0.8)
    return i.imagen()
}

// B · La consola (la portátil de hugorocha.pe, con las carpetas de rayyan.pe en su pantalla)
func consola() -> CGImage {
    let i = Icono()
    i.fondo(0xF6F1E6, 0xE9E0CE, puntos: col(0x3A2612, 0.09))
    i.grilla(15, 22, 29, dy: 2)
    i.sombra(0, 20, 34, 0.35)
    i.px(1, 0, 13, 21, 0x2A1A4A); i.px(0, 1, 14, 20, 0x2A1A4A)           // contorno
    i.sinSombra()
    i.px(1, 1, 13, 20, 0x8847FF)                                          // cuerpo morado
    i.px(1, 1, 13, 1, 0xA67BFF); i.px(1, 18, 13, 20, 0x6A2EE8)
    i.px(2, 2, 12, 10, 0x3A2468)                                          // marco de la pantalla
    i.px(3, 3, 11, 9, 0x120A22)                                           // pantalla
    i.px(4, 4, 5, 4, 0x0D99FF); i.px(4, 5, 7, 7, 0x0D99FF); i.px(4, 5, 7, 5, 0x5CB8FF) // carpeta Finder
    i.px(9, 6, 9, 6, 0xB89CFF); i.px(10, 7, 10, 7, 0xB89CFF)              // › (diagonal)
    i.px(4, 8, 6, 8, 0xD97757)                                            // cursor
    i.px(3, 13, 5, 13, 0x1B1520); i.px(4, 12, 4, 14, 0x1B1520)            // cruceta
    i.px(11, 12, 11, 12, 0xD97757); i.px(12, 12, 12, 12, 0xD97757, 0)     // A
    i.px(10, 13, 10, 13, 0xE4AE39); i.px(11, 12, 12, 12, 0xD97757)        // B y A
    i.px(5, 16, 6, 16, 0x5A3AA8); i.px(8, 16, 9, 16, 0x5A3AA8)            // select / start
    return i.imagen()
}

// C · Carpeta con rótulo (Finder oscuro y collage de rayyan.pe, en píxel de hugorocha.pe)
func carpeta() -> CGImage {
    let i = Icono()
    i.fondo(0x2A2A2A, 0x161616, puntos: nil)
    // semáforos del Finder
    i.ctx.setFillColor(col(0xFF5F57)); i.ctx.fillEllipse(in: CGRect(x: 182, y: 182, width: 44, height: 44))
    i.ctx.setFillColor(col(0xFEBC2E)); i.ctx.fillEllipse(in: CGRect(x: 244, y: 182, width: 44, height: 44))
    i.ctx.setFillColor(col(0x28C840)); i.ctx.fillEllipse(in: CGRect(x: 306, y: 182, width: 44, height: 44))
    i.grilla(22, 16, 28, dy: 40)
    i.sombra(0, 22, 40, 0.5)
    i.px(0, 0, 8, 2, 0x0A78D6)                                            // pestaña
    i.px(0, 2, 21, 15, 0x0A78D6)
    i.sinSombra()
    i.px(1, 2, 20, 4, 0xFBFAF6)                                           // hoja que asoma
    i.px(0, 4, 21, 15, 0x0D99FF); i.px(0, 4, 21, 4, 0x5CB8FF); i.px(0, 14, 21, 15, 0x0A84E8)
    // tira de papel (rótulo) con cinta
    i.px(2, 7, 19, 11, 0xFBFAF6)
    i.px(1, 6, 3, 7, 0xF2E3A0, 0.85); i.px(18, 11, 20, 12, 0xF2E3A0, 0.85)
    i.px(5, 8, 5, 8, 0x17191D); i.px(6, 9, 6, 9, 0x17191D); i.px(5, 10, 5, 10, 0x17191D) // ›
    i.px(8, 10, 10, 10, 0xD97757)                                         // cursor
    i.px(12, 9, 16, 9, 0x8847FF)                                          // pixel morado de Hugo
    return i.imagen()
}

let iconos = [("A", cartucho()), ("B", consola()), ("C", carpeta())]
let dir = CommandLine.arguments[1]
for (n, img) in iconos {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/logo-\(n).png"))
}
// hoja de contacto: grande arriba, tamaño Dock (64 px) abajo sobre un Dock oscuro y uno claro
let W = 3 * 420 + 4 * 30, H = 420 + 60 + 2 * 100 + 40
let hoja = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
hoja.setFillColor(col(0x1E1E1E)); hoja.fill(CGRect(x: 0, y: 0, width: W, height: H))
hoja.setFillColor(col(0xD8D4CC)); hoja.fill(CGRect(x: 0, y: 0, width: W, height: 120))
hoja.interpolationQuality = .high
for (k, (_, img)) in iconos.enumerated() {
    let x = CGFloat(30 + k * 450)
    hoja.draw(img, in: CGRect(x: x, y: CGFloat(H - 450), width: 420, height: 420))
    hoja.draw(img, in: CGRect(x: x + 178, y: 150, width: 64, height: 64))   // Dock oscuro
    hoja.draw(img, in: CGRect(x: x + 178, y: 28, width: 64, height: 64))    // Dock claro
}
let rep = NSBitmapImageRep(cgImage: hoja.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/hoja.png"))
print("ok")
