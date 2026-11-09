# Hermes Agent con el blueprint NemoClaw (la forma oficial)

Fuente: blueprint <https://build.nvidia.com/nvidia/nemoclaw-for-hermes-agent/nemoclawcard> →
repo <https://github.com/NVIDIA/NemoClaw> (docs `docs/get-started/quickstart-hermes.mdx`,
revisado el 2026-11-06, commit `e7045cc`, release `v0.0.141`).

## Qué cambia respecto al ejercicio anterior

| Antes (`openshell-hermes.sh`, hecho a mano)                       | Ahora (NemoClaw)                                                      |
|-------------------------------------------------------------------|-----------------------------------------------------------------------|
| OpenShell 0.1.7 desde `./vendor` con un tap local modificado      | El instalador pone **OpenShell 0.0.116 exacto** (fijado por NemoClaw) y verifica su checksum |
| `gateway.toml` a mano para que Colima alcance el gateway          | NemoClaw configura el gateway y le pasa el socket de Colima           |
| `Dockerfile.hermes` propio (Hermes 0.19 en `python:3.12-slim`)    | Imagen gestionada de Hermes (0.21.3), con digest fijado               |
| Provider profile propio `nvidia-hermes.yaml`                      | Provider nativo "NVIDIA Endpoints"; la key queda fuera del sandbox    |
| Política Landlock por defecto + reglas aprobadas a mano           | Política base para Hermes + **presets** (`pypi`, `github`, `npm`…)    |
| `ask` / `chat` con `sandbox create` efímero                       | Sandbox persistente `my-hermes` con dashboard (:18789) y API OpenAI (:8642) |

La CLI es `nemoclaw`; **`nemohermes`** es la misma CLI con Hermes preseleccionado.

---

## Instalación automática en otra Mac

`bash instalar.sh` deja una Mac nueva igual que la del laboratorio (sandbox `hermes-v023` del fork v0.23, SOUL,
AGENTS, skills, plugin, red, context7, Webapp y batería). Ver `README.md`. Los pasos de abajo explican lo que hace
y cómo se llegó a cada decisión; el sandbox `my-hermes` de los primeros pasos ya no se crea.

### Lecciones de la caída del 2026-11-09 (ya incorporadas en `instalar.sh`)

- **No uses `hermes plugins enable/disable`.** Re-sincroniza el entorno de Python de Hermes en
  `/sandbox/.hermes/installs/<id>/environments/…` sin el extra del servidor de API (sin `aiohttp`) y lo registra en
  `facts.json`. El gateway que ya corre no lo nota; al reiniciar falla el health (puerto 18642), `nemoclaw-start`
  sale y el contenedor queda en fase `Error`, de la que ni `start`, ni `stop`, ni `recover` lo sacan. Los plugins se
  activan editando `plugins.enabled` en `config.yaml` y reiniciando el gateway.
- **Recuperar el sandbox del fork:** `destroy --yes --no-cleanup-gateway` + onboarding (o `instalar.sh`), nunca
  `rebuild`. Antes, respalda `/sandbox` del contenedor parado con `docker cp <id>:/sandbox - > sandbox.tar`.
- **`nemohermes <sb> upload` omite las carpetas `.git`.** Para subir un repo, súbelo en un tar creado con
  `COPYFILE_DISABLE=1` (sin él, macOS mete archivos `._*` que rompen el pack de git).
- **Tras un `destroy`, el proveedor de un MCP sobrevive** (`<sb>-mcp-<srv>`) y `mcp add` se niega con
  "non-prefix partial state". Bórralo con `openshell provider delete <sb>-mcp-<srv>` y repite el `mcp add`.
- **`hermes webapp` exige que `/sandbox/.hermes` no sea escribible por el grupo.** El Dockerfile lo deja en 3770 y el
  grupo `sandbox` tiene miembros (`gateway`, `root`); como todo corre con el usuario `sandbox`,
  `chmod g-w /sandbox/.hermes` lo arregla.
- **`nemohermes <sb> gateway restart` puede quedarse en "Confirming the gateway stays responsive" muchos minutos**
  aunque el gateway ya volvió; compruébalo con `curl` al health desde dentro y corta el comando.

## Paso 0 — Limpiar lo del ejercicio anterior (una vez)

El instalador detecta que 0.1.7 está por encima del máximo y **reinstala 0.0.116**. Eso es un
downgrade: la base `~/.local/state/openshell/gateway/openshell.db` de 0.1.7 puede no migrar
("migration N was previously applied…"). Mejor empezar limpio y **respaldar** (no borrar):

```bash
cd ~/Documents/proyectos/openshell-hermes
bash legacy/openshell-hermes.sh clean
bash pruebas-openshell.sh limpiar
brew services stop openshell
brew uninstall openshell
mkdir -p ~/openshell-backup-0.1.7
mv ~/.config/openshell ~/openshell-backup-0.1.7/config
mv ~/.local/state/openshell ~/openshell-backup-0.1.7/state
```

Los dos primeros borran los sandboxes viejos. Cada `mv` va a su propia subcarpeta porque ambas
carpetas se llaman `openshell` y un solo `mv` choca.

> Los bloques de esta guía no llevan comentarios `#`: en zsh (macOS) `interactivecomments` viene
> apagado y un `# ...` pegado en la terminal se vuelve argumentos del comando.

No toques `/opt/homebrew/var/openshell` ni el tap `nvidia/openshell`: el instalador de NemoClaw
reescribe la fórmula del tap con la oficial verificada. Colima se queda como está (4 CPU / 8 GB
es el mínimo; 16 GB recomendado). Requisitos ya cubiertos en tu Mac: Node ≥ 22.19, npm ≥ 10,
`colima` + `docker` CLI.

## Paso 1 — Instalar NemoClaw para Hermes

El `export` es opcional: apaga la telemetría que NemoClaw manda a NVIDIA por defecto.

```bash
export NEMOCLAW_DISABLE_TELEMETRY=1
curl -fsSL https://www.nvidia.com/nemoclaw.sh | NEMOCLAW_AGENT=hermes NEMOCLAW_SANDBOX_NAME=my-hermes bash
```

(Si prefieres leer el script antes: `curl -fsSL https://www.nvidia.com/nemoclaw.sh -o nemoclaw.sh && less nemoclaw.sh`.)

## Paso 2 — Onboarding (el asistente interactivo)

En macOS normalmente no aparece "express install"; el asistente pregunta:

1. **Proveedor de inferencia** → *NVIDIA Endpoints*. Pega tu `nvapi-...` cuando lo pida
   (la variable oficial es `NVIDIA_INFERENCE_API_KEY`; tu `.env` usa `API_KEY`).
2. **Modelo** → el que te funcionó en `probe` (p. ej. `nvidia/nemotron-3.5-super-vl-120b-a12b`,
   que es el del ejemplo oficial, o `nvidia/nemotron-3.5-lightning-30b-a3b`).
3. **Nombre del sandbox** → `my-hermes`.
4. **Tavily / mensajería** → sáltalos en la primera corrida.
5. **Tier de política de red** → acepta el sugerido.
6. Revisa el resumen → *Apply configuration*.

La primera vez tarda varios minutos (descarga la imagen gestionada, ~2.4 GB comprimida).
Al terminar imprime "NemoHermes is ready" con las URLs del dashboard y la API.

Versión sin preguntas (útil para repetir):

```bash
export NEMOCLAW_AGENT=hermes NEMOCLAW_NON_INTERACTIVE=1 NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1
export NEMOCLAW_SANDBOX_NAME=my-hermes NEMOCLAW_WEB_SEARCH_PROVIDER=none
read -rs "NVIDIA_INFERENCE_API_KEY?nvapi key: " && export NVIDIA_INFERENCE_API_KEY
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
unset NVIDIA_INFERENCE_API_KEY
```

Si se interrumpe: `nemohermes onboard --resume` (o `--fresh` para empezar de cero).

Cuando el onboarding termine, la key ya vive en el provider de OpenShell: borra el `.env` de esta
carpeta (`rm .env`); nada de NemoClaw lo usa.

## Paso 3 — Verificar y usar

| Para…                                         | Comando |
|-----------------------------------------------|---------|
| Ver el estado del sandbox                     | `nemohermes my-hermes status` |
| URL del dashboard (ábrela en el navegador)    | `nemohermes my-hermes dashboard-url --quiet` |
| Hermes en tu terminal (preflight completo en macOS) | `nemohermes launch my-hermes` |
| Shell dentro del sandbox (luego: `hermes`)    | `nemohermes my-hermes connect` |
| Probar la API OpenAI-compatible               | `curl -sf http://127.0.0.1:8642/health` |

Si tras reiniciar la Mac no responde: `nemohermes my-hermes recover`.

## Paso 4 — Operar el día a día

| Quiero…                         | Comando |
|---------------------------------|---------|
| Ver logs                        | `nemohermes my-hermes logs --follow` |
| Cambiar de modelo sin reconstruir | `nemohermes inference set --model <id> --provider <provider> --sandbox my-hermes` |
| Ver la política de red viva     | `nemohermes my-hermes policy list` / `policy get` / `policy explain` |
| Abrir un preset de red          | `nemohermes my-hermes policy add pypi --dry-run` y luego sin `--dry-run` |
| Instalar una skill              | `nemohermes my-hermes skill install ./mi-skill/` (va a `/sandbox/.hermes/skills/<name>`) |
| Listar skills                   | `nemohermes my-hermes skill list` |
| Plugin de Hermes (no skill)     | `nemohermes my-hermes exec -- hermes plugins list` + `gateway restart` |
| Subir/bajar archivos            | `nemohermes my-hermes upload <local> <remoto>` / `download <remoto> <local>` |
| Reconstruir conservando estado  | `nemohermes my-hermes rebuild` |
| Borrar el sandbox               | `nemohermes my-hermes destroy` |

Presets disponibles en esta versión: `brave brew brew-balanced claude-code github gmail
huggingface jira local-inference local-memory npm nous-* outlook personal-open-internet
public-reference pypi tavily weather` (más los tuyos con `--from-file`).

Reglas que importan:

- No uses `openshell sandbox create`, `openshell self-update` ni `brew services` a mano sobre
  esto: NemoClaw es el dueño del gateway (`nemohermes onboard` lo recrea).
- Nunca pongas keys en `/sandbox/.hermes/.env`, `config.yaml` ni dentro de skills: se registran
  con `nemohermes credentials add …` y OpenShell inyecta un placeholder.
- Una skill solo funciona si la política deja salir a los hosts que usa: revisa con
  `policy add <preset> --dry-run` antes de abrir nada.

## Paso 5 — Policy Advisor: que Hermes pida la red que necesita

OpenShell controla el tráfico del agente en tres capas:

1. **Política de red** (deny-by-default): reglas por host + puerto + binario y, en APIs HTTP, por
   método + ruta. Los presets son reglas ya escritas (p. ej. `pypi` solo permite `GET`/`HEAD`).
2. **Policy Advisor**: cuando algo se bloquea, Hermes propone una regla acotada a
   `http://policy.local`; el **policy prover** compara qué alcanzaría el sandbox con y sin ella y
   marca destinos riesgosos (IPs privadas, comodines). Tú apruebas o rechazas; lo aprobado entra sin
   reiniciar. Aunque el advisor esté apagado, OpenShell redacta borradores de regla por cada bloqueo.
3. **Middleware**: servicios propios que inspeccionan, modifican o niegan el contenido del tráfico ya
   permitido, antes de que OpenShell inyecte las credenciales. Avanzado; no verificado en 0.0.116.

Fuente: `docs/how-it-works/policies/advisor.mdx` y `docs/extensibility/` en
<https://github.com/NVIDIA/OpenShell>.

### Activarlo (viene apagado)

```bash
openshell settings set my-hermes --key agent_policy_proposals_enabled --value true
openshell settings get my-hermes
```

Hazlo antes de abrir la sesión de Hermes: los agentes leen sus instrucciones al arrancar.

### Revisar propuestas en vivo

```bash
openshell term
```

En el panel: `j`/`k` para elegir el sandbox, `Enter`, luego `r` para ir a *Network Rules*.
`a` aprueba, `x` rechaza, `A` aprueba todo.

Desde la línea de comandos:

| Para…               | Comando |
|---------------------|---------|
| Ver pendientes      | `openshell rule get my-hermes --status pending` |
| Aprobar             | `openshell rule approve my-hermes --chunk-id <id>` |
| Rechazar con motivo | `openshell rule reject my-hermes --chunk-id <id> --reason "Solo lectura"` |
| Historial           | `openshell rule history my-hermes` |

Hermes recibe el motivo del rechazo y puede proponer algo más estrecho.

### Prueba guiada

Con el tier Balanced (sin `github`), abre Hermes y pídele: *"Clona https://github.com/psf/requests
en /sandbox/requests. Si la red te bloquea, lee /etc/openshell/skills/policy_advisor.md y pide
acceso por policy.local."* Verás la propuesta en `openshell term` con el resultado del prover.

La pista del prompt hace falta porque OpenShell deja su guía en `/etc/openshell/skills/` y en
`/AGENTS.md`, y Hermes carga sus skills de `/sandbox/.hermes/skills`.

### Aprobación automática (opcional)

```bash
openshell settings set my-hermes --key proposal_approval_mode --value auto
```

Solo aprueba sola una propuesta cuando el prover no encuentra riesgo y el destino no está marcado;
el resto sigue esperando tu decisión. Vuelve a `manual` con el mismo comando.

> **No lo actives sin el revisor.** En la prueba del 2026-11-06 el prover marcó `curl → webhook.site:443`
> (un destino típico de exfiltración) como "no new findings": el modo `auto` lo habría aprobado.

### Revisor automático de propuestas (`revisor/revisor.py`)

Un script en el host que lee las propuestas pendientes y la actividad de red reciente, y le pide a
Nemotron un veredicto: `rechazar`, `recomendar` o `escalar`. El modelo no tiene herramientas (solo
devuelve JSON) y el script **nunca aprueba**: con `--apply` solo rechaza, con el motivo que Hermes recibe.
Un piso determinista rechaza siempre comodines, IPs privadas o de metadatos y hosts típicos de
exfiltración, diga lo que diga el modelo.

| Para…                              | Comando |
|------------------------------------|---------|
| Ver veredictos sin tocar nada      | `python3 revisor/revisor.py` |
| Rechazar lo que marque             | `python3 revisor/revisor.py --apply` |
| Correrlo cada 2 minutos            | `while true; do python3 revisor/revisor.py --apply; sleep 120; done` |
| Probar la lógica sin red           | `python3 revisor/revisor.py --self-test` |

Usa `NVIDIA_API_KEY` del entorno o `API_KEY` del `.env` del proyecto (si borras el `.env`, exporta la
variable). Guarda lo ya revisado en `revisor/estado.json`; bórralo para revisar todo de nuevo. Lo que
quede en `recomendar` o `escalar` lo apruebas o rechazas tú en `openshell term`.

### Lo que dura cada cosa

- Reglas aprobadas: viven mientras exista el sandbox; un `destroy` o recrear las borra.
- Para algo permanente: `nemohermes my-hermes policy add <preset>` o un preset propio con
  `policy add --from-file`.
- No verificado: si `nemohermes my-hermes rebuild` conserva los ajustes de `openshell settings`.
  Revísalo con `openshell settings get my-hermes` después de reconstruir.

## Paso 6 — Que tu agente de código te guíe (opcional)

NemoClaw trae la skill `nemoclaw-user-guide` (en `.agents/skills/` del repo) para Claude Code,
Cursor, Codex, etc. Con ella tu agente consulta la doc correcta antes de cada comando
(ver `docs/resources/agent-skills.mdx` del repo).

---

## Skills de build.nvidia.com para Hermes

La página <https://build.nvidia.com/skills> es solo un listado; el código vive en
<https://github.com/NVIDIA/skills> (`skills/<nombre>/SKILL.md`, formato agentskills.io, compatible con
Hermes). Son **437 skills** (lista completa en `skills-nvidia-catalogo.txt`), y casi todas son para
productos NVIDIA (TAO, DOCA, Jetson, BioNeMo, Megatron…). **No hay skills genéricas** de revisión
de código, testing, tareas o notas: para eso conviene mirar las skills propias de Hermes
(`hermes skills browse`) o crear las tuyas.

### Cómo instalarlas (desde el host, sin abrir red en el sandbox)

```bash
git clone --depth 1 https://github.com/NVIDIA/skills ~/nvidia-skills
nemohermes my-hermes skill install ~/nvidia-skills/skills/<nombre>/
nemohermes my-hermes skill list
```

Después abre una sesión nueva de Hermes para que cargue la skill.

### Las que sí valen la pena para ti

| Skill | Para qué | Red que necesita |
|-------|----------|------------------|
| `nemo-rl-session-memory` | Memoria de sesión duradera: escribe `./session/<fecha>/` con estado, timeline, archivos tocados y handoff; checkpoints cada 30 min o antes de ediciones grandes. Genérica pese al nombre. **La mejor para organización.** | Ninguna (solo `git`) |
| `ethos-orchestrate` + `ethos-explore` + `ethos-write` | Redactar y mantener un `ETHOS.md`: propósito, límites y criterio de éxito del agente. Instálalas juntas. | Ninguna |
| `nemoclaw-user-guide` | Lleva al agente a la doc oficial de NemoClaw (incluida la variante Hermes). Útil sobre todo en tu agente de código del host. | `docs.nvidia.com` (no hay preset: política propia) |
| `mcore-create-issue` / `mcore-split-pr` | Triage de un fallo de GitHub Actions → issue; partir un PR grande por CODEOWNERS. **Traen `NVIDIA/Megatron-LM` fijo**: edita el `SKILL.md` para tu repo. | Preset `github` + credencial de `gh` |
| `skill-card-generator` | Genera la ficha de gobernanza de una skill tuya. Solo si escribes skills. | Ninguna |

Descartadas en tu Mac: `compute-sanitizer-diagnose-cuda-bugs` y `tilegym-*` necesitan GPU con CUDA;
`nvidia-skill-finder` usa `npx` y solo sirve si trabajas con productos NVIDIA.

Antes de abrir un preset para una skill: `nemohermes my-hermes policy add github --dry-run`.

## Hermes v0.23.0 con un fork del blueprint (sandbox `hermes-v023`)

NemoClaw 0.0.141 fija Hermes en v0.21.3 a propósito. Solo acepta versiones que NVIDIA revisó (por hash) y aplica unos 16 parches atados a esa versión. Además, desde v0.21.6 Hermes usa etiquetas `v0.23.0` y el script de descarga de NemoClaw solo acepta las de fecha (`v2026.x.y`). A la fecha (2026-11-07) no hay ningún PR de NVIDIA para pasar a 0.22 o 0.23.

El fork está en `nemoclaw-hermes-v023/`: es un clon de NVIDIA/NemoClaw `v0.0.141` en la rama `hermes-v0.23.0`. Con `git diff` ves todos los cambios, y cada uno lleva un comentario `# hermes v0.23 fork:`. El repo no guarda el fork entero: guarda `fork/hermes-v023.patch` (el `git diff`) y `fork/Dockerfile.hermes-v023`, e `instalar.sh` lo recrea (clon de `v0.0.141` + parche da un árbol idéntico; comprobado el 2026-11-09). Si cambias el fork, regenera el parche con `git -C nemoclaw-hermes-v023 diff --binary > fork/hermes-v023.patch` y copia el Dockerfile. Lo que cambia frente al oficial:

- **Python y Node:** Python 3.14.9 (lo exige v0.23), instalado en `/opt/hermes/.python` porque Landlock solo permite `/opt/hermes`. El TUI y la web se compilan con Node 24, aunque v0.23 pide 26.
- **Rutas de estado:** `state.db` y `gateway.lock` son archivos normales en `HERMES_HOME`, porque v0.23 rechaza los symlinks a `runtime/`.
- **Parches de NVIDIA:** 7 siguen igual (con hashes recalculados) y los obsoletos se quitaron (MCP proxy, external-supervisor, langfuse, profile-policy, etc.). También se quitaron los probes de dos usuarios `gateway`/`sandbox`, porque OpenShell 0.0.116 corre todo con un solo usuario.
- **Config:** `plugins.auto_update_check_hours: 0` y `security.allow_lazy_installs: false`.

Reconstruir y crear el sandbox. La base tarda unos 30 min la primera vez, luego sale de la caché:
```
cd nemoclaw-hermes-v023
docker build -f agents/hermes/Dockerfile.base -t nemoclaw-hermes-sandbox-base-local:v0.23.0 .
NEMOCLAW_CPU=3 NEMOCLAW_DASHBOARD_PORT=18790 NEMOCLAW_HERMES_API_PORT=8643 nemohermes onboard --fresh --from "$PWD/Dockerfile.hermes-v023" --name hermes-v023
```
Dashboard: http://127.0.0.1:18790/. API: http://127.0.0.1:8643/v1, con la clave de `nemohermes hermes-v023 gateway-token --quiet`.

Reglas:
- Usa destroy + onboard, **nunca `rebuild`**: se quitó el parche que vaciaba los cron antes de reconstruir.
- Nunca ejecutes `scripts/update-hermes-agent.sh --update-installed-copies`, porque reescribe `~/.nemoclaw`.
- Si actualizas NemoClaw, el fork puede dejar de funcionar: queda atado al contrato de la 0.0.141.

Lo que se pierde frente a la imagen oficial:
- Los pins de seguridad de NVIDIA para dependencias Python/Node, y el parche de htmlparser (solo cubre el Python del sistema).
- El bridge de WhatsApp instalado.
- El aviso "install out of sync" de Hermes es esperado: quiere bajar ffmpeg, node y ripgrep por su cuenta.

Ruido de red nuevo en v0.23: propuestas a `raw.githubusercontent.com` y `nousresearch.github.io`, además de `openrouter.ai`.

### Webapp: el workspace de Desktop en el navegador (v0.23)

v0.23 trae la **Webapp**: el gateway sirve el workspace de Desktop (chats, Group Chats, plugins, ajustes) en su propio puerto. Viene apagada por defecto; el fork la enciende en `managed-policy.ts` con `webapp: {enabled: true, host: 127.0.0.1, port: 9120}`. La imagen compila el bundle (`apps/desktop/dist-webapp`) con un Node 26 temporal, porque su script exige Node ≥ 26.

NemoClaw solo reenvía el dashboard y la API, así que el puerto 9120 se reenvía a mano. Este reenvío no lo gestiona NemoClaw y hay que repetirlo tras reiniciar el Mac o el sandbox:
```
nohup openshell forward service --target-port 9120 --local 127.0.0.1:9120 hermes-v023 >/dev/null 2>&1 &
```
Cada navegador necesita un enlace de un solo uso para iniciar sesión:
```
nemohermes hermes-v023 exec -- hermes webapp --no-open --skip-build
```
Abre el enlace que imprime, que empieza por `http://127.0.0.1:9120/`. `hermes webapp --sign-out` cierra la sesión en todas las pestañas.

Por qué el fork parchea `gateway/webapp_listener.py` (aprobado a mano): en Linux, Hermes solo deja canjear el enlace si la conexión del navegador es del mismo usuario que el gateway. Pero con `openshell forward` la conexión llega dentro del sandbox desde el supervisor de OpenShell, que es otro usuario, y todos los enlaces fallaban con "already used or has expired". El parche hace que se comporte como en WSL y macOS: el enlace se imprime para abrirlo a mano y se canjea sin esa comprobación. Sigue siendo de un solo uso y dura 60 s, así que no lo compartas ni lo pegues en otro lado.

### Batería de aislamiento

Para comprobar que el sandbox sigue encerrado (por ejemplo, después de reconstruir la imagen del fork):
```
bash pruebas/correr-aislamiento.sh
```
Sube `pruebas/aislamiento.sh` al sandbox, lo corre y lo borra. Cada prueba dice lo que espera la política: **PASS** es que OpenShell hizo lo esperado, **FAIL** es un hueco (o un error de la prueba) y el comando sale con código ≠0. **NOTA RIESGO** marca lo que la política permite pero conviene saber: curl con acceso total a github.com, POST a nousresearch.com, venvs que heredan la red de Hermes, y que el agente puede reescribir su SOUL.md, AGENTS.md y config.yaml. La key real nunca entra: el lanzador solo pasa su sha256.

Los bloqueos dejan propuestas de red pendientes. Al final el lanzador las lista: recházalas una por una con `openshell rule reject hermes-v023 --chunk-id <id>`, nunca las apruebes en bloque.

### Servidores MCP (ejemplo: context7)

Hermes puede usar servidores MCP remotos (Streamable HTTP por HTTPS). NemoClaw los registra así; la key se lee sin mostrarla y queda en un proveedor de OpenShell, nunca en el sandbox:
```
read -rs 'CONTEXT7_API_KEY?Key context7: '; export CONTEXT7_API_KEY
nemohermes hermes-v023 mcp add context7 --url https://mcp.context7.com/mcp --env CONTEXT7_API_KEY
unset CONTEXT7_API_KEY
nemohermes hermes-v023 mcp status context7 --tools
```
Nunca pegues la key en un chat: si pasa, revócala y crea otra.

Qué controla OpenShell 0.0.116 con la política `protocol: mcp` que genera NemoClaw: host, ruta exacta e IPs, los métodos MCP permitidos, el nombre de las herramientas (bloqueos con `--deny-tool`) y el tamaño de la petición. Qué no controla: los argumentos (lo que Hermes pregunte sale al servicio) ni las respuestas (Hermes las marca como `<untrusted_tool_result>`).

En el fork hay un paso extra: la regla generada autoriza `/opt/hermes/.venv/bin/python*`, que no coincide con el python real del fork, y Hermes recibe 403. Hay que cambiar en la política viva los binarios de `mcp_bridge_<srv>` por `/usr/local/bin/hermes` y `/opt/hermes/.venv/bin/python` (exacto), aplicarla con `openshell policy set hermes-v023 --policy <archivo> --wait` partiendo de `openshell policy get hermes-v023 --base`, y luego `nemohermes hermes-v023 mcp restart <srv>`. Se pierde con `mcp update` o un rebuild. La batería (sección 1b) lo comprueba.

En el chat, Hermes encuentra las herramientas MCP con `tool_search` y las llama con `tool_call`; para usarlas basta pedirlo ("usa context7 para…").
