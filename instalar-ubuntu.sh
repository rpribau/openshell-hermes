#!/usr/bin/env bash
# instalar-ubuntu.sh: laboratorio completo en Ubuntu 22.04 (x86_64 o arm64) con Docker Engine nativo.
#   Docker -> NemoClaw v0.0.141 (+ OpenShell 0.0.116) -> fork que construye Hermes v0.23.0 ->
#   sandbox hermes-v023 con SOUL, AGENTS, skills, plugin reglas_codigo, red, context7, Webapp y batería.
#
# Uso:   bash instalar-ubuntu.sh [--sin-context7] [--sin-requests] [--sin-bateria] [--sin-webapp-link]
# Corre como tu usuario (no con sudo): pide la contraseña de sudo para apt y Docker.
# Pide a mano (nunca se guardan en disco): la key nvapi-... de NVIDIA y, si quieres context7, su key.
set -uo pipefail
SANDBOX_CPU="${SANDBOX_CPU-}"    # en Linux Docker ve todos los núcleos: lo decide NemoClaw

preparar_plataforma() {
  paso "1. Ubuntu, recursos y paquetes base"
  [[ "$(uname -s)" == Linux ]] || die "Este script es para Ubuntu (en Mac: instalar-mac.sh)."
  (( EUID != 0 )) || die "Córrelo con tu usuario, no como root: NemoClaw instala en tu \$HOME y usa sudo cuando hace falta."
  local id ver
  id=$(. /etc/os-release && echo "${ID:-}"); ver=$(. /etc/os-release && echo "${VERSION_ID:-}")
  [[ "$id" == ubuntu ]] || die "Distribución $id no soportada por este script (es para Ubuntu)."
  [[ "$ver" == 22.04 ]] && ok "Ubuntu 22.04" || aviso "Ubuntu $ver: el script se probó pensando en 22.04 (NVIDIA valida 24.04)."
  case "$(uname -m)" in x86_64|aarch64) ok "Arquitectura $(uname -m)" ;; *) die "Arquitectura $(uname -m) no soportada" ;; esac
  local kmaj kmin
  kmaj=$(uname -r | cut -d. -f1); kmin=$(uname -r | cut -d. -f2)
  (( kmaj > 5 || (kmaj == 5 && kmin >= 13) )) && ok "Kernel $(uname -r) (Landlock disponible)" \
    || aviso "Kernel $(uname -r) < 5.13: el sandbox correría sin Landlock (restricciones de archivos)."
  local cpus mem_gb disco_gb
  cpus=$(nproc); mem_gb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
  disco_gb=$(( $(df -Pk "$HOME" | awk 'NR==2{print $4}') / 1024 / 1024 ))
  (( cpus >= 4 )) || die "Hay $cpus CPU; NemoClaw necesita 4 como mínimo."
  (( mem_gb >= 7 )) || die "Hay ${mem_gb} GB de RAM; NemoClaw necesita 8 como mínimo."
  (( disco_gb >= 20 )) || die "Hay ${disco_gb} GB libres en \$HOME; hacen falta 20 como mínimo (40 recomendado)."
  (( mem_gb >= 15 )) || aviso "${mem_gb} GB de RAM: funciona, pero NVIDIA recomienda 16."
  (( disco_gb >= 40 )) || aviso "${disco_gb} GB libres: funciona, pero NVIDIA recomienda 40 (imágenes de ~2.4 GB y la base del fork)."
  ok "$cpus CPU, ${mem_gb} GB de RAM, ${disco_gb} GB libres"
  # git y curl para el fork; binutils (strings) y zstd los pide el instalador de NemoClaw; lsof para verificar puertos.
  local faltan=() p
  for p in ca-certificates curl git binutils zstd lsof; do dpkg -s "$p" >/dev/null 2>&1 || faltan+=("$p"); done
  if (( ${#faltan[@]} )); then
    echo "    Instalando con apt (pide tu contraseña de sudo): ${faltan[*]}"
    { sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${faltan[@]}"; } \
      > "$TMPD/apt.log" 2>&1 || { tail -20 "$TMPD/apt.log" >&2; die "apt-get install falló"; }
  fi
  ok "Paquetes base: ca-certificates curl git binutils zstd lsof"

  paso "2. Docker Engine"
  if ! command -v docker >/dev/null; then
    echo "    Instalando Docker con el script oficial (get.docker.com; pide sudo)."
    curl -fsSL https://get.docker.com -o "$TMPD/get-docker.sh" || die "No pude descargar get.docker.com"
    sudo sh "$TMPD/get-docker.sh" || die "La instalación de Docker falló"
  fi
  systemctl is-active --quiet docker || sudo systemctl enable --now docker || die "No pude arrancar docker.service"
  if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    aviso "Tu usuario entra al grupo docker: sus miembros controlan Docker con impacto de root (solo en una máquina personal)."
    sudo usermod -aG docker "$USER" || die "usermod -aG docker falló"
  fi
  if ! docker info >/dev/null 2>&1; then
    # El grupo nuevo no vale en esta sesión hasta volver a entrar; se relanza el script dentro de `sg docker`.
    [[ -z "${INSTALAR_REEXEC:-}" ]] || die "Docker sigue sin responder dentro de 'sg docker'. Cierra sesión, vuelve a entrar y corre el script otra vez."
    echo "    Relanzando el script con el grupo docker activo..."
    rm -rf "$TMPD"   # exec no corre el trap de salida
    exec sg docker -c "INSTALAR_REEXEC=1 $(printf '%q ' bash "$REPO/instalar-ubuntu.sh" "$@")"
  fi
  ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null) accesible sin sudo"
  if ! docker buildx version >/dev/null 2>&1; then
    sudo apt-get install -y -qq docker-buildx-plugin || die "Falta docker buildx (paquete docker-buildx-plugin)"
  fi
  ok "docker buildx"
}

source "$(cd "$(dirname "$0")" && pwd)/lib/comun.sh"
