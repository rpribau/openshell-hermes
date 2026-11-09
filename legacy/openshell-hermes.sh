#!/usr/bin/env bash
# RETIRADO: montaje manual previo a NemoClaw; se conserva para consulta. Ver ../GUIA-NEMOCLAW-HERMES.md
# Hermes Agent dentro de NVIDIA OpenShell (sin NemoClaw), usando Nemotron vía
# NVIDIA API. Pensado para esta Mac: Homebrew en /opt/homebrew, Colima como
# Docker, y Hermes ya instalado en ~/.hermes (de ahí se toma la API key).
#
# Orden (sin sudo, desde esta carpeta):
#   ./openshell-hermes.sh colima      # 1. arranca Colima con la imagen local (sin descargar de GitHub)
#   ./openshell-hermes.sh install     # 2. instala OpenShell 0.1.7 desde ./vendor y configura el gateway
#   ./openshell-hermes.sh gateway     #    (solo) registra el gateway local en la CLI y espera a que responda
#   ./openshell-hermes.sh network     #    (solo) reescribe gateway.toml para que los sandboxes de Colima alcancen el gateway
#   ./openshell-hermes.sh build       # 3. construye la imagen hermes-sbx:local
#   ./openshell-hermes.sh setup       # 4. perfil + provider (key de ./.env: API_KEY / ENDPOINT; si no, de tu Hermes)
#   ./openshell-hermes.sh smoke       # 5. curl a /v1/models desde el sandbox
#   ./openshell-hermes.sh probe       #    prueba qué modelos de chat responden con tu key
#   ./openshell-hermes.sh ask "..."   # 6. Hermes one-shot (hermes -z) en sandbox
#   ./openshell-hermes.sh chat        #    Hermes interactivo (TUI) en sandbox
#   ./openshell-hermes.sh project ~/repo  # sube un repo a /workspace; ahí corre: hermes-sbx
#   ./openshell-hermes.sh doctor      # diagnóstico de todo lo anterior
#   ./openshell-hermes.sh rules <sandbox> | logs <sandbox> | clean
#
# Variables: MODEL (o MODEL= en ./.env; default nvidia/nemotron-3.5-lightning-30b-a3b), IMAGE, PROVIDER,
#            HERMES_ENV_FILE (default ~/.hermes/.env), COLIMA_CPU/COLIMA_MEM/COLIMA_DISK

set -euo pipefail
cd "$(dirname "$0")"
DIR="$PWD"

if [[ $EUID -eq 0 ]]; then
  echo "[!] No corras este script con sudo: Homebrew, el gateway de OpenShell y Colima deben ser de tu usuario." >&2
  exit 1
fi

IMAGE="${IMAGE:-hermes-sbx:local}"
PROVIDER="${PROVIDER:-nvidia-hermes-prod}"
PROFILE_FILE="nvidia-hermes.yaml"
HERMES_ENV_FILE="${HERMES_ENV_FILE:-${HERMES_HOME:-$HOME/.hermes}/.env}"
PROJECT_ENV="$DIR/../.env"   # (vive en la raíz del proyecto) API_KEY=nvapi-...  y  ENDPOINT=https://integrate.api.nvidia.com/v1

# Lee una variable de un .env SIN ejecutarlo (no usa `source`).
env_get() {
  local file="$1" name="$2"
  [[ -f "$file" ]] || return 0
  grep -E "^[[:space:]]*(export[[:space:]]+)?${name}[[:space:]]*=" "$file" | tail -1 \
    | sed -E 's/^[^=]*=//; s/^[[:space:]]+//; s/[[:space:]]+$//; s/\r$//; s/^["'\'']//; s/["'\'']$//' || true
}

API="$(env_get "$PROJECT_ENV" ENDPOINT)"; API="${API:-https://integrate.api.nvidia.com/v1}"; API="${API%/}"
case "$API" in
  https://integrate.api.nvidia.com/*) ;;
  *) echo "[!] ENDPOINT=$API no es integrate.api.nvidia.com: actualiza 'host' en nvidia-hermes.yaml o OpenShell lo bloqueará." >&2 ;;
esac
# Modelo: variable de la terminal > MODEL= en ./.env > default
MODEL="${MODEL:-$(env_get "$PROJECT_ENV" MODEL)}"; MODEL="${MODEL:-nvidia/nemotron-3.5-lightning-30b-a3b}"
PROBE_MODELS="${PROBE_MODELS:-nvidia/nemotron-3-super-120b-a12b nvidia/nemotron-3-ultra-550b-a55b nvidia/nemotron-3.5-lightning-30b-a3b nvidia/nemotron-nano-3-30b-a3b nvidia/nemotron-3-nano-omni-30b-a3b-reasoning nvidia/nemotron-3.5-bolt-e4b nvidia/nemotron-3.5-super-vl-120b-a12b nvidia/llama-3.1-nemotron-ultra-253b-v1 nvidia/llama-3.1-nemotron-70b-instruct}"
SANDBOXES="hermes-smoke hermes-probe hermes-ask hermes-chat hermes-project"

COLIMA_IMG="$DIR/ubuntu-24.04-minimal-cloudimg-arm64-docker.raw.gz"
COLIMA_IMG_SHA512="32242674b046b5057e60c4aba334b51e3665f05412cda89ed081cc2de153ae5c41f6b105b5c442cbe48d78e2cc21e9ba1950e406b6fb4fc2fd1dd2259240abbd"
COLIMA_SOCK="$HOME/.colima/default/docker.sock"
OS_VERSION="0.1.7"
OS_RELEASE_URL="https://github.com/NVIDIA/OpenShell/releases/download/v${OS_VERSION}/"
GATEWAY_TOML="$HOME/.config/openshell/gateway.toml"

export HOMEBREW_NO_AUTO_UPDATE=1   # evita el auto-update lento de brew en cada install

say()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { warn "$*"; exit 1; }
fresh() { openshell sandbox delete "$1" >/dev/null 2>&1 || true; }

# ---------------------------------------------------------------- 1. Colima
cmd_colima() {
  command -v colima >/dev/null || die "Falta colima: brew install colima docker docker-buildx"
  if colima status >/dev/null 2>&1; then
    say "Colima ya está corriendo"
  elif [[ -d "$HOME/.colima/_lima/colima" ]]; then
    say "La VM de Colima ya existe; arrancándola"
    colima start
  else
    if [[ ! -f "$COLIMA_IMG" ]]; then
      compgen -G "colima-parts/ubuntu-img.part*" >/dev/null || die "No encuentro $COLIMA_IMG ni colima-parts/"
      say "Uniendo colima-parts/ en $(basename "$COLIMA_IMG")"
      # El glob ordena alfabéticamente: part00..part02, part03a, part03b, part04..part07
      cat colima-parts/ubuntu-img.part* > "$COLIMA_IMG"
    fi
    say "Verificando hash de la imagen de Colima (unos segundos)"
    [[ "$(shasum -a 512 "$COLIMA_IMG" | cut -d' ' -f1)" == "$COLIMA_IMG_SHA512" ]] \
      || die "El hash no coincide: la imagen está corrupta o es otra versión."
    say "Creando VM de Colima con la imagen local (sin descargar nada)"
    colima start --cpu "${COLIMA_CPU:-4}" --memory "${COLIMA_MEM:-8}" --disk "${COLIMA_DISK:-60}" \
      --disk-image "$COLIMA_IMG"
  fi
  docker context use colima >/dev/null 2>&1 || true
  docker info --format 'Docker {{.ServerVersion}} en {{.OperatingSystem}} ({{.NCPU}} CPU, {{.MemTotal}} bytes RAM)'
  [[ -S "$COLIMA_SOCK" ]] && echo "Socket: $COLIMA_SOCK"
}

# ---------------------------------------------------------------- 2. OpenShell
colima_host_ip() {
  # IP con la que la VM de Colima alcanza el localhost de tu Mac (Lima: host.lima.internal).
  local ip
  ip=$(colima ssh -- getent ahostsv4 host.lima.internal 2>/dev/null | awk 'NR==1{print $1}') || true
  echo "${ip:-192.168.5.2}"
}

write_gateway_toml() {
  mkdir -p "$(dirname "$GATEWAY_TOML")"
  if [[ -f "$GATEWAY_TOML" ]] && ! grep -q 'generado por openshell-hermes.sh' "$GATEWAY_TOML"; then
    warn "Ya existe $GATEWAY_TOML (no lo toco). Asegúrate de que apunte a $COLIMA_SOCK."
    return
  fi
  local hip; hip=$(colima_host_ip)
  echo "La VM de Colima ve tu Mac en: $hip"
  if colima ssh -- timeout 5 bash -c "</dev/tcp/$hip/17670" 2>/dev/null; then
    echo "Desde la VM sí se alcanza el gateway en $hip:17670"
  else
    warn "Desde la VM no se alcanza $hip:17670 (¿gateway detenido?). Sigo, pero revisa después."
  fi
  # Sin esto el supervisor (red host de la VM) usa https://127.0.0.1:17670, que dentro de
  # Colima es la VM y no tu Mac. host.openshell.internal ya está en el certificado del gateway.
  cat > "$GATEWAY_TOML" <<EOF
# generado por openshell-hermes.sh: gateway local usando el Docker de Colima
[openshell]
version = 2

[openshell.gateway]
compute_driver = "docker"

[openshell.drivers.docker]
socket_path = "$COLIMA_SOCK"
grpc_endpoint = "https://host.openshell.internal:17670"
host_gateway_ip = "$hip"
EOF
  echo "Escrito $GATEWAY_TOML"
}

configure_gateway() {
  say "Configurando gateway para usar Colima"
  write_gateway_toml
  openshell-gateway config preflight --path "$GATEWAY_TOML" || warn "preflight reportó algo; revisa arriba"
  brew services restart openshell
}

cmd_network() {
  colima status >/dev/null 2>&1 || die "Colima no está corriendo: ./openshell-hermes.sh colima"
  configure_gateway
  cmd_gateway
  fresh hermes-smoke
}

cmd_install() {
  command -v brew >/dev/null || die "Falta Homebrew"
  docker info >/dev/null 2>&1 || die "Docker (Colima) no responde. Corre primero: ./openshell-hermes.sh colima"

  if brew list --formula nvidia/openshell/openshell >/dev/null 2>&1 || brew list --formula openshell >/dev/null 2>&1; then
    say "OpenShell ya está instalado: $(openshell --version 2>/dev/null || echo '?')"
  else
    [[ -f vendor/openshell.rb ]] || die "Falta vendor/openshell.rb"
    say "Verificando paquetes de OpenShell en ./vendor"
    (cd vendor && shasum -a 256 -c SHA256SUMS)

    say "Preparando tap local nvidia/openshell con fórmula que apunta a ./vendor"
    local tap; tap="$(brew --repository)/Library/Taps/nvidia/homebrew-openshell"
    [[ -d "$tap" ]] || brew tap-new --no-git nvidia/openshell >/dev/null
    mkdir -p "$tap/Formula"
    sed "s#${OS_RELEASE_URL}#file://${DIR}/vendor/#g" vendor/openshell.rb > "$tap/Formula/openshell.rb"
    grep -c "file://" "$tap/Formula/openshell.rb" | xargs -I{} echo "{} URLs locales en la fórmula"

    say "Instalando OpenShell ${OS_VERSION} (local, sin descargas)"
    brew install nvidia/openshell/openshell
  fi

  configure_gateway
  cmd_gateway
}

gateway_ok() {
  local out
  out=$(openshell status 2>&1) || return 1
  ! grep -qiE 'no gateway configured|unreachable|error|refused' <<<"$out"
}

cmd_gateway() {
  say "Registrando el gateway local en la CLI (https://localhost:17670)"
  # Tras un restart el gateway tarda unos segundos; esperar evita re-registrarlo en vano.
  for _ in $(seq 1 10); do gateway_ok && break; sleep 1; done
  if gateway_ok; then
    echo "Ya estaba registrado."
  elif openshell gateway list 2>/dev/null | grep -qE '(^|[[:space:]])openshell([[:space:]]|$)'; then
    echo "Registro 'openshell' ya existe; esperando a que el gateway levante."
    openshell gateway select openshell >/dev/null 2>&1 || true
  else
    # Si ya existe un registro con ese nombre, add falla y no pasa nada.
    openshell gateway add https://localhost:17670 --local --name openshell || true
    openshell gateway select openshell >/dev/null 2>&1 || true
  fi
  say "Esperando a que responda"
  for _ in $(seq 1 30); do gateway_ok && break; sleep 1; done
  openshell status
  gateway_ok || {
    warn "El gateway no responde o no está registrado. Registros y logs:"
    openshell gateway list || true
    tail -n 30 "$(brew --prefix)/var/log/openshell/openshell-gateway.err.log" 2>/dev/null || true
    exit 1
  }
}

# ---------------------------------------------------------------- 3-4. Imagen y provider
cmd_build() {
  docker info >/dev/null 2>&1 || die "Docker (Colima) no responde. Corre: ./openshell-hermes.sh colima"
  say "Construyendo $IMAGE (descarga python:3.12-slim de Docker Hub y Hermes de PyPI)"
  docker build -t "$IMAGE" -f Dockerfile.hermes .
  say "Verificando Hermes dentro de la imagen (sin red ni key)"
  docker run --rm --network none "$IMAGE" hermes-sbx --version
}

hermes_python() {
  # Intérprete del Hermes del host (el de su venv), leído del shebang de `hermes`.
  local h py
  h=$(command -v hermes 2>/dev/null) || h=""
  if [[ -n "$h" ]]; then
    py=$(head -1 "$h" | sed -nE 's/^#!(.*python[0-9.]*)$/\1/p')
    [[ -n "$py" && -x "$py" ]] && { echo "$py"; return; }
  fi
  for py in "$HOME/.hermes/hermes-agent/venv/bin/python" "$HOME/.hermes/hermes-agent/.venv/bin/python"; do
    [[ -x "$py" ]] && { echo "$py"; return; }
  done
  return 1
}

key_from_hermes() {
  # Usa el propio código de Hermes para resolver la credencial del proveedor "nvidia"
  # (env, ~/.hermes/.env o credential pool de `hermes auth`). No imprime la key.
  local py; py=$(hermes_python) || return 1
  "$py" -c 'import sys, logging; logging.disable(logging.CRITICAL)
from hermes_cli.auth import resolve_api_key_provider_credentials as r
sys.stdout.write((r("nvidia").get("api_key") or "").strip())' 2>/dev/null
}

load_key() {
  # Orden: terminal > ./.env (API_KEY o NVIDIA_API_KEY) > ~/.hermes/.env > credential pool de Hermes
  local src="entorno de la terminal" v
  if [[ "${NVIDIA_API_KEY:-}" != nvapi-* ]]; then
    v="$(env_get "$PROJECT_ENV" NVIDIA_API_KEY)"; [[ -n "$v" ]] || v="$(env_get "$PROJECT_ENV" API_KEY)"
    export NVIDIA_API_KEY="$v"; src="$PROJECT_ENV"
  fi
  if [[ "${NVIDIA_API_KEY:-}" != nvapi-* ]]; then
    NVIDIA_API_KEY="$(env_get "$HERMES_ENV_FILE" NVIDIA_API_KEY)"; export NVIDIA_API_KEY; src="$HERMES_ENV_FILE"
  fi
  if [[ "${NVIDIA_API_KEY:-}" != nvapi-* ]]; then
    NVIDIA_API_KEY="$(key_from_hermes || true)"; export NVIDIA_API_KEY; src="Hermes (credential pool / config)"
  fi
  if [[ "${NVIDIA_API_KEY:-}" != nvapi-* ]]; then
    warn "No pude obtener la key de NVIDIA desde Hermes."
    warn "Revisa con: hermes auth list   (proveedor 'nvidia')"
    warn "O expórtala a mano solo para este paso: export NVIDIA_API_KEY='nvapi-...'"
    exit 1
  fi
  echo "Key encontrada vía $src (${NVIDIA_API_KEY:0:9}…), solo en el entorno de este proceso."
}

cmd_setup() {
  load_key
  say "Importando perfil $PROFILE_FILE"
  if openshell profile lint -f "$PROFILE_FILE" 2>/dev/null; then
    openshell profile import -f "$PROFILE_FILE"
  else
    openshell provider profile lint -f "$PROFILE_FILE"
    openshell provider profile import -f "$PROFILE_FILE" --global
  fi
  say "Creando provider $PROVIDER (OpenShell lee NVIDIA_API_KEY del entorno)"
  openshell provider create --name "$PROVIDER" --type nvidia-hermes --from-existing
}

# ---------------------------------------------------------------- 5-6. Pruebas
cmd_smoke() {
  fresh hermes-smoke
  say "Sandbox hermes-smoke: modelos Nemotron disponibles"
  openshell sandbox create --name hermes-smoke --from "$IMAGE" --provider "$PROVIDER" -- \
    sh -c "curl -sS $API/models -H \"Authorization: Bearer \$NVIDIA_API_KEY\" | tr ',' '\n' | grep -o '\"id\":\"[^\"]*nemotron[^\"]*\"' | sort -u"
}

cmd_probe() {
  fresh hermes-probe
  say "Sandbox hermes-probe: ¿qué modelos de chat responden con tu key? (unos segundos por modelo)"
  # shellcheck disable=SC2016  # $NVIDIA_API_KEY, $API y $PROBE_MODELS se expanden DENTRO del sandbox
  openshell sandbox create --name hermes-probe --from "$IMAGE" --provider "$PROVIDER" \
    --env "API=$API" --env "PROBE_MODELS=$PROBE_MODELS" -- sh -c '
    for m in $PROBE_MODELS; do
      rm -f /tmp/r.json
      body=$(printf "{\"model\":\"%s\",\"messages\":[{\"role\":\"user\",\"content\":\"Responde solo: OK\"}],\"max_tokens\":32}" "$m")
      code=$(curl -sS -m 90 -o /tmp/r.json -w "%{http_code}" "$API/chat/completions" \
        -H "Authorization: Bearer $NVIDIA_API_KEY" -H "Content-Type: application/json" -d "$body" 2>/dev/null) || code="ERR(curl $?)"
      if [ "$code" = 200 ]; then echo "  OK   $m"; else echo "  $code  $m  $(head -c 110 /tmp/r.json 2>/dev/null | tr -d "\n")"; fi
    done'
  echo
  echo "Fija el que quieras en .env (línea MODEL=...) o úsalo una vez: MODEL=<id> ./openshell-hermes.sh ask"
}

cmd_ask() {
  local prompt="${1:-Responde en español en una línea: ¿qué modelo eres y en qué entorno estás corriendo? Ejecuta uname -a para comprobarlo.}"
  fresh hermes-ask
  say "Sandbox hermes-ask: hermes -z con $MODEL"
  openshell sandbox create --name hermes-ask --from "$IMAGE" --provider "$PROVIDER" --env "NVIDIA_BASE_URL=$API" --env "HERMES_SBX_MODEL=$MODEL" -- \
    hermes-sbx --provider nvidia -m "$MODEL" -z "$prompt"
}

cmd_chat() {
  fresh hermes-chat
  say "Sandbox hermes-chat: Hermes interactivo con $MODEL (sal con /exit o Ctrl+D)"
  openshell sandbox create --name hermes-chat --from "$IMAGE" --provider "$PROVIDER" --env "NVIDIA_BASE_URL=$API" --env "HERMES_SBX_MODEL=$MODEL" -- \
    hermes-sbx --provider nvidia -m "$MODEL"
}

cmd_project() {
  local dir="${1:?Pasa la carpeta del proyecto}"
  fresh hermes-project
  say "Subiendo $dir a /workspace (respeta .gitignore). En la shell que abre, ejecuta: hermes-sbx"
  echo "Para bajar cambios desde otra terminal: openshell sandbox download (ver --help)"
  openshell sandbox create --name hermes-project --from "$IMAGE" --provider "$PROVIDER" --env "NVIDIA_BASE_URL=$API" --env "HERMES_SBX_MODEL=$MODEL" \
    --upload "$dir:/workspace"
}

cmd_rules() {
  local n="${1:?Pasa el nombre del sandbox}"
  openshell rule get "$n" --status pending
  echo "Aprobar:  openshell rule approve $n --chunk-id <id>"
  echo "Rechazar: openshell rule reject  $n --chunk-id <id> --reason 'no necesario'"
}

cmd_doctor() {
  ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
  no() { printf '  \033[31m✗\033[0m %s\n' "$*"; }
  say "Diagnóstico"
  command -v brew   >/dev/null && ok "Homebrew $(brew --prefix)" || no "Homebrew"
  command -v colima >/dev/null && ok "colima instalado" || no "colima (brew install colima)"
  colima status >/dev/null 2>&1 && ok "Colima corriendo" || no "Colima detenido (./openshell-hermes.sh colima)"
  docker info >/dev/null 2>&1 && ok "Docker responde ($(docker context show 2>/dev/null))" || no "Docker no responde"
  command -v openshell >/dev/null && ok "OpenShell $(openshell --version 2>/dev/null)" || no "OpenShell (./openshell-hermes.sh install)"
  [[ -f "$GATEWAY_TOML" ]] && ok "gateway.toml: $GATEWAY_TOML" || no "sin $GATEWAY_TOML"
  grep -q 'host_gateway_ip' "$GATEWAY_TOML" 2>/dev/null \
    && ok "sandboxes → gateway vía $(sed -nE 's/^host_gateway_ip = "(.*)"/\1/p' "$GATEWAY_TOML")" \
    || no "gateway.toml sin host_gateway_ip: los sandboxes no alcanzan el gateway (./openshell-hermes.sh network)"
  gateway_ok && ok "gateway registrado y respondiendo" || no "gateway sin registrar o caído (./openshell-hermes.sh gateway)"
  docker image inspect "$IMAGE" >/dev/null 2>&1 && ok "imagen $IMAGE" || no "imagen $IMAGE (./openshell-hermes.sh build)"
  openshell provider list 2>/dev/null | grep -q "$PROVIDER" && ok "provider $PROVIDER" || no "provider $PROVIDER (./openshell-hermes.sh setup)"
  command -v hermes >/dev/null && ok "Hermes del host: $(hermes --version 2>/dev/null | head -1)" || no "hermes no está en el PATH (no es necesario para el sandbox)"
  if [[ "$(env_get "$PROJECT_ENV" API_KEY)$(env_get "$PROJECT_ENV" NVIDIA_API_KEY)" == nvapi-* ]]; then
    ok "key de NVIDIA en $PROJECT_ENV (endpoint: $API)"
  elif [[ "$(key_from_hermes 2>/dev/null || true)" == nvapi-* ]]; then
    ok "key de NVIDIA desde Hermes (proveedor nvidia)"
  else
    no "sin key: agrega API_KEY=nvapi-... en $PROJECT_ENV"
  fi
}

# Con NemoClaw instalado, él es dueño del gateway: estos comandos lo reescribirían o reiniciarían.
if command -v nemoclaw >/dev/null && [[ "${1:-}" =~ ^(install|gateway|network)$ ]]; then
  die "NemoClaw está instalado y maneja el gateway. Usa nemohermes (ver ../GUIA-NEMOCLAW-HERMES.md)."
fi

case "${1:-}" in
  colima)  cmd_colima ;;
  install) cmd_install ;;
  gateway) cmd_gateway ;;
  network) cmd_network ;;
  build)   cmd_build ;;
  setup)   cmd_setup ;;
  smoke)   cmd_smoke ;;
  probe)   cmd_probe ;;
  ask)     shift; cmd_ask "${1:-}" ;;
  chat)    cmd_chat ;;
  project) shift; cmd_project "${1:-}" ;;
  rules)   shift; cmd_rules "${1:-}" ;;
  logs)    shift; openshell logs "${1:?Pasa el nombre del sandbox}" --tail ;;
  doctor)  cmd_doctor ;;
  clean)   for s in $SANDBOXES; do fresh "$s"; done; echo "Listo." ;;
  *) sed -n '2,24p' "${0##*/}"; exit 1 ;;
esac
