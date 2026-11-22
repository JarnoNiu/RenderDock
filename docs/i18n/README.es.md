<div align="center">

<img src="../../assets/icon.png" width="120" alt="Icono de RenderDock">

# RenderDock

**Todos los renders de tu Mac, en una cápsula flotante.**

[English](../../README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · **Español** · [Français](README.fr.md) · [Deutsch](README.de.md) · [Português](README.pt-BR.md) · [Русский](README.ru.md)

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![Dependencias: ninguna](https://img.shields.io/badge/dependencies-none-4FEDB0)
![Licencia: MIT](https://img.shields.io/badge/license-MIT-42C2FF)

<img src="../../assets/demo.gif" width="820" alt="Demostración de RenderDock: la cápsula se despliega en un panel, se arrastra por la pantalla y se acopla a una esquina">

<sub>La interfaz de arriba la dibuja la propia app en modo demo. Los trabajos, las cifras y el puntero siguen un guion; el fondo es un escritorio simulado.</sub>

</div>

---

RenderDock es una pequeña app nativa de macOS para quienes lanzan sus renders desde scripts y terminales. Encuentra todos los trabajos de Blender sin interfaz que se ejecutan en el equipo, muestra por dónde va cada uno y vigila el hardware que hace el trabajo. No requiere configuración y nunca toca tus trabajos.

## Por qué

Un render lanzado desde un script de shell no tiene ventana. Acabas ejecutando `ps`, contando archivos en una carpeta de salida y preguntándote si el Mac entró en reposo hace una hora. RenderDock reúne todo eso en un solo lugar que siempre está en pantalla y nunca estorba.

## Qué ofrece

<table>
<tr>
<td width="50%" valign="top">

**Una cápsula que vive donde quieras**

Arrástrala a cualquier pantalla. Se acopla a los bordes, a las esquinas y al centro del borde superior o inferior, y recuerda dónde la dejaste. Flota sobre las apps en pantalla completa y te sigue de un Space a otro.

<img src="../../assets/capsule-en.png" width="380" alt="La cápsula contraída">

**Todo el panorama con un clic**

- Cada cadena de trabajos en una tarjeta: título, proyecto, script y tiempo transcurrido
- Una barra de segmentos para las colas de varios planos: terminado (Done), renderizando (Rendering), en pausa (Paused), siguiente (Up next)
- Del plano en curso: miniatura del último fotograma, número de fotogramas, segundos por fotograma, tiempo restante, núcleos de CPU y memoria
- Estados que distingue: en ejecución (Running), en pausa (`SIGSTOP`), atascado (Stalled), en cola (Queued)

**El equipo, de un vistazo**

CPU, uso de GPU y memoria de GPU, memoria y presión de memoria, temperatura del SoC, swap, espacio libre en disco, fuente de alimentación y si algo está manteniendo el Mac despierto.

</td>
<td width="50%" valign="top">

<img src="../../assets/panel-en.png" width="400" alt="El panel desplegado, con tarjetas de trabajos y métricas del sistema">

</td>
</tr>
</table>

También incluye un elemento en la barra de menús con un anillo de progreso, un interruptor opcional **Mantener activo durante el render** (Keep Awake While Rendering) y **Abrir al iniciar sesión** (Launch at Login).

## Inicio rápido

Requisitos: macOS 14 o posterior y la cadena de herramientas de Swift 6 (Xcode 16 o posterior, o solo las Command Line Tools: `xcode-select --install`).

```bash
git clone https://github.com/JarnoNiu/RenderDock.git
cd RenderDock
zsh scripts/install.sh
```

Eso compila la app, la copia en `/Applications/RenderDock.app` y la abre. Sin contraseña de administrador y sin dependencias que descargar. Añade `--login` para activar también la apertura al iniciar sesión.

¿No hay ningún render en marcha? Échale un vistazo con trabajos inventados:

```bash
open -n /Applications/RenderDock.app --args --demo
```

O mira cómo detecta un proceso real, sin Blender y sin GPU de por medio:

```bash
zsh scripts/fake-render.sh 60 1
```

> Todavía no hay una descarga precompilada. La app no está notarizada, y una descarga sin firmar da más problemas que una compilación de 30 segundos. Las versiones firmadas y un cask de Homebrew están en la hoja de ruta.

## Cómo encuentra tus renders

RenderDock lee la tabla de procesos y las carpetas de salida. No se engancha a Blender y no tienes que cambiar tus scripts.

| Lo que ve | Lo que muestra |
|---|---|
| Un proceso de Blender iniciado con `-b` / `--background` | Un **plano** |
| El script más externo por encima de él en el árbol de procesos (`zsh render_all.sh`, `python queue.py`, …) | Una **cadena de trabajos**: una tarjeta. El título es la primera línea de comentario de ese script |
| Argumentos `scene:shot` en la línea de comandos de un script de cola | La **cola**: qué planos están terminados, cuáles se están renderizando y cuáles vienen después |
| Un script envuelto en `caffeinate` que aún no tiene proceso de render | **En cola** |
| Un proceso detenido con `kill -STOP` | **En pausa** |
| Ningún fotograma nuevo durante 10 veces el tiempo habitual por fotograma (5 minutos como mínimo) | **Atascado** |
| Archivos de imagen en la carpeta de salida, sin duplicados por número de fotograma | **Fotogramas terminados**, segundos por fotograma, miniatura del último fotograma |

La carpeta de salida se toma del `-o` / `--render-output` del propio Blender (incluidas las rutas `//` relativas al `.blend`) o de un argumento del script `--out CARPETA` después de `--`.

### De dónde sale el porcentaje

RenderDock solo muestra un porcentaje cuando conoce el total. No adivina.

| Fuente | Se muestra como |
|---|---|
| `render-progress.json` en la carpeta de salida (ver más abajo) | exacto: `412/720 frames · 57%` y tiempo restante |
| Un rango de fotogramas en la línea de comandos: `-s 1 -e 250 -a` o `-f 1..250` | exacto |
| Un clip anterior con el mismo nombre junto a la carpeta de salida | estimación, marcada con `≈`. Se descarta en cuanto el número de fotogramas la supera |
| Ninguna de las anteriores | solo número de fotogramas y segundos por fotograma, con una barra indeterminada |

```bash
# progreso exacto, sin configuración
blender -b shot_010.blend -o //render/frame_#### -s 1 -e 250 -a
```

### `render-progress.json`: progreso exacto para cualquier pipeline

Si el rango está guardado dentro del `.blend` o tu script renderiza los fotogramas por su cuenta, escribe un archivo pequeño en la carpeta de salida después de cada fotograma:

```json
{"done": 12, "total": 720}
```

```python
# en un script de Python de Blender
(out_dir / "render-progress.json").write_text(json.dumps({"done": i + 1, "total": len(frames)}))
```

Cualquier cosa que pueda escribir un archivo puede informar de su progreso así, no solo Blender.

## Lo que no hace

- Es de **solo lectura**. No envía señales, no escribe nada fuera de sus propias preferencias y no establece conexiones de red.
- La versión 0.1 no tiene botones para pausar, reanudar ni detener. Los scripts de cola suelen gestionar `STOP`/`CONT` por sí mismos, y dos manos sobre el mismo interruptor son mala idea.
- Si ni la carpeta de salida ni el rango de fotogramas están en la línea de comandos, el trabajo aparece igualmente, con CPU, memoria y tiempo transcurrido, pero sin fotogramas.
- La temperatura del SoC se lee de los sensores IOHID, una interfaz privada disponible en Apple Silicon. En los Mac con Intel, o tras una actualización del sistema que cambie los sensores de sitio, el recuadro muestra `–`. No se leen la velocidad de los ventiladores ni la potencia consumida.
- Compilada y probada en macOS 26 con un M5 Max. Compila para macOS 14, pero no se ha probado en 14, en 15 ni en Mac con Intel. Se agradecen los informes.
- Idiomas de la interfaz: inglés y chino simplificado (sigue el idioma del sistema; se puede forzar uno con `--lang en` o `--lang zh`).

## Hoja de ruta

La lista completa de tareas pendientes, con su cronograma, está en **[ROADMAP.md](../../ROADMAP.md)**.

En resumen (planes, no promesas):

- Progreso exacto sin configurar nada: un wrapper o un add-on que lea la salida de fotogramas del propio Blender
- Más allá de Blender: codificaciones con ffmpeg, ComfyUI, After Effects y un pequeño formato de adaptador para todo lo demás
- Notificaciones cuando un trabajo termina, se atasca o falla, en el Mac y en el teléfono
- Una API local, para que una pantalla de escritorio, una luz de estado o una tecla de Stream Deck muestren el mismo progreso
- Historial: cuánto tardaron de verdad los planos, y mejores estimaciones del tiempo restante a partir de ahí
- Controles opcionales: pausar, reanudar, bajar la prioridad
- Versiones firmadas y notarizadas, Homebrew, más idiomas de interfaz

## Desarrollo

| Comando | Qué hace |
|---|---|
| `zsh scripts/build-app.sh` | Compila `build/RenderDock.app` (firma ad hoc; el icono lo dibuja la propia app) |
| `zsh scripts/install.sh [--login]` | Compila, instala en `/Applications` y vuelve a abrir la app |
| `.build/release/RenderDock --dump` | Imprime como texto los trabajos detectados y las métricas, sin interfaz |
| `.build/release/RenderDock --snapshot CARPETA [--demo]` | Renderiza la cápsula y el panel a PNG |
| `zsh scripts/make-demo.sh` | Regenera las capturas de pantalla y el GIF de `assets/` |
| `zsh scripts/fake-render.sh [fotogramas] [s/fotograma]` | Un render simulado para probar la detección |
| `python3 scripts/verify-interactions.py <binario>` | Inyecta clics y arrastres en una instancia iniciada con `--debug` y comprueba el despliegue, la contracción y el acople (12 comprobaciones) |

El código es Swift y SwiftUI sin más, con AppKit para la ventana: unas 3000 líneas, sin paquetes. Consulta [CONTRIBUTING.md](../../CONTRIBUTING.md).

## Agradecimientos

RenderDock no comparte código con estos proyectos, pero ellos mostraron lo que se puede hacer sin `sudo`: [Stats](https://github.com/exelban/stats) y [macmon](https://github.com/vladkens/macmon), por la lectura de datos de GPU y de sensores, y [boring.notch](https://github.com/TheBoredTeam/boring.notch), por lograr que una interfaz pequeña y siempre presente se sienta en casa en un Mac.

Un proyecto con un objetivo parecido: [Blender Render Monitor](https://github.com/DUBSON0/blender-render-monitor) también lista los renders de Blender en un Mac y ya tiene pausa, reanudación y cola. Obtiene el progreso de un script de hook de Blender o de un archivo de registro. RenderDock 0.1 se escribió sin conocerlo; los dos no comparten código.

## Licencia

[MIT](../../LICENSE)
