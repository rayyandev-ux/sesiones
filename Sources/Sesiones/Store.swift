import AppKit
import Carbon.HIToolbox
import SwiftTerm
import SwiftUI
import UserNotifications

enum Vista: Hashable {
    case inicio
    case carpeta(String)
    case buscar
    case terminal(UUID)
}

/// Un grupo de pestañas, como los de Warp: tiene nombre y se pliega.
struct Grupo: Identifiable, Equatable {
    let id: UUID
    var nombre: String
    var plegado = false
}

/// Lo que está haciendo el agente dentro de una terminal.
enum Estado {
    case nada, trabajando, listo, permiso
}

@MainActor
final class Store: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    /// el árbol: las carpetas de primer nivel (cada una trae las suyas dentro)
    @Published var carpetas: [Carpeta] = []
    @Published var todas: [Sesion] = []
    /// tu carpeta de proyectos: de ahí sale el árbol
    @Published var raiz = Datos.carpetaBase()
    @Published var total = 0
    /// carpetas desplegadas en la barra lateral
    @Published var desplegadas: Set<String> = [] { didSet { UserDefaults.standard.set(Array(desplegadas), forKey: "desplegadas") } }
    @Published var vista: Vista = .inicio { didSet { if vista != oldValue { cambioDeVista = Date(); alMostrar() } } }
    @Published var carpetaSel: String?
    @Published var sesionSel: String?
    @Published var query = "" {
        didSet {
            if !query.isEmpty, vista != .buscar { antesDeBuscar = vista; vista = .buscar }
            if query.isEmpty, vista == .buscar { vista = antesDeBuscar }
        }
    }
    @Published var terminales: [Term] = []
    @Published var grupos: [Grupo] = []
    /// lo que se está renombrando en la barra lateral: "term:<uuid>", "grupo:<uuid>" o "sesion:<id>"
    @Published var editando: String?
    /// nombres que les pusiste a las sesiones (id → nombre)
    @Published var nombres: [String: String] = [:]
    /// se instaló una versión nueva de la app encima de esta: se ofrece reiniciar
    @Published var hayVersionNueva = false
    private let fechaDelPrograma = Store.fechaDelPrograma()
    /// terminal mostrada a la derecha cuando la pantalla está dividida
    @Published var lado: UUID?
    @Published var aviso: String?
    @Published var pideNuevaCarpeta = false
    @Published var pideBusqueda = 0
    @Published var tamFuente: CGFloat = 13

    var cambioDeVista = Date()
    private var antesDeBuscar: Vista = .inicio
    private var cargando = false
    private var otraVez = false
    private var idsConocidos: Set<String> = []
    private var pendientes: [(cwd: String, desde: Date, term: UUID)] = []
    private var timers: [Timer] = []
    private var saliendo = false
    private let notificaciones = Bundle.main.bundleIdentifier != nil
    private var registro: String?
    private var fotoPedida = false
    private var carpetaDePrueba: String?
    private var pestanaDePruebaHecha = false

    override init() {
        super.init()
        let f = UserDefaults.standard.double(forKey: "tamFuente")
        tamFuente = f > 0 ? CGFloat(f) : 13
        desplegadas = Set(UserDefaults.standard.stringArray(forKey: "desplegadas") ?? [])
        recargar()
        restaurar()
        timers.append(Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recargar() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.vigilar() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.leerRamas(); self?.revisarVersion() }
        })
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recargar(); self?.alMostrar() }
        }
        nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saliendo = true }
        }
        carpetaDePrueba = ProcessInfo.processInfo.environment["SESIONES_CARPETA"] // solo para pruebas: abre esa carpeta
        editando = ProcessInfo.processInfo.environment["SESIONES_EDITAR"] // solo para pruebas: "term:…", "grupo:…"
        if ProcessInfo.processInfo.environment["SESIONES_REINICIAR"] != nil { // solo para pruebas: reinicia a los 3 s
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if let t = self?.terminales.last { self?.mostrar(t) }
                self?.reiniciar()
            }
        }
        // solo para pruebas: SESIONES_PRUEBA abre una terminal con ese comando y anota los cambios de estado
        if let cmd = ProcessInfo.processInfo.environment["SESIONES_PRUEBA"] {
            let t = crear(cwd: Datos.home, motor: nil, sesionId: nil, titulo: "prueba")
            t.vista.send(txt: cmd + "\n")
            mostrar(t)
            registro = ProcessInfo.processInfo.environment["SESIONES_LOG"]
        }
        if notificaciones {
            let c = UNUserNotificationCenter.current()
            c.delegate = self
            c.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    // MARK: datos

    func recargar() {
        if cargando { otraVez = true; return }
        cargando = true
        Task.detached(priority: .userInitiated) {
            let r = Datos.todo()
            await MainActor.run { self.aplica(r) }
        }
    }

    private func aplica(_ r: (carpetas: [Carpeta], sesiones: [Sesion], raiz: String, nombres: [String: String])) {
        cargando = false
        if raiz != r.raiz { raiz = r.raiz }
        if nombres != r.nombres { nombres = r.nombres }
        let ids = Set(r.sesiones.map(\.id))
        // una sesión nueva abierta desde la app: se le pone su id a la pestaña
        if !pendientes.isEmpty && !idsConocidos.isEmpty {
            for s in r.sesiones where !idsConocidos.contains(s.id) {
                if let k = pendientes.firstIndex(where: { $0.cwd == s.cwd && s.mtime >= $0.desde.addingTimeInterval(-5) }) {
                    let p = pendientes.remove(at: k)
                    if let t = terminales.first(where: { $0.id == p.term }), t.sesionId == nil {
                        t.sesionId = s.id
                        t.titulo = s.titulo
                        // si ya le habías puesto nombre a la pestaña, pasa a ser el nombre de la sesión
                        if let n = t.nombre {
                            Datos.nombrar(s.id, n)
                            nombres[s.id] = n
                            t.titulo = n
                            t.nombre = nil
                        }
                        guardarAbiertas()
                    }
                }
            }
            pendientes.removeAll { Date().timeIntervalSince($0.desde) > 3600 }
        }
        idsConocidos = ids
        carpetas = r.carpetas
        todas = r.sesiones
        total = r.sesiones.count
        // los títulos que Claude pone a las sesiones nuevas llegan después: se actualizan en las pestañas
        let porId = Dictionary(r.sesiones.map { ($0.id, $0.titulo) }, uniquingKeysWith: { a, _ in a })
        for t in terminales { if let id = t.sesionId, let tit = porId[id], tit != t.titulo { t.titulo = tit } }
        if carpetaSel == nil { carpetaSel = carpetas.first?.id }
        if case .carpeta(let n) = vista, carpeta(n) == nil { vista = .inicio }
        if let c = carpetaDePrueba { carpetaDePrueba = nil; if carpeta(c) != nil { abrirCarpeta(c) } }
        // solo para pruebas: SESIONES_PESTANA=n muestra la pestaña n (desde 1)
        if !pestanaDePruebaHecha, let n = ProcessInfo.processInfo.environment["SESIONES_PESTANA"].flatMap(Int.init) {
            pestanaDePruebaHecha = true
            irA(n - 1)
        }
        if otraVez { otraVez = false; recargar() }
        // solo para pruebas: SESIONES_FOTO=/ruta.png guarda una foto de la ventana y cierra la app
        if let ruta = ProcessInfo.processInfo.environment["SESIONES_FOTO"], !fotoPedida {
            fotoPedida = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let v = NSApp.windows.first(where: { $0.canBecomeMain })?.contentView,
                   let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: ruta))
                }
                exit(0)
            }
        }
    }

    func carpeta(_ id: String) -> Carpeta? {
        for c in carpetas { if let x = c.buscar(id) { return x } }
        return nil
    }

    /// La carpeta que contiene a esta (nil si está en el primer nivel).
    func padre(de id: String) -> Carpeta? {
        func busca(_ c: Carpeta) -> Carpeta? {
            if c.hijos.contains(where: { $0.id == id }) { return c }
            for h in c.hijos { if let x = busca(h) { return x } }
            return nil
        }
        for c in carpetas { if let x = busca(c) { return x } }
        return nil
    }

    var recientes: [Sesion] {
        let aparte = Set(carpetas.filter { $0.grupo && $0.ruta == nil && $0.id != Datos.nFuera }.flatMap(\.todas).map(\.id))
        return Array(todas.lazy.filter { !aparte.contains($0.id) }.prefix(6))
    }

    /// Las sesiones de una carpeta y de todo lo que tiene dentro, la más reciente arriba.
    func sesiones(de id: String) -> [Sesion] {
        (carpeta(id)?.todas ?? []).sorted { $0.mtime > $1.mtime }
    }

    var resultados: [Sesion] {
        let palabras = query.lowercased().split(separator: " ").map(String.init)
        guard !palabras.isEmpty else { return [] }
        return todas.filter { s in
            let t = (s.titulo + " " + s.prompts.joined(separator: " ") + " " + s.cwd + " " + s.motor.rawValue).lowercased()
            return palabras.allSatisfy { t.contains($0) }
        }
    }

    var listaActual: [Sesion] {
        switch vista {
        case .buscar: return resultados
        case .carpeta(let n): return sesiones(de: n)
        default: return []
        }
    }

    var abiertas: Set<String> { Set(terminales.compactMap(\.sesionId)) }

    // MARK: carpetas

    func abrirCarpeta(_ id: String) {
        carpetaSel = id
        sesionSel = sesiones(de: id).first?.id
        vista = .carpeta(id)
        // en la barra lateral se despliega el camino hasta ella
        var arriba = padre(de: id)
        while let p = arriba { desplegadas.insert(p.id); arriba = padre(de: p.id) }
        if carpeta(id)?.hijos.isEmpty == false { desplegadas.insert(id) }
    }

    /// Mueve la carpeta del disco a la Papelera (se puede recuperar). Solo dentro de la carpeta de proyectos,
    /// y nunca con terminales abiertas adentro. Las sesiones no se borran: quedan en «Ya no existen».
    func eliminarCarpeta(_ c: Carpeta) {
        guard let ruta = c.ruta else { return }
        let r = (ruta as NSString).standardizingPath
        let base = (Datos.carpetaBase() as NSString).standardizingPath
        guard r.hasPrefix(base + "/"), r != base, r != Datos.home else {
            aviso = "Solo puedo eliminar carpetas que están dentro de tu carpeta de proyectos (\(Datos.corta(base)))."
            return
        }
        let dentro: (String) -> Bool = { $0 == r || $0.hasPrefix(r + "/") }
        let abiertasAqui = terminales.filter { $0.iniciado && dentro($0.cwd) }
        guard abiertasAqui.isEmpty else {
            aviso = abiertasAqui.count == 1
                ? "Hay una terminal abierta en esta carpeta («\(abiertasAqui[0].titulo)»). Ciérrala primero."
                : "Hay \(abiertasAqui.count) terminales abiertas en esta carpeta. Ciérralas primero."
            return
        }
        let n = c.todas.count
        var detalle = "Se mueve a la Papelera con todo lo que tiene adentro; puedes recuperarla desde ahí."
        if FileManager.default.fileExists(atPath: r + "/.git") { detalle += " Es un repositorio de git: si tiene cambios sin subir, se van con la carpeta." }
        if n > 0 { detalle += " Sus \(n) sesión\(n == 1 ? "" : "es") de Claude/Codex no se borran: quedan en «Ya no existen»." }
        guard confirma("¿Mover «\(c.nombre)» a la Papelera?", detalle + "\n\n\(Datos.corta(r))", "Mover a la Papelera") else { return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: r), resultingItemURL: nil)
        } catch {
            aviso = "No pude moverla a la Papelera: \(error.localizedDescription)"
            return
        }
        if case .carpeta(let id) = vista, let v = carpeta(id), let vr = v.ruta, dentro((vr as NSString).standardizingPath) { vista = .inicio }
        if let sel = carpetaSel, let v = carpeta(sel), let vr = v.ruta, dentro((vr as NSString).standardizingPath) { carpetaSel = nil }
        recargar()
    }

    func desplegar(_ id: String) {
        if desplegadas.contains(id) { desplegadas.remove(id) } else { desplegadas.insert(id) }
    }

    var nombreRaiz: String { (raiz as NSString).lastPathComponent }

    /// La carpeta del disco donde se crearía una carpeta nueva: la que estás viendo, o tu carpeta de proyectos.
    var dondeCrear: String {
        if case .carpeta(let id) = vista, let c = carpeta(id), let r = c.ruta { return r }
        return raiz
    }

    /// Solo se crean carpetas donde el árbol las va a mostrar: en tu carpeta de proyectos, dentro de una de sus
    /// carpetas, o un nivel más adentro si esa no es un repositorio.
    var puedeCrearCarpeta: Bool {
        guard case .carpeta(let id) = vista else { return vista == .inicio }
        guard let c = carpeta(id), let r = c.ruta, !c.grupo, r.hasPrefix(raiz + "/") else { return false }
        let nivel = r.dropFirst(raiz.count).split(separator: "/").count
        return nivel == 1 || (nivel == 2 && !FileManager.default.fileExists(atPath: r + "/.git"))
    }

    /// Crea una carpeta de verdad en el disco, dentro de la que estás viendo.
    func crearCarpeta(_ nombre: String) {
        guard !Datos.limpia(nombre).isEmpty else { aviso = "Ponle un nombre"; return }
        let dir = dondeCrear + "/" + Datos.nombreEnDisco(nombre)
        if FileManager.default.fileExists(atPath: dir) { aviso = "Ya existe una carpeta con ese nombre"; return }
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false) }
        catch { aviso = "No pude crear \(Datos.corta(dir)): \(error.localizedDescription)"; return }
        if case .carpeta(let id) = vista { desplegadas.insert(id) }
        recargar()
    }

    /// Soltar sesiones sobre "Archivo" las archiva.
    func mover(_ ids: [String], a carpeta: String) {
        let sesiones = ids.filter { !$0.hasPrefix("term:") }
        if carpeta == Datos.nArchivo, !sesiones.isEmpty { archivar(sesiones, true) }
    }

    func archivar(_ ids: [String], _ si: Bool) {
        Datos.archivar(ids, si)
        recargar()
    }

    // MARK: terminales

    func retomar(_ s: Sesion) {
        if let t = terminales.first(where: { $0.sesionId == s.id }) { mostrar(t); return }
        guard FileManager.default.fileExists(atPath: s.cwd) else {
            aviso = "La carpeta de esta sesión ya no existe (se movió o se borró): \(Datos.corta(s.cwd))"
            return
        }
        mostrar(crear(cwd: s.cwd, motor: s.motor, sesionId: s.id, titulo: s.titulo))
    }

    func nuevaSesion(en cwd: String, motor: Motor = .claude) {
        let t = crear(cwd: cwd, motor: motor, sesionId: nil, titulo: "\(motor.nombre) · " + (cwd as NSString).lastPathComponent)
        pendientes.append((cwd, Date(), t.id))
        mostrar(t)
    }

    /// Abre una sesión nueva en la carpeta del disco de esta carpeta.
    func sesionAqui(_ id: String, motor: Motor = .claude) {
        guard let dir = carpeta(id)?.ruta else { return }
        guard FileManager.default.fileExists(atPath: dir) else { aviso = "Esa carpeta ya no existe: \(Datos.corta(dir))"; return }
        nuevaSesion(en: dir, motor: motor)
    }

    func nuevaTerminal(en cwd: String? = nil) {
        mostrar(crear(cwd: cwd ?? Datos.home, motor: nil, sesionId: nil, titulo: "Terminal"))
    }

    @discardableResult
    private func crear(cwd: String, motor: Motor?, sesionId: String?, titulo: String, dormida: Bool = false,
                       grupo: UUID? = nil, nombre: String? = nil) -> Term {
        let t = Term(cwd: cwd, motor: motor, sesionId: sesionId, titulo: titulo, store: self)
        t.grupo = grupo
        t.nombre = nombre
        t.rama = Datos.rama(de: cwd)
        terminales.append(t)
        if !dormida { t.iniciar() }
        guardarAbiertas()
        return t
    }

    func mostrar(_ t: Term) {
        if lado == t.id, let a = terminalActiva { lado = a.id }
        // si está en un grupo plegado, el grupo se abre
        if let g = t.grupo, let k = grupos.firstIndex(where: { $0.id == g }), grupos[k].plegado {
            grupos[k].plegado = false
            guardarAbiertas()
        }
        vista = .terminal(t.id)
        alMostrar()
    }

    // MARK: pestañas en el orden de la barra lateral (primero los grupos, luego las sueltas)

    var ordenadas: [Term] {
        grupos.flatMap { g in terminales.filter { $0.grupo == g.id } } + sueltas
    }

    var sueltas: [Term] {
        let ids = Set(grupos.map(\.id))
        return terminales.filter { $0.grupo == nil || !ids.contains($0.grupo!) }
    }

    func pestanas(de g: UUID) -> [Term] { terminales.filter { $0.grupo == g } }

    // MARK: renombrar

    /// Nombre de una pestaña. Si es una sesión, el nombre es de la sesión: se ve también en sus carpetas y vuelve
    /// al retomarla. nil o vacío quita el nombre.
    func renombrar(_ t: Term, _ nombre: String?) {
        let limpio = Datos.limpia(nombre ?? "")
        if let id = t.sesionId {
            nombrarSesion(id, limpio.isEmpty ? nil : limpio)
        } else {
            t.nombre = limpio.isEmpty ? nil : limpio
        }
        guardarAbiertas()
    }

    func nombrarSesion(_ id: String, _ nombre: String?) {
        Datos.nombrar(id, nombre)
        nombres[id] = nombre
        if let nombre {
            for t in terminales where t.sesionId == id { t.titulo = nombre }
        }
        recargar() // sin nombre, vuelve el título que le puso Claude
    }

    func tieneNombre(_ t: Term) -> Bool { t.sesionId.map { nombres[$0] != nil } ?? (t.nombre != nil) }

    /// Termina de renombrar y devuelve el cursor a la terminal.
    func finEdicion() {
        editando = nil
        if let t = terminalActiva { DispatchQueue.main.async { t.vista.window?.makeFirstResponder(t.vista) } }
    }

    // MARK: grupos de pestañas

    /// Grupo nuevo (con esta pestaña dentro, si se da una) y se queda escribiendo su nombre.
    @discardableResult
    func nuevoGrupo(con t: Term? = nil) -> UUID {
        let usados = Set(grupos.map(\.nombre))
        var n = 1
        while usados.contains("Grupo \(n)") { n += 1 }
        let g = Grupo(id: UUID(), nombre: "Grupo \(n)")
        grupos.append(g)
        if let t { t.grupo = g.id }
        editando = "grupo:" + g.id.uuidString
        guardarAbiertas()
        return g.id
    }

    func renombrarGrupo(_ id: UUID, _ nombre: String) {
        let limpio = Datos.limpia(nombre)
        guard !limpio.isEmpty, let k = grupos.firstIndex(where: { $0.id == id }) else { return }
        grupos[k].nombre = limpio
        guardarAbiertas()
    }

    func plegar(_ id: UUID) {
        guard let k = grupos.firstIndex(where: { $0.id == id }) else { return }
        grupos[k].plegado.toggle()
        guardarAbiertas()
    }

    func mover(_ t: Term, aGrupo g: UUID?) {
        guard t.grupo != g else { return }
        objectWillChange.send()
        t.grupo = g
        guardarAbiertas()
    }

    /// Lo que se suelta sobre un grupo: una pestaña ("term:<uuid>") entra al grupo; una sesión de las carpetas se abre ahí.
    func soltar(_ items: [String], enGrupo g: UUID?) -> Bool {
        var algo = false
        for i in items {
            if i.hasPrefix("term:"), let t = terminales.first(where: { $0.id.uuidString == String(i.dropFirst(5)) }) {
                mover(t, aGrupo: g); algo = true
            } else if let s = todas.first(where: { $0.id == i }) {
                if let t = terminales.first(where: { $0.sesionId == s.id }) {
                    mover(t, aGrupo: g)
                } else if FileManager.default.fileExists(atPath: s.cwd) {
                    crear(cwd: s.cwd, motor: s.motor, sesionId: s.id, titulo: s.titulo, dormida: true, grupo: g)
                }
                algo = true
            }
        }
        return algo
    }

    /// Saca las pestañas del grupo (siguen abiertas) y borra el grupo.
    func desagrupar(_ id: UUID) {
        objectWillChange.send()
        for t in terminales where t.grupo == id { t.grupo = nil }
        grupos.removeAll { $0.id == id }
        guardarAbiertas()
    }

    func cerrarGrupo(_ id: UUID) {
        for t in pestanas(de: id) { cerrar(t) }
        grupos.removeAll { $0.id == id }
        guardarAbiertas()
    }

    /// Terminal nueva dentro del grupo, en la carpeta de su última pestaña.
    func nuevaTerminal(enGrupo g: UUID) {
        let cwd = pestanas(de: g).last?.cwd ?? Datos.home
        if let k = grupos.firstIndex(where: { $0.id == g }) { grupos[k].plegado = false }
        mostrar(crear(cwd: cwd, motor: nil, sesionId: nil, titulo: "Terminal", grupo: g))
    }

    // MARK: actualizar la app sin instalar otra copia

    private static func fechaDelPrograma() -> Date? {
        guard let ruta = Bundle.main.executablePath else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: ruta))?[.modificationDate] as? Date
    }

    /// La app nueva se copia encima de esta en /Applications; esta sigue corriendo con el programa viejo hasta reiniciar.
    private func revisarVersion() {
        guard !hayVersionNueva, let antes = fechaDelPrograma, let ahora = Store.fechaDelPrograma(), ahora > antes else { return }
        hayVersionNueva = true
    }

    /// Cierra y vuelve a abrir la app. Las pestañas vuelven y la que estabas viendo se retoma sola.
    func reiniciar() {
        guardarAbiertas()
        UserDefaults.standard.set(true, forKey: "reabrirActiva")
        UserDefaults.standard.synchronize()
        saliendo = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // espera a que esta copia termine de cerrarse y abre la app otra vez
        p.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; open \"$0\"", Bundle.main.bundlePath]
        do { try p.run() } catch { aviso = "No pude reiniciar: \(error.localizedDescription). Ciérrala con ⌘Q y ábrela."; saliendo = false; return }
        NSApp.terminate(nil)
    }

    /// cambió el tema: las terminales abiertas toman los colores nuevos
    func recolorear() {
        for t in terminales { t.colores() }
    }

    private func leerRamas() {
        for t in terminales {
            let r = Datos.rama(de: t.cwd)
            if r != t.rama { t.rama = r }
        }
    }

    var terminalActiva: Term? {
        if case .terminal(let id) = vista { return terminales.first { $0.id == id } }
        return nil
    }

    var terminalLado: Term? {
        guard let lado, case .terminal(let a) = vista, a != lado else { return nil }
        return terminales.first { $0.id == lado }
    }

    /// la terminal donde está el cursor (la activa o la de al lado)
    var terminalConFoco: Term? {
        if let l = terminalLado, NSApp.keyWindow?.firstResponder === l.vista { return l }
        return terminalActiva
    }

    func cerrar(_ t: Term) {
        t.terminar()
        guard let k = terminales.firstIndex(where: { $0 === t }) else { return }
        var orden = ordenadas
        let j = orden.firstIndex { $0 === t } ?? 0
        orden.removeAll { $0 === t }
        terminales.remove(at: k)
        if editando == "term:" + t.id.uuidString { editando = nil }
        if lado == t.id { lado = nil }
        if vista == .terminal(t.id) {
            if let l = lado, let lt = terminales.first(where: { $0.id == l }) {
                lado = nil
                vista = .terminal(lt.id)
            } else if orden.isEmpty {
                vista = .inicio
            } else {
                // la de al lado en la barra lateral
                mostrar(orden[min(j, orden.count - 1)])
            }
        }
        guardarAbiertas()
        actualizarInsignia()
        recargar()
    }

    func terminoProceso(_ t: Term) {
        if !saliendo, terminales.contains(where: { $0 === t }) { cerrar(t) }
    }

    func cerrarActiva() {
        if let t = terminalConFoco { cerrar(t) }
    }

    func pestana(_ paso: Int) {
        let orden = ordenadas
        guard !orden.isEmpty else { return }
        let k = orden.firstIndex { $0 === terminalActiva } ?? (paso > 0 ? -1 : 0)
        mostrar(orden[(k + paso + orden.count) % orden.count])
    }

    func irA(_ n: Int) {
        let orden = ordenadas
        if n < orden.count { mostrar(orden[n]) }
    }

    func fuente(_ delta: CGFloat) {
        tamFuente = delta == 0 ? 13 : min(28, max(9, tamFuente + delta))
        UserDefaults.standard.set(Double(tamFuente), forKey: "tamFuente")
        for t in terminales { t.ponFuente(tamFuente) }
    }

    // MARK: pantalla dividida

    func abrirAlLado(_ t: Term) {
        guard let a = terminalActiva else { mostrar(t); return }
        guard a !== t else { return }
        lado = t.id
        t.iniciar()
        alMostrar()
    }

    func dividir() {
        if lado != nil, terminalLado != nil { lado = nil; return }
        guard let a = terminalActiva else { nuevaTerminal(); return }
        let t = crear(cwd: a.cwd, motor: nil, sesionId: nil, titulo: "Terminal")
        lado = t.id
        DispatchQueue.main.async { t.vista.window?.makeFirstResponder(t.vista) }
    }

    /// Lo dictado se escribe en la terminal donde está el cursor (sin Enter: lo revisas y lo mandas tú).
    func escribirDictado(_ texto: String) {
        if let t = terminalConFoco {
            t.iniciar()
            t.vista.send(txt: texto)
            t.vista.window?.makeFirstResponder(t.vista)
        } else {
            query = texto // fuera de una terminal, sirve para buscar
        }
    }

    func buscarEnTerminal() {
        guard let t = terminalConFoco else { pideBusqueda += 1; return }
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        t.vista.performFindPanelAction(item)
    }

    // MARK: lo que pasa dentro de cada terminal

    private func visibles() -> Set<UUID> {
        guard NSApp.isActive else { return [] }
        var v = Set<UUID>()
        if let a = terminalActiva { v.insert(a.id) }
        if let l = terminalLado { v.insert(l.id) }
        return v
    }

    private func alMostrar() {
        let v = visibles()
        for t in terminales where v.contains(t.id) && t.sinVer { t.sinVer = false }
        actualizarInsignia()
    }

    private func vigilar() {
        let v = visibles()
        for t in terminales where t.iniciado {
            let hubo = t.salida.tomar()
            guard hubo || t.estado == .trabajando || t.quietos < 3 else { continue }
            let leido = t.leerEstado()
            let antes = t.estado
            var nuevo = antes
            switch leido {
            case .permiso:
                t.quietos = 0
                nuevo = .permiso
            case .trabajando:
                t.quietos = 0
                if antes != .trabajando { t.desde = Date() }
                nuevo = .trabajando
            default:
                t.quietos += 1
                if antes == .trabajando && t.quietos >= 2 { nuevo = .listo }
                else if antes == .permiso && t.quietos >= 2 { nuevo = .nada }
            }
            guard nuevo != antes else { continue }
            t.estado = nuevo
            if let registro, let h = FileHandle(forWritingAtPath: registro) ?? { FileManager.default.createFile(atPath: registro, contents: nil); return FileHandle(forWritingAtPath: registro) }() {
                h.seekToEndOfFile(); h.write("\(Date().timeIntervalSince1970) \(antes) -> \(nuevo)\n".data(using: .utf8)!); h.closeFile()
            }
            if (nuevo == .listo || nuevo == .permiso) && !v.contains(t.id) {
                t.sinVer = true
                if nuevo == .permiso || Date().timeIntervalSince(t.desde) > 4 { notificar(t, permiso: nuevo == .permiso) }
            }
        }
        actualizarInsignia()
    }

    private func actualizarInsignia() {
        let n = terminales.filter(\.sinVer).count
        let etiqueta = n > 0 ? "\(n)" : nil
        if NSApp.dockTile.badgeLabel != etiqueta { NSApp.dockTile.badgeLabel = etiqueta }
    }

    private func notificar(_ t: Term, permiso: Bool) {
        guard notificaciones else { return }
        let c = UNMutableNotificationContent()
        c.title = permiso ? "Necesita tu permiso" : "\(t.motor?.nombre ?? "La terminal") terminó"
        c.body = t.etiqueta
        c.sound = .default
        c.userInfo = ["term": t.id.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: t.id.uuidString, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["term"] as? String
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let id, let t = self.terminales.first(where: { $0.id.uuidString == id }) { self.mostrar(t) }
            completionHandler()
        }
    }

    // MARK: recordar las pestañas abiertas

    func guardarAbiertas() {
        guard !saliendo else { return }
        let lista: [[String: String]] = terminales.map {
            ["motor": $0.motor?.rawValue ?? "", "sesion": $0.sesionId ?? "", "cwd": $0.cwd, "titulo": $0.titulo,
             "nombre": $0.nombre ?? "", "grupo": $0.grupo?.uuidString ?? ""]
        }
        UserDefaults.standard.set(lista, forKey: "abiertas")
        UserDefaults.standard.set(terminalActiva.flatMap { a in terminales.firstIndex { $0 === a } } ?? -1, forKey: "activa")
        UserDefaults.standard.set(grupos.map { ["id": $0.id.uuidString, "nombre": $0.nombre, "plegado": $0.plegado ? "1" : ""] },
                                  forKey: "grupos")
    }

    /// Al abrir la app vuelven tus pestañas y tus grupos, dormidas: cada una arranca cuando la abres (no gasta RAM antes).
    private func restaurar() {
        let gs = UserDefaults.standard.array(forKey: "grupos") as? [[String: String]] ?? []
        grupos = gs.compactMap { d in
            guard let id = d["id"].flatMap(UUID.init(uuidString:)) else { return nil }
            return Grupo(id: id, nombre: d["nombre"] ?? "Grupo", plegado: d["plegado"] == "1")
        }
        guard var lista = UserDefaults.standard.array(forKey: "abiertas") as? [[String: String]] else { return }
        for k in lista.indices { lista[k]["i"] = String(k) }
        var restauradas: [String: Term] = [:]
        // se lee antes de crear las pestañas, porque cada una vuelve a guardar la lista
        let reabrir = UserDefaults.standard.bool(forKey: "reabrirActiva")
        let activa = String(UserDefaults.standard.integer(forKey: "activa"))
        UserDefaults.standard.removeObject(forKey: "reabrirActiva")
        defer {
            // después de un reinicio por actualización, la pestaña que estabas viendo vuelve despierta
            if reabrir, let t = restauradas[activa] { mostrar(t) }
        }
        for d in lista {
            let cwd = d["cwd"] ?? Datos.home
            guard FileManager.default.fileExists(atPath: cwd) else { continue }
            let motor = Motor(rawValue: d["motor"] ?? "")
            let sesion = d["sesion"].flatMap { $0.isEmpty ? nil : $0 }
            if motor != nil && sesion == nil { continue } // sesión nueva que nunca llegó a guardarse
            let grupo = d["grupo"].flatMap(UUID.init(uuidString:)).flatMap { g in grupos.contains { $0.id == g } ? g : nil }
            let t = crear(cwd: cwd, motor: motor, sesionId: sesion, titulo: d["titulo"] ?? "Terminal", dormida: true,
                          grupo: grupo, nombre: d["nombre"].flatMap { $0.isEmpty ? nil : $0 })
            restauradas[d["i"] ?? ""] = t
        }
    }

    // MARK: atajo global ⌥Espacio

    func alternarVentana() {
        if NSApp.isActive, NSApp.keyWindow != nil {
            NSApp.hide(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - atajo global (Carbon, no necesita permisos de accesibilidad)

enum AtajoGlobal {
    nonisolated(unsafe) static var accion: (() -> Void)?
    nonisolated(unsafe) private static var ref: EventHotKeyRef?

    static func registrar(_ accion: @escaping () -> Void) {
        self.accion = accion
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { AtajoGlobal.accion?() }
            return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: OSType(0x5345_5331), id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - vista de terminal: arrastrar archivos pega su ruta

/// Marca que se enciende desde el hilo de la terminal cuando llega salida nueva.
final class Bandera: @unchecked Sendable {
    private var valor = false
    private let lock = NSLock()
    func encender() { lock.lock(); valor = true; lock.unlock() }
    func tomar() -> Bool { lock.lock(); defer { valor = false; lock.unlock() }; return valor }
}

final class VistaTerminal: LocalProcessTerminalView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("no se usa") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let rutas = VistaTerminal.rutas(sender.draggingPasteboard) else { return false }
        send(txt: rutas + " ")
        window?.makeFirstResponder(self)
        return true
    }

    /// ⌘V con archivos o carpetas copiados en el Finder pega su ruta completa, como Warp
    /// (el Finder también deja el nombre como texto, que es lo único que pegaba antes).
    override func paste(_ sender: Any) {
        if let rutas = VistaTerminal.rutas(NSPasteboard.general) {
            send(txt: rutas)
        } else {
            super.paste(sender)
        }
    }

    /// Las rutas de los archivos del portapapeles, listas para la terminal (con comillas si hace falta).
    static func rutas(_ pb: NSPasteboard) -> String? {
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return nil }
        return urls.map { u -> String in
            let p = u.path
            let seguro = p.allSatisfy { $0.isLetter || $0.isNumber || "/._-~+@".contains($0) }
            return seguro ? p : "'" + p.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}

// MARK: - una terminal (proceso + vista de SwiftTerm)

final class Term: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let motor: Motor?
    @Published var sesionId: String?
    @Published var titulo: String
    /// el nombre que le pusiste a la pestaña (solo en terminales sin sesión; las sesiones guardan el suyo)
    @Published var nombre: String?
    @Published var grupo: UUID?
    @Published var rama: String?
    @Published var cwd: String
    @Published var estado: Estado = .nada
    @Published var sinVer = false
    @Published private(set) var iniciado = false
    let vista: VistaTerminal
    weak var store: Store?
    let salida = Bandera()
    var quietos = 0
    var desde = Date()
    private var vivo = true

    /// la terminal es "la tele": el fondo lo pone el tema
    static var fondo: NSColor { Tema.p.terminalFondo }

    func colores() {
        vista.nativeBackgroundColor = Tema.p.terminalFondo
        vista.nativeForegroundColor = Tema.p.terminalTexto
        vista.caretColor = Tema.p.cursor
        vista.needsDisplay = true
    }

    /// lo que se ve en la pestaña
    var etiqueta: String { nombre ?? titulo }

    @MainActor
    init(cwd: String, motor: Motor?, sesionId: String?, titulo: String, store: Store) {
        self.motor = motor
        self.sesionId = sesionId
        self.titulo = titulo
        self.cwd = cwd
        self.store = store
        vista = VistaTerminal(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        super.init()
        vista.processDelegate = self
        colores()
        vista.optionAsMetaKey = false // Option + tecla escribe @, #, etc. con teclado en español
        let b = salida
        vista.setProcessOutputHandler { b.encender() }
        ponFuente(store.tamFuente)
    }

    /// Arranca el proceso (las pestañas restauradas esperan a que las abras).
    @MainActor
    func iniciar() {
        guard !iniciado else { return }
        iniciado = true
        let shell = Term.shellDelUsuario()
        var env = ProcessInfo.processInfo.environment
        // si la app se abrió desde otra terminal, no heredar sus marcas (Claude dejaría de guardar la sesión)
        for k in env.keys where k.hasPrefix("CLAUDECODE") || k.hasPrefix("CLAUDE_CODE_") || k.hasPrefix("WARP_")
            || ["TERM_SESSION_ID", "ITERM_SESSION_ID", "TERM_PROGRAM_VERSION", "CODEX_SANDBOX", "CODEX_THREAD_ID"].contains(k) {
            env[k] = nil
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Sesiones"
        if env["LANG"] == nil { env["LANG"] = "es_ES.UTF-8" }
        var comando: String?
        if let motor { comando = sesionId.map { motor.retomar($0) } ?? motor.rawValue }
        // shell de login para tener tu PATH; al salir del agente te quedas en la terminal
        let args = comando.map { ["-l", "-i", "-c", "\($0); exec '\(shell)' -l"] } ?? ["-l"]
        let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : Datos.home
        vista.startProcess(executable: shell, args: args, environment: env.map { "\($0.key)=\($0.value)" },
                           execName: nil, currentDirectory: dir)
    }

    static func shellDelUsuario() -> String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if FileManager.default.isExecutableFile(atPath: s) { return s }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    func ponFuente(_ tam: CGFloat) {
        vista.font = NSFont(name: "SF Mono", size: tam) ?? NSFont.monospacedSystemFont(ofSize: tam, weight: .regular)
    }

    func terminar() {
        guard vivo else { return }
        vivo = false
        if iniciado { vista.terminate() }
    }

    /// Lee la pantalla: Claude y Codex muestran "esc to interrupt" mientras trabajan y un menú cuando piden permiso.
    func leerEstado() -> Estado {
        guard let snap = vista.terminalContentSnapshot(region: .history(maximumScrollbackRows: -1)) else { return .nada }
        let texto = snap.rows.map(\.text).joined(separator: "\n").lowercased()
        if texto.contains("do you want to") || texto.contains("would you like to run") || texto.contains("❯ 1. yes")
            || texto.contains("allow this") {
            return .permiso
        }
        if texto.contains("esc to interrupt") || texto.contains("esc to stop") { return .trabajando }
        return .nada
    }

    // LocalProcessTerminalViewDelegate
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard sesionId == nil, motor == nil else { return } // las sesiones conservan su título
        let t = title.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { DispatchQueue.main.async { self.titulo = t } }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let u = URL(string: directory) else { return }
        let p = u.path.isEmpty ? directory : u.path
        DispatchQueue.main.async { self.cwd = p }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            self.vivo = false
            self.store?.terminoProceso(self)
        }
    }
}
