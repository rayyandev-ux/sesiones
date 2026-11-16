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

/// Lo que está haciendo el agente dentro de una terminal.
enum Estado {
    case nada, trabajando, listo, permiso
}

@MainActor
final class Store: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var carpetas: [Carpeta] = []
    @Published var total = 0
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
    private var pendientes: [(cwd: String, carpeta: String?, desde: Date, term: UUID)] = []
    private var timers: [Timer] = []
    private var saliendo = false
    private let notificaciones = Bundle.main.bundleIdentifier != nil
    private var registro: String?

    override init() {
        super.init()
        let f = UserDefaults.standard.double(forKey: "tamFuente")
        tamFuente = f > 0 ? CGFloat(f) : 13
        recargar()
        restaurar()
        timers.append(Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recargar() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.vigilar() }
        })
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recargar(); self?.alMostrar() }
        }
        nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saliendo = true }
        }
        if let c = ProcessInfo.processInfo.environment["SESIONES_CARPETA"] { vista = .carpeta(c) } // solo para pruebas
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

    private func aplica(_ r: (carpetas: [Carpeta], total: Int, ids: Set<String>)) {
        cargando = false
        // una sesión nueva abierta desde la app: se le pone su id a la pestaña y se queda en su carpeta
        if !pendientes.isEmpty && !idsConocidos.isEmpty {
            let nuevas = r.ids.subtracting(idsConocidos)
            var mover: [(String, String)] = []
            for s in r.carpetas.flatMap(\.sesiones) where nuevas.contains(s.id) {
                if let k = pendientes.firstIndex(where: { $0.cwd == s.cwd && s.mtime >= $0.desde.addingTimeInterval(-5) }) {
                    let p = pendientes.remove(at: k)
                    if let t = terminales.first(where: { $0.id == p.term }), t.sesionId == nil {
                        t.sesionId = s.id
                        t.titulo = s.titulo
                        guardarAbiertas()
                    }
                    if let c = p.carpeta, s.carpeta != c { mover.append((s.id, c)) }
                }
            }
            pendientes.removeAll { Date().timeIntervalSince($0.desde) > 3600 }
            if !mover.isEmpty {
                for (id, c) in mover { _ = Datos.mover([id], a: c) }
                idsConocidos = r.ids
                recargar()
                return
            }
        }
        idsConocidos = r.ids
        carpetas = r.carpetas
        total = r.total
        // los títulos que Claude pone a las sesiones nuevas llegan después: se actualizan en las pestañas
        let porId = Dictionary(r.carpetas.flatMap(\.sesiones).map { ($0.id, $0.titulo) }, uniquingKeysWith: { a, _ in a })
        for t in terminales { if let id = t.sesionId, let tit = porId[id], tit != t.titulo { t.titulo = tit } }
        if carpetaSel == nil { carpetaSel = carpetas.first?.nombre }
        if case .carpeta(let n) = vista, !carpetas.contains(where: { $0.nombre == n }) { vista = .inicio }
        if otraVez { otraVez = false; recargar() }
    }

    var todas: [Sesion] { carpetas.flatMap(\.sesiones).sorted { $0.mtime > $1.mtime } }

    var recientes: [Sesion] {
        Array(carpetas.filter { $0.nombre != "Pruebas" && $0.nombre != "Archivo" }
            .flatMap(\.sesiones).sorted { $0.mtime > $1.mtime }.prefix(6))
    }

    func sesiones(de nombre: String) -> [Sesion] {
        carpetas.first { $0.nombre == nombre }?.sesiones ?? []
    }

    var resultados: [Sesion] {
        let palabras = query.lowercased().split(separator: " ").map(String.init)
        guard !palabras.isEmpty else { return [] }
        return todas.filter { s in
            let t = (s.titulo + " " + s.prompts.joined(separator: " ") + " " + s.cwd + " " + s.carpeta + " " + s.motor.rawValue).lowercased()
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

    func abrirCarpeta(_ n: String) {
        carpetaSel = n
        sesionSel = sesiones(de: n).first?.id
        vista = .carpeta(n)
    }

    func crearCarpeta(_ nombre: String) {
        if let e = Datos.crearCarpeta(nombre) { aviso = e } else { carpetaSel = Datos.limpia(nombre); recargar() }
    }

    func renombrar(_ viejo: String, _ nuevo: String) {
        if let e = Datos.renombrar(viejo, nuevo) { aviso = e; return }
        let n = Datos.limpia(nuevo)
        if carpetaSel == viejo { carpetaSel = n }
        if vista == .carpeta(viejo) { vista = .carpeta(n) }
        recargar()
    }

    func borrar(_ nombre: String) {
        if let e = Datos.borrar(nombre) { aviso = e; return }
        if vista == .carpeta(nombre) { vista = .inicio }
        recargar()
    }

    func mover(_ ids: [String], a carpeta: String) {
        if carpeta == "Archivo" { archivar(ids, true); return }
        if Datos.mover(ids, a: carpeta) != nil {
            // carpeta automática (por proyecto): se vuelve una carpeta tuya y la sesión entra
            if let e = Datos.crearCarpeta(carpeta) ?? Datos.mover(ids, a: carpeta) { aviso = e; return }
        }
        recargar()
    }

    func archivar(_ ids: [String], _ si: Bool) {
        Datos.archivar(ids, si)
        recargar()
    }

    func mueveCarpeta(_ nombre: String, antesDe destino: String) {
        Datos.mueveCarpeta(nombre, antesDe: destino)
        recargar()
    }

    // MARK: terminales

    func retomar(_ s: Sesion) {
        if let t = terminales.first(where: { $0.sesionId == s.id }) { mostrar(t); return }
        guard FileManager.default.fileExists(atPath: s.cwd) else { aviso = "Esa carpeta ya no existe: \(s.cwd)"; return }
        mostrar(crear(cwd: s.cwd, motor: s.motor, sesionId: s.id, titulo: s.titulo))
    }

    func nuevaSesion(en cwd: String, carpeta: String?, motor: Motor = .claude) {
        let t = crear(cwd: cwd, motor: motor, sesionId: nil, titulo: "\(motor.nombre) · " + (cwd as NSString).lastPathComponent)
        pendientes.append((cwd, carpeta, Date(), t.id))
        mostrar(t)
    }

    /// Dónde arrancan las sesiones nuevas de esta carpeta: la que elegiste, la de su sesión más reciente,
    /// o (si está vacía) <base>/<nombre> (base = "base" en carpetas.json, por defecto ~/Proyectos).
    func dirDeTrabajo(_ carpeta: String) -> (dir: String, nueva: Bool) {
        if let d = Datos.dirGuardado(carpeta) { return (d, !FileManager.default.fileExists(atPath: d)) }
        if let s = sesiones(de: carpeta).first(where: { FileManager.default.fileExists(atPath: $0.cwd) }) { return (s.cwd, false) }
        let d = Datos.carpetaBase() + "/" + Datos.nombreEnDisco(carpeta)
        return (d, !FileManager.default.fileExists(atPath: d))
    }

    func sesionAqui(_ carpeta: String, motor: Motor = .claude) {
        let (dir, nueva) = dirDeTrabajo(carpeta)
        if nueva {
            do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
            catch { aviso = "No pude crear \(dir): \(error.localizedDescription)"; return }
        }
        if Datos.dirGuardado(carpeta) == nil && sesiones(de: carpeta).isEmpty { Datos.ponDir(carpeta, dir) }
        nuevaSesion(en: dir, carpeta: carpeta, motor: motor)
    }

    func cambiarDir(_ carpeta: String) {
        if let d = elegirDirectorio(dirDeTrabajo(carpeta).dir) { Datos.ponDir(carpeta, d); recargar(); objectWillChange.send() }
    }

    func nuevaTerminal(en cwd: String? = nil) {
        mostrar(crear(cwd: cwd ?? Datos.home, motor: nil, sesionId: nil, titulo: "Terminal"))
    }

    @discardableResult
    private func crear(cwd: String, motor: Motor?, sesionId: String?, titulo: String, dormida: Bool = false) -> Term {
        let t = Term(cwd: cwd, motor: motor, sesionId: sesionId, titulo: titulo, store: self)
        terminales.append(t)
        if !dormida { t.iniciar() }
        guardarAbiertas()
        return t
    }

    func mostrar(_ t: Term) {
        if lado == t.id, let a = terminalActiva { lado = a.id }
        vista = .terminal(t.id)
        alMostrar()
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
        terminales.remove(at: k)
        if lado == t.id { lado = nil }
        if vista == .terminal(t.id) {
            if let l = lado, let lt = terminales.first(where: { $0.id == l }) {
                lado = nil
                vista = .terminal(lt.id)
            } else if terminales.isEmpty {
                vista = .inicio
            } else {
                vista = .terminal(terminales[min(k, terminales.count - 1)].id)
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
        guard !terminales.isEmpty else { return }
        let k = terminales.firstIndex { $0 === terminalActiva } ?? (paso > 0 ? -1 : 0)
        mostrar(terminales[(k + paso + terminales.count) % terminales.count])
    }

    func irA(_ n: Int) {
        if n < terminales.count { mostrar(terminales[n]) }
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
        c.body = t.titulo
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

    private func guardarAbiertas() {
        guard !saliendo else { return }
        let lista: [[String: String]] = terminales.map {
            ["motor": $0.motor?.rawValue ?? "", "sesion": $0.sesionId ?? "", "cwd": $0.cwd, "titulo": $0.titulo]
        }
        UserDefaults.standard.set(lista, forKey: "abiertas")
    }

    /// Al abrir la app vuelven tus pestañas, dormidas: cada una arranca cuando la abres (no gasta RAM antes).
    private func restaurar() {
        guard let lista = UserDefaults.standard.array(forKey: "abiertas") as? [[String: String]] else { return }
        for d in lista {
            let cwd = d["cwd"] ?? Datos.home
            guard FileManager.default.fileExists(atPath: cwd) else { continue }
            let motor = Motor(rawValue: d["motor"] ?? "")
            let sesion = d["sesion"].flatMap { $0.isEmpty ? nil : $0 }
            if motor != nil && sesion == nil { continue } // sesión nueva que nunca llegó a guardarse
            crear(cwd: cwd, motor: motor, sesionId: sesion, titulo: d["titulo"] ?? "Terminal", dormida: true)
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
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        let texto = urls.map { u -> String in
            let p = u.path
            let seguro = p.allSatisfy { $0.isLetter || $0.isNumber || "/._-~+@".contains($0) }
            return seguro ? p : "'" + p.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ") + " "
        send(txt: texto)
        window?.makeFirstResponder(self)
        return true
    }
}

// MARK: - una terminal (proceso + vista de SwiftTerm)

final class Term: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let motor: Motor?
    @Published var sesionId: String?
    @Published var titulo: String
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

    static let fondo = NSColor(hex: 0x0E1730)

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
        vista.nativeBackgroundColor = Term.fondo
        vista.nativeForegroundColor = NSColor(hex: 0xE6ECF7)
        vista.caretColor = NSColor(hex: 0x4D8AE6)
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
