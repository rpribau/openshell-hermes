#!/usr/bin/env bash
# instalar-mac.sh: laboratorio completo en macOS con Apple Silicon (Homebrew + Colima).
#   Colima -> NemoClaw v0.0.141 (+ OpenShell 0.0.116) -> fork que construye Hermes v0.23.0 ->
#   sandbox hermes-v023 con SOUL, AGENTS, skills, plugin reglas_codigo, red, context7, Webapp y batería.
#
# Uso:   bash instalar-mac.sh [--sin-context7] [--sin-requests] [--sin-bateria] [--sin-webapp-link]
# Se puede volver a correr: cada paso revisa si ya está hecho y lo salta.
# Pide a mano (nunca se guardan en disco): la key nvapi-... de NVIDIA y, si quieres context7, su key.
set -uo pipefail
COLIMA_CPU="${COLIMA_CPU:-4}"
COLIMA_MEMORY="${COLIMA_MEMORY:-12}"
SANDBOX_CPU="${SANDBOX_CPU-3}"   # NemoClaw calcula la CPU sobre el host (p. ej. 15 núcleos) y Docker solo ve los de Colima

preparar_plataforma() {
  paso "1. Mac y herramientas (Homebrew, Colima, Docker, buildx, git, Node)"
  [[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || die "Este script es para macOS en Apple Silicon (en Ubuntu: instalar-ubuntu.sh)."
  command -v brew >/dev/null || die "Falta Homebrew. Instálalo desde https://brew.sh y vuelve a correr este script."
  local f
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

  paso "2. Colima (${COLIMA_CPU} CPU / ${COLIMA_MEMORY} GB)"
  if colima status >/dev/null 2>&1; then
    ok "Colima ya está corriendo"
  else
    colima start --cpu "$COLIMA_CPU" --memory "$COLIMA_MEMORY" || die "colima start falló"
  fi
  docker context use colima >/dev/null 2>&1 || true
  local ncpu
  ncpu=$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)
  (( ncpu > SANDBOX_CPU )) || die "Docker ve $ncpu CPU; necesitas más que SANDBOX_CPU=$SANDBOX_CPU (colima stop; colima start --cpu $COLIMA_CPU --memory $COLIMA_MEMORY)."
  ok "Docker ve $ncpu CPU"
}

source "$(cd "$(dirname "$0")" && pwd)/lib/comun.sh"
