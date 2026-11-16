import AppKit
import SwiftUI

// MARK: - colores

// los colores viven en Temas.swift (Tema, Paleta)

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
        .preferredColorScheme(Tema.p.oscuro ? .dark : .light)
        .alert("Nueva carpeta", isPresented: $store.pideNuevaCarpeta) {
            TextField("Nombre", text: $nombreNuevo)
            Button("Crear") { store.crearCarpeta(nombreNuevo); nombreNuevo = "" }
            Button("Cancelar", role: .cancel) { nombreNuevo = "" }
        } message: {
            Text("Se crea en \(Datos.corta(store.dondeCrear))")
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
            HStack { // semáforos de la ventana a la izquierda, el tema a la derecha
                Spacer()
                MenuTema().padding(.trailing, 14)
            }
            .frame(height: 46)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    Titulo(texto: store.nombreRaiz)
                    FilaLateral(icono: "square.grid.2x2", nombre: "Todas", detalle: "\(store.total)", activa: store.vista == .inicio, margen: 20) {
                        store.vista = .inicio
                    }
                    // tus carpetas, igual que en el Finder
                    ForEach(store.carpetas.filter { !$0.grupo }) { c in
                        RamaLateral(carpeta: c, nivel: 0)
                    }
                    // lo que no está dentro de ninguna
                    let aparte = store.carpetas.filter(\.grupo)
                    if !aparte.isEmpty {
                        Titulo(texto: "Aparte")
                        ForEach(aparte) { c in
                            RamaLateral(carpeta: c, nivel: 0)
                        }
                    }
                    CabeceraAbiertas()
                    if store.terminales.isEmpty && store.grupos.isEmpty {
                        Text("Abre una sesión y aparece aquí")
                            .font(Letra.texto(11.5)).foregroundColor(Tema.tenue)
                            .padding(.horizontal, 18).padding(.vertical, 6)
                    }
                    let orden = store.ordenadas.map(\.id)
                    ForEach(store.grupos) { g in
                        FilaGrupo(grupo: g)
                        if !g.plegado {
                            let dentro = store.pestanas(de: g.id)
                            if dentro.isEmpty {
                                Text("Arrastra pestañas aquí")
                                    .font(Letra.texto(11.5)).foregroundColor(Tema.tenue)
                                    .padding(.leading, 46).padding(.vertical, 4)
                            }
                            ForEach(dentro) { t in
                                FilaTerminal(term: t, numero: (orden.firstIndex(of: t.id) ?? 99) + 1, sangria: 14)
                            }
                        }
                    }
                    ForEach(store.sueltas) { t in
                        FilaTerminal(term: t, numero: (orden.firstIndex(of: t.id) ?? 99) + 1)
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
    var margen: CGFloat = 10
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
        .padding(.leading, margen)
        .padding(.trailing, 10)
        .frame(height: 28)
        .background(Forma(cornerRadius: 6).fill(resaltada ? Tema.azul.opacity(0.5) : activa ? Tema.sel : hover ? Tema.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: accion)
        .padding(.horizontal, 8)
    }
}

extension Carpeta {
    var icono: String {
        if id == Datos.nArchivo { return "archivebox" }
        if id == Datos.nFuera { return "folder" }
        if id == Datos.nPerdidas || (ruta == nil && !grupo) { return "questionmark.folder" }
        if grupo { return ruta == nil ? "flask" : "tray.full" } // Pruebas / las sueltas
        return "folder.fill"
    }

    var cuantas: String { total == 0 ? "vacía" : total == 1 ? "1 sesión" : "\(total) sesiones" }
}

/// Una carpeta de la barra lateral y, si está desplegada, las que tiene dentro.
struct RamaLateral: View {
    @EnvironmentObject var store: Store
    let carpeta: Carpeta
    let nivel: Int

    var body: some View {
        FilaCarpetaLateral(carpeta: carpeta, nivel: nivel)
        if store.desplegadas.contains(carpeta.id) {
            ForEach(carpeta.hijos) { h in
                RamaLateral(carpeta: h, nivel: nivel + 1)
            }
        }
    }
}

struct FilaCarpetaLateral: View {
    @EnvironmentObject var store: Store
    let carpeta: Carpeta
    let nivel: Int
    @State private var destino = false
    @State private var hover = false

    var activa: Bool { store.vista == .carpeta(carpeta.id) }
    var abierta: Bool { store.desplegadas.contains(carpeta.id) }
    var archivo: Bool { carpeta.id == Datos.nArchivo }

    var body: some View {
        HStack(spacing: 0) {
            // la flecha despliega; el resto de la fila abre la carpeta
            Image(systemName: "chevron.right")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundColor(Tema.tenue)
                .rotationEffect(.degrees(abierta ? 90 : 0))
                .animation(.easeOut(duration: 0.12), value: abierta)
                .frame(width: 14, height: 28)
                .contentShape(Rectangle())
                .opacity(carpeta.hijos.isEmpty ? 0 : 1)
                .allowsHitTesting(!carpeta.hijos.isEmpty)
                .onTapGesture { store.desplegar(carpeta.id) }
            HStack(spacing: 8) {
                Image(systemName: carpeta.icono)
                    .font(Letra.texto(12))
                    .foregroundColor(activa ? Tema.texto : Tema.gris)
                    .frame(width: 16)
                Text(carpeta.nombre).font(Letra.texto(13)).foregroundColor(carpeta.total == 0 ? Tema.gris : Tema.texto).lineLimit(1)
                Spacer(minLength: 4)
                if carpeta.total > 0 {
                    Text("\(carpeta.total)").font(Letra.texto(11.5)).foregroundColor(Tema.tenue)
                }
            }
        }
        .padding(.leading, 6 + CGFloat(nivel) * 14)
        .padding(.trailing, 10)
        .frame(height: 28)
        .background(Forma(cornerRadius: 6).fill(destino ? Tema.azul.opacity(0.5) : activa ? Tema.sel : hover ? Tema.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.abrirCarpeta(carpeta.id) }
        .padding(.horizontal, 8)
        .dropDestination(for: String.self) { ids, _ in
            guard archivo else { return false }
            store.mover(ids, a: carpeta.id)
            return true
        } isTargeted: { destino = $0 && archivo }
        .contextMenu { MenuCarpeta(carpeta: carpeta) }
        .help(carpeta.ruta.map(Datos.corta) ?? "")
    }
}

/// "Abiertas", con los botones de grupo nuevo y terminal nueva. Soltar una pestaña aquí la saca de su grupo.
struct CabeceraAbiertas: View {
    @EnvironmentObject var store: Store
    @State private var destino = false

    var body: some View {
        HStack(spacing: 2) {
            Titulo(texto: "Abiertas")
            Spacer()
            Group {
                Button { store.nuevoGrupo() } label: {
                    Image(systemName: "square.3.layers.3d").font(Letra.fuerte(11)).foregroundColor(Tema.gris)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Grupo de pestañas nuevo")
                Button { store.nuevaTerminal() } label: {
                    Image(systemName: "plus").font(Letra.fuerte(11)).foregroundColor(Tema.gris)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Terminal nueva (⌘N)")
            }
            .padding(.top, 14)
        }
        .padding(.trailing, 10)
        .background(Forma(cornerRadius: 6).fill(destino ? Tema.azul.opacity(0.35) : .clear).padding(.horizontal, 8))
        .dropDestination(for: String.self) { items, _ in
            store.soltar(items, enGrupo: nil)
        } isTargeted: { destino = $0 }
    }
}

/// Cabecera de un grupo de pestañas: flecha para plegar, nombre y cuántas tiene.
struct FilaGrupo: View {
    @EnvironmentObject var store: Store
    let grupo: Grupo
    @State private var hover = false
    @State private var destino = false

    var clave: String { "grupo:" + grupo.id.uuidString }
    var cuantas: Int { store.pestanas(de: grupo.id).count }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Tema.gris)
                .rotationEffect(.degrees(grupo.plegado ? 0 : 90))
                .animation(.easeOut(duration: 0.12), value: grupo.plegado)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                if store.editando == clave {
                    CampoNombre(inicial: grupo.nombre, fuente: Letra.fuerte(13)) { n in
                        if let n { store.renombrarGrupo(grupo.id, n) }
                        store.finEdicion()
                    }
                } else {
                    Text(grupo.nombre).font(Letra.fuerte(13)).foregroundColor(Tema.texto).lineLimit(1)
                }
                Text(cuantas == 1 ? "1 pestaña" : "\(cuantas) pestañas").font(Letra.texto(11)).foregroundColor(Tema.tenue)
            }
            Spacer(minLength: 2)
            if hover {
                Button { store.nuevaTerminal(enGrupo: grupo.id) } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundColor(Tema.gris)
                        .frame(width: 20, height: 20).background(Circle().fill(Tema.velo(0.08)))
                }
                .buttonStyle(.plain)
                .help("Terminal nueva en este grupo")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Forma(cornerRadius: 6).fill(destino ? Tema.azul.opacity(0.4) : hover ? Tema.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { store.editando = clave }
        .simultaneousGesture(TapGesture().onEnded { if store.editando != clave { store.plegar(grupo.id) } })
        .dropDestination(for: String.self) { items, _ in
            store.soltar(items, enGrupo: grupo.id)
        } isTargeted: { destino = $0 }
        .contextMenu {
            Button("Renombrar") { store.editando = clave }
            Button("Terminal nueva en el grupo") { store.nuevaTerminal(enGrupo: grupo.id) }
            Divider()
            Button("Desagrupar (las pestañas siguen abiertas)") { store.desagrupar(grupo.id) }
            Button("Cerrar el grupo y sus pestañas") {
                if cuantas == 0 || confirma("¿Cerrar «\(grupo.nombre)» y sus \(cuantas) pestañas?",
                                             "Las sesiones no se pierden: puedes retomarlas desde sus carpetas.", "Cerrar") {
                    store.cerrarGrupo(grupo.id)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
    }
}

/// Campo para escribir un nombre en el sitio. Enter guarda, Esc cancela, salir del campo guarda.
struct CampoNombre: View {
    let inicial: String
    let fuente: Font
    /// nil = cancelado
    let listo: (String?) -> Void
    @State private var texto = ""
    @State private var hecho = false
    @FocusState private var foco: Bool

    var body: some View {
        TextField("Nombre", text: $texto)
            .textFieldStyle(.plain)
            .font(fuente)
            .foregroundColor(Tema.texto)
            .padding(.horizontal, 4)
            .background(Forma(cornerRadius: 4).fill(Tema.campo))
            .overlay(Forma(cornerRadius: 4).stroke(Tema.azul.opacity(0.8)))
            .focused($foco)
            .onAppear {
                texto = inicial
                DispatchQueue.main.async { foco = true }
            }
            .onSubmit { terminar(texto) }
            .onExitCommand { terminar(nil) }
            .onChange(of: foco) { antes, ahora in if antes && !ahora { terminar(texto) } }
    }

    private func terminar(_ t: String?) {
        guard !hecho else { return }
        hecho = true
        listo(t)
    }
}

struct FilaTerminal: View {
    @EnvironmentObject var store: Store
    @ObservedObject var term: Term
    let numero: Int
    var sangria: CGFloat = 0
    @State private var hover = false

    var activa: Bool { store.vista == .terminal(term.id) || store.terminalLado === term }
    var clave: String { "term:" + term.id.uuidString }

    var body: some View {
        HStack(spacing: 8) {
            IndicadorEstado(term: term, activa: activa)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                if store.editando == clave {
                    CampoNombre(inicial: term.etiqueta, fuente: Letra.texto(12.5)) { n in
                        if let n { store.renombrar(term, n) }
                        store.finEdicion()
                    }
                } else {
                    Text(term.etiqueta).font(Letra.texto(12.5)).foregroundColor(Tema.texto).lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text((term.cwd as NSString).lastPathComponent).lineLimit(1)
                    if let r = term.rama {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 8.5, weight: .semibold))
                        Text(r).lineLimit(1)
                    }
                }
                .font(Letra.texto(11)).foregroundColor(Tema.tenue)
            }
            Spacer(minLength: 2)
            if hover && store.editando != clave {
                Button { store.cerrar(term) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(Tema.gris)
                        .frame(width: 18, height: 18).background(Circle().fill(Tema.velo(0.08)))
                }
                .buttonStyle(.plain)
                .help("Cerrar (⌘W)")
            } else if numero <= 9 {
                Text("⌘\(numero)").font(Letra.texto(10.5)).foregroundColor(Tema.tenue)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Forma(cornerRadius: 6).fill(activa ? Tema.sel : hover ? Tema.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { store.editando = clave }
        .simultaneousGesture(TapGesture().onEnded { if store.editando != clave { store.mostrar(term) } })
        .draggable(clave) {
            Label(term.etiqueta, systemImage: term.motor == nil ? "terminal" : "sparkle")
                .padding(6).background(Tema.lado).cornerRadius(6)
        }
        .dropDestination(for: String.self) { items, _ in
            store.soltar(items.filter { $0 != clave }, enGrupo: term.grupo)
        }
        .contextMenu {
            Button("Renombrar") { store.editando = clave }
            if store.tieneNombre(term) {
                Button("Quitar el nombre") { store.renombrar(term, nil) }
            }
            Menu("Mover a grupo") {
                ForEach(store.grupos) { g in
                    Button(g.nombre) { store.mover(term, aGrupo: g.id) }.disabled(term.grupo == g.id)
                }
                if !store.grupos.isEmpty { Divider() }
                Button("Grupo nuevo…") { store.nuevoGrupo(con: term) }
            }
            if term.grupo != nil {
                Button("Sacar del grupo") { store.mover(term, aGrupo: nil) }
            }
            Divider()
            Button("Abrir al lado") { store.abrirAlLado(term) }.disabled(store.terminalActiva == nil || store.terminalActiva === term)
            Divider()
            Button("Cerrar") { store.cerrar(term) }
        }
        .padding(.leading, 8 + sangria)
        .padding(.trailing, 8)
        .help("Doble clic para renombrar")
    }
}

// MARK: - cabecera

struct Cabecera: View {
    @EnvironmentObject var store: Store
    @FocusState private var buscando: Bool

    var actual: Carpeta? {
        if case .carpeta(let id) = store.vista { return store.carpeta(id) }
        return nil
    }

    var titulo: String {
        switch store.vista {
        case .inicio: return store.nombreRaiz
        case .carpeta: return actual?.nombre ?? ""
        case .buscar: return "Buscar"
        case .terminal: return store.terminalActiva?.etiqueta ?? "Terminal"
        }
    }

    var subtitulo: String {
        switch store.vista {
        case .inicio: return "\(store.total) sesiones de Claude y Codex · \(Datos.corta(store.raiz))"
        case .carpeta:
            guard let c = actual else { return "" }
            let donde: String
            if let r = c.ruta { donde = Datos.corta(r) }
            else if c.id == Datos.nFuera { donde = "abiertas fuera de \(store.nombreRaiz)" }
            else if c.id == Datos.nPerdidas { donde = "su carpeta se movió o se borró" }
            else if c.id == Datos.nArchivo { donde = "las que archivaste" }
            else if c.id.hasPrefix(Datos.nPerdidas + ":") { donde = "ya no existe " + Datos.corta(String(c.id.dropFirst(Datos.nPerdidas.count + 1))) }
            else { donde = "carpetas temporales" }
            return "\(c.cuantas) · \(donde)"
        case .buscar: return "\(store.resultados.count) resultados"
        case .terminal: return store.terminalActiva.map { Datos.corta($0.cwd) } ?? ""
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if store.vista != .inicio {
                Button {
                    if store.vista == .buscar { store.query = "" }
                    else if case .carpeta(let id) = store.vista, let p = store.padre(de: id) { store.abrirCarpeta(p.id) }
                    else { store.vista = .inicio }
                } label: {
                    Image(systemName: "chevron.left").font(Letra.fuerte(13)).foregroundColor(Tema.gris)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Volver (⌘T te lleva al inicio)")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(titulo).font(Letra.titulo(15)).tracking(-0.3).foregroundColor(Tema.texto).lineLimit(1)
                Text(subtitulo).font(Letra.texto(11.5)).foregroundColor(Tema.gris).lineLimit(1)
            }
            Spacer(minLength: 12)
            if let c = actual, c.ruta != nil { MenuNuevaSesion(carpeta: c) }
            if store.vista != .buscar, store.puedeCrearCarpeta {
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
                .background(Forma(cornerRadius: 7).fill(Tema.velo(0.07)))
            }
            if store.hayVersionNueva {
                Button { store.reiniciar() } label: {
                    Label("Actualizar", systemImage: "arrow.clockwise").font(Letra.fuerte(12.5))
                }
                .buttonStyle(PastillaAzulChica())
                .help("Hay una versión nueva instalada. Reinicia la app: tus pestañas vuelven y la que estás viendo se retoma sola.")
            }
            // uso de Claude (5 h y semana), como en Warp
            BotonUso()
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
            .background(Forma(cornerRadius: 7).fill(Tema.velo(configuration.isPressed ? 0.16 : 0.09)))
    }
}

struct MenuNuevaSesion: View {
    @EnvironmentObject var store: Store
    let carpeta: Carpeta

    var body: some View {
        let corto = Datos.corta(carpeta.ruta ?? "")
        Menu {
            Button("Codex en \(corto)") { store.sesionAqui(carpeta.id, motor: .codex) }
            Button("Terminal en \(corto)") { store.nuevaTerminal(en: carpeta.ruta) }
            Divider()
            Button("Elegir otra carpeta del disco…") {
                if let d = elegirDirectorio(carpeta.ruta) { store.nuevaSesion(en: d) }
            }
        } label: {
            Label("Nueva sesión", systemImage: "plus").font(Letra.texto(12.5))
        } primaryAction: {
            store.sesionAqui(carpeta.id)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(Forma(cornerRadius: 7).fill(Tema.velo(0.09)))
        .help("Abre Claude en \(corto). La flecha tiene más opciones.")
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
        .background(FondoTema())
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
        let ids = store.carpetas.map(\.id)
        guard !ids.isEmpty else { return .handled }
        let k = ids.firstIndex(of: store.carpetaSel ?? "") ?? 0
        store.carpetaSel = ids[min(ids.count - 1, max(0, k + d))]
        return .handled
    }
}

struct Baldosa: View {
    @EnvironmentObject var store: Store
    let carpeta: Carpeta
    @State private var destino = false

    var sel: Bool { store.carpetaSel == carpeta.id }
    var archivo: Bool { carpeta.id == Datos.nArchivo }

    var body: some View {
        VStack(spacing: 7) {
            CarpetaPixel(abierta: sel)
                .frame(width: 112, height: 84)
                .padding(9)
                .background(Forma(cornerRadius: 9).fill(destino ? Tema.azul.opacity(0.35) : sel ? Tema.sel : .clear))
            Text(carpeta.nombre)
                .font(Letra.fuerte(13.5))
                .foregroundColor(sel ? .white : Tema.texto)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Forma(cornerRadius: 5).fill(sel ? Tema.azul : .clear))
                .shadow(color: Tema.sombraTexto.opacity(sel ? 0 : 0.45), radius: 3, y: 1)
            Text(carpeta.hijos.isEmpty ? carpeta.cuantas : "\(carpeta.hijos.count) \(carpeta.hijos.count == 1 ? "carpeta" : "carpetas") · \(carpeta.cuantas)")
                .font(Letra.texto(12.5))
                .foregroundColor(Tema.gris)
                .lineLimit(1)
                .shadow(color: Tema.sombraTexto.opacity(0.6), radius: 3, y: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.abrirCarpeta(carpeta.id) }
        .simultaneousGesture(TapGesture().onEnded { store.carpetaSel = carpeta.id })
        .contextMenu { MenuCarpeta(carpeta: carpeta) }
        .dropDestination(for: String.self) { ids, _ in
            guard archivo else { return false }
            store.mover(ids, a: carpeta.id)
            return true
        } isTargeted: { destino = $0 && archivo }
        .help(carpeta.ruta.map(Datos.corta) ?? "")
    }
}

struct MenuCarpeta: View {
    @EnvironmentObject var store: Store
    let carpeta: Carpeta

    var body: some View {
        Button("Abrir") { store.abrirCarpeta(carpeta.id) }
        if let r = carpeta.ruta {
            Button("Nueva sesión aquí") { store.sesionAqui(carpeta.id) }
            Button("Terminal aquí") { store.nuevaTerminal(en: r) }
            Divider()
            Button("Mostrar en Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: r)) }
            Divider()
            Button("Mover a la Papelera…", role: .destructive) { store.eliminarCarpeta(carpeta) }
        }
    }
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
        let actual: Carpeta? = { if case .carpeta(let id) = store.vista { return store.carpeta(id) }; return nil }()
        let dentro = actual?.hijos ?? []
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    // como en el Finder: primero las carpetas que tiene dentro, luego sus sesiones
                    if !dentro.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 22)], alignment: .leading, spacing: 26) {
                            ForEach(dentro) { c in Baldosa(carpeta: c) }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 16)
                        .padding(.bottom, 26)
                        if !lista.isEmpty {
                            Text("Sesiones de aquí dentro")
                                .font(Letra.titulo(13)).foregroundColor(Tema.gris)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 8)
                        }
                    }
                    if lista.isEmpty {
                        if let c = actual {
                            if dentro.isEmpty { CarpetaVacia(carpeta: c).padding(.top, 70) }
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
                    if store.editando == "sesion:" + sesion.id {
                        CampoNombre(inicial: sesion.titulo, fuente: Letra.fuerte(13.5)) { n in
                            if let n { store.nombrarSesion(sesion.id, Datos.limpia(n).isEmpty ? nil : Datos.limpia(n)) }
                            store.editando = nil
                        }
                        .frame(maxWidth: 420)
                    } else {
                        Text(sesion.titulo)
                            .font(Letra.fuerte(13.5))
                            .foregroundColor(Tema.texto)
                            .lineLimit(1)
                    }
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
        .background(Forma(cornerRadius: 8).fill(sel ? Tema.sel : hover ? Tema.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { store.retomar(sesion) }
        .simultaneousGesture(TapGesture().onEnded { store.sesionSel = sesion.id })
        .draggable(sesion.id) {
            Label(sesion.titulo, systemImage: "sparkle").padding(6).background(Tema.lado).cornerRadius(6)
        }
        .contextMenu {
            Button("Retomar") { store.retomar(sesion) }
            Button("Renombrar") { store.editando = "sesion:" + sesion.id }
            if store.nombres[sesion.id] != nil {
                Button("Quitar el nombre") { store.nombrarSesion(sesion.id, nil) }
            }
            if sesion.carpeta == Datos.nArchivo {
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
                Text(term.etiqueta).font(Letra.fuerte(11.5)).foregroundColor(Tema.gris).lineLimit(1)
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
                Text("\(sesion.proyecto) · \(hace(sesion.mtime))")
                    .font(Letra.texto(11.5)).foregroundColor(Tema.gris).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Forma(cornerRadius: 9).fill(hover ? Tema.tarjetaHover : Tema.tarjeta))
            .overlay(Forma(cornerRadius: 9).stroke(Tema.linea))
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
            .background(Forma(cornerRadius: 4).stroke(Tema.tenue))
    }
}

struct CarpetaVacia: View {
    @EnvironmentObject var store: Store
    let carpeta: Carpeta

    var body: some View {
        VStack(spacing: 14) {
            CarpetaPixel().frame(width: 80, height: 60)
            Text("Todavía no hay sesiones aquí").font(Letra.titulo(17)).foregroundColor(Tema.texto)
            if let r = carpeta.ruta {
                HStack(spacing: 10) {
                    Button { store.sesionAqui(carpeta.id) } label: { Label("Empezar con Claude", systemImage: "sparkle") }
                        .buttonStyle(PastillaAzul())
                    Button { store.sesionAqui(carpeta.id, motor: .codex) } label: { Text("Con Codex") }
                        .buttonStyle(Pastilla())
                }
                Text("Se abre en \(Datos.corta(r))").font(Letra.texto(12)).foregroundColor(Tema.gris)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct PastillaAzulChica: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Forma(cornerRadius: 7).fill(Tema.azul.opacity(configuration.isPressed ? 0.8 : 1)))
    }
}

struct PastillaAzul: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Letra.fuerte(13))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Forma(cornerRadius: 8).fill(Tema.azul.opacity(configuration.isPressed ? 0.8 : 1)))
    }
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
