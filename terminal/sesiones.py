#!/usr/bin/env python3
"""Sesiones: tus sesiones de Claude Code como carpetas (pantalla de inicio de Warp).

  sesiones            abre las carpetas
  sesiones --lista    imprime cada carpeta con sus sesiones (sin pantalla)

Las carpetas y sus reglas viven en ~/.sesiones/carpetas.json (las comparte con la app Sesiones).
"""
import glob
import json
import os
import re
import select
import signal
import subprocess
import sys
import termios
import time
import tty
import unicodedata

HOME = os.path.expanduser("~")
BASE = os.path.join(HOME, ".claude", "projects")
DIR = os.path.join(HOME, ".sesiones")  # la misma configuración que usa la app
CONF = os.path.join(DIR, "carpetas.json")
CACHE = os.path.join(DIR, ".cache.json")

# ---------------------------------------------------------------- colores
PAGE = (34, 34, 34)
INK = (236, 236, 238)
MUTED = (142, 142, 147)
SOFT = (99, 99, 102)
SEL_BG = (58, 58, 60)
ROW_BG = (46, 46, 48)
BLUE = (10, 100, 214)
ACCENT = (10, 132, 255)
BACK = (56, 56, 59)
PAPER = (240, 240, 242)
FRONT_TOP = (108, 108, 113)
FRONT_BOT = (74, 74, 78)


def fg(c):
    return "\x1b[38;2;%d;%d;%dm" % c


def bg(c):
    return "\x1b[48;2;%d;%d;%dm" % c


BOLD, NOBOLD, RESET = "\x1b[1m", "\x1b[22m", "\x1b[0m"


# ---------------------------------------------------------------- texto
def cw(ch):
    if unicodedata.combining(ch):
        return 0
    if ord(ch) in (0xFE0F, 0x200D):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def width(s):
    return sum(cw(c) for c in s)


def fit(s, n):
    """Corta s a n columnas (con …) y rellena con espacios."""
    if n <= 0:
        return ""
    out, w = [], 0
    if width(s) > n:
        for c in s:
            if w + cw(c) > n - 1:
                break
            out.append(c)
            w += cw(c)
        return "".join(out) + "…" + " " * (n - 1 - w)
    return s + " " * (n - width(s))


def hace(ts):
    d = time.time() - ts
    if d < 60:
        return "ahora"
    if d < 3600:
        return "hace %d min" % (d // 60)
    if d < 86400:
        return "hace %d h" % (d // 3600)
    dias = int(d // 86400)
    if dias == 1:
        return "ayer"
    if dias < 7:
        return "hace %d días" % dias
    meses = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"]
    t = time.localtime(ts)
    return "%d %s" % (t.tm_mday, meses[t.tm_mon - 1])


def limpia(s):
    return re.sub(r"\s+", " ", s or "").strip()


# ---------------------------------------------------------------- sesiones
def texto_usuario(d):
    if d.get("isSidechain") or d.get("isMeta"):
        return None
    c = (d.get("message") or {}).get("content")
    if isinstance(c, list):
        partes = [b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text"]
        if not partes or any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
            return None
        c = " ".join(partes)
    if not isinstance(c, str):
        return None
    c = re.sub(r"<pasted_content[^>]*>.*?</pasted_content[^>]*>", " ", c, flags=re.S)
    c = limpia(c)
    if not c or c.startswith("<") or c.startswith("[Request interrupted"):
        return None
    return c


def lee_sesion(path):
    cwd, ai, custom, prompts, sdk = None, None, None, [], False
    with open(path, "rb") as f:
        for raw in f:
            if b'"ai-title"' in raw or b'"custom-title"' in raw:
                try:
                    d = json.loads(raw)
                except ValueError:
                    continue
                if d.get("type") == "ai-title":
                    ai = d.get("aiTitle") or ai
                elif d.get("type") == "custom-title":
                    custom = d.get("customTitle") or custom
                continue
            if len(prompts) < 3 and b'"type":"user"' in raw:
                try:
                    d = json.loads(raw)
                except ValueError:
                    continue
                if d.get("type") != "user":
                    continue
                cwd = cwd or d.get("cwd")
                sdk = sdk or str(d.get("entrypoint", "")).startswith("sdk")
                t = texto_usuario(d)
                if t:
                    prompts.append(t[:400])
            elif cwd is None and b'"cwd"' in raw and len(raw) < 20000:
                try:
                    cwd = json.loads(raw).get("cwd")
                except ValueError:
                    pass
    return {"cwd": cwd, "ai": ai, "custom": custom, "prompts": prompts, "sdk": sdk}


def carga_sesiones():
    try:
        cache = json.load(open(CACHE))
    except Exception:
        cache = {}
    nuevo, out = {}, []
    for path in glob.glob(os.path.join(BASE, "*", "*.jsonl")):
        try:
            st = os.stat(path)
        except OSError:
            continue
        key = "%d:%d" % (st.st_mtime, st.st_size)
        hit = cache.get(path)
        if hit and hit[0] == key:
            info = hit[1]
        else:
            try:
                info = lee_sesion(path)
            except OSError:
                continue
        nuevo[path] = [key, info]
        if not info["prompts"]:
            continue  # sesión vacía, nada que retomar
        s = dict(info)
        s["id"] = os.path.basename(path)[:-6]
        s["mtime"] = st.st_mtime
        s["cwd"] = s["cwd"] or HOME
        s["titulo"] = limpia(s["custom"] or s["ai"] or s["prompts"][0])
        out.append(s)
    try:
        tmp = CACHE + ".tmp"
        json.dump(nuevo, open(tmp, "w"))
        os.replace(tmp, CACHE)
    except OSError:
        pass
    out.sort(key=lambda s: -s["mtime"])
    return out


# ---------------------------------------------------------------- carpetas
CONF_INICIAL = {
    "base": "~/Proyectos",
    "porProyecto": True,
    "carpetas": [{"nombre": "Otros", "rutas": [], "palabras": []}],
    "pruebas": {"nombre": "Pruebas", "rutas": ["/private/tmp", "/tmp/", "Application Support/Claude/scratch"]},
    "manual": {},
}


def carga_conf():
    try:
        return json.load(open(CONF))
    except (OSError, ValueError):
        os.makedirs(DIR, exist_ok=True)
        guarda_conf(CONF_INICIAL)
        return json.loads(json.dumps(CONF_INICIAL))


def guarda_conf(conf):
    tmp = CONF + ".tmp"
    with open(tmp, "w") as f:
        json.dump(conf, f, ensure_ascii=False, indent=2)
    os.replace(tmp, CONF)


def clasifica(sesiones, conf):
    carpetas = conf["carpetas"]
    nombres = [c["nombre"] for c in carpetas]
    pruebas = conf.get("pruebas") or {}
    otros = nombres[-1]
    regs = [[re.compile(p, re.I) for p in c.get("palabras", [])] for c in carpetas]
    manual = conf.get("manual", {})
    archivo = set(conf.get("archivo", []))
    prioridad = [bool(c.get("prioridad")) for c in carpetas]
    grupos = {n: [] for n in nombres}
    if pruebas:
        grupos[pruebas["nombre"]] = []
    grupos["Archivo"] = []
    autos = []
    for s in sesiones:
        destino = "Archivo" if s["id"] in archivo else manual.get(s["id"])
        if destino not in grupos:
            destino = None
        if not destino and pruebas and any(r in s["cwd"] for r in pruebas.get("rutas", [])):
            destino = pruebas["nombre"]
        if not destino:
            t = (s["titulo"] + " " + s["prompts"][0]).lower()
            for c, rs, pr in zip(carpetas, regs, prioridad):
                if pr and any(r.search(t) for r in rs):
                    destino = c["nombre"]
                    break
        if not destino:
            for c in carpetas:
                if any(r in s["cwd"] for r in c.get("rutas", [])):
                    destino = c["nombre"]
                    break
        if not destino:
            titulo = s["titulo"].lower()
            resto = " ".join(s["prompts"]).lower()
            mejor, puntos = otros, 0
            for c, rs in zip(carpetas, regs):
                p = sum(3 * len(r.findall(titulo)) + len(r.findall(resto)) for r in rs)
                if p > puntos:
                    mejor, puntos = c["nombre"], p
            destino = mejor
        if conf.get("porProyecto") and destino == otros:
            proyecto = os.path.basename(s["cwd"].rstrip("/"))
            if s["cwd"] != HOME and proyecto not in nombres:
                destino = proyecto
                grupos.setdefault(proyecto, [])
                autos.append(proyecto) if proyecto not in autos else None
        s["carpeta"] = destino
        grupos[destino].append(s)
    orden = [n for n in nombres if n != otros] + autos + [otros] + ([pruebas["nombre"]] if pruebas else []) + ["Archivo"]
    return [(n, grupos[n]) for n in orden if grupos[n]]


# ---------------------------------------------------------------- icono
IW, IH = 20, 14  # píxeles (cada celda = 1 ancho x 2 alto)


def px_carpeta(x, y):
    if y == 0:
        return BACK if 1 <= x <= 8 else None
    if y == 1:
        return BACK
    if y == 2:
        return PAPER if 2 <= x <= IW - 3 else BACK
    if y == IH - 1 and x in (0, IW - 1):
        return None
    t = (y - 3) / float(IH - 4)
    c = tuple(int(a + (b - a) * t) for a, b in zip(FRONT_TOP, FRONT_BOT))
    if y == 3:
        c = tuple(min(255, v + 10) for v in c)
    return c


def icono(fondo):
    filas = []
    for r in range(IH // 2):
        linea = []
        for x in range(IW):
            a = px_carpeta(x, 2 * r) or fondo
            b = px_carpeta(x, 2 * r + 1) or fondo
            linea.append(fg(a) + bg(b) + "▀")
        filas.append("".join(linea))
    return filas


# ---------------------------------------------------------------- pantalla
class App:
    TW, TH = 28, 13  # tamaño de cada carpeta en la cuadrícula

    def __init__(self):
        self.conf = carga_conf()
        self.sesiones = []
        self.grupos = []
        self.vista = "inicio"  # inicio | carpeta | buscar | mover
        self.sel_c = 0
        self.sel_s = 0
        self.scroll = 0
        self.query = ""
        self.antes = "inicio"
        self.aviso = ""
        self.zonas = []
        self.redim = True
        self.ultimo_click = (None, 0)
        self.recarga()

    def recarga(self):
        self.sesiones = carga_sesiones()
        self.grupos = clasifica(self.sesiones, self.conf)
        self.sel_c = min(self.sel_c, max(0, len(self.grupos) - 1))

    # -- datos de la vista actual
    def lista(self):
        if self.vista == "buscar" or (self.vista == "mover" and self.antes == "buscar"):
            q = self.query.lower().split()
            res = []
            for s in self.sesiones:
                hay = (s["titulo"] + " " + " ".join(s["prompts"]) + " " + s["cwd"]).lower()
                if all(w in hay for w in q):
                    res.append(s)
            return res
        if not self.grupos:
            return []
        return self.grupos[self.sel_c][1]

    # -- dibujo
    def pinta(self):
        cols, rows = os.get_terminal_size()
        self.cols, self.rows = cols, rows
        self.zonas = []
        L = [bg(PAGE) + " " * cols for _ in range(rows)]

        def put(y, x, s, plain_w=None):
            if 0 <= y < rows:
                w = plain_w if plain_w is not None else width(re.sub(r"\x1b\[[0-9;]*m", "", s))
                pad = max(0, cols - x - w)
                L[y] = bg(PAGE) + " " * x + s + RESET + bg(PAGE) + " " * pad

        if self.vista == "inicio":
            self.pinta_inicio(put, cols, rows)
        else:
            self.pinta_lista(put, cols, rows)
        sys.stdout.write("\x1b[H" + "\r\n".join(L) + RESET)
        sys.stdout.flush()

    def pie(self, put, rows, texto):
        put(rows - 1, 3, fg(SOFT) + bg(PAGE) + texto)

    def pinta_inicio(self, put, cols, rows):
        total = len(self.sesiones)
        put(1, 4, fg(MUTED) + bg(PAGE) + "Claude Code · %d sesiones" % total)
        n = max(1, min(len(self.grupos), (cols - 4) // self.TW))
        x0 = max(2, (cols - n * self.TW) // 2)
        self.por_fila = n
        filas_vis = max(1, (rows - 5) // self.TH)
        fila_sel = self.sel_c // n
        primera = max(0, fila_sel - filas_vis + 1)
        lineas = {}
        for i, (nombre, ses) in enumerate(self.grupos):
            f, c = divmod(i, n)
            if f < primera or f >= primera + filas_vis:
                continue
            top = 3 + (f - primera) * self.TH
            left = x0 + c * self.TW
            sel = i == self.sel_c
            fondo = SEL_BG if sel else PAGE
            ix = left + (self.TW - IW) // 2
            if sel:
                lineas.setdefault(top, []).append((ix - 1, fg(SEL_BG) + bg(PAGE) + "▄" * (IW + 2)))
            for r, linea in enumerate(icono(fondo)):
                pre = bg(SEL_BG) + " " if sel else bg(PAGE) + " "
                lineas.setdefault(top + 1 + r, []).append((ix - 1, pre + linea + pre))
            if sel:
                lineas.setdefault(top + 1 + IH // 2, []).append((ix - 1, fg(SEL_BG) + bg(PAGE) + "▀" * (IW + 2)))
            etq = fit(nombre, self.TW - 4).rstrip()
            ew = width(etq) + 2
            ex = left + (self.TW - ew) // 2
            estilo = (bg(BLUE) + fg((255, 255, 255))) if sel else (bg(PAGE) + fg(INK))
            lineas.setdefault(top + IH // 2 + 3, []).append((ex, estilo + " " + etq + " "))
            sub = "%d ítem%s" % (len(ses), "" if len(ses) == 1 else "s")
            lineas.setdefault(top + IH // 2 + 4, []).append((left + (self.TW - width(sub)) // 2, bg(PAGE) + fg(MUTED) + sub))
            self.zonas.append((top, top + IH // 2 + 5, left, left + self.TW, ("carpeta", i)))
        for y, partes in lineas.items():
            partes.sort()
            s, x = "", 0
            for px, txt in partes:
                plain = re.sub(r"\x1b\[[0-9;]*m", "", txt)
                s += bg(PAGE) + " " * max(0, px - x) + txt
                x = max(x, px) + width(plain)
            put(y, 0, s, x)
        if self.aviso:
            put(rows - 2, 3, fg(MUTED) + bg(PAGE) + self.aviso)
        self.pie(put, rows, "←↑↓→ moverte · ⏎ abrir · / buscar · r recargar · q salir a la terminal")

    def pinta_lista(self, put, cols, rows):
        items = self.lista()
        mover = self.vista == "mover"
        if self.vista == "buscar" or self.antes == "buscar" and mover:
            cab = fg(MUTED) + bg(PAGE) + "‹  " + fg(INK) + BOLD + "Buscar  " + NOBOLD + fg(ACCENT) + self.query + fg(INK) + "▏" + fg(MUTED) + "   %d resultados" % len(items)
        else:
            nombre = self.grupos[self.sel_c][0] if self.grupos else ""
            cab = fg(MUTED) + bg(PAGE) + "‹  " + fg(INK) + BOLD + nombre + NOBOLD + fg(MUTED) + "   %d sesiones · la más reciente arriba" % len(items)
        put(1, 3, cab)
        self.zonas.append((1, 2, 0, 6, ("atras",)))
        alto = 3
        cap = max(1, (rows - 5) // alto)
        self.sel_s = max(0, min(self.sel_s, len(items) - 1))
        if self.sel_s < self.scroll:
            self.scroll = self.sel_s
        if self.sel_s >= self.scroll + cap:
            self.scroll = self.sel_s - cap + 1
        ancho = cols - 8
        for k, s in enumerate(items[self.scroll:self.scroll + cap]):
            i = self.scroll + k
            y = 3 + k * alto
            sel = i == self.sel_s
            fondo = ROW_BG if sel else PAGE
            barra = (fg(ACCENT) + bg(fondo) + "▌") if sel else (bg(fondo) + " ")
            cuando = hace(s["mtime"])
            tw = ancho - width(cuando) - 4
            put(y, 3, barra + bg(fondo) + fg(INK) + BOLD + " " + fit(s["titulo"], tw) + NOBOLD + "  " + fg(MUTED) + cuando + " ", ancho + 1)
            proyecto = "~" if s["cwd"] == HOME else os.path.basename(s["cwd"].rstrip("/"))
            if self.vista == "buscar" or self.antes == "buscar":
                proyecto = s.get("carpeta", "") + " · " + proyecto
            if s.get("sdk"):
                proyecto += " · automática (SDK)"
            meta = proyecto + "  ·  " + s["prompts"][0]
            put(y + 1, 3, barra + bg(fondo) + fg(MUTED) + " " + fit(meta, ancho - 1), ancho + 1)
            self.zonas.append((y, y + 2, 3, 3 + ancho + 1, ("sesion", i)))
        if not items:
            put(4, 6, fg(MUTED) + bg(PAGE) + ("Nada con esas palabras." if self.query else "Sin sesiones."))
        if mover:
            self.pinta_mover(put, cols, rows)
            self.pie(put, rows, "1–9 elegir carpeta · esc cancelar")
        elif self.vista == "buscar":
            self.pie(put, rows, "escribe para filtrar · ↑↓ elegir · ⏎ retomar · esc volver")
        else:
            self.pie(put, rows, "↑↓ elegir · ⏎ retomar · m mover a otra carpeta · / buscar · esc volver")
        if self.aviso:
            put(rows - 2, 3, fg(MUTED) + bg(PAGE) + self.aviso)

    def pinta_mover(self, put, cols, rows):
        nombres = [c["nombre"] for c in self.conf["carpetas"]]
        w = max(width(n) for n in nombres) + 10
        x = max(2, (cols - w) // 2)
        y0 = max(2, (rows - len(nombres) - 4) // 2)
        caja = bg(SEL_BG) + fg(INK)
        put(y0, x, caja + fit("  Mover a…", w))
        for k, n in enumerate(nombres):
            put(y0 + 1 + k, x, caja + fit("  %d  %s" % (k + 1, n), w))
            self.zonas.append((y0 + 1 + k, y0 + 2 + k, x, x + w, ("mover", k)))
        put(y0 + 1 + len(nombres), x, caja + " " * w)

    # -- acciones
    def abre_carpeta(self, i):
        self.sel_c = i
        self.vista, self.sel_s, self.scroll, self.aviso = "carpeta", 0, 0, ""

    def retoma(self, s):
        if not os.path.isdir(s["cwd"]):
            self.aviso = "Esa carpeta ya no existe: " + s["cwd"]
            return
        sale_pantalla()
        print("\n  → Retomando: %s\n    %s\n" % (s["titulo"], s["cwd"]))
        try:
            subprocess.call(["claude", "--resume", s["id"]], cwd=s["cwd"])
        except FileNotFoundError:
            self.aviso = "No encontré el comando claude"
        except KeyboardInterrupt:
            pass
        entra_pantalla()
        self.recarga()
        self.sel_s, self.scroll = 0, 0

    def mueve(self, k):
        nombres = [c["nombre"] for c in self.conf["carpetas"]]
        items = self.lista()
        if not items or k >= len(nombres):
            self.vista = self.antes
            return
        s = items[self.sel_s]
        self.conf.setdefault("manual", {})[s["id"]] = nombres[k]
        guarda_conf(self.conf)
        self.aviso = "Movida a %s: %s" % (nombres[k], s["titulo"])
        self.vista = self.antes
        self.recarga()

    def tecla(self, k):
        if k is None:
            return True
        if k == "ctrl-c":
            return False
        v = self.vista
        if v == "mover":
            if k in ("esc", "q", "left"):
                self.vista = self.antes
            elif len(k) == 1 and k.isdigit() and k != "0":
                self.mueve(int(k) - 1)
            elif k[0] == "click" and k[1][0] == "mover":
                self.mueve(k[1][1])
            return True
        if isinstance(k, tuple):
            return self.click(k)
        if v == "inicio":
            n = getattr(self, "por_fila", 4)
            g = len(self.grupos)
            if k in ("q", "esc"):
                return False
            if k in ("right", "l"):
                self.sel_c = min(g - 1, self.sel_c + 1)
            elif k in ("left", "h"):
                self.sel_c = max(0, self.sel_c - 1)
            elif k in ("down", "j"):
                self.sel_c = min(g - 1, self.sel_c + n)
            elif k in ("up", "k"):
                self.sel_c = max(0, self.sel_c - n)
            elif k in ("enter", " ") and g:
                self.abre_carpeta(self.sel_c)
            elif k == "/":
                self.antes, self.vista, self.query, self.sel_s, self.scroll = "inicio", "buscar", "", 0, 0
            elif k == "r":
                self.recarga()
            elif len(k) == 1 and k.isdigit() and 0 < int(k) <= g:
                self.abre_carpeta(int(k) - 1)
            self.aviso = "" if k != "r" else "Recargado"
            return True
        # carpeta o buscar
        items = self.lista()
        if k == "down" or (v == "carpeta" and k == "j"):
            self.sel_s = min(len(items) - 1, self.sel_s + 1)
        elif k == "up" or (v == "carpeta" and k == "k"):
            self.sel_s = max(0, self.sel_s - 1)
        elif k == "pagedown":
            self.sel_s = min(len(items) - 1, self.sel_s + 10)
        elif k == "pageup":
            self.sel_s = max(0, self.sel_s - 10)
        elif k == "enter" and items:
            self.retoma(items[self.sel_s])
        elif k == "esc" or (k == "left" and v == "carpeta") or (v == "carpeta" and k in ("q", "backspace")):
            self.vista, self.query, self.aviso = "inicio", "", ""
        elif v == "carpeta" and k == "/":
            self.antes, self.vista, self.query, self.sel_s, self.scroll = "carpeta", "buscar", "", 0, 0
        elif v == "carpeta" and k == "m":
            if items:
                self.antes, self.vista = v, "mover"
        elif v == "buscar" and k == "backspace":
            self.query = self.query[:-1]
            self.sel_s = self.scroll = 0
        elif v == "buscar" and len(k) == 1 and k.isprintable():
            self.query += k
            self.sel_s = self.scroll = 0
        return True

    def click(self, ev):
        tipo, x, y = ev
        if tipo == "wheel_up":
            return self.tecla("up" if self.vista != "inicio" else "up")
        if tipo == "wheel_down":
            return self.tecla("down")
        for y0, y1, x0, x1, accion in self.zonas:
            if y0 <= y < y1 and x0 <= x < x1:
                ahora = time.time()
                doble = self.ultimo_click[0] == accion and ahora - self.ultimo_click[1] < 0.45
                self.ultimo_click = (accion, ahora)
                if accion[0] == "atras":
                    return self.tecla("esc")
                if accion[0] == "carpeta":
                    if self.sel_c == accion[1] or doble:
                        self.abre_carpeta(accion[1])
                    else:
                        self.sel_c = accion[1]
                elif accion[0] == "sesion":
                    if self.sel_s == accion[1] or doble:
                        self.sel_s = accion[1]
                        self.retoma(self.lista()[accion[1]])
                    else:
                        self.sel_s = accion[1]
                return True
        return True


# ---------------------------------------------------------------- terminal
_viejo = None


def entra_pantalla():
    global _viejo
    fd = sys.stdin.fileno()
    _viejo = termios.tcgetattr(fd)
    tty.setraw(fd)
    sys.stdout.write("\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1006h")
    sys.stdout.flush()


def sale_pantalla():
    sys.stdout.write("\x1b[?1000l\x1b[?1006l\x1b[?25h" + RESET + "\x1b[2J\x1b[H\x1b[?1049l")
    sys.stdout.flush()
    if _viejo:
        termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, _viejo)


TECLAS = {"[A": "up", "[B": "down", "[C": "right", "[D": "left", "OA": "up", "OB": "down",
          "OC": "right", "OD": "left", "[5~": "pageup", "[6~": "pagedown", "[H": "home", "[F": "end"}


def lee_teclas(fd):
    data = os.read(fd, 4096)
    while select.select([fd], [], [], 0.01)[0]:
        mas = os.read(fd, 4096)
        if not mas:
            break
        data += mas
    s = data.decode("utf-8", "ignore")
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\x1b":
            m = re.match(r"\x1b\[<(\d+);(\d+);(\d+)([Mm])", s[i:])
            if m:
                b, x, y, kind = int(m.group(1)), int(m.group(2)) - 1, int(m.group(3)) - 1, m.group(4)
                if kind == "M" and b == 0:
                    out.append(("click", x, y))
                elif b == 64:
                    out.append(("wheel_up", x, y))
                elif b == 65:
                    out.append(("wheel_down", x, y))
                i += len(m.group(0))
                continue
            m = re.match(r"\x1b(\[[0-9;]*[A-Za-z~]|O[A-Z])", s[i:])
            if m:
                out.append(TECLAS.get(m.group(1), None))
                i += len(m.group(0))
                continue
            out.append("esc")
            i += 1
            continue
        if c in "\r\n":
            out.append("enter")
        elif c in "\x7f\x08":
            out.append("backspace")
        elif c == "\x03":
            out.append("ctrl-c")
        elif c == "\x04":
            out.append("ctrl-c")
        elif c == "\t":
            out.append("down")
        elif c >= " ":
            out.append(c)
        i += 1
    return out


def main():
    if "--lista" in sys.argv:
        conf = carga_conf()
        for nombre, ses in clasifica(carga_sesiones(), conf):
            print("\n%s (%d)" % (nombre, len(ses)))
            for s in ses:
                print("   %-12s %-28s %s" % (hace(s["mtime"]), os.path.basename(s["cwd"])[:28], s["titulo"][:80]))
        return
    if not sys.stdin.isatty():
        print("sesiones necesita una terminal")
        return
    app = App()

    def al_redim(*_):
        app.redim = True

    signal.signal(signal.SIGWINCH, al_redim)
    entra_pantalla()
    try:
        fd = sys.stdin.fileno()
        seguir = True
        while seguir:
            if app.redim:
                sys.stdout.write("\x1b[2J")
                app.redim = False
            app.pinta()
            try:
                listo = select.select([fd], [], [], 30)[0]
            except InterruptedError:
                continue
            if not listo:
                continue
            for k in lee_teclas(fd):
                if isinstance(k, tuple) and k[0] in ("click", "wheel_up", "wheel_down"):
                    if app.vista == "mover" and k[0] == "click":
                        hit = [z[4] for z in app.zonas if z[0] <= k[2] < z[1] and z[2] <= k[1] < z[3] and z[4][0] == "mover"]
                        seguir = app.tecla(("click", hit[0])) if hit else app.tecla("esc")
                    else:
                        seguir = app.click(k)
                else:
                    seguir = app.tecla(k)
                if not seguir:
                    break
    finally:
        sale_pantalla()


if __name__ == "__main__":
    main()
