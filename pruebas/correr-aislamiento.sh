#!/usr/bin/env bash
# Corre pruebas/aislamiento.sh DENTRO del sandbox NemoClaw de Hermes y muestra las propuestas de red
# NUEVAS que dejaron los bloqueos (no las aprueba ni las rechaza: decide el humano).
#   bash pruebas/correr-aislamiento.sh [sandbox]     (por defecto hermes-v023)
# Sale con el código de la batería: distinto de 0 si hubo algún FAIL.

set -uo pipefail
cd "$(dirname "$0")/.."
SB="${1:-hermes-v023}"
export NEMOCLAW_NO_POLICY_HINT=1   # sin las pistas de "policy add" tras cada bloqueo

# sha256 de la key real para que el sandbox compruebe que NO la tiene. La key nunca sale de aquí.
KEY_SHA="${KEY_SHA:-}"   # instalar.sh lo pasa ya calculado; si no, se saca de .env
if [[ -z "$KEY_SHA" ]]; then
  k=$(grep -E '^[[:space:]]*(export[[:space:]]+)?(NVIDIA_API_KEY|API_KEY)[[:space:]]*=' .env 2>/dev/null | tail -1 \
      | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]+$//; s/\r$//; s/^["'\'']//; s/["'\'']$//')
  [[ "$k" == nvapi-* ]] && KEY_SHA=$(printf %s "$k" | shasum -a 256 | cut -d' ' -f1) \
    || echo "[!] Sin API_KEY=nvapi-... en .env: la prueba de hash queda como NOTA" >&2
  unset k
fi

uuids() { grep 'Chunk:' | grep -oE '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}'; }
antes=$(openshell rule get "$SB" --status pending 2>&1 | uuids | tr "\n" " ")
inicio=$(date -u '+%Y-%m-%d %H:%M:%S')

nemohermes "$SB" upload pruebas/aislamiento.sh /tmp/ || exit 1
# NemoClaw añade una línea sobre los logs OCSF; se filtra solo esa, no cualquier línea con "OCSF".
nemohermes "$SB" exec -- env KEY_SHA="$KEY_SHA" bash /tmp/aislamiento.sh 2>&1 \
  | grep -v '^NemoClaw is attempting to enable OpenShell OCSF'
rc=${PIPESTATUS[0]}
nemohermes "$SB" exec -- rm -f /tmp/aislamiento.sh >/dev/null 2>&1

echo
echo "Propuestas de red de esta corrida en '$SB' (revísalas con openshell rule get/approve/reject; aquí no se tocan)."
echo "Son evidencia de bloqueos de la batería: NO las apruebes en bloque."
sleep 10   # el advisor agrupa los bloqueos y redacta las reglas unos segundos después
# Nuevas = chunk que no estaba antes. Retocadas = ya estaban y esta corrida les sumó hits (last seen >= inicio,
# hora UTC como la de OpenShell) o son de las copias /tmp/aisl-*.
openshell rule get "$SB" --status pending 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g' \
  | awk -v antes="$antes" -v inicio="$inicio" 'BEGIN{RS=""; n=split(antes,a," "); for(i=1;i<=n;i++) viejo[a[i]]=1}
      /Chunk:/ { match($0,/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/); id=substr($0,RSTART,RLENGTH)
                 if (!(id in viejo)) { nuevas = nuevas $0 "\n\n"; next }
                 ls=""; if (match($0,/last seen [0-9-]+ [0-9:]+/)) ls=substr($0,RSTART+10,19)
                 if ($0 ~ /\/tmp\/aisl-/ || (ls != "" && ls >= inicio)) {
                   match($0,/Rule: [^\n]*/); r=substr($0,RSTART+6,RLENGTH-6)
                   match($0,/Binary: [^\n]*/); b=substr($0,RSTART+8,RLENGTH-8)
                   retocadas = retocadas "    " id "  " r "  " b "  (last seen " ls ")\n" } }
      END { printf "NUEVAS:\n%s", (nuevas ? nuevas : "    (ninguna)\n")
            printf "\nYA PENDIENTES CON ACTIVIDAD DURANTE LA CORRIDA (de la batería o de Hermes en segundo plano):\n%s", (retocadas ? retocadas : "    (ninguna)\n") }'
exit "$rc"
