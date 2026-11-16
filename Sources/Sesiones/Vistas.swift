import AppKit
import SwiftUI

// MARK: - colores

enum Tema {
    static let fondo = Color(hex: 0x0E1730)      // noche azul
    static let lado = Color(hex: 0x0A1126)
    static let linea = Color(hex: 0x8CAAE6, 0.13)
    static let texto = Color(hex: 0xEEF2FB)
    static let gris = Color(hex: 0x93A6CC)
    static let tenue = Color(hex: 0x5E7099)
    static let azul = Color(hex: 0x4D8AE6)       // azul cielo
    static let sel = Color(hex: 0x4D8AE6, 0.20)
    static let hover = Color(hex: 0xFFFFFF, 0.05)
    static let tarjeta = Color(hex: 0x16244A, 0.72)
}

// MARK: - raíz

struct Raiz: View {
    @EnvironmentObject var store: Store
    @State private var nombreNuevo = ""

    var body: some View {
        HStack(spacing: 0) {
            Lateral()
                .frame(width: 236)
                .background(Tema.lado)
            Rectangle().fill(Tema.linea).frame(width: 1)
            VStack(spacing: 0) {
                Cabecera()
                Rectangle().fill(Tema.linea).frame(height: 1)
                ZStack {
                    Tema.fondo
                    switch store.vista {
                    case .inicio: Cuadricula()
                    case .carpeta, .buscar: ListaSesiones()
                    case .terminal: AreaTerminal()
                    }
                }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .alert("Nueva carpeta", isPresented: $store.pideNuevaCarpeta) {
            TextField("Nombre", text: $nombreNuevo)
            Button("Crear") { store.crearCarpeta(nombreNuevo); nombreNuevo = "" }
            Button("Cancelar", role: .cancel) { nombreNuevo = "" }
        }
        .alert(store.aviso ?? "", isPresented: Binding(get: { store.aviso != nil }, set: { if !$0 { store.aviso = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}

// MARK: - barra lateral

struct Lateral: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 46) // semáforos de la ventana
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    Titulo(texto: "Carpetas")
                    FilaLateral(icono: "square.grid.2x2", nombre: "Todas", detalle: "\(store.total)", activa: store.vista == .inicio) {
                        store.vista = .inicio
                    }
                    ForEach(store.carpetas) { c in
                        FilaCarpetaLateral(carpeta: c)
                    }
                    HStack {
                        Titulo(texto: "Abiertas")
                        Spacer()
                        Button { store.nuevaTerminal() } label: {
                            Image(systemName: "plus").font(Letra.fuerte(11)).foregroundColor(Tema.gris)
                                .frame(width: 22, height: 22).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Terminal nueva (⌘N)")
                        .padding(.trailing, 10)
                        .padding(.top, 14)
                    }
                    if store.terminales.isEmpty {
                        Text("Abre una sesión y aparece aquí")
                            .font(Letra.texto(11.5)).foregroundColor(Tema.tenue)
                            .padding(.horizontal, 18).padding(.vertical, 6)
                    }
                    ForEach(Array(store.terminales.enumerated()), id: \.element.id) { k, t in
                        FilaTerminal(term: t, numero: k + 1)
                    }
                }
                .padding(.bottom, 16)
            }
        }
    }
}

struct Titulo: View {
    let texto: String
    var body: some View {
        Text(texto)
            .font(Letra.fuerte(11))
            .foregroundColor(Tema.tenue)
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }
}

struct FilaLateral: View {
    let icono: String
    let nombre: String
    let detalle: String
    let activa: Bool
    var resaltada = false
    let accion: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icono)
                .font(Letra.texto(12))
                .foregroundColor(activa ? Tema.texto : Tema.gris)
                .frame(width: 16)
            Text(nombre).font(Letra.texto(13)).foregroundColor(Tema.texto).lineLimit(1)
            Spacer(minLength: 4)
            Text(detalle).font(Letra.texto(11.5)).foregroundColor(Tema.tenue)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(resaltada ? Tema.azul.opacity(0.5) : activa ? Tema.sel : hover ? Tema.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: accion)
        .padding(.horizontal, 8)
    }
}

struct FilaCarpetaLateral: View {
    @EnvironmentObject var store: Store
    let carpeta: Carpeta
    @State private var destino = false

    var body: some View {
        FilaLateral(icono: "folder.fill", nombre: carpeta.nombre, detalle: "\(carpeta.sesiones.count)",
                    activa: store.vista == .carpeta(carpeta.nombre), resaltada: destino) {
            store.abrirCarpeta(carpeta.nombre)
        }
        .dropDestination(for: String.self) { ids, _ in
            store.mover(ids, a: carpeta.nombre)
            return true
        } isTargeted: { destino = $0 }
        .contextMenu { MenuCarpeta(carpeta: carpeta) }
    }
}

struct FilaTerminal: View {
    @EnvironmentObject var store: Store
    @ObservedObject var term: Term
    let numero: Int
    @State private var hover = false

    var activa: Bool { store.vista == .terminal(term.id) || store.terminalLado === term }

    var body: some View {
        HStack(spacing: 8) {
            IndicadorEstado(term: term, activa: activa)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(term.titulo).font(Letra.texto(12.5)).foregroundColor(Tema.texto).lineLimit(1)
                Text((term.cwd as NSString).lastPathComponent).font(Letra.texto(11)).foregroundColor(Tema.tenue).lineLimit(1)
            }
            Spacer(minLength: 2)
            if hover {
                Button { store.cerrar(term) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(Tema.gris)
                        .frame(width: 18, height: 18).background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Cerrar (⌘W)")
            } else if numero <= 9 {
                Text("⌘\(numero)").font(Letra.texto(10.5)).foregroundColor(Tema.tenue)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 6).fill(activa ? Tema.sel : hover ? Tema.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.mostrar(term) }
        .contextMenu {
            Button("Abrir al lado") { store.abrirAlLado(term) }.disabled(store.terminalActiva == nil || store.terminalActiva === term)
            Divider()
            Button("Cerrar") { store.cerrar(term) }
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - cabecera

struct Cabecera: View {
    @EnvironmentObject var store: Store
    @FocusState private var buscando: Bool

    var titulo: String {
        switch store.vista {
        case .inicio: return "Carpetas"
        case .carpeta(let n): return n
        case .buscar: return "Buscar"
        case .terminal: return store.terminalActiva?.titulo ?? "Terminal"
        }
    }

    var subtitulo: String {
        switch store.vista {
        case .inicio: return "\(store.total) sesiones de Claude y Codex"
        case .carpeta(let n):
            let d = store.dirDeTrabajo(n).dir.replacingOccurrences(of: Datos.home, with: "~")
            return "\(store.sesiones(de: n).count) sesiones · las nuevas se abren en \(d)"
        case .buscar: return "\(store.resultados.count) resultados"
        case .terminal: return store.terminalActiva.map { $0.cwd.replacingOccurrences(of: Datos.home, with: "~") } ?? ""
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if store.vista != .inicio {
                Button {
                    if store.vista == .buscar { store.query = "" } else { store.vista = .inicio }
                } label: {
                    Image(systemName: "chevron.left").font(Letra.fuerte(13)).foregroundColor(Tema.gris)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Volver a las carpetas (⌘T)")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(titulo).font(Letra.titulo(15)).tracking(-0.3).foregroundColor(Tema.texto).lineLimit(1)
                Text(subtitulo).font(Letra.texto(11.5)).foregroundColor(Tema.gris).lineLimit(1)
            }
            Spacer(minLength: 12)
            if case .carpeta(let n) = store.vista { MenuNuevaSesion(carpeta: n) }
            if store.vista == .inicio {
                Button { store.pideNuevaCarpeta = true } label: {
                    Label("Nueva carpeta", systemImage: "folder.badge.plus").font(Letra.texto(12.5))
                }
                .buttonStyle(Pastilla())
                .help("⇧⌘N")
            }
            if case .terminal = store.vista {
                Button { store.buscarEnTerminal() } label: { Image(systemName: "magnifyingglass").font(Letra.texto(12.5)) }
                    .buttonStyle(Pastilla()).help("Buscar en la terminal (⌘F)")
                Button { store.dividir() } label: {
                    Image(systemName: store.terminalLado == nil ? "rectangle.split.2x1" : "rectangle").font(Letra.texto(12.5))
                }
                .buttonStyle(Pastilla()).help(store.terminalLado == nil ? "Dividir pantalla (⌘D)" : "Quitar la división (⌘D)")
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(Letra.texto(11.5)).foregroundColor(Tema.gris)
                    TextField("Buscar sesiones", text: $store.query)
                        .textFieldStyle(.plain)
                        .font(Letra.texto(12.5))
                        .focused($buscando)
                        .onExitCommand { store.query = ""; buscando = false }
                    if !store.query.isEmpty {
                        Button { store.query = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(Letra.texto(11)).foregroundColor(Tema.gris)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .frame(width: 230, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .frame(height: 56)
        .background(Tema.fondo)
        .onChange(of: store.pideBusqueda) { _, _ in buscando = true }
    }
}

struct Pastilla: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(Tema.texto)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.09)))
    }
}

struct MenuNuevaSesion: View {
    @EnvironmentObject var store: Store
    let carpeta: String

    var dirs: [String] {
        var vistos = Set<String>(), out: [String] = []
        for s in store.sesiones(de: carpeta) where !vistos.contains(s.cwd) && FileManager.default.fileExists(atPath: s.cwd) {
            vistos.insert(s.cwd); out.append(s.cwd)
            if out.count == 6 { break }
        }
        return out
    }

    var body: some View {
        let trabajo = store.dirDeTrabajo(carpeta)
        let corto = trabajo.dir.replacingOccurrences(of: Datos.home, with: "~")
        Menu {
            Button("Codex en \(corto)") { store.sesionAqui(carpeta, motor: .codex) }
            let otras = dirs.filter { $0 != trabajo.dir }
            if !otras.isEmpty {
                Section("Claude en otra carpeta de esta") {
                    ForEach(otras.prefix(5), id: \.self) { d in
                        Button(d.replacingOccurrences(of: Datos.home, with: "~")) { store.nuevaSesion(en: d, carpeta: carpeta) }
                    }
                }
            }
            Divider()
            Button("Elegir otra carpeta del disco…") {
                if let d = elegirDirectorio(trabajo.dir) { store.nuevaSesion(en: d, carpeta: carpeta) }
            }
            Button("Cambiar carpeta de trabajo…") { store.cambiarDir(carpeta) }
        } label: {
            Label("Nueva sesión", systemImage: "plus").font(Letra.texto(12.5))
        } primaryAction: {
            store.sesionAqui(carpeta)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.09)))
        .help("Abre Claude en \(corto)\(trabajo.nueva ? " (se crea al abrir)" : ""). La flecha tiene más opciones.")
    }
}

@MainActor
func elegirDirectorio(_ inicio: String?) -> String? {
    let p = NSOpenPanel()
    p.canChooseDirectories = true
    p.canChooseFiles = false
    p.canCreateDirectories = true
    p.prompt = "Abrir aquí"
    if let inicio { p.directoryURL = URL(fileURLWithPath: inicio) }
    return p.runModal() == .OK ? p.url?.path : nil
}

// MARK: - cuadrícula de carpetas

struct Cuadricula: View {
    @EnvironmentObject var store: Store
    @FocusState private var foco: Bool
    @State private var ancho: CGFloat = 900

    let minimo: CGFloat = 150, espacio: CGFloat = 22, margen: CGFloat = 44

    var porFila: Int { max(1, Int((ancho - 2 * margen + espacio) / (minimo + espacio))) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !store.recientes.isEmpty {
                    Text("Recientes")
                        .font(Letra.titulo(13)).foregroundColor(Tema.gris)
                        .padding(.bottom, 10)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 400), spacing: 12)], spacing: 12) {
                        ForEach(store.recientes) { s in TarjetaReciente(sesion: s) }
                    }
                    .padding(.bottom, 34)
                    Text("Carpetas")
                        .font(Letra.titulo(13)).foregroundColor(Tema.gris)
                        .padding(.bottom, 14)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minimo, maximum: 200), spacing: espacio)], spacing: 30) {
                    ForEach(store.carpetas) { c in
                        Baldosa(carpeta: c)
                    }
                }
            }
            .padding(margen)
        }
        .background(GeometryReader { g in Color.clear.onAppear { ancho = g.size.width }.onChange(of: g.size.width) { _, w in ancho = w } })
        .background(FondoNoche())
        .focusable()
        .focusEffectDisabled()
        .focused($foco)
        .onAppear { foco = true }
        .onKeyPress(.leftArrow) { paso(-1) }
        .onKeyPress(.rightArrow) { paso(1) }
        .onKeyPress(.upArrow) { paso(-porFila) }
        .onKeyPress(.downArrow) { paso(porFila) }
        .onKeyPress(.return) {
            if let n = store.carpetaSel { store.abrirCarpeta(n) }
            return .handled
        }
    }

    private func paso(_ d: Int) -> KeyPress.Result {
        let nombres = store.carpetas.map(\.nombre)
        guard !nombres.isEmpty else { return .handled }
        let k = nombres.firstIndex(of: store.carpetaSel ?? "") ?? 0
        store.carpetaSel = nombres[min(nombres.count - 1, max(0, k + d))]
        return .handled
    }
}

struct Baldosa: View {
    @EnvironmentObject var store: Store
    let carpeta: Carpeta
    @State private var destino = false

    var sel: Bool { store.carpetaSel == carpeta.nombre }

    var body: some View {
        VStack(spacing: 7) {
            CarpetaPixel(abierta: sel)
                .frame(width: 112, height: 84)
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 9).fill(destino ? Tema.azul.opacity(0.35) : sel ? Tema.sel : .clear))
            Text(carpeta.nombre)
                .font(Letra.fuerte(13.5))
                .foregroundColor(sel ? .white : Tema.texto)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(sel ? Tema.azul : .clear))
                .shadow(color: .black.opacity(sel ? 0 : 0.45), radius: 3, y: 1)
            Text(carpeta.sesiones.count == 1 ? "1 ítem" : "\(carpeta.sesiones.count) ítems")
                .font(Letra.texto(12.5))
                .foregroundColor(Tema.gris)
                .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.abrirCarpeta(carpeta.nombre) }
        .simultaneousGesture(TapGesture().onEnded { store.carpetaSel = carpeta.nombre })
        .contextMenu { MenuCarpeta(carpeta: carpeta) }
        .draggable("carpeta:" + carpeta.nombre)
        .dropDestination(for: String.self) { items, _ in
            if let c = items.first, c.hasPrefix("carpeta:") {
                store.mueveCarpeta(String(c.dropFirst(8)), antesDe: carpeta.nombre)
            } else {
                store.mover(items, a: carpeta.nombre)
            }
            return true
        } isTargeted: { destino = $0 }
    }
}

struct MenuCarpeta: View {
    @EnvironmentObject var store: Store
    let carpeta: Carpeta

    var body: some View {
        Button("Abrir") { store.abrirCarpeta(carpeta.nombre) }
        Button("Renombrar…") {
            if let n = pideTexto("Renombrar carpeta", valor: carpeta.nombre, boton: "Renombrar") { store.renombrar(carpeta.nombre, n) }
        }
        .disabled(carpeta.auto)
        Divider()
        Button("Eliminar carpeta…") {
            if confirma("¿Eliminar la carpeta «\(carpeta.nombre)»?", "Las sesiones no se borran: vuelven a repartirse solas en las otras carpetas.", "Eliminar") {
                store.borrar(carpeta.nombre)
            }
        }
        .disabled(carpeta.fija)
    }
}

@MainActor
func pideTexto(_ titulo: String, valor: String, boton: String) -> String? {
    let a = NSAlert()
    a.messageText = titulo
    a.addButton(withTitle: boton)
    a.addButton(withTitle: "Cancelar")
    let campo = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    campo.stringValue = valor
    a.accessoryView = campo
    a.window.initialFirstResponder = campo
    return a.runModal() == .alertFirstButtonReturn ? campo.stringValue : nil
}

@MainActor
func confirma(_ msg: String, _ detalle: String, _ boton: String) -> Bool {
    let a = NSAlert()
    a.messageText = msg
    a.informativeText = detalle
    a.addButton(withTitle: boton)
    a.addButton(withTitle: "Cancelar")
    return a.runModal() == .alertFirstButtonReturn
}

/// La carpeta gris de tu referencia (estilo Finder oscuro), dibujada en vectores.
struct IconoCarpeta: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let atras = Color(white: 0.23)
            // pestaña + fondo
            var fondo = Path(roundedRect: CGRect(x: 0, y: h * 0.09, width: w, height: h * 0.91), cornerRadius: w * 0.06)
            fondo.addPath(Path(roundedRect: CGRect(x: 0, y: 0, width: w * 0.4, height: h * 0.2), cornerRadius: w * 0.05))
            ctx.fill(fondo, with: .color(atras))
            // hoja
            ctx.fill(Path(roundedRect: CGRect(x: w * 0.055, y: h * 0.17, width: w * 0.89, height: h * 0.25), cornerRadius: w * 0.025),
                     with: .color(Color(white: 0.96)))
            // frente con degradado
            let frente = CGRect(x: 0, y: h * 0.255, width: w, height: h * 0.745)
            ctx.fill(Path(roundedRect: frente, cornerRadius: w * 0.06),
                     with: .linearGradient(Gradient(colors: [Color(white: 0.40), Color(white: 0.31)]),
                                           startPoint: CGPoint(x: 0, y: frente.minY), endPoint: CGPoint(x: 0, y: frente.maxY)))
            // brillo del borde superior
            ctx.fill(Path(CGRect(x: w * 0.04, y: frente.minY, width: w * 0.92, height: 1)), with: .color(.white.opacity(0.14)))
        }
    }
}

// MARK: - lista de sesiones

struct ListaSesiones: View {
    @EnvironmentObject var store: Store
    @FocusState private var foco: Bool

    var body: some View {
        let lista = store.listaActual
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if lista.isEmpty {
                        if case .carpeta(let n) = store.vista {
                            CarpetaVacia(carpeta: n).padding(.top, 70)
                        } else {
                            Text("Nada con esas palabras.").font(Letra.texto(13)).foregroundColor(Tema.gris).padding(.top, 60)
                        }
                    }
                    ForEach(lista) { s in
                        FilaSesion(sesion: s, enBusqueda: store.vista == .buscar)
                            .id(s.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($foco)
            .onAppear { foco = store.vista != .buscar }
            .onKeyPress(.upArrow) { paso(-1, lista, proxy) }
            .onKeyPress(.downArrow) { paso(1, lista, proxy) }
            .onKeyPress(.return) {
                // el mismo Enter que abrió la carpeta no debe abrir también una sesión
                guard Date().timeIntervalSince(store.cambioDeVista) > 0.4 else { return .handled }
                if let s = lista.first(where: { $0.id == store.sesionSel }) ?? lista.first { store.retomar(s) }
                return .handled
            }
            .onKeyPress(.escape) { store.query = ""; store.vista = .inicio; return .handled }
        }
    }

    private func paso(_ d: Int, _ lista: [Sesion], _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !lista.isEmpty else { return .handled }
        let k = lista.firstIndex { $0.id == store.sesionSel } ?? -1
        let j = min(lista.count - 1, max(0, k + d))
        store.sesionSel = lista[j].id
        proxy.scrollTo(lista[j].id)
        return .handled
    }
}

struct FilaSesion: View {
    @EnvironmentObject var store: Store
    let sesion: Sesion
    let enBusqueda: Bool
    @State private var hover = false

    var sel: Bool { store.sesionSel == sesion.id }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(store.abiertas.contains(sesion.id) ? Color.green : .clear)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(sesion.titulo)
                        .font(Letra.fuerte(13.5))
                        .foregroundColor(Tema.texto)
                        .lineLimit(1)
                    if sesion.motor == .codex { Insignia(texto: "Codex") }
                }
                Text(meta)
                    .font(Letra.texto(12))
                    .foregroundColor(Tema.gris)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(hace(sesion.mtime))
                .font(Letra.texto(12))
                .foregroundColor(Tema.gris)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(sel ? Tema.sel : hover ? Tema.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { store.retomar(sesion) }
        .simultaneousGesture(TapGesture().onEnded { store.sesionSel = sesion.id })
        .draggable(sesion.id) {
            Label(sesion.titulo, systemImage: "sparkle").padding(6).background(Tema.lado).cornerRadius(6)
        }
        .contextMenu {
            Button("Retomar") { store.retomar(sesion) }
            Menu("Mover a") {
                ForEach(store.carpetas) { c in
                    Button(c.nombre) { store.mover([sesion.id], a: c.nombre) }.disabled(c.nombre == sesion.carpeta)
                }
                Divider()
                Button("Carpeta nueva…") {
                    if let n = pideTexto("Nueva carpeta", valor: "", boton: "Crear y mover") {
                        store.crearCarpeta(n)
                        store.mover([sesion.id], a: Datos.limpia(n))
                    }
                }
            }
            if sesion.carpeta == "Archivo" {
                Button("Sacar del archivo") { store.archivar([sesion.id], false) }
            } else {
                Button("Archivar") { store.archivar([sesion.id], true) }
            }
            Divider()
            Button("Terminal en esta carpeta") { store.nuevaTerminal(en: sesion.cwd) }
            Button("Mostrar en Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: sesion.cwd)) }
            Button("Copiar ID de la sesión") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sesion.id, forType: .string)
            }
        }
    }

    var meta: String {
        var partes = [String]()
        if enBusqueda { partes.append(sesion.carpeta) }
        partes.append(sesion.proyecto + (sesion.sdk ? " · automática (SDK)" : ""))
        partes.append(sesion.prompt)
        return partes.joined(separator: "  ·  ")
    }
}

// MARK: - terminal

final class Contenedor: NSView {
    var term: NSView? {
        didSet {
            guard oldValue !== term else { return }
            oldValue?.removeFromSuperview()
            if let term { addSubview(term); needsLayout = true }
        }
    }
    override func layout() {
        super.layout()
        term?.frame = bounds.insetBy(dx: 10, dy: 8)
    }
}

struct TerminalHost: NSViewRepresentable {
    let term: Term

    func makeNSView(context: Context) -> Contenedor {
        let v = Contenedor()
        v.wantsLayer = true
        v.layer?.backgroundColor = Term.fondo.cgColor
        return v
    }

    func updateNSView(_ v: Contenedor, context: Context) {
        term.iniciar()
        guard v.term !== term.vista else { return }
        v.term = term.vista
        let t = term.vista
        DispatchQueue.main.async { t.window?.makeFirstResponder(t) }
    }
}

// MARK: - piezas nuevas

/// Pantalla de terminal, sola o dividida en dos.
struct AreaTerminal: View {
    @EnvironmentObject var store: Store

    var body: some View {
        if let a = store.terminalActiva {
            VStack(spacing: 0) {
                if let l = store.terminalLado {
                    HStack(spacing: 0) {
                        Panel(term: a, principal: true)
                        Rectangle().fill(Tema.linea).frame(width: 1)
                        Panel(term: l, principal: false)
                    }
                } else {
                    TerminalHost(term: a)
                }
                BarraTerminal(term: a)
            }
        }
    }
}

struct Panel: View {
    @EnvironmentObject var store: Store
    @ObservedObject var term: Term
    let principal: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                IndicadorEstado(term: term, activa: true)
                Text(term.titulo).font(Letra.fuerte(11.5)).foregroundColor(Tema.gris).lineLimit(1)
                Spacer()
                if !principal {
                    Button { store.lado = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(Tema.gris)
                    }
                    .buttonStyle(.plain).help("Quitar de la división (la terminal sigue abierta)")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Tema.lado)
            TerminalHost(term: term)
        }
    }
}

/// Punto de estado: girando mientras trabaja, naranja si pide permiso, azul si terminó y no lo has visto.
struct IndicadorEstado: View {
    @ObservedObject var term: Term
    let activa: Bool

    var body: some View {
        ZStack {
            if !term.iniciado {
                Image(systemName: "moon.zzz").font(Letra.texto(10)).foregroundColor(Tema.tenue)
            } else {
                switch term.estado {
                case .trabajando:
                    ProgressView().controlSize(.mini).scaleEffect(0.8)
                case .permiso:
                    Image(systemName: "exclamationmark.circle.fill").font(Letra.texto(11)).foregroundColor(.orange)
                case .listo where term.sinVer:
                    Circle().fill(Color(red: 0.04, green: 0.52, blue: 1)).frame(width: 8, height: 8)
                default:
                    Image(systemName: term.motor == nil ? "terminal" : "sparkle")
                        .font(Letra.texto(11)).foregroundColor(activa ? Tema.texto : Tema.gris)
                }
            }
        }
        .frame(width: 16, height: 16)
        .help(ayuda)
    }

    var ayuda: String {
        if !term.iniciado { return "Dormida: arranca cuando la abras" }
        switch term.estado {
        case .trabajando: return "Trabajando"
        case .permiso: return "Necesita tu permiso"
        case .listo: return "Terminó"
        case .nada: return ""
        }
    }
}

struct TarjetaReciente: View {
    @EnvironmentObject var store: Store
    let sesion: Sesion
    @State private var hover = false

    var body: some View {
        Button { store.retomar(sesion) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if store.abiertas.contains(sesion.id) { Circle().fill(Color.green).frame(width: 6, height: 6) }
                    Text(sesion.titulo)
                        .font(Letra.fuerte(13)).foregroundColor(Tema.texto)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if sesion.motor == .codex { Insignia(texto: "Codex") }
                }
                Text("\(sesion.carpeta) · \(sesion.proyecto) · \(hace(sesion.mtime))")
                    .font(Letra.texto(11.5)).foregroundColor(Tema.gris).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(hover ? Color(hex: 0x1D2F5E, 0.85) : Tema.tarjeta))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Tema.linea))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .draggable(sesion.id)
        .help(sesion.prompt)
    }
}

struct Insignia: View {
    let texto: String
    var body: some View {
        Text(texto)
            .font(Letra.fuerte(10))
            .foregroundColor(Tema.gris)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).stroke(Tema.tenue))
    }
}

struct CarpetaVacia: View {
    @EnvironmentObject var store: Store
    let carpeta: String

    var body: some View {
        let t = store.dirDeTrabajo(carpeta)
        VStack(spacing: 14) {
            CarpetaPixel().frame(width: 80, height: 60)
            Text("Todavía no hay sesiones aquí").font(Letra.titulo(17)).foregroundColor(Tema.texto)
            HStack(spacing: 10) {
                Button { store.sesionAqui(carpeta) } label: { Label("Empezar con Claude", systemImage: "sparkle") }
                    .buttonStyle(PastillaAzul())
                Button { store.sesionAqui(carpeta, motor: .codex) } label: { Text("Con Codex") }
                    .buttonStyle(Pastilla())
            }
            HStack(spacing: 6) {
                Text("Se abre en \(t.dir.replacingOccurrences(of: Datos.home, with: "~"))\(t.nueva ? " (la creo al empezar)" : "")")
                Button("Cambiar") { store.cambiarDir(carpeta) }.buttonStyle(.link)
            }
            .font(Letra.texto(12)).foregroundColor(Tema.gris)
            Text("También puedes arrastrar sesiones aquí desde otra carpeta.").font(Letra.texto(12)).foregroundColor(Tema.tenue)
        }
        .frame(maxWidth: .infinity)
    }
}

struct PastillaAzul: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Letra.fuerte(13))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Tema.azul.opacity(configuration.isPressed ? 0.8 : 1)))
    }
}
