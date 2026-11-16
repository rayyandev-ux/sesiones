# Temperas Cremosas

(antes *Sesiones*; el repo y el programa conservan ese nombre)

Una app nativa para Mac que ordena tus sesiones de **Claude Code** y **Codex** en carpetas, como el Finder, y las abre en terminales dentro de la misma app. Liviana: Swift + SwiftUI + [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), pesa ~4 MB y usa ~100 MB de RAM.

*A native macOS app that organizes your Claude Code and Codex sessions into Finder-like folders and resumes them in built-in terminals. Spanish UI.*

## Qué hace

- **Carpetas como en tu Finder**: el árbol copia tu carpeta de proyectos (categorías, proyectos y sus partes), con carpetas que se despliegan. Cada sesión aparece en la carpeta del disco donde vive hoy, aunque hayas movido el proyecto. Puedes archivar las viejas.
- **La más reciente arriba**: dentro de cada carpeta, ordenadas por la última vez que les hablaste. Arriba de todo, tus 6 sesiones recientes.
- **Terminales dentro**: doble clic retoma la sesión (`claude --resume` / `codex resume`) en su carpeta. Pestañas a la izquierda, pantalla dividida (⌘D), búsqueda en la terminal (⌘F), arrastrar archivos pega su ruta, y ⌘V con archivos copiados en el Finder también.
- **Pestañas con nombre y en grupos**: doble clic en una pestaña (o clic derecho › Renombrar) para ponerle nombre; si es una sesión, el nombre se ve también en sus carpetas. Arma grupos de pestañas que se pliegan, arrastrando pestañas o sesiones encima. Cada pestaña muestra su rama de git.
- **Uso de Claude**: arriba a la derecha, la ventana de 5 h y la semana; al pasar el mouse, el detalle. Lo lee de `~/.claude/uso-claude/estado.json`, que escribe el status line de [WarpConsumo](https://github.com/Perezhppr/WarpConsumo).
- **Temas**: *Noche pixel* (el original) o *Consola* (morado, cartuchos y letras pixel, crema de día y morado de noche según la hora). Se elige con el ícono de paleta arriba de la barra lateral o en el menú Tema.
- **Te avisa**: cada pestaña muestra si el agente está trabajando, si terminó o si te pide permiso, con notificación de macOS e insignia en el Dock.
- **Dictado**: mantén **fn** (o toca *Hablar*), habla y suelta: el texto se escribe en la terminal. Usa el reconocimiento de voz de Apple, en tu Mac.
- **Recuerda tus pestañas** al cerrar y abrir (vuelven dormidas: arrancan cuando las abres).
- **⌥Espacio** trae o esconde la app desde cualquier lado.

## Instalar

Requisitos: macOS 14 o más nuevo y las Command Line Tools de Xcode (`xcode-select --install`). Para retomar sesiones necesitas `claude` y/o `codex` instalados.

```bash
git clone https://github.com/rayyandev-ux/sesiones.git
cd sesiones
./empaquetar.sh        # compila, arma "Temperas Cremosas.app" y la copia a /Applications
```

La app queda firmada localmente (ad-hoc). Si tienes un certificado de desarrollador, pon su hash en un archivo `.firma` (o en `SESIONES_FIRMA`) para que macOS recuerde el permiso del micrófono entre versiones:

```bash
security find-identity -v -p codesigning   # copia el hash de tu certificado
echo TU_HASH > .firma
```

## Carpetas

El árbol sale de tu disco. En `~/.sesiones/carpetas.json` (se crea al abrir la app por primera vez) solo dices cuál es tu carpeta de proyectos:

```json
{
  "base": "~/Desktop/Proyectos",
  "pruebas": { "nombre": "Pruebas", "rutas": ["/private/tmp", "/tmp/"] }
}
```

- `base`: tu carpeta de proyectos. Se muestran sus carpetas y las de dentro, tal cual; y un tercer nivel dentro de las que no son un repositorio (un cliente o producto con `web`, `ios`, `android`).
- Cada sesión va a la carpeta donde se abrió. Si moviste un proyecto y te llevaste su historial de `~/.claude/projects`, la app encuentra la carpeta nueva y la retoma ahí.
- Al final, aparte: **Sueltas** (abiertas directo en `base`), **Otros lugares** (fuera de `base`), **Ya no existen** (su carpeta se movió o se borró), **Pruebas** (`pruebas.rutas`) y **Archivo** (`archivo`, lo llena la app).
- *Nueva carpeta* crea una carpeta de verdad en el disco, dentro de la que estás viendo.

## Desde la terminal

`terminal/sesiones.py` es la versión en modo texto (sin dependencias, Python 3), útil como pantalla de inicio de Warp u otra terminal. Todavía reparte las sesiones a la manera original (una carpeta por proyecto y reglas `carpetas` de `carpetas.json`), no como árbol:

```bash
ln -s "$PWD/terminal/sesiones.py" ~/.local/bin/sesiones
sesiones           # carpetas en la terminal
sesiones --lista   # imprime carpetas y sesiones
```

## Privacidad

Temperas Cremosas solo **lee** tus archivos locales (`~/.claude/projects` y la base de Codex en `~/.codex`, en modo solo lectura) y guarda su configuración en `~/.sesiones`. No envía nada a internet. El dictado usa el reconocimiento de voz de Apple; cuando tu idioma lo permite, se hace en el propio Mac.

## Licencia

MIT. Las fuentes Manrope y DM Sans van con su licencia OFL 1.1.
