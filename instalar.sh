#!/usr/bin/env bash
# instalar.sh: elige el instalador según el sistema. Mismas opciones que instalar-mac.sh / instalar-ubuntu.sh:
#   bash instalar.sh [--sin-context7] [--sin-requests] [--sin-bateria] [--sin-webapp-link]
d="$(cd "$(dirname "$0")" && pwd)"
case "$(uname -s)" in
  Darwin) exec bash "$d/instalar-mac.sh" "$@" ;;
  Linux)  exec bash "$d/instalar-ubuntu.sh" "$@" ;;
  *) echo "Sistema $(uname -s) no soportado: usa macOS (Apple Silicon) o Ubuntu." >&2; exit 1 ;;
esac
