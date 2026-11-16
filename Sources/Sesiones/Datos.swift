import Foundation
import SQLite3

enum Motor: String {
    case claude, codex
    var nombre: String { self == .claude ? "Claude" : "Codex" }
    func retomar(_ id: String) -> String { self == .claude ? "claude --resume \(id)" : "codex resume \(id)" }
}

// Lee las sesiones de Claude Code (~/.claude/projects) y las reparte en carpetas.
// Comparte carpetas.json y la caché con el comando `sesiones` (~/.sesiones).

struct Sesion: Identifiable, Hashable {
    let id: String
    /// carpeta del disco donde vive hoy (si moviste el proyecto con su historial, la nueva)
    var cwd: String
    /// ruta corta para mostrar: "Clientes/Rufino/web"
    var proyecto: String
    var titulo: String
    let prompt: String
    let prompts: [String]
    let sdk: Bool
    let mtime: Date
    var motor: Motor = .claude
    var carpeta: String = ""
}

/// Una carpeta del árbol. Las de verdad copian tu disco (id = su ruta); las de grupo ("Archivo", "Pruebas",
/// "Otros lugares", "Ya no existen") juntan lo que no está dentro de tu carpeta de proyectos.
struct Carpeta: Identifiable, Hashable {
    let id: String
    let nombre: String
    /// carpeta real del disco; nil si no existe o es un grupo
    var ruta: String?
    var grupo = false
    /// sesiones abiertas justo en esta carpeta
    var sesiones: [Sesion] = []
    var hijos: [Carpeta] = []
    /// sesiones de esta carpeta y de todo lo que tiene dentro
    var total = 0

    var todas: [Sesion] { sesiones + hijos.flatMap(\.todas) }

    func buscar(_ id: String) -> Carpeta? {
        if self.id == id { return self }
        for h in hijos { if let c = h.buscar(id) { return c } }
        return nil
    }
}

/// Encuentra dónde está hoy la carpeta de una sesión.
/// Claude Code guarda cada sesión en ~/.claude/projects/<clave>, y la clave es la ruta donde se abrió con "-" en
/// lugar de todo lo que no sea letra o número. Si moviste un proyecto y te llevaste su historial, la ruta escrita
/// dentro de la sesión es la vieja: la de hoy se saca buscando en el disco la carpeta que da esa misma clave.
final class Rutas {
    private var listas: [String: [(nombre: String, claves: [String])]] = [:]
    private var resueltas: [String: String?] = [:]
    private var carpetas: [String: Bool] = [:]
    private let fm = FileManager.default

    static func clave(_ ruta: String) -> String {
        String(decoding: ruta.utf16.map { u -> UInt8 in
            (u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122) ? UInt8(u) : 45
        }, as: UTF8.self)
    }

    func esCarpeta(_ ruta: String) -> Bool {
        if let c = carpetas[ruta] { return c }
        var dir: ObjCBool = false
        let c = fm.fileExists(atPath: ruta, isDirectory: &dir) && dir.boolValue
        carpetas[ruta] = c
        return c
    }

    func real(cwd: String, clave: String) -> String {
        if Rutas.clave(cwd) == clave && esCarpeta(cwd) { return cwd }
        if let r = resueltas[clave] { return r ?? cwd }
        let r = busca("", Substring(clave))
        resueltas[clave] = r
        return r ?? cwd
    }

    private func hijos(_ dir: String) -> [(nombre: String, claves: [String])] {
        if let l = listas[dir] { return l }
        let l = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).map { n -> (nombre: String, claves: [String]) in
            // las tildes pueden estar guardadas juntas o separadas: se prueban las dos formas
            let a = Rutas.clave(n.precomposedStringWithCanonicalMapping), b = Rutas.clave(n.decomposedStringWithCanonicalMapping)
            return (n, a == b ? [a] : [a, b])
        }
        listas[dir] = l
        return l
    }

    /// `resto` empieza con "-" (la barra que separa carpetas).
    private func busca(_ dir: String, _ resto: Substring) -> String? {
        guard resto.first == "-" else { return nil }
        let cuerpo = resto.dropFirst()
        for h in hijos(dir.isEmpty ? "/" : dir) {
            for c in h.claves where cuerpo.hasPrefix(c) {
                let sig = cuerpo.dropFirst(c.count)
                let ruta = dir + "/" + h.nombre
                if sig.isEmpty {
                    if esCarpeta(ruta) { return ruta }
                } else if sig.first == "-", esCarpeta(ruta), let r = busca(ruta, sig) {
                    return r
                }
            }
        }
        return nil
    }
}

enum Datos {
    static let home = NSHomeDirectory()
    static let base = home + "/.claude/projects"
    static let dir = home + "/.sesiones"
    static let conf = ProcessInfo.processInfo.environment["SESIONES_CONF"] ?? (dir + "/carpetas.json")
    static let cache = dir + "/.cache.json"

    // MARK: lectura rápida de cada sesión (archivo mapeado en memoria, solo se parsean las líneas útiles)

    private static let nAi = Array("\"ai-title\"".utf8)
    private static let nCustom = Array("\"custom-title\"".utf8)
    private static let nUser = Array("\"type\":\"user\"".utf8)
    private static let nCwd = Array("\"cwd\"".utf8)
    private static let pegado = try! NSRegularExpression(pattern: "<pasted_content[^>]*>.*?</pasted_content[^>]*>", options: [.dotMatchesLineSeparators])

    @inline(__always)
    private static func tiene(_ p: UnsafeRawPointer, _ len: Int, _ aguja: [UInt8]) -> Bool {
        aguja.withUnsafeBytes { memmem(p, len, $0.baseAddress, aguja.count) != nil }
    }

    private static func json(_ p: UnsafeRawPointer, _ len: Int) -> [String: Any]? {
        let d = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: p), count: len, deallocator: .none)
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func limpia(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    private static func textoUsuario(_ d: [String: Any]) -> String? {
        if (d["isSidechain"] as? Bool) == true || (d["isMeta"] as? Bool) == true { return nil }
        let msg = d["message"] as? [String: Any]
        var texto: String?
        if let c = msg?["content"] as? String {
            texto = c
        } else if let bloques = msg?["content"] as? [[String: Any]] {
            if bloques.contains(where: { ($0["type"] as? String) == "tool_result" }) { return nil }
            let partes = bloques.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }
            if partes.isEmpty { return nil }
            texto = partes.joined(separator: " ")
        }
        guard var t = texto else { return nil }
        t = pegado.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: " ")
        t = limpia(t)
        if t.isEmpty || t.hasPrefix("<") || t.hasPrefix("[Request interrupted") { return nil }
        return t
    }

    static func leeSesion(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return nil }
        var cwd: String?, ai: String?, custom: String?, sdk = false
        var prompts: [String] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let n = raw.count
            var inicio = 0
            while inicio < n {
                let p = base + inicio
                let fin: Int
                if let nl = memchr(p, 0x0A, n - inicio) { fin = base.distance(to: UnsafeRawPointer(nl)) } else { fin = n }
                let len = fin - inicio
                if len > 2 {
                    if tiene(p, len, nAi) || tiene(p, len, nCustom) {
                        if let d = json(p, len) {
                            if (d["type"] as? String) == "ai-title", let t = d["aiTitle"] as? String, !t.isEmpty { ai = t }
                            if (d["type"] as? String) == "custom-title", let t = d["customTitle"] as? String, !t.isEmpty { custom = t }
                        }
                    } else if prompts.count < 3 && tiene(p, len, nUser) {
                        if let d = json(p, len), (d["type"] as? String) == "user" {
                            if cwd == nil { cwd = d["cwd"] as? String }
                            if let e = d["entrypoint"] as? String, e.hasPrefix("sdk") { sdk = true }
                            if let t = textoUsuario(d) { prompts.append(String(t.prefix(400))) }
                        }
                    } else if cwd == nil && len < 20000 && tiene(p, len, nCwd) {
                        cwd = json(p, len)?["cwd"] as? String
                    }
                }
                inicio = fin + 1
            }
        }
        var info: [String: Any] = ["prompts": prompts, "sdk": sdk]
        info["cwd"] = cwd ?? NSNull()
        info["ai"] = ai ?? NSNull()
        info["custom"] = custom ?? NSNull()
        return info
    }

    // MARK: todas las sesiones, con caché compartida

    static func cargaSesiones() -> [Sesion] {
        var cacheVieja: [String: Any] = [:]
        if let d = FileManager.default.contents(atPath: cache),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { cacheVieja = o }

        var archivos: [String] = []
        var claves: [String] = []
        let fm = FileManager.default
        for d in (try? fm.contentsOfDirectory(atPath: base)) ?? [] {
            let carpeta = base + "/" + d
            for f in (try? fm.contentsOfDirectory(atPath: carpeta)) ?? [] where f.hasSuffix(".jsonl") {
                archivos.append(carpeta + "/" + f)
                claves.append(d)
            }
        }

        let lock = NSLock()
        var cacheNueva: [String: Any] = [:]
        var leidas: [(Sesion, String)] = []
        leidas.reserveCapacity(archivos.count)

        DispatchQueue.concurrentPerform(iterations: archivos.count) { i in
            let path = archivos[i]
            var st = stat()
            guard stat(path, &st) == 0 else { return }
            let key = "\(st.st_mtimespec.tv_sec):\(st.st_size)"
            var info: [String: Any]?
            lock.lock()
            if let hit = cacheVieja[path] as? [Any], hit.count == 2, (hit[0] as? String) == key {
                info = hit[1] as? [String: Any]
            }
            lock.unlock()
            if info == nil { info = leeSesion(path) }
            guard let info else { return }
            let prompts = info["prompts"] as? [String] ?? []
            var sesion: Sesion?
            if let primero = prompts.first {
                let cwd = (info["cwd"] as? String) ?? home
                let titulo = limpia((info["custom"] as? String) ?? (info["ai"] as? String) ?? primero)
                let proyecto = cwd == home ? "~" : (cwd as NSString).lastPathComponent
                sesion = Sesion(
                    id: ((path as NSString).lastPathComponent as NSString).deletingPathExtension,
                    cwd: cwd, proyecto: proyecto, titulo: titulo, prompt: primero, prompts: prompts,
                    sdk: (info["sdk"] as? Bool) ?? false,
                    mtime: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                )
            }
            lock.lock()
            cacheNueva[path] = [key, info]
            if let sesion { leidas.append((sesion, claves[i])) }
            lock.unlock()
        }

        if let d = try? JSONSerialization.data(withJSONObject: cacheNueva) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? d.write(to: URL(fileURLWithPath: cache), options: .atomic)
        }
        // la carpeta donde vive hoy cada sesión (ahí es donde `claude --resume` la encuentra)
        let rutas = Rutas()
        var out = leidas.map { s, clave -> Sesion in
            var s = s
            s.cwd = rutas.real(cwd: s.cwd, clave: clave)
            return s
        }
        out.sort { $0.mtime > $1.mtime }
        return out
    }

    // MARK: Codex (lee su base SQLite en solo lectura)

    static func cargaCodex() -> [Sesion] {
        let dir = home + "/.codex"
        let bases = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }.sorted()
        guard let base = bases.last else { return [] }
        let path = dir + "/" + base
        let sql = """
            select id, cwd, coalesce(nullif(name,''), nullif(title,''), first_user_message), first_user_message,
                   coalesce(updated_at_ms, updated_at * 1000)
            from threads where archived = 0 and first_user_message != '' and source in ('cli','vscode','exec')
            """
        for uri in ["file:\(path)?mode=ro", "file:\(path)?mode=ro&immutable=1"] {
            var db: OpaquePointer?
            guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { sqlite3_close(db); continue }
            sqlite3_busy_timeout(db, 300)
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { sqlite3_finalize(st); sqlite3_close(db); continue }
            var out: [Sesion] = []
            func col(_ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
            while sqlite3_step(st) == SQLITE_ROW {
                let cwd = col(1).isEmpty ? home : col(1)
                let primero = limpia(col(3))
                let titulo = String(limpia(col(2)).prefix(160))
                guard !titulo.isEmpty else { continue }
                out.append(Sesion(
                    id: col(0), cwd: cwd, proyecto: cwd == home ? "~" : (cwd as NSString).lastPathComponent,
                    titulo: titulo, prompt: String((primero.isEmpty ? titulo : primero).prefix(400)),
                    prompts: [String(primero.prefix(400))], sdk: false,
                    mtime: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(st, 4)) / 1000),
                    motor: .codex))
            }
            sqlite3_finalize(st)
            sqlite3_close(db)
            return out
        }
        return []
    }

    // MARK: carpetas.json

    static func cargaConf() -> [String: Any] {
        if let d = FileManager.default.contents(atPath: conf),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let c = o["carpetas"] as? [[String: Any]], !c.isEmpty {
            var o = o
            if o["manual"] == nil { o["manual"] = [String: String]() }
            return o
        }
        let inicial: [String: Any] = [
            "base": "~/Proyectos",
            "porProyecto": true,
            "carpetas": [["nombre": "Otros", "rutas": [String](), "palabras": [String]()]],
            "pruebas": ["nombre": "Pruebas", "rutas": ["/private/tmp", "/tmp/", "Application Support/Claude/scratch"]],
            "manual": [String: String](),
        ]
        guardaConf(inicial)
        return inicial
    }

    static func guardaConf(_ c: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: c, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? d.write(to: URL(fileURLWithPath: conf), options: .atomic)
    }

    static let nArchivo = "Archivo"
    static let nFuera = "Otros lugares"
    static let nPerdidas = "Ya no existen"
    /// carpetas que no son proyectos: no se muestran dentro de una carpeta sin repositorio
    private static let ruido: Set<String> = ["node_modules", "build", "dist", "vendor", "Pods", "DerivedData", "__pycache__", "venv"]

    static func corta(_ ruta: String) -> String {
        ruta == home ? "~" : ruta.hasPrefix(home + "/") ? "~" + ruta.dropFirst(home.count) : ruta
    }

    /// Pieza del árbol mientras se arma.
    private final class Nodo {
        let id: String, nombre: String, ruta: String?
        var grupo = false
        var sesiones: [Sesion] = []
        var hijos: [String: Nodo] = [:]

        init(id: String, nombre: String, ruta: String?, grupo: Bool = false) {
            self.id = id; self.nombre = nombre; self.ruta = ruta; self.grupo = grupo
        }

        func hijo(_ llave: String, id: String, nombre: String, ruta: String?) -> Nodo {
            if let h = hijos[llave] { return h }
            let h = Nodo(id: id, nombre: nombre, ruta: ruta)
            hijos[llave] = h
            return h
        }

        func carpeta() -> Carpeta {
            // en el mismo orden que el Finder
            let hs = hijos.values.map { $0.carpeta() }.sorted { $0.nombre.localizedStandardCompare($1.nombre) == .orderedAscending }
            return Carpeta(id: id, nombre: nombre, ruta: ruta, grupo: grupo, sesiones: sesiones, hijos: hs,
                           total: sesiones.count + hs.reduce(0) { $0 + $1.total })
        }
    }

    /// Arma el árbol de carpetas copiando tu disco: lo que hay dentro de "base" (carpetas.json) sale igual que en el
    /// Finder, y cada sesión va a la carpeta donde se abrió. Lo demás va a los grupos del final.
    static func clasifica(_ sesiones: [Sesion], conf: [String: Any]) -> [Carpeta] {
        let fm = FileManager.default
        let rutas = Rutas()
        let raiz = carpetaBase(conf)
        let nombreRaiz = (raiz as NSString).lastPathComponent
        let pruebas = conf["pruebas"] as? [String: Any]
        let rPruebas = pruebas?["rutas"] as? [String] ?? []
        let archivo = Set(conf["archivo"] as? [String] ?? [])

        let arbol = Nodo(id: raiz, nombre: nombreRaiz, ruta: raiz)
        func nodo(_ ruta: String) -> Nodo {
            var n = arbol, actual = raiz
            for parte in ruta.dropFirst(raiz.count).split(separator: "/") {
                actual += "/" + parte
                n = n.hijo(String(parte), id: actual, nombre: String(parte), ruta: actual)
            }
            return n
        }

        // el disco manda: dos niveles de carpetas tal cual, y un tercero dentro de las que no son un repositorio
        // (un cliente o producto con varias partes: web, ios, android)
        func visibles(_ dir: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { n in
                guard !n.hasPrefix("."), !ruido.contains(n), rutas.esCarpeta(dir + "/" + n) else { return false }
                let paquete = try? URL(fileURLWithPath: dir + "/" + n).resourceValues(forKeys: [.isPackageKey]).isPackage
                return paquete != true
            }
        }
        for a in visibles(raiz) {
            let ra = raiz + "/" + a
            _ = nodo(ra)
            for b in visibles(ra) {
                let rb = ra + "/" + b
                _ = nodo(rb)
                if fm.fileExists(atPath: rb + "/.git") { continue }
                for c in visibles(rb) { _ = nodo(rb + "/" + c) }
            }
        }

        let fuera = Nodo(id: nFuera, nombre: nFuera, ruta: nil, grupo: true)
        let perdidas = Nodo(id: nPerdidas, nombre: nPerdidas, ruta: nil, grupo: true)
        let nodoPruebas = (pruebas?["nombre"] as? String).map { Nodo(id: $0, nombre: $0, ruta: nil, grupo: true) }
        let nodoArchivo = Nodo(id: nArchivo, nombre: nArchivo, ruta: nil, grupo: true)

        for var s in sesiones {
            let dentro = s.cwd == raiz || s.cwd.hasPrefix(raiz + "/")
            let ultimo = (s.cwd as NSString).lastPathComponent
            s.proyecto = !dentro ? corta(s.cwd) : s.cwd == raiz ? nombreRaiz : String(s.cwd.dropFirst(raiz.count + 1))
            let destino: Nodo
            if archivo.contains(s.id) {
                destino = nodoArchivo
            } else if let p = nodoPruebas, rPruebas.contains(where: { s.cwd.contains($0) }) {
                destino = p
            } else if !rutas.esCarpeta(s.cwd) {
                destino = perdidas.hijo(s.cwd, id: nPerdidas + ":" + s.cwd, nombre: ultimo, ruta: nil)
            } else if dentro {
                destino = nodo(s.cwd)
            } else {
                destino = fuera.hijo(s.cwd, id: s.cwd, nombre: s.cwd == home ? "Inicio (~)" : ultimo, ruta: s.cwd)
            }
            s.carpeta = destino.id
            destino.sesiones.append(s)
        }

        var lista = arbol.carpeta().hijos
        // las sesiones abiertas directo en la carpeta de proyectos, sin entrar a ninguna
        if !arbol.sesiones.isEmpty {
            lista.append(Carpeta(id: raiz, nombre: "Sueltas en " + nombreRaiz, ruta: raiz, grupo: true,
                                 sesiones: arbol.sesiones, total: arbol.sesiones.count))
        }
        for g in [fuera, perdidas, nodoPruebas, nodoArchivo].compactMap({ $0 }) {
            let c = g.carpeta()
            if c.total > 0 { lista.append(c) }
        }
        return lista
    }

    static func todo() -> (carpetas: [Carpeta], sesiones: [Sesion], raiz: String, nombres: [String: String]) {
        let conf = cargaConf()
        let nombres = conf["nombres"] as? [String: String] ?? [:]
        // el nombre que le pusiste a una sesión manda sobre el que le puso Claude
        let sesiones = (cargaSesiones() + cargaCodex())
            .map { s -> Sesion in
                guard let n = nombres[s.id] else { return s }
                var s = s
                s.titulo = n
                return s
            }
            .sorted { $0.mtime > $1.mtime }
        let carpetas = clasifica(sesiones, conf: conf)
        return (carpetas, carpetas.flatMap(\.todas).sorted { $0.mtime > $1.mtime }, carpetaBase(conf), nombres)
    }

    // MARK: nombres que les pones a las sesiones (se ven en la app, no cambian el historial de Claude)

    /// nil o vacío quita el nombre y vuelve el que le puso Claude.
    static func nombrar(_ id: String, _ nombre: String?) {
        var c = cargaConf()
        var n = c["nombres"] as? [String: String] ?? [:]
        let limpio = limpia(nombre ?? "")
        n[id] = limpio.isEmpty ? nil : limpio
        c["nombres"] = n
        guardaConf(c)
    }

    /// La rama de git de una carpeta (o el commit si no está en una rama), como la muestra Warp.
    static func rama(de dir: String) -> String? {
        let fm = FileManager.default
        var d = dir
        while !d.isEmpty && d != "/" && d != home {
            let g = d + "/.git"
            var esDir: ObjCBool = false
            if fm.fileExists(atPath: g, isDirectory: &esDir) {
                var gitdir = g
                if !esDir.boolValue { // worktree o submódulo: ".git" es un archivo que apunta a la carpeta real
                    guard let t = try? String(contentsOfFile: g, encoding: .utf8), t.hasPrefix("gitdir:") else { return nil }
                    let r = t.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                    gitdir = r.hasPrefix("/") ? r : d + "/" + r
                }
                guard let head = try? String(contentsOfFile: gitdir + "/HEAD", encoding: .utf8) else { return nil }
                let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
                return h.hasPrefix("ref: refs/heads/") ? String(h.dropFirst(16)) : String(h.prefix(7))
            }
            d = (d as NSString).deletingLastPathComponent
        }
        return nil
    }

    // MARK: archivo

    static func archivar(_ ids: [String], _ si: Bool) {
        var c = cargaConf()
        var a = c["archivo"] as? [String] ?? []
        if si { a.append(contentsOf: ids.filter { !a.contains($0) }) } else { a.removeAll { ids.contains($0) } }
        c["archivo"] = a
        guardaConf(c)
    }

    /// Tu carpeta de proyectos ("base" en carpetas.json): de ahí sale el árbol.
    static func carpetaBase(_ conf: [String: Any]? = nil) -> String {
        let b = ((conf ?? cargaConf())["base"] as? String) ?? "~/Proyectos"
        return ((b as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    /// Nombre de carpeta seguro para el disco ("GTA 6 / clips" → "GTA 6 - clips").
    static func nombreEnDisco(_ nombre: String) -> String {
        let n = limpia(nombre.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-"))
        return n.isEmpty || n.hasPrefix(".") ? "carpeta" : n
    }
}

func hace(_ fecha: Date) -> String {
    let d = Date().timeIntervalSince(fecha)
    if d < 60 { return "ahora" }
    if d < 3600 { return "hace \(Int(d / 60)) min" }
    if d < 86400 { return "hace \(Int(d / 3600)) h" }
    let dias = Int(d / 86400)
    if dias == 1 { return "ayer" }
    if dias < 7 { return "hace \(dias) días" }
    let meses = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"]
    let c = Calendar.current.dateComponents([.day, .month], from: fecha)
    return "\(c.day ?? 1) \(meses[(c.month ?? 1) - 1])"
}
