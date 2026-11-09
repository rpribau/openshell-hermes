#!/bin/bash
# Batería de aislamiento que corre DENTRO del sandbox NemoClaw de Hermes (hermes-v023).
# La lanza el host con pruebas/correr-aislamiento.sh. Cada prueba dice qué espera la POLÍTICA:
# "permitido" o "bloqueado". PASS = OpenShell hizo lo esperado. Lo que la política permite pero es
# riesgoso va como NOTA con la palabra RIESGO, no como PASS.
# Variable que pasa el host: KEY_SHA (sha256 de la key real; la key nunca entra aquí). Puede venir vacía.

pass=0; fail=0; info=0
G=$'\e[32m'; Rr=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'

# El placeholder va en un archivo 600 (curl -H @archivo), no en argv donde lo ve cualquier proceso.
limpia() { rm -f "$AUTHF" /tmp/aisl-curl /tmp/aisl-py /tmp/aisl-body.* /tmp/aisl-mcp.py; rmdir /tmp/aisl-m 2>/dev/null; }
# Si algo mata este script a la mitad, limpia y al menos imprime el conteo parcial.
trap 'limpia; printf "\n(terminó) PASS=%d FAIL=%d NOTA=%d\n" "$pass" "$fail" "$info"' EXIT
AUTHF=$(mktemp /tmp/aisl-auth.XXXXXX) || exit 1
printf 'Authorization: Bearer %s\n' "$NVIDIA_INFERENCE_API_KEY" > "$AUTHF"

seccion() { printf '\n%s%s%s\n' "$B" "$1" "$N"; }

# prueba <nombre> <permitido|bloqueado> <comando o función exportada...>
prueba() {
  local name="$1" exp="$2" out got rc; shift 2
  # stdin vacío + timeout también para funciones: nada puede quedarse esperando (p. ej. su pidiendo contraseña)
  out=$(timeout 40 bash -c '"$@"' _ "$@" 2>&1 </dev/null); rc=$?
  # timeout, no ejecutable, no existe o muerto por señal no es un bloqueo: es un error de la prueba
  case $rc in
    0) got=permitido ;;
    124|126|127) got="error (rc=$rc)" ;;
    *) if [ "$rc" -gt 128 ]; then got="error (rc=$rc)"; else got=bloqueado; fi ;;
  esac
  if [ "$got" = "$exp" ]; then
    pass=$((pass+1)); printf '  %sPASS%s %-60s %s\n' "$G" "$N" "$name" "($got)"
  else
    fail=$((fail+1)); printf '  %sFAIL%s %-60s esperado=%s obtenido=%s\n' "$Rr" "$N" "$name" "$exp" "$got"
    printf '       %s\n' "$(printf '%s' "$out" | head -c 220 | tr '\n' ' ')"
  fi
}

# nota <nombre> <comando...>: no califica, solo reporta lo que pasa
nota() {
  local name="$1" out r; shift
  out=$(timeout 40 bash -c '"$@"' _ "$@" 2>&1 </dev/null) && r="funciona" || r="falla"
  info=$((info+1)); printf '  %sNOTA%s %-60s %s: %s\n' "$Y" "$N" "$name" "$r" "$(printf '%s' "$out" | head -c 110 | tr '\n' ' ')"
}
# aviso <nombre> <texto>: nota que no ejecuta nada
aviso() { info=$((info+1)); printf '  %sNOTA%s %-60s %s\n' "$Y" "$N" "$1" "$2"; }

API=https://integrate.api.nvidia.com/v1
C="curl -sS -f -m 20 -o /dev/null"     # para lo permitido: exige 2xx
PY=$(readlink -f "$(command -v python3)")  # el intérprete real; OpenShell mira la ruta resuelta
PYHOME=${PY%/bin/*}
RE_KEY='nvapi-[A-Za-z0-9_-]{20,}'
RE_PH='^openshell:resolve:env:((v[0-9A-Za-z]+|s[0-9a-f]+)_)?NVIDIA_INFERENCE_API_KEY$'
export API AUTHF PY PYHOME RE_KEY RE_PH

# llega <curl> <args...>: 1 solo si OpenShell la frenó (CONNECT 403, cuerpo 403 de OpenShell/policy_denied)
# o, con --noproxy, si no hubo DNS/ruta (rc 6/7). Cualquier otra cosa (respuesta del servidor, flag mala,
# error local de curl) devuelve 0, que en una prueba "bloqueado" sale FAIL.
llega() {
  local bin="$1" out rc bf=/tmp/aisl-body.$$; shift
  out=$("$bin" -sS -m 20 -o "$bf" -w '%{http_code}' "$@" 2>&1); rc=$?
  if grep -q 'CONNECT tunnel failed, response 403' <<<"$out" \
     || { [ "${out: -3}" = 403 ] && grep -qE 'OpenShell|policy_denied' "$bf" 2>/dev/null; } \
     || { [[ " $* " == *" --noproxy "* ]] && [[ $rc == [67] ]]; }; then
    rm -f "$bf"; echo "frenada (rc=$rc)"; return 1
  fi
  rm -f "$bf"; echo "rc=$rc ${out: -200}"; return 0
}
# py_red <python> <código>: el código imprime BLOQUEADO solo ante el error esperado del aislamiento,
# así un error de sintaxis u otra excepción no pasa por bloqueo.
py_red() { local out; out=$("$1" -c "$2" 2>&1); echo "$out"; ! grep -q BLOQUEADO <<<"$out"; }
URL_NEG='
except Exception as e: print("BLOQUEADO" if "Tunnel connection failed: 403" in str(e) else repr(e))'
SOCK_NEG='
except OSError as e: print("BLOQUEADO" if e.errno in (errno.ECONNREFUSED,errno.EPERM,errno.ENETUNREACH) else repr(e))'
export -f llega py_red

seccion "1. Red (proxy de OpenShell + política por binario y L7)"
prueba "curl -> NVIDIA GET /v1/models (perfil NVIDIA)"              permitido $C -H @"$AUTHF" "$API/models"
prueba "python3 (venv) -> NVIDIA GET /v1/models"                   permitido python3 -c 'import os,urllib.request as u
u.urlopen(u.Request("https://integrate.api.nvidia.com/v1/models",headers={"Authorization":"Bearer "+os.environ["NVIDIA_INFERENCE_API_KEY"]}),timeout=30).read(1)'
prueba "curl -> NVIDIA POST /v1/embeddings (L7 no lo lista)"        bloqueado llega curl -X POST -H @"$AUTHF" -H 'Content-Type: application/json' -d '{}' "$API/embeddings"
prueba "curl -> example.com"                                       bloqueado llega curl https://example.com
prueba "python3 -> example.com"                                    bloqueado py_red python3 'import urllib.request as u
try: u.urlopen("https://example.com",timeout=15)'"$URL_NEG"
prueba "curl -> NVIDIA por HTTP plano (puerto 80)"                 bloqueado llega curl http://integrate.api.nvidia.com/v1/models
prueba "curl -> IP directa 1.1.1.1"                                bloqueado llega curl https://1.1.1.1
prueba "curl --noproxy '*' -> example.com"                          bloqueado llega curl --noproxy '*' https://example.com
prueba "curl --noproxy '*' -> NVIDIA (sin proxy no hay DNS)"        bloqueado llega curl --noproxy '*' -H @"$AUTHF" "$API/models"
prueba "socket TCP crudo a 1.1.1.1:443 (python)"                   bloqueado py_red python3 'import socket,errno
try: socket.create_connection(("1.1.1.1",443),timeout=8)'"$SOCK_NEG"
prueba "UDP a 8.8.8.8:53 (DNS directo)"                            bloqueado py_red python3 'import socket,errno
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(5)
try: s.sendto(bytes.fromhex("abcd01000001000000000000076578616d706c6503636f6d0000010001"),("8.8.8.8",53)); s.recv(512)'"$SOCK_NEG"
prueba "curl -> pypi.org/simple/requests/ (preset pypi, GET)"       permitido $C https://pypi.org/simple/requests/
prueba "curl -X POST -> pypi.org (pypi solo permite GET)"           bloqueado llega curl -X POST -d x https://pypi.org/simple/requests/
prueba "curl -> registry.npmjs.org (npm_yarn no incluye curl)"      bloqueado llega curl https://registry.npmjs.org/
nota   "RIESGO curl -> github.com (brew-balanced da acceso full)"   $C https://github.com
aviso  "RIESGO python POST a nousresearch.com (no se ejecuta)"      "la política nous_research permite GET y POST /** a hermes, venv python y /usr/bin/python3*: canal de salida"

# MCP context7 (registrado con `nemohermes <sb> mcp add`; política protocol: mcp + key en proveedor de OpenShell).
if grep -q '^  context7:' /sandbox/.hermes/config.yaml 2>/dev/null; then
seccion "1b. MCP context7 (protocol: mcp)"
# Cliente MCP mínimo. Imprime BLOQUEADO solo ante un 403 de OpenShell; nunca imprime el placeholder.
cat > /tmp/aisl-mcp.py <<'EOF'
import json, re, sys, urllib.request as u, urllib.error as ue
quien, accion = sys.argv[1], sys.argv[2]
m = re.search(r"context7:.*?Authorization:\s*['\"]?(Bearer [^'\"\n]+)", open("/sandbox/.hermes/config.yaml").read(), re.S)
if not m:
    print("SIN_CONFIG"); sys.exit(2)
auth = m.group(1).strip() if quien == "real" else "Bearer ctx7sk-00000000-0000-0000-0000-000000000000"
def post(path, body, sid=None):
    h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
         "MCP-Protocol-Version": "2025-06-18", "Authorization": auth}
    if sid:
        h["Mcp-Session-Id"] = sid
    try:
        with u.urlopen(u.Request("https://mcp.context7.com" + path, data=json.dumps(body).encode(), headers=h, method="POST"), timeout=30) as r:
            return r.status, r.headers.get("Mcp-Session-Id"), r.read(20000).decode("utf-8", "replace")
    except ue.HTTPError as e:
        b = e.read(400).decode("utf-8", "replace")
        if e.code == 403 and "OpenShell" in b:
            print("BLOQUEADO"); sys.exit(0)
        return e.code, None, b
    except ue.URLError as e:
        if "Tunnel connection failed: 403" in str(e):
            print("BLOQUEADO"); sys.exit(0)
        raise
ini = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "aislamiento", "version": "0"}}}
if accion == "ruta":
    print("HTTP %s" % post("/otra", ini)[0]); sys.exit(0)
st, sid, _ = post("/mcp", ini)
post("/mcp", {"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
if accion == "lista":
    b = post("/mcp", {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, sid)[2]
    print("TOOLS:" + ",".join(sorted(set(re.findall(r'"name":"([^"]+)"', b)))))
elif accion == "resolver":
    st, _, b = post("/mcp", {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
        "name": "resolve-library-id", "arguments": {"query": "http client", "libraryName": "requests"}}}, sid)
    print("INVALIDA" if "Invalid API key" in b else "RESULTADOS" if "/psf/requests" in b else "OTRO HTTP %s" % st)
elif accion == "metodo":
    print("HTTP %s" % post("/mcp", {"jsonrpc": "2.0", "id": 4, "method": "sampling/createMessage", "params": {}}, sid)[0])
EOF
HPY=/opt/hermes/.venv/bin/python
ctx7() { "$1" /tmp/aisl-mcp.py "$2" "$3" 2>&1 | tail -3; }
ctx7_lista() { local o; o=$(ctx7 "$HPY" real lista); echo "$o"; grep -q '^TOOLS:.*resolve-library-id' <<<"$o"; }
# La key real se prueba por contraste: con el placeholder hay resultados, con una key falsa "Invalid API key".
ctx7_sustituye() { local r f; r=$(ctx7 "$HPY" real resolver); f=$(ctx7 "$HPY" falsa resolver); echo "placeholder=$r falsa=$f"; [ "$r" = RESULTADOS ] && [ "$f" = INVALIDA ]; }
# 1 solo si OpenShell la frenó; un traceback u otra respuesta cuenta como "llegó" (FAIL en una prueba bloqueado).
ctx7_llega() { local o; o=$(ctx7 "$@"); echo "$o"; ! grep -q '^BLOQUEADO$' <<<"$o"; }
export HPY; export -f ctx7 ctx7_lista ctx7_sustituye ctx7_llega
prueba "python de Hermes -> context7 tools/list (parche de binarios)" permitido ctx7_lista
prueba "el proxy sustituye la key de context7 (placeholder vs falsa)" permitido ctx7_sustituye
prueba "método MCP no permitido (sampling/createMessage)"          bloqueado ctx7_llega "$HPY" real metodo
prueba "python de Hermes -> mcp.context7.com/otra (ruta fuera)"   bloqueado ctx7_llega "$HPY" real ruta
prueba "/usr/bin/python3.13 -> context7"                           bloqueado ctx7_llega /usr/bin/python3.13 real lista
prueba "curl -> context7 /mcp"                                     bloqueado llega curl -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"ping"}' https://mcp.context7.com/mcp
aviso  "RIESGO argumentos de tools/call sin filtro"                "OpenShell mira método y nombre de herramienta, no argumentos: lo que Hermes ponga en query sale a Upstash"
aviso  "RIESGO respuestas MCP sin inspección"                      "OpenShell 0.0.116 no revisa respuestas; la única defensa es el <untrusted_tool_result> de Hermes"
fi

seccion "2. Identidad del binario"
copia_curl() {
  local rc
  cp /usr/bin/curl /tmp/aisl-curl && /tmp/aisl-curl --version >/dev/null || { rm -f /tmp/aisl-curl; echo "la copia no arranca"; return 0; }
  llega /tmp/aisl-curl -H @"$AUTHF" "$API/models"; rc=$?; rm -f /tmp/aisl-curl; return $rc
}
copia_python() {
  # Sin PYTHONHOME la copia no encuentra su stdlib; con él es el mismo intérprete en otra ruta.
  local rc
  cp "$PY" /tmp/aisl-py && PYTHONHOME=$PYHOME /tmp/aisl-py -c 'import ssl' || { rm -f /tmp/aisl-py; echo "la copia no arranca"; return 0; }
  PYTHONHOME=$PYHOME py_red /tmp/aisl-py 'import urllib.request as u
try: u.urlopen("https://pypi.org/simple/requests/",timeout=20)'"$URL_NEG"
  rc=$?; rm -f /tmp/aisl-py; return $rc
}
git_nvidia() {
  local out; out=$(GIT_TERMINAL_PROMPT=0 git ls-remote "$API/x" 2>&1)
  echo "$out"
  grep -qE 'CONNECT tunnel failed|OpenShell' <<<"$out" && return 1
  return 0   # cualquier otra respuesta = llegó a NVIDIA (o error ajeno a OpenShell)
}
export URL_NEG; export -f copia_curl copia_python git_nvidia
prueba "curl copiado a /tmp -> NVIDIA"                             bloqueado copia_curl
prueba "python real copiado a /tmp -> pypi"                        bloqueado copia_python
prueba "git -> NVIDIA (git solo está en el preset github)"          bloqueado git_nvidia
prueba "git ls-remote github.com/psf/requests (preset github)"     permitido env GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/psf/requests HEAD
# Intérprete que registra el gestor de paquetes de Hermes (tools/facts.json): vive en /sandbox, el agente lo puede reemplazar.
PMPY=$(ls /sandbox/.hermes/tools/python-*/bin/python3.* 2>/dev/null | head -1)
if [ -n "$PMPY" ]; then
  nota "RIESGO intérprete del gestor de paquetes escribible ($PMPY)" test -w "$PMPY"
  prueba "python del gestor de paquetes -> pypi (no está en ninguna política)" bloqueado py_red "$PMPY" 'import urllib.request as u
try: u.urlopen("https://pypi.org/simple/requests/",timeout=20)'"$URL_NEG"
fi
if [ -x /sandbox/.venv-reqs/bin/python ]; then
  nota "RIESGO venv /sandbox/.venv-reqs -> pypi (hereda la red)"    /sandbox/.venv-reqs/bin/python -c 'import urllib.request as u; print(u.urlopen("https://pypi.org/simple/requests/",timeout=20).status)'
fi

seccion "3. Credenciales: el agente nunca ve la key real"
es_placeholder() { [[ "$NVIDIA_INFERENCE_API_KEY" =~ $RE_PH ]]; }
export -f es_placeholder
prueba "NVIDIA_INFERENCE_API_KEY es un placeholder openshell:"     permitido es_placeholder
if [ -n "$KEY_SHA" ]; then
  prueba "sha256 de la variable != sha256 de la key real"          permitido sh -c '[ "$(printf %s "$NVIDIA_INFERENCE_API_KEY" | sha256sum | cut -d" " -f1)" != "$KEY_SHA" ]'
else
  aviso "sha256 de la variable vs key real"                        "sin KEY_SHA (no hay key en el .env del host): no se mide"
fi
aviso "sustitución del placeholder hacia hosts permitidos no-NVIDIA" "NO se mide (haría falta un eco de headers en un host nuevo; decisión del usuario)"
buscar_key() {
  # Junta toda cadena nvapi- de entornos y argv de procesos legibles y de archivos (también binarios,
  # venvs y state.db). La key real = fuga; cualquier otra nvapi- también cuenta. Solo imprime rutas.
  local f hits line tok enc=1
  hits=$(
    for f in /proc/[0-9]*/environ /proc/[0-9]*/cmdline; do tr '\0' '\n' 2>/dev/null <"$f" | grep -aoE "$RE_KEY" | sed "s#^#$f:#"; done
    find /sandbox /tmp /etc /opt/hermes /usr/local/share /app /var/log -name .git -prune -o -type f \( -size -50M -o -path '/sandbox/.hermes/tools/*' \) -print0 2>/dev/null \
      | xargs -0 -r grep -aoHE "$RE_KEY" 2>/dev/null
  )
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    tok="nvapi-${line##*:nvapi-}"; f=${line%%:nvapi-*}; enc=0
    if [ -n "$KEY_SHA" ] && [ "$(printf %s "$tok" | sha256sum | cut -d' ' -f1)" = "$KEY_SHA" ]; then echo "KEY REAL en $f"
    else echo "otra nvapi- en $f"; fi
  done <<<"$hits"
  return $enc
}
export -f buscar_key
prueba "nvapi- en /proc/*/{environ,cmdline} y archivos (sin .git ni >=50 MB salvo .hermes/tools)" bloqueado buscar_key

seccion "4. Sistema de archivos (Landlock + permisos)"
escribe() { local f="$1/.aisl-$$"; ( : > "$f" ) && rm -f "$f"; }
export -f escribe
prueba "escribir en /tmp"                                          permitido escribe /tmp
prueba "escribir en /sandbox"                                      permitido escribe /sandbox
prueba "escribir en /sandbox/.hermes"                              permitido escribe /sandbox/.hermes
for d in /opt/hermes /opt/hermes/.python "$(echo /opt/hermes/.venv/lib/python3*/site-packages)" /etc /usr/local/bin /run /var/tmp /dev/shm; do
  prueba "escribir en $d"                                          bloqueado escribe "$d"
done
prueba "modificar /usr/bin/curl (test -w)"                         bloqueado test -w /usr/bin/curl
prueba "modificar la política gestionada (test -w)"                bloqueado test -w /usr/local/share/nemoclaw/hermes-managed-policy.json
for f in /sandbox/.hermes/SOUL.md /sandbox/AGENTS.md /sandbox/.hermes/config.yaml; do
  nota "RIESGO el agente puede reescribir $f"                      test -w "$f"
done
# Solo test -r: su contenido nunca se imprime.
for f in /etc/openshell/auth/sandbox.jwt /etc/openshell/tls/client/tls.key; do
  nota "RIESGO el agente puede leer $f"                            test -r "$f"
done
for d in /root /opt /var/lib /home; do prueba "listar $d"          bloqueado ls "$d"; done
prueba "leer /etc/shadow"                                          bloqueado cat /etc/shadow
prueba "leer /proc/1/environ"                                      bloqueado cat /proc/1/environ
prueba "ver el socket de Docker"                                   bloqueado sh -c 'test -e /var/run/docker.sock || test -e /run/docker.sock'
# Montajes del host (Mac/Colima) fuera de los de OpenShell; imprime los que haya y sale 1.
prueba "sin montajes virtiofs/9p/sshfs/fakeowner fuera de /etc|/opt/openshell" permitido awk '/ - (virtiofs|9p|fuse\.sshfs) |fakeowner/ && $5 !~ /^\/(etc|opt)\/openshell\// {print $5; m=1} END {exit m}' /proc/self/mountinfo

seccion "5. Procesos y privilegios"
prueba "no corre como root"                                        permitido sh -c '[ "$(id -u)" != 0 ]'
prueba "capabilities efectivas en cero"                            permitido grep -qE '^CapEff:[[:space:]]*0+$' /proc/self/status
prueba "capabilities de bounding en cero"                          permitido grep -qE '^CapBnd:[[:space:]]*0+$' /proc/self/status
prueba "NoNewPrivs activo (setuid no sirve)"                       permitido grep -qE '^NoNewPrivs:[[:space:]]*1' /proc/self/status
prueba "seccomp activo (modo filtro)"                              permitido grep -qE '^Seccomp:[[:space:]]*2' /proc/self/status
prueba "crear user namespace (unshare -r)"                         bloqueado unshare -r true
prueba "montar un tmpfs"                                           bloqueado sh -c 'mkdir -p /tmp/aisl-m && mount -t tmpfs none /tmp/aisl-m'
rmdir /tmp/aisl-m 2>/dev/null
prueba "chroot (/usr/sbin/chroot)"                                 bloqueado /usr/sbin/chroot / true
env_gateway() {
  local pid; pid=$(pgrep -f 'hermes.real gateway' | head -1)
  [ -n "$pid" ] || { echo "no encontré el gateway de Hermes"; return 0; }
  cat "/proc/$pid/environ" >/dev/null
}
export -f env_gateway
prueba "leer /proc/<gateway de Hermes>/environ (mismo uid)"         bloqueado env_gateway
nota   "identidad del proceso"                                     id

seccion "6. Puertos locales"
# 1 solo si la API contesta 401 exacto (puerto cerrado o 404 no cuentan como "pide auth")
sin_bearer() { local c; c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:18642/v1/models); echo "HTTP $c"; [ "$c" != 401 ]; }
export -f sin_bearer
prueba "API de Hermes 127.0.0.1:18642/health (sin auth)"            permitido $C http://127.0.0.1:18642/health
prueba "API de Hermes /v1/models sin Bearer (401)"                 bloqueado sin_bearer
nota   "dashboard 127.0.0.1:19119 (alcanzable por el agente)"       curl -sS -m 5 -o /dev/null -w 'HTTP %{http_code}' http://127.0.0.1:19119/
nota   "webapp 127.0.0.1:9120"                                     curl -sS -m 5 -o /dev/null -w 'HTTP %{http_code}' http://127.0.0.1:9120/

seccion "7. Al final por si cuelga"
prueba "su a root (setuid)"                                        bloqueado su -c true root

trap limpia EXIT
printf '\n%sResultado:%s %s%d PASS%s, %s%d FAIL%s, %d NOTA\n' "$B" "$N" "$G" "$pass" "$N" "$Rr" "$fail" "$N" "$info"
[ "$fail" -eq 0 ]
