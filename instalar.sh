#!/usr/bin/env bash
# instalar.sh: deja una Mac con Apple Silicon con el laboratorio completo, igual que la original:
#   Colima -> NemoClaw v0.0.141 (+ OpenShell 0.0.116) -> fork que construye Hermes v0.23.0 ->
#   sandbox hermes-v023 con SOUL, AGENTS, skills, plugin reglas_codigo, red, context7, Webapp y batería.
#
# Uso:   bash instalar.sh [--sin-context7] [--sin-requests] [--sin-bateria] [--sin-webapp-link]
# Se puede volver a correr: cada paso revisa si ya está hecho y lo salta.
# Pide dos cosas a mano (nunca se guardan en disco): la key nvapi-... de NVIDIA y, si quieres
# context7, su key. Variables que puedes cambiar: ver "Configuración" abajo.
set -uo pipefail

# ── Configuración ──────────────────────────────────────────────────────────────────────────────
SB="${SB:-hermes-v023}"
NEMOCLAW_TAG="v0.0.141"
NEMOCLAW_COMMIT="b7dcc9bb"                       # commit de v0.0.141; el parche está hecho contra él
OPENSHELL_VERSION="0.0.116"
MODELO="${MODELO:-nvidia/nemotron-3.5-super-vl-120b-a12b}"
PRESETS="${PRESETS:-npm,pypi,huggingface,brew-balanced,github}"
COLIMA_CPU="${COLIMA_CPU:-4}"
COLIMA_MEMORY="${COLIMA_MEMORY:-12}"
SANDBOX_CPU="${SANDBOX_CPU:-3}"                  # NemoClaw calcula CPU sobre el host; sin esto falla con Colima
PUERTO_DASHBOARD="${PUERTO_DASHBOARD:-18790}"
PUERTO_API="${PUERTO_API:-8643}"
PUERTO_WEBAPP="${PUERTO_WEBAPP:-9120}"
BASE_IMG="nemoclaw-hermes-sandbox-base-local:v0.23.0"
REQUESTS_TAG="v2.34.2"
RUIDO_DE_FONDO="openrouter.ai raw.githubusercontent.com nousresearch.github.io models.dev portal.nousresearch.com opencode.ai"

CON_CONTEXT7=1; CON_REQUESTS=1; CON_BATERIA=1; CON_LINK=1
for a in "$@"; do
  case "$a" in
    --sin-context7) CON_CONTEXT7=0 ;;
    --sin-requests) CON_REQUESTS=0 ;;
    --sin-bateria) CON_BATERIA=0 ;;
    --sin-webapp-link) CON_LINK=0 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "Opción desconocida: $a" >&2; exit 2 ;;
  esac
done

REPO="$(cd "$(dirname "$0")" && pwd)"
FORK="$REPO/nemoclaw-hermes-v023"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/instalar-hermes.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
export NEMOCLAW_DISABLE_TELEMETRY=1 NEMOCLAW_NO_POLICY_HINT=1
KEY_SHA=""

paso()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()    { printf '    \033[32m✓\033[0m %s\n' "$*"; }
aviso() { printf '    \033[33m!\033[0m %s\n' "$*" >&2; }
die()   { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
si()    { local r; read -r -p "    $1 [s/N] " r </dev/tty; [[ "$r" == [sSyY]* ]]; }

# Ejecuta dentro del sandbox; quita la línea informativa de NemoClaw sobre OCSF y conserva el código de salida.
sx() {
  local out rc
  out=$(nemohermes "$SB" exec -- sh -c "$1" 2>&1); rc=$?
  [[ -n "$out" ]] && printf '%s\n' "$out" | grep -v '^NemoClaw is attempting to enable OpenShell OCSF'
  return $rc
}
subir() { nemohermes "$SB" upload "$1" "$2" >/dev/null 2>&1 || die "No pude subir $1 a $2"; }
sha_local() { shasum -a 256 "$1" | cut -c1-16; }
sha_remoto() { sx "sha256sum '$1' 2>/dev/null | cut -c1-16" | tail -1; }
salud() { sx "curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:18642/health" | tail -1; }

# ── 1. Mac y herramientas ──────────────────────────────────────────────────────────────────────
paso "1. Mac y herramientas (Homebrew, Colima, Docker, buildx, git, Node)"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || die "Este script es para macOS en Apple Silicon."
command -v brew >/dev/null || die "Falta Homebrew. Instálalo desde https://brew.sh y vuelve a correr este script."
for f in colima docker docker-buildx git; do
  if brew list --formula "$f" >/dev/null 2>&1; then ok "$f ya está"; else brew install "$f" || die "brew install $f falló"; fi
done
if ! command -v node >/dev/null || ! node -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>22||(a===22&&b>=19)?0:1)'; then
  brew install node || die "brew install node falló"
fi
ok "node $(node --version)"
mkdir -p "$HOME/.docker/cli-plugins"
ln -sfn "$(brew --prefix)/opt/docker-buildx/bin/docker-buildx" "$HOME/.docker/cli-plugins/docker-buildx"
docker buildx version >/dev/null 2>&1 && ok "docker buildx" || die "docker buildx no responde"

# ── 2. Colima ──────────────────────────────────────────────────────────────────────────────────
paso "2. Colima (${COLIMA_CPU} CPU / ${COLIMA_MEMORY} GB)"
if colima status >/dev/null 2>&1; then
  ok "Colima ya está corriendo"
else
  colima start --cpu "$COLIMA_CPU" --memory "$COLIMA_MEMORY" || die "colima start falló"
fi
docker context use colima >/dev/null 2>&1 || true
ncpu=$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)
(( ncpu > SANDBOX_CPU )) || die "Docker ve $ncpu CPU; necesitas más que SANDBOX_CPU=$SANDBOX_CPU (colima stop; colima start --cpu $COLIMA_CPU --memory $COLIMA_MEMORY)."
ok "Docker ve $ncpu CPU"

# ── 3. NemoClaw v0.0.141 ───────────────────────────────────────────────────────────────────────
paso "3. NemoClaw $NEMOCLAW_TAG (CLI nemohermes) y OpenShell $OPENSHELL_VERSION"
if command -v nemohermes >/dev/null && nemohermes --version 2>/dev/null | grep -q "${NEMOCLAW_TAG}"; then
  ok "nemohermes ${NEMOCLAW_TAG} ya está"
else
  command -v nemohermes >/dev/null && aviso "Hay otro NemoClaw ($(nemohermes --version 2>&1 | head -1)); el fork solo funciona con ${NEMOCLAW_TAG}."
  curl -fsSL https://www.nvidia.com/nemoclaw.sh -o "$TMPD/nemoclaw.sh" || die "No pude descargar el instalador de NemoClaw"
  NEMOCLAW_INSTALL_TAG="$NEMOCLAW_TAG" NEMOCLAW_AGENT=hermes NEMOCLAW_DEFER_ONBOARDING=1 bash "$TMPD/nemoclaw.sh" </dev/tty \
    || die "El instalador de NemoClaw falló"
  hash -r
  nemohermes --version 2>/dev/null | grep -q "${NEMOCLAW_TAG}" || die "Tras instalar, nemohermes no es ${NEMOCLAW_TAG}"
fi
openshell --version 2>/dev/null | grep -q "$OPENSHELL_VERSION" || die "openshell no es $OPENSHELL_VERSION ($(openshell --version 2>&1))"
ok "openshell $OPENSHELL_VERSION"

# ── 4. Fork (NemoClaw v0.0.141 + parche hermes v0.23) ──────────────────────────────────────────
paso "4. Fork nemoclaw-hermes-v023 (clon de $NEMOCLAW_TAG + fork/hermes-v023.patch)"
if [[ ! -d "$FORK/.git" ]]; then
  git clone -q --depth 1 --branch "$NEMOCLAW_TAG" https://github.com/NVIDIA/NemoClaw.git "$FORK" 2>/dev/null \
    || die "No pude clonar NVIDIA/NemoClaw $NEMOCLAW_TAG"
  [[ "$(git -C "$FORK" rev-parse HEAD)" == "$NEMOCLAW_COMMIT"* ]] || die "El tag $NEMOCLAW_TAG ya no apunta a $NEMOCLAW_COMMIT; revisa antes de seguir."
  git -C "$FORK" switch -q -c hermes-v0.23.0
  git -C "$FORK" apply "$REPO/fork/hermes-v023.patch" || die "El parche no aplica sobre $NEMOCLAW_TAG"
  cp "$REPO/fork/Dockerfile.hermes-v023" "$FORK/"
  ok "Fork creado"
else
  git -C "$FORK" apply --reverse --check "$REPO/fork/hermes-v023.patch" 2>/dev/null \
    || die "$FORK existe pero no tiene aplicado fork/hermes-v023.patch. Muévelo a otro lado y vuelve a correr."
  cmp -s "$REPO/fork/Dockerfile.hermes-v023" "$FORK/Dockerfile.hermes-v023" || die "El Dockerfile del fork no coincide con fork/Dockerfile.hermes-v023"
  ok "Fork ya está y coincide con el parche"
fi

# ── 5. Imagen base de Hermes v0.23 ─────────────────────────────────────────────────────────────
paso "5. Imagen base $BASE_IMG"
if docker image inspect "$BASE_IMG" >/dev/null 2>&1; then
  ok "La imagen base ya existe"
else
  echo "    Construyendo la imagen base: la primera vez tarda unos 30 min."
  (cd "$FORK" && docker build -f agents/hermes/Dockerfile.base -t "$BASE_IMG" .) || die "Falló el build de la imagen base"
  ok "Imagen base construida"
fi

# ── 6. Sandbox ─────────────────────────────────────────────────────────────────────────────────
paso "6. Sandbox $SB (onboarding no interactivo desde el fork)"
fase() { openshell sandbox get "$SB" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | awk '/Phase:/{print $2; exit}'; }
if [[ -n "$(fase)" ]]; then
  [[ "$(fase)" == Ready ]] || die "El sandbox $SB existe pero está en fase $(fase). Ver GUIA (sección de recuperación)."
  ok "El sandbox ya existe y está Ready"
else
  echo "    El onboarding acepta el aviso de software de terceros de NemoClaw (lo muestra su instalador)."
  si "¿Lo aceptas?" || die "Sin aceptar el aviso no se puede crear el sandbox."
  key="${NVIDIA_INFERENCE_API_KEY:-}"
  [[ -n "$key" ]] || read -r -s -p "    Key de NVIDIA (nvapi-..., no se muestra ni se guarda): " key </dev/tty; echo
  [[ "$key" == nvapi-* ]] || die "La key debe empezar por nvapi-"
  KEY_SHA=$(printf %s "$key" | shasum -a 256 | cut -d' ' -f1)
  (cd "$FORK" && NVIDIA_INFERENCE_API_KEY="$key" NEMOCLAW_NON_INTERACTIVE=1 NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 \
     NEMOCLAW_PROVIDER=build NEMOCLAW_MODEL="$MODELO" NEMOCLAW_SANDBOX_NAME="$SB" NEMOCLAW_WEB_SEARCH_PROVIDER=none \
     NEMOCLAW_POLICY_TIER=balanced NEMOCLAW_POLICY_MODE=custom NEMOCLAW_POLICY_PRESETS="$PRESETS" \
     NEMOCLAW_CPU="$SANDBOX_CPU" NEMOCLAW_DASHBOARD_PORT="$PUERTO_DASHBOARD" NEMOCLAW_HERMES_API_PORT="$PUERTO_API" \
     nemohermes onboard --fresh --non-interactive --yes-i-accept-third-party-software \
       --from "$FORK/Dockerfile.hermes-v023" --name "$SB") || { unset key; die "El onboarding falló"; }
  unset key
  [[ "$(fase)" == Ready ]] || die "Tras el onboarding el sandbox no está Ready"
  ok "Sandbox creado"
fi
[[ "$(salud)" == 200 ]] || die "El gateway de Hermes no responde en el sandbox"
ok "Gateway sano"

# ── 7. Red y Policy Advisor ────────────────────────────────────────────────────────────────────
paso "7. Red: presets exactos y Policy Advisor (manual)"
openshell settings set "$SB" --key agent_policy_proposals_enabled --value true >/dev/null || die "settings proposals"
openshell settings set "$SB" --key ocsf_json_enabled --value true >/dev/null || die "settings ocsf"
ok "Propuestas de red y OCSF JSON encendidos; proposal_approval_mode sin definir (= manual)"
activos=$(nemohermes "$SB" status 2>/dev/null | awk -F': ' '/Policies:/{print $2; exit}' | tr -d ' ')
for p in $(echo "$PRESETS" | tr ',' ' '); do
  [[ ",$activos," == *",$p,"* ]] || { nemohermes "$SB" policy add "$p" --yes >/dev/null || die "policy add $p"; ok "preset $p añadido"; }
done
for p in $(echo "$activos" | tr ',' ' '); do
  [[ ",$PRESETS," == *",$p,"* ]] || { nemohermes "$SB" policy remove "$p" --yes >/dev/null || die "policy remove $p"; ok "preset $p quitado"; }
done
ok "Presets: $(nemohermes "$SB" status 2>/dev/null | awk -F': ' '/Policies:/{print $2; exit}')"

# ── 8. SOUL, AGENTS y skills ───────────────────────────────────────────────────────────────────
paso "8. SOUL.md, AGENTS.md y skills"
[[ "$(sha_remoto /sandbox/.hermes/SOUL.md)" == "$(sha_local "$REPO/hermes/SOUL.md")" ]] || subir "$REPO/hermes/SOUL.md" /sandbox/.hermes/
[[ "$(sha_remoto /sandbox/AGENTS.md)" == "$(sha_local "$REPO/hermes/AGENTS.md")" ]] || subir "$REPO/hermes/AGENTS.md" /sandbox/
[[ "$(sha_remoto /sandbox/.hermes/SOUL.md)" == "$(sha_local "$REPO/hermes/SOUL.md")" ]] || die "SOUL.md no quedó igual"
ok "SOUL.md $(sha_local "$REPO/hermes/SOUL.md") y AGENTS.md $(sha_local "$REPO/hermes/AGENTS.md")"
lista=$(nemohermes "$SB" skill list 2>/dev/null)
for d in "$REPO"/hermes/skills/*/; do
  s=$(basename "$d")
  if grep -q "│ ${s:0:20}" <<<"$lista"; then ok "skill $s ya está"
  else nemohermes "$SB" skill install "$d" >/dev/null 2>&1 || die "skill install $s"; ok "skill $s instalada"; fi
done

# ── 9. Plugin reglas_codigo y config.yaml ──────────────────────────────────────────────────────
paso "9. Plugin reglas_codigo, config.yaml y permisos"
sx 'ls /sandbox/.hermes/installs/*/facts.json' >/dev/null 2>&1 \
  && die "Existe /sandbox/.hermes/installs/*/facts.json: el gateway arrancaría con un entorno sin aiohttp (ver GUIA, caída del 2026-11-09)."
[[ "$(sha_remoto /sandbox/.hermes/plugins/reglas_codigo/__init__.py)" == "$(sha_local "$REPO/hermes/plugins/reglas_codigo/__init__.py")" ]] \
  || { sx 'mkdir -p /sandbox/.hermes/plugins' >/dev/null; subir "$REPO/hermes/plugins/reglas_codigo" /sandbox/.hermes/plugins/; }
ok "Plugin en /sandbox/.hermes/plugins/reglas_codigo"
# Se activa editando config.yaml, NUNCA con `hermes plugins enable`: ese comando re-sincroniza el entorno de Python
# de Hermes sin el extra del servidor de API (sin aiohttp) y el próximo reinicio deja el sandbox caído.
sx 'cat /sandbox/.hermes/config.yaml' > "$TMPD/config.yaml" || die "No pude leer config.yaml"
cambio=0
# Hermes reescribe config.yaml a su gusto (sangría de 2 o 4 en las listas): se detecta con cualquier sangría y el
# nuevo elemento copia la del primer elemento de plugins.enabled.
if ! awk '/^plugins:/{p=1;next} p&&/^[^ ]/{p=0} p&&/^ *- reglas_codigo$/{f=1} END{exit !f}' "$TMPD/config.yaml"; then
  awk '/^plugins:/{p=1; print; next} p&&/^[^ ]/{p=0}
       p&&/^  enabled:$/{en=1; print; next}
       p&&en&&!e&&/^ *- /{print; match($0,/^ */); printf "%s- reglas_codigo\n", substr($0,1,RLENGTH); e=1; next}
       {print} END{if(!e) exit 1}' \
    "$TMPD/config.yaml" > "$TMPD/c2" || die "config.yaml no tiene plugins.enabled"
  mv "$TMPD/c2" "$TMPD/config.yaml"; cambio=1
fi
if ! grep -q '^telemetry:' "$TMPD/config.yaml"; then
  printf 'telemetry:\n  shared_metrics:\n    enabled: false\n    send: false\n    offer_version: 2\n' >> "$TMPD/config.yaml"; cambio=1
fi
if (( cambio )); then
  sx 'cp /sandbox/.hermes/config.yaml /sandbox/.hermes/config.yaml.antes-instalar' >/dev/null
  subir "$TMPD/config.yaml" /sandbox/.hermes/
  ok "config.yaml: reglas_codigo en plugins.enabled y telemetría apagada (copia en config.yaml.antes-instalar)"
fi
sx 'cd /opt/hermes && HERMES_HOME=/sandbox/.hermes /opt/hermes/.venv/bin/python -B -c "
from hermes_cli.config import load_config_readonly as l
c = l(); assert \"reglas_codigo\" in c[\"plugins\"][\"enabled\"]; assert c[\"telemetry\"][\"shared_metrics\"][\"enabled\"] is False
print(\"ok\")"' | grep -qx ok || die "Hermes no lee bien el config.yaml nuevo"
# El Dockerfile pone .hermes en 3770; con el grupo sandbox compartido, `hermes webapp` se niega a arrancar.
sx 'chmod g-w /sandbox/.hermes && chmod 640 /sandbox/.hermes/config.yaml' >/dev/null || die "chmod en .hermes"
ok "Permisos: .hermes 3750, config.yaml 640"

# Hay que reiniciar el gateway si arrancó antes del último cambio de config.yaml (así carga el plugin).
gateway_al_dia() {   # inicio del proceso = btime + starttime/CLK_TCK (la fecha de /proc/<pid> no es fiable)
  sx 'p=$(pgrep -f "hermes.real gateway run" | head -1); [ -n "$p" ] || exit 1
      ini=$(( $(awk "/^btime/{print \$2}" /proc/stat) + $(awk "{print \$22}" /proc/$p/stat) / $(getconf CLK_TCK) ))
      [ "$ini" -ge "$(stat -c %Y /sandbox/.hermes/config.yaml)" ]' >/dev/null 2>&1
}
if gateway_al_dia; then
  ok "El gateway ya arrancó con este config.yaml"
else
  echo "    Reiniciando el gateway para cargar el plugin (el CLI a veces se queda esperando; el script lo vigila)."
  nemohermes "$SB" gateway restart > "$TMPD/restart.log" 2>&1 &
  rpid=$!
  for _ in $(seq 1 60); do   # hasta 5 min, termine o no el CLI
    sleep 5
    if gateway_al_dia && [[ "$(salud)" == 200 ]]; then break; fi
  done
  kill $rpid 2>/dev/null; wait $rpid 2>/dev/null
  gateway_al_dia && [[ "$(salud)" == 200 ]] || { cat "$TMPD/restart.log" >&2; die "El gateway no volvió sano tras el reinicio"; }
  ok "Gateway reiniciado y sano"
fi
nemohermes "$SB" exec -- sh -c 'HERMES_HOME=/sandbox/.hermes /usr/local/bin/hermes plugins list 2>/dev/null' 2>/dev/null \
  | grep -E "reglas_codigo +│ enabled" >/dev/null && ok "Plugin reglas_codigo activo" || die "reglas_codigo no aparece activo"

# ── 10. Proyecto de pruebas /sandbox/requests ──────────────────────────────────────────────────
if (( CON_REQUESTS )); then
  paso "10. Proyecto de pruebas /sandbox/requests (psf/requests $REQUESTS_TAG, limpio)"
  if sx 'test -d /sandbox/requests/.git' >/dev/null 2>&1; then
    ok "/sandbox/requests ya existe (no se toca)"
  else
    git clone -q --branch "$REQUESTS_TAG" https://github.com/psf/requests.git "$TMPD/requests" 2>/dev/null || die "No pude clonar psf/requests"
    # `upload` omite las carpetas .git, así que va en un tar; COPYFILE_DISABLE evita los ._* de macOS.
    COPYFILE_DISABLE=1 tar -czf "$TMPD/requests.tgz" -C "$TMPD" requests || die "tar de requests"
    subir "$TMPD/requests.tgz" /sandbox/.hermes/cache/scratch/
    sx 'tar -xzf /sandbox/.hermes/cache/scratch/requests.tgz -C /sandbox && rm -f /sandbox/.hermes/cache/scratch/requests.tgz && cd /sandbox/requests && git log --oneline -1' \
      | tail -1 | grep -q . || die "No quedó /sandbox/requests"
    ok "/sandbox/requests en $REQUESTS_TAG"
  fi
fi

# ── 11. context7 ───────────────────────────────────────────────────────────────────────────────
c7_herramientas() { nemohermes "$SB" mcp status context7 --tools 2>/dev/null | grep -c -E -- "- (query-docs|resolve-library-id)$"; }
if (( CON_CONTEXT7 )); then
  paso "11. MCP context7 (OpenShell protocol: mcp)"
  if nemohermes "$SB" mcp list 2>/dev/null | grep -q context7; then
    ok "context7 ya está registrado"
  elif si "¿Registrar context7? Necesitas su key (context7.com)."; then
    prov="$SB-mcp-context7"
    if openshell provider get "$prov" >/dev/null 2>&1; then
      aviso "Existe el proveedor $prov de un sandbox anterior; NemoClaw no registra encima de él."
      si "¿Lo borro? (vas a escribir la key otra vez)" || die "Sin borrarlo no se puede registrar context7."
      openshell provider delete "$prov" >/dev/null || die "No pude borrar $prov"
    fi
    read -r -s -p "    Key de context7 (no se muestra ni se guarda): " CONTEXT7_API_KEY </dev/tty; echo
    export CONTEXT7_API_KEY
    nemohermes "$SB" mcp add context7 --url https://mcp.context7.com/mcp --env CONTEXT7_API_KEY
    unset CONTEXT7_API_KEY
    nemohermes "$SB" mcp list 2>/dev/null | grep -q context7 || die "context7 no quedó registrado"
    ok "context7 registrado"
  else
    aviso "context7 omitido"
  fi
  if nemohermes "$SB" mcp list 2>/dev/null | grep -q context7; then
    # Bug del fork: la regla generada autoriza /opt/hermes/.venv/bin/python* (glob), que no resuelve el symlink al
    # python real y da 403. Se deja el python exacto (OpenShell sí resuelve symlinks en rutas exactas) y se quita python3*.
    openshell policy get "$SB" --base 2>/dev/null | sed '1,/^---$/d' > "$TMPD/base.yaml"
    awk '/^  mcp_bridge_context7:$/{s=1; print; next}
         s && /^  [^ ]/{s=0}
         s && $0=="    - path: /usr/bin/python3*"{next}
         s && $0=="    - path: /opt/hermes/.venv/bin/python*"{print "    - path: /opt/hermes/.venv/bin/python"; next}
         {print}' "$TMPD/base.yaml" > "$TMPD/parche.yaml"
    if cmp -s "$TMPD/base.yaml" "$TMPD/parche.yaml"; then
      ok "La regla de context7 ya tiene los binarios exactos"
    else
      grep -q '^  mcp_bridge_context7:$' "$TMPD/parche.yaml" || die "No encontré mcp_bridge_context7 en la política"
      openshell policy set "$SB" --policy "$TMPD/parche.yaml" --wait >/dev/null || die "policy set falló"
      nemohermes "$SB" mcp restart context7 >/dev/null 2>&1
      sleep 5
      ok "Política de context7 parcheada"
    fi
    [[ "$(c7_herramientas)" == 2 ]] && ok "context7 responde: query-docs y resolve-library-id" \
      || aviso "context7 no lista sus 2 herramientas; prueba: nemohermes $SB mcp restart context7"
  fi
fi

# ── 12. Webapp ─────────────────────────────────────────────────────────────────────────────────
paso "12. Webapp (puerto $PUERTO_WEBAPP, reenvío manual)"
web() { curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PUERTO_WEBAPP/" 2>/dev/null; }
if [[ "$(web)" != 200 ]]; then
  nohup openshell forward service --target-port 9120 --local "127.0.0.1:$PUERTO_WEBAPP" "$SB" >/dev/null 2>&1 &
  sleep 4
fi
[[ "$(web)" == 200 ]] && ok "Webapp en http://127.0.0.1:$PUERTO_WEBAPP/ (repetir el reenvío tras reiniciar la Mac)" \
  || aviso "La Webapp no responde en $PUERTO_WEBAPP"

# ── 13. Batería de aislamiento ─────────────────────────────────────────────────────────────────
if (( CON_BATERIA )); then
  paso "13. Batería de aislamiento"
  pend() { openshell rule get "$SB" --status pending 2>&1 | grep 'Chunk:' | grep -oE '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}' | tr '\n' ' '; }
  antes=" $(pend)"
  KEY_SHA="$KEY_SHA" bash "$REPO/pruebas/correr-aislamiento.sh" "$SB" > "$TMPD/bateria.txt" 2>&1; brc=$?
  sed $'s/\x1b\\[[0-9;]*m//g' "$TMPD/bateria.txt" | grep -E "^\s+(FAIL|NOTA RIESGO)|Resultado:" | cut -c1-150
  # Las propuestas nuevas son de los bloqueos que provoca la batería: se rechazan una por una. El ruido de fondo de
  # Hermes (llamadas a catálogos de modelos) se deja pendiente, como en la máquina original.
  openshell rule get "$SB" --status pending 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g' | awk -v RS="" '/Chunk:/{gsub(/[ \t\n]+/," "); print}' \
    > "$TMPD/pend.txt"
  n=0
  while IFS= read -r bloque; do
    id=$(grep -oE '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}' <<<"$bloque" | head -1)
    [[ -z "$id" || "$antes" == *" $id "* ]] && continue
    ruido=0; for h in $RUIDO_DE_FONDO; do [[ "$bloque" == *"Endpoints: $h:"* ]] && ruido=1; done
    (( ruido )) && continue
    openshell rule reject "$SB" --chunk-id "$id" --reason "bloqueo provocado por la batería de aislamiento (instalar.sh)" >/dev/null && n=$((n+1))
  done < "$TMPD/pend.txt"
  ok "$n propuestas de la batería rechazadas; pendientes: $(pend | wc -w | tr -d ' ') (ruido de fondo de Hermes)"
  (( brc == 0 )) || die "La batería tiene FAIL; detalle en la salida de arriba"
fi

# ── Fin ────────────────────────────────────────────────────────────────────────────────────────
paso "Listo"
cat <<EOF
    Sandbox:    $SB ($(fase)), Hermes v0.23.0, modelo $MODELO
    Dashboard:  http://127.0.0.1:$PUERTO_DASHBOARD/
    API:        http://127.0.0.1:$PUERTO_API/v1   (clave: nemohermes $SB gateway-token --quiet)
    Webapp:     http://127.0.0.1:$PUERTO_WEBAPP/   (reenvío: nohup openshell forward service --target-port 9120 --local 127.0.0.1:$PUERTO_WEBAPP $SB >/dev/null 2>&1 &)
    Estado:     nemohermes $SB status
    No uses \`hermes plugins enable/disable\` ni \`nemohermes $SB rebuild\` en este sandbox (ver GUIA).
EOF
if (( CON_LINK )) && si "¿Generar ahora el enlace de entrada a la Webapp (un solo uso, 60 s)?"; then
  nemohermes "$SB" exec -- hermes webapp --no-open --skip-build 2>&1 | grep -v 'install out of sync\|OCSF'
fi
