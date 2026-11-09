# openshell-hermes

Laboratorio para correr **Hermes Agent v0.23.0** (Nous Research) dentro de **NVIDIA OpenShell**, con el blueprint
**NemoClaw for Hermes Agent**, en macOS (Apple Silicon, con Colima) o en Ubuntu 22.04 (Docker nativo). El sandbox `hermes-v023` queda encerrado
(Landlock, seccomp, red denegada por defecto con presets y Policy Advisor manual) y configurado con reglas de
trabajo propias, skills, un plugin de barandillas para código y el MCP context7.

## Instalar en otra máquina

Hay dos instaladores con los mismos pasos 3-13 (`lib/comun.sh`); solo cambia cómo se prepara el sistema.
`bash instalar.sh` elige el que toca según el sistema.

| | macOS (Apple Silicon) | Ubuntu 22.04 (x86_64 o arm64) |
|---|---|---|
| Script | `bash instalar-mac.sh` | `bash instalar-ubuntu.sh` (con tu usuario, no con `sudo`) |
| Requisitos previos | [Homebrew](https://brew.sh) | `sudo` con contraseña; 4 CPU, 8 GB de RAM (16 recomendado), 40 GB libres |
| Paso 1 | brew: colima, docker, docker-buildx, git, node | apt: curl, git, binutils, zstd, lsof; revisa kernel (Landlock ≥ 5.13) y recursos |
| Paso 2 | Colima 4 CPU / 12 GB | Docker Engine nativo (get.docker.com), servicio activo y tu usuario en el grupo `docker` (si hace falta, el script se relanza con `sg docker`) |
| CPU del sandbox | `SANDBOX_CPU=3` (NemoClaw calcula sobre los núcleos del host y Docker solo ve los de Colima) | la decide NemoClaw |

En los dos hace falta una key de NVIDIA (`nvapi-...`, en <https://build.nvidia.com/settings/api-keys>) y, si
quieres context7, su key (<https://context7.com>).

```bash
git clone <url-de-este-repo> openshell-hermes
```

```bash
cd openshell-hermes && bash instalar.sh
```

La primera vez tarda unos 45 min (la imagen base de Hermes v0.23 se compila ~30 min). El script pregunta solo
tres cosas: aceptar el aviso de software de terceros de NemoClaw, la key de NVIDIA y si quieres registrar
context7 (y su key). Las keys se leen sin mostrarse y no se guardan en disco: quedan en proveedores de OpenShell
y el sandbox solo ve un placeholder. Si algo falla, corrige y vuelve a correrlo: cada paso salta lo ya hecho.

Opciones: `--sin-context7`, `--sin-requests`, `--sin-bateria`, `--sin-webapp-link`. Variables: `SB` (nombre del
sandbox), `MODELO`, `PRESETS`, `SANDBOX_CPU`, `PUERTO_DASHBOARD`/`PUERTO_API`/`PUERTO_WEBAPP`; en Mac también
`COLIMA_CPU` (4) y `COLIMA_MEMORY` (12).

**Qué está probado:** en la Mac, el script completo sobre el sandbox existente (todos los pasos y la batería,
61 PASS / 0 FAIL). En Ubuntu 22.04, dentro de un contenedor: el paso 1 real, el paso 4 real (clon + parche en
Linux da el mismo árbol), la lógica del paso 2 y todo el `awk` con `mawk`; el gateway de OpenShell 0.0.116 corre
en Ubuntu 22.04 (pide glibc 2.28). **No probado:** una instalación completa desde cero en ninguno de los dos, y la
imagen base del fork en x86_64 (solo se compiló en arm64). NVIDIA valida Ubuntu 24.04; 22.04 debería funcionar.

## Qué hacen los pasos 3-13 (iguales en los dos)

3. Instala **NemoClaw v0.0.141** (fijo: el fork depende de esa versión) sin onboarding; trae OpenShell 0.0.116
   (en Linux, también Node con nvm si falta).
4. Recrea el fork: clona NVIDIA/NemoClaw `v0.0.141`, aplica `fork/hermes-v023.patch` y copia
   `fork/Dockerfile.hermes-v023` en `nemoclaw-hermes-v023/`.
5. Compila la imagen base de Hermes v0.23.
6. Crea el sandbox `hermes-v023` con onboarding no interactivo (NVIDIA Endpoints,
   `nvidia/nemotron-3.5-super-vl-120b-a12b`, presets `npm pypi huggingface brew-balanced github`, sin búsqueda
   web, sin GPU aunque la máquina tenga una NVIDIA).
7. Enciende el Policy Advisor (propuestas de red + OCSF JSON; aprobación manual) y deja exactos los presets.
8. Sube `hermes/SOUL.md`, `hermes/AGENTS.md` e instala las skills de `hermes/skills/`.
9. Instala el plugin `hermes/plugins/reglas_codigo`, lo activa en `config.yaml` (no con `hermes plugins enable`),
   apaga la telemetría de Hermes, corrige permisos de `.hermes` y reinicia el gateway.
10. Clona `psf/requests` v2.34.2 limpio en `/sandbox/requests` (proyecto de pruebas).
11. Registra context7 y corrige su regla de red (bug del fork con el binario de Python).
12. Abre el reenvío de la Webapp (puerto 9120).
13. Corre la batería de aislamiento y rechaza las propuestas de red que provocan sus bloqueos.

Al final: dashboard <http://127.0.0.1:18790/>, API <http://127.0.0.1:8643/v1>, Webapp <http://127.0.0.1:9120/>.
El reenvío de la Webapp hay que repetirlo tras reiniciar la máquina (el comando sale al final del script).

## Estructura

```
instalar.sh                 elige instalar-mac.sh o instalar-ubuntu.sh según el sistema
instalar-mac.sh             pasos 1-2 en macOS (Homebrew, Colima) y luego lib/comun.sh
instalar-ubuntu.sh          pasos 1-2 en Ubuntu 22.04 (apt, Docker Engine, grupo docker) y luego lib/comun.sh
lib/comun.sh                pasos 3-13, iguales en los dos sistemas
fork/                       parche y Dockerfile que convierten NemoClaw v0.0.141 en el fork de Hermes v0.23.0
hermes/SOUL.md              identidad y todas las reglas de trabajo de Hermes -> /sandbox/.hermes/SOUL.md
hermes/AGENTS.md            lo propio de /sandbox -> /sandbox/AGENTS.md
hermes/skills/              skills locales (NVIDIA/skills + las que escribió Hermes)
hermes/plugins/             plugin reglas_codigo (hooks de Hermes) y su autoprueba
pruebas/                    batería de aislamiento (`bash pruebas/correr-aislamiento.sh`)
GUIA-NEMOCLAW-HERMES.md     guía paso a paso y explicación de cada pieza
CLAUDE.md                   notas del laboratorio (hallazgos, pruebas, decisiones)
legacy/                     scripts del montaje manual anterior (retirado; solo consulta)
```

## No hacer en este sandbox

- `hermes plugins enable/disable`: re-sincroniza el entorno de Python de Hermes sin `aiohttp` y el siguiente
  reinicio deja el sandbox caído.
- `nemohermes hermes-v023 rebuild`: el fork quitó el parche que lo hace seguro; usa `destroy` + `instalar.sh`.
- `proposal_approval_mode=auto`: el prover de OpenShell deja pasar exfiltración evidente.
- Actualizar NemoClaw: el fork está atado a v0.0.141.
