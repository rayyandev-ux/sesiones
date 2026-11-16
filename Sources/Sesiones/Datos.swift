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
    let cwd: String
    let proyecto: String
    let titulo: String
    let prompt: String
    let prompts: [String]
    let sdk: Bool
    let mtime: Date
    var motor: Motor = .claude
    var carpeta: String = ""
}

struct Carpeta: Identifiable, Hashable {
    var id: String { nombre }
    let nombre: String
    var sesiones: [Sesion]
    let fija: Bool
    var auto = false
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
        let fm = FileManager.default
        for d in (try? fm.contentsOfDirectory(atPath: base)) ?? [] {
            let carpeta = base + "/" + d
            for f in (try? fm.contentsOfDirectory(atPath: carpeta)) ?? [] where f.hasSuffix(".jsonl") {
                archivos.append(carpeta + "/" + f)
            }
        }

        let lock = NSLock()
        var cacheNueva: [String: Any] = [:]
        var out: [Sesion] = []
        out.reserveCapacity(archivos.count)

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
            if let sesion { out.append(sesion) }
            lock.unlock()
        }

        if let d = try? JSONSerialization.data(withJSONObject: cacheNueva) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? d.write(to: URL(fileURLWithPath: cache), options: .atomic)
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

    static func clasifica(_ sesiones: [Sesion], conf: [String: Any]) -> [Carpeta] {
        let carpetas = conf["carpetas"] as? [[String: Any]] ?? []
        let nombres = carpetas.compactMap { $0["nombre"] as? String }
        let pruebas = conf["pruebas"] as? [String: Any]
        let nPruebas = pruebas?["nombre"] as? String
        let rPruebas = pruebas?["rutas"] as? [String] ?? []
        let otros = nombres.last ?? "Otros"
        let manual = conf["manual"] as? [String: String] ?? [:]
        let rutas = carpetas.map { $0["rutas"] as? [String] ?? [] }
        let regs: [[NSRegularExpression]] = carpetas.map {
            ($0["palabras"] as? [String] ?? []).compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        }
        let porProyecto = (conf["porProyecto"] as? Bool) == true
        let prioridad = carpetas.map { ($0["prioridad"] as? Bool) == true }
        let archivo = Set(conf["archivo"] as? [String] ?? [])
        let nArchivo = "Archivo"
        var grupos: [String: [Sesion]] = [:]
        for n in nombres { grupos[n] = [] }
        if let nPruebas { grupos[nPruebas] = [] }
        grupos[nArchivo] = []

        func cuenta(_ r: NSRegularExpression, _ t: String) -> Int {
            r.numberOfMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length))
        }

        var autos = Set<String>()
        for var s in sesiones {
            var destino: String? = archivo.contains(s.id) ? nArchivo : manual[s.id]
            if let d = destino, grupos[d] == nil { destino = nil }
            if destino == nil, let nPruebas, rPruebas.contains(where: { s.cwd.contains($0) }) { destino = nPruebas }
            if destino == nil {
                // carpetas con prioridad: basta una coincidencia en el título o el primer mensaje
                let t = (s.titulo + " " + s.prompt).lowercased()
                if let k = regs.indices.first(where: { prioridad[$0] && regs[$0].contains { cuenta($0, t) > 0 } }) { destino = nombres[k] }
            }
            if destino == nil, let k = rutas.firstIndex(where: { $0.contains(where: { s.cwd.contains($0) }) }) { destino = nombres[k] }
            if destino == nil {
                let titulo = s.titulo.lowercased()
                let resto = s.prompts.joined(separator: " ").lowercased()
                var mejor = otros, puntos = 0
                for (k, rs) in regs.enumerated() {
                    let p = rs.reduce(0) { $0 + 3 * cuenta($1, titulo) + cuenta($1, resto) }
                    if p > puntos { mejor = nombres[k]; puntos = p }
                }
                destino = mejor
            }
            if porProyecto && destino == otros && s.proyecto != "~" && grupos[s.proyecto] == nil || porProyecto && destino == otros && autos.contains(s.proyecto) {
                destino = s.proyecto
                autos.insert(s.proyecto)
            }
            s.carpeta = destino!
            grupos[destino!, default: []].append(s)
        }
        var lista = nombres.filter { $0 != otros }.map { Carpeta(nombre: $0, sesiones: grupos[$0] ?? [], fija: false) }
        // carpetas automáticas (una por proyecto), la más reciente primero
        lista += autos.map { Carpeta(nombre: $0, sesiones: grupos[$0] ?? [], fija: true, auto: true) }
            .sorted { ($0.sesiones.first?.mtime ?? .distantPast) > ($1.sesiones.first?.mtime ?? .distantPast) }
        if let g = grupos[otros], !g.isEmpty || !porProyecto { lista.append(Carpeta(nombre: otros, sesiones: g, fija: true)) }
        if let nPruebas, let g = grupos[nPruebas], !g.isEmpty {
            lista.append(Carpeta(nombre: nPruebas, sesiones: g, fija: true))
        }
        if let g = grupos[nArchivo], !g.isEmpty {
            lista.append(Carpeta(nombre: nArchivo, sesiones: g, fija: true))
        }
        return lista
    }

    static func todo() -> (carpetas: [Carpeta], total: Int, ids: Set<String>) {
        let sesiones = (cargaSesiones() + cargaCodex()).sorted { $0.mtime > $1.mtime }
        return (clasifica(sesiones, conf: cargaConf()), sesiones.count, Set(sesiones.map(\.id)))
    }

    // MARK: cambios en carpetas

    private static func existe(_ c: [String: Any], _ nombre: String) -> Bool {
        let carpetas = c["carpetas"] as? [[String: Any]] ?? []
        return carpetas.contains { ($0["nombre"] as? String) == nombre } || ((c["pruebas"] as? [String: Any])?["nombre"] as? String) == nombre
            || nombre == "Archivo"
    }

    /// Devuelve un mensaje de error, o nil si salió bien.
    static func crearCarpeta(_ nombre: String) -> String? {
        let nombre = limpia(nombre)
        var c = cargaConf()
        if nombre.isEmpty { return "Ponle un nombre" }
        if existe(c, nombre) { return "Ya existe una carpeta con ese nombre" }
        var carpetas = c["carpetas"] as? [[String: Any]] ?? []
        carpetas.insert(["nombre": nombre, "rutas": [String](), "palabras": [String]()], at: max(0, carpetas.count - 1))
        c["carpetas"] = carpetas
        guardaConf(c)
        return nil
    }

    static func renombrar(_ viejo: String, _ nuevo: String) -> String? {
        let nuevo = limpia(nuevo)
        var c = cargaConf()
        if nuevo.isEmpty { return "Ponle un nombre" }
        if nuevo == viejo { return nil }
        if existe(c, nuevo) { return "Ya existe una carpeta con ese nombre" }
        var carpetas = c["carpetas"] as? [[String: Any]] ?? []
        if let k = carpetas.firstIndex(where: { ($0["nombre"] as? String) == viejo }) {
            carpetas[k]["nombre"] = nuevo
            c["carpetas"] = carpetas
        } else if var p = c["pruebas"] as? [String: Any], (p["nombre"] as? String) == viejo {
            p["nombre"] = nuevo
            c["pruebas"] = p
        } else { return "No encontré esa carpeta" }
        var manual = c["manual"] as? [String: String] ?? [:]
        for (k, v) in manual where v == viejo { manual[k] = nuevo }
        c["manual"] = manual
        guardaConf(c)
        return nil
    }

    static func borrar(_ nombre: String) -> String? {
        var c = cargaConf()
        var carpetas = c["carpetas"] as? [[String: Any]] ?? []
        guard let k = carpetas.firstIndex(where: { ($0["nombre"] as? String) == nombre }), k < carpetas.count - 1 else {
            return "Esa carpeta no se puede borrar"
        }
        carpetas.remove(at: k)
        c["carpetas"] = carpetas
        var manual = c["manual"] as? [String: String] ?? [:]
        for (id, v) in manual where v == nombre { manual[id] = nil }
        c["manual"] = manual
        guardaConf(c)
        return nil
    }

    static func mover(_ ids: [String], a carpeta: String) -> String? {
        var c = cargaConf()
        guard existe(c, carpeta) else { return "No encontré esa carpeta" }
        var manual = c["manual"] as? [String: String] ?? [:]
        for id in ids { manual[id] = carpeta }
        c["manual"] = manual
        if var a = c["archivo"] as? [String] { a.removeAll { ids.contains($0) }; c["archivo"] = a }
        guardaConf(c)
        return nil
    }

    static func archivar(_ ids: [String], _ si: Bool) {
        var c = cargaConf()
        var a = c["archivo"] as? [String] ?? []
        if si { a.append(contentsOf: ids.filter { !a.contains($0) }) } else { a.removeAll { ids.contains($0) } }
        c["archivo"] = a
        if !si {
            var manual = c["manual"] as? [String: String] ?? [:]
            for id in ids where manual[id] == "Archivo" { manual[id] = nil }
            c["manual"] = manual
        }
        guardaConf(c)
    }

    /// Carpeta de trabajo (en disco) donde arrancan las sesiones nuevas de una carpeta.
    /// Carpeta del disco donde se crean las carpetas de trabajo nuevas.
    static func carpetaBase() -> String {
        let b = (cargaConf()["base"] as? String) ?? "~/Proyectos"
        return (b as NSString).expandingTildeInPath
    }

    static func dirGuardado(_ nombre: String) -> String? {
        let carpetas = cargaConf()["carpetas"] as? [[String: Any]] ?? []
        return (carpetas.first { ($0["nombre"] as? String) == nombre }?["dir"] as? String).map { ($0 as NSString).expandingTildeInPath }
    }

    /// Guarda la carpeta de trabajo y la añade a sus rutas: todo lo que se abra ahí cae solo en esta carpeta.
    static func ponDir(_ nombre: String, _ dir: String) {
        var c = cargaConf()
        var carpetas = c["carpetas"] as? [[String: Any]] ?? []
        guard let k = carpetas.firstIndex(where: { ($0["nombre"] as? String) == nombre }) else { return }
        if let viejo = carpetas[k]["dir"] as? String, var r = carpetas[k]["rutas"] as? [String] {
            r.removeAll { $0 == viejo }
            carpetas[k]["rutas"] = r
        }
        carpetas[k]["dir"] = dir
        var rutas = carpetas[k]["rutas"] as? [String] ?? []
        if !rutas.contains(dir) { rutas.append(dir) }
        carpetas[k]["rutas"] = rutas
        c["carpetas"] = carpetas
        guardaConf(c)
    }

    /// Nombre de carpeta seguro para el disco ("GTA 6 / clips" → "GTA 6 - clips").
    static func nombreEnDisco(_ nombre: String) -> String {
        let n = limpia(nombre.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-"))
        return n.isEmpty || n.hasPrefix(".") ? "carpeta" : n
    }

    static func mueveCarpeta(_ nombre: String, antesDe destino: String) {
        var c = cargaConf()
        var carpetas = c["carpetas"] as? [[String: Any]] ?? []
        guard carpetas.count > 1,
              let k = carpetas.firstIndex(where: { ($0["nombre"] as? String) == nombre }), k < carpetas.count - 1 else { return }
        let item = carpetas.remove(at: k)
        var j = carpetas.firstIndex(where: { ($0["nombre"] as? String) == destino }) ?? (carpetas.count - 1)
        j = min(j, carpetas.count - 1)
        carpetas.insert(item, at: j)
        c["carpetas"] = carpetas
        guardaConf(c)
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
