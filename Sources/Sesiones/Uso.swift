import SwiftUI

// Uso de Claude (ventana de 5 h y semana), el mismo botón que WarpConsumo pone sobre Warp.
// Lee ~/.claude/uso-claude/estado.json, que escribe el status line de Claude Code (statusline.sh de WarpConsumo).

struct UsoVentana: Decodable {
    let used_percentage: Double?
    let resets_at: Double?
}

struct UsoSesion: Decodable {
    let model: String?
    let cost_usd: Double?
    let context_pct: Double?
    let dir: String?
}

struct UsoEstado: Decodable {
    let updated_at: Double?
    let five_hour: UsoVentana?
    let seven_day: UsoVentana?
    let limits_updated_at: Double?
    let session: UsoSesion?
}

@MainActor
final class Uso: ObservableObject {
    @Published var estado: UsoEstado?
    @Published var ahora = Date()
    /// con el panel abierto la hora se refresca cada 2 s; si no, cada 20 s
    var panelAbierto = false

    private let archivo = NSHomeDirectory() + "/.claude/uso-claude/estado.json"
    private var ultimaFecha: Date?
    private var timer: Timer?

    init() {
        refrescar()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refrescar() }
        }
    }

    func refrescar() {
        if panelAbierto || Date().timeIntervalSince(ahora) >= 20 { ahora = Date() }
        let fecha = (try? FileManager.default.attributesOfItem(atPath: archivo))?[.modificationDate] as? Date
        guard fecha != ultimaFecha else { return }
        ultimaFecha = fecha
        if let d = FileManager.default.contents(atPath: archivo), let e = try? JSONDecoder().decode(UsoEstado.self, from: d) {
            estado = e
        } else if fecha == nil {
            estado = nil
        }
    }

    /// Porcentaje usado; 0 si la ventana ya se reinició, nil si no hay dato.
    func porcentaje(_ v: UsoVentana?) -> Double? {
        guard let v, let p = v.used_percentage else { return nil }
        if reiniciada(v) { return 0 }
        return min(max(p, 0), 100)
    }

    func reiniciada(_ v: UsoVentana?) -> Bool {
        guard let r = v?.resets_at else { return false }
        return Date(timeIntervalSince1970: r) <= ahora
    }
}

enum FormatoUso {
    private static let local = Locale(identifier: "es_PE")

    private static func fecha(_ plantilla: String, _ d: Date) -> String {
        let f = DateFormatter()
        f.locale = local
        f.setLocalizedDateFormatFromTemplate(plantilla)
        return f.string(from: d)
    }

    static func pct(_ p: Double?) -> String { p.map { "\(Int($0.rounded()))%" } ?? "—" }

    static func cuando(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "a las \(fecha("hmma", d))" }
        if cal.isDateInTomorrow(d) { return "mañana a las \(fecha("hmma", d))" }
        return "el \(fecha("EEEdMMMhmma", d))"
    }

    static func falta(_ ahora: Date, _ d: Date) -> String {
        let s = Int(d.timeIntervalSince(ahora))
        let dias = s / 86400, horas = (s % 86400) / 3600, min = (s % 3600) / 60
        if dias > 0 { return "en \(dias) d \(horas) h" }
        if horas > 0 { return "en \(horas) h \(min) min" }
        return "en \(max(min, 1)) min"
    }

    static func hace(_ ahora: Date, _ d: Date) -> String {
        let s = Int(ahora.timeIntervalSince(d))
        if s < 60 { return "hace un momento" }
        if s < 3600 { return "hace \(s / 60) min" }
        if s < 86400 { return "hace \(s / 3600) h" }
        return "hace \(s / 86400) d"
    }
}

func colorUso(_ p: Double?) -> Color {
    guard let p else { return Tema.azul }
    return p >= 90 ? Color(hex: 0xFF5C5C) : p >= 70 ? Color(hex: 0xFFB333) : Tema.azul
}

struct RayasUso: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.28)))
            var trazo = Path()
            var x = -size.height
            while x < size.width {
                trazo.move(to: CGPoint(x: x, y: size.height))
                trazo.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 5
            }
            ctx.stroke(trazo, with: .color(color), lineWidth: 2)
        }
    }
}

struct BarraUso: View {
    let fraccion: Double
    let color: Color
    let rayado: Bool

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Forma(cornerRadius: 3.5).fill(Tema.velo(0.09))
                Group { if rayado { RayasUso(color: color) } else { color } }
                    .frame(width: fraccion > 0 ? max(g.size.width * fraccion, 7) : 0)
                    .clipShape(Forma(cornerRadius: 3.5))
            }
        }
        .frame(height: 7)
    }
}

/// El botón de la cabecera: "5h 7% | sem 43%". Al pasar el mouse abre el detalle; un clic lo deja abierto.
struct BotonUso: View {
    @EnvironmentObject var uso: Uso
    @State private var abierto = false
    @State private var fijado = false
    @State private var sobreBoton = false
    @State private var sobrePanel = false

    var body: some View {
        HStack(spacing: 0) {
            if uso.estado == nil {
                Text("Claude —").font(Letra.fuerte(11.5)).foregroundColor(Tema.gris).padding(.horizontal, 10)
            } else {
                segmento("5h", uso.porcentaje(uso.estado?.five_hour), principal: true)
                Rectangle().fill(Tema.linea).frame(width: 1)
                segmento("sem", uso.porcentaje(uso.estado?.seven_day), principal: false)
            }
        }
        .frame(height: 28)
        .background(Tema.velo(0.07))
        .clipShape(Forma(cornerRadius: 7))
        .overlay(Forma(cornerRadius: 7).strokeBorder(fijado ? Tema.azul.opacity(0.7) : Tema.velo(0.08)))
        .fixedSize()
        .contentShape(Rectangle())
        .onHover { sobreBoton = $0; revisar() }
        .onTapGesture {
            fijado.toggle()
            abierto = fijado || sobreBoton
        }
        .popover(isPresented: $abierto, arrowEdge: .bottom) {
            PanelUso()
                .environmentObject(uso)
                .onHover { sobrePanel = $0; revisar() }
        }
        .onChange(of: abierto) { _, a in
            uso.panelAbierto = a
            if a { uso.refrescar() } else { fijado = false }
        }
    }

    private func revisar() {
        if sobreBoton || sobrePanel {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if (sobreBoton || sobrePanel) && !abierto { abierto = true }
            }
        } else if !fijado {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if !sobreBoton && !sobrePanel && !fijado { abierto = false }
            }
        }
    }

    private func segmento(_ etiqueta: String, _ p: Double?, principal: Bool) -> some View {
        HStack(spacing: 4) {
            Text(etiqueta).font(Letra.texto(10.5)).foregroundColor(Tema.gris)
            Text(FormatoUso.pct(p))
                .font(Letra.fuerte(12))
                .monospacedDigit()
                .foregroundColor((p ?? 0) >= 70 ? colorUso(p) : Tema.texto.opacity(principal ? 1 : 0.75))
        }
        .padding(.horizontal, 9)
        .frame(maxHeight: .infinity)
        .background(principal ? Tema.velo(0.05) : Color.clear)
    }
}

struct PanelUso: View {
    @EnvironmentObject var uso: Uso

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Uso de Claude").font(Letra.texto(12)).foregroundColor(Tema.gris)
                Spacer()
                if let modelo = uso.estado?.session?.model {
                    Text(modelo).font(Letra.fuerte(12)).foregroundColor(Tema.texto.opacity(0.85))
                }
            }
            if let e = uso.estado {
                limite("Sesión de 5 h", e.five_hour, rayado: false)
                limite("Semana", e.seven_day, rayado: true)
                separador
                sesion(e.session)
                separador
                Text(pie(e))
                    .font(Letra.texto(11).italic())
                    .foregroundColor(Tema.gris)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Todavía no hay datos. Los escribe el status line de Claude Code (el de WarpConsumo): envía un mensaje en Claude Code y aparecen aquí.")
                    .font(Letra.texto(12.5))
                    .foregroundColor(Tema.texto.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .background(Tema.lado)
    }

    private var separador: some View { Rectangle().fill(Tema.linea).frame(height: 1) }

    private func limite(_ titulo: String, _ v: UsoVentana?, rayado: Bool) -> some View {
        let p = uso.porcentaje(v)
        let color = colorUso(p)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Group { if rayado { RayasUso(color: color) } else { color } }
                    .frame(width: 11, height: 11)
                    .clipShape(Forma(cornerRadius: 3))
                Text(titulo).font(Letra.fuerte(14)).foregroundColor(Tema.texto)
                Spacer()
                Text(FormatoUso.pct(p))
                    .font(Letra.fuerte(14))
                    .monospacedDigit()
                    .foregroundColor((p ?? 0) >= 70 ? color : Tema.texto)
            }
            BarraUso(fraccion: (p ?? 0) / 100, color: color, rayado: rayado)
            Text(detalle(v)).font(Letra.texto(11.5)).foregroundColor(Tema.gris)
        }
    }

    private func detalle(_ v: UsoVentana?) -> String {
        guard let v, v.used_percentage != nil else { return "Sin datos todavía" }
        if uso.reiniciada(v) { return "Ya se reinició: sin uso en la ventana nueva" }
        guard let r = v.resets_at else { return "Usado en esta ventana" }
        let d = Date(timeIntervalSince1970: r)
        return "Se reinicia \(FormatoUso.cuando(d)) · \(FormatoUso.falta(uso.ahora, d))"
    }

    private func sesion(_ s: UsoSesion?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Última sesión de Claude Code").font(Letra.fuerte(12)).foregroundColor(Tema.texto.opacity(0.85))
            fila("Carpeta", s?.dir.flatMap { $0.isEmpty ? nil : $0 } ?? "—")
            fila("Contexto usado", FormatoUso.pct(s?.context_pct))
            fila("Costo equivalente (API)", s?.cost_usd.map { String(format: "$%.2f", $0) } ?? "—")
        }
    }

    private func fila(_ nombre: String, _ valor: String) -> some View {
        HStack(spacing: 8) {
            Circle().strokeBorder(Tema.azul, lineWidth: 1.5).frame(width: 7, height: 7)
            Text(nombre).font(Letra.texto(12)).foregroundColor(Tema.gris)
            Spacer()
            Text(valor).font(Letra.fuerte(12)).monospacedDigit().foregroundColor(Tema.texto).lineLimit(1)
        }
    }

    private func pie(_ e: UsoEstado) -> String {
        let marca = e.limits_updated_at ?? e.updated_at
        let cuando = marca.map { FormatoUso.hace(uso.ahora, Date(timeIntervalSince1970: $0)) } ?? "sin fecha"
        return "Actualizado \(cuando). Clic en el botón para dejarlo abierto."
    }
}
