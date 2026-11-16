# Sesiones

Una app nativa para Mac que ordena tus sesiones de **Claude Code** y **Codex** en carpetas, como el Finder, y las abre en terminales dentro de la misma app. Liviana: Swift + SwiftUI + [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), pesa ~4 MB y usa ~100 MB de RAM.

*A native macOS app that organizes your Claude Code and Codex sessions into Finder-like folders and resumes them in built-in terminals. Spanish UI.*

## Qué hace

- **Carpetas**: tus sesiones se reparten solas (por defecto, una carpeta por proyecto). Puedes crear carpetas, renombrarlas, arrastrar sesiones entre ellas y archivar las viejas.
- **La más reciente arriba**: dentro de cada carpeta, ordenadas por la última vez que les hablaste. Arriba de todo, tus 6 sesiones recientes.
- **Terminales dentro**: doble clic retoma la sesión (`claude --resume` / `codex resume`) en su carpeta. Pestañas a la izquierda, pantalla dividida (⌘D), búsqueda en la terminal (⌘F), arrastrar archivos pega su ruta.
- **Te avisa**: cada pestaña muestra si el agente está trabajando, si terminó o si te pide permiso, con notificación de macOS e insignia en el Dock.
- **Dictado**: mantén **fn** (o toca *Hablar*), habla y suelta: el texto se escribe en la terminal. Usa el reconocimiento de voz de Apple, en tu Mac.
- **Recuerda tus pestañas** al cerrar y abrir (vuelven dormidas: arrancan cuando las abres).
- **⌥Espacio** trae o esconde la app desde cualquier lado.

## Instalar

Requisitos: macOS 14 o más nuevo y las Command Line Tools de Xcode (`xcode-select --install`). Para retomar sesiones necesitas `claude` y/o `codex` instalados.

```bash
git clone https://github.com/rayyandev-ux/sesiones.git
cd sesiones
./empaquetar.sh        # compila, arma Sesiones.app y la copia a /Applications
```

La app queda firmada localmente (ad-hoc). Si tienes un certificado de desarrollador, pon su hash en un archivo `.firma` (o en `SESIONES_FIRMA`) para que macOS recuerde el permiso del micrófono entre versiones:

```bash
security find-identity -v -p codesigning   # copia el hash de tu certificado
echo TU_HASH > .firma
```

## Carpetas y reglas

Todo vive en `~/.sesiones/carpetas.json` (se crea al abrir la app por primera vez):

```json
{
  "base": "~/Proyectos",
  "porProyecto": true,
  "carpetas": [
    { "nombre": "Clientes", "rutas": ["/clientes/"], "palabras": ["cotizaci[oó]n", "\\bcrm\\b"], "dir": "~/Proyectos/clientes" },
    { "nombre": "Otros", "rutas": [], "palabras": [] }
  ]
}
```

- `rutas`: si la carpeta de trabajo de la sesión contiene ese texto, va directo a esa carpeta.
- `palabras`: expresiones regulares que se buscan en el título y tus primeros mensajes; gana la carpeta con más coincidencias. Con `"prioridad": true` basta una.
- `dir`: dónde arrancan las sesiones nuevas de esa carpeta (si no hay, se usa `base/<nombre>`).
- `porProyecto`: lo que no cae en ninguna carpeta se agrupa por proyecto. Con `false` va a la última carpeta (*Otros*).
- `manual` y `archivo` los llena la app cuando mueves o archivas.

## Desde la terminal

`terminal/sesiones.py` es la misma idea en modo texto (sin dependencias, Python 3), útil como pantalla de inicio de Warp u otra terminal:

```bash
ln -s "$PWD/terminal/sesiones.py" ~/.local/bin/sesiones
sesiones           # carpetas en la terminal
sesiones --lista   # imprime carpetas y sesiones
```

## Privacidad

Sesiones solo **lee** tus archivos locales (`~/.claude/projects` y la base de Codex en `~/.codex`, en modo solo lectura) y guarda su configuración en `~/.sesiones`. No envía nada a internet. El dictado usa el reconocimiento de voz de Apple; cuando tu idioma lo permite, se hace en el propio Mac.

## Licencia

MIT. Las fuentes Manrope y DM Sans van con su licencia OFL 1.1.
