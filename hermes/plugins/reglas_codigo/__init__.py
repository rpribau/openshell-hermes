"""reglas_codigo: barandillas mecánicas para las reglas de "Proyectos de código" del SOUL.

1. pre_tool_call: bloquea la primera edición de código (write_file/patch) en un proyecto con tests
   si en el scratch no hay un ``fallas-antes*`` creado en esta sesión (línea base).
2. pre_tool_call: manda a aprobación humana los borrados por otra vía (rmtree, os.unlink, find -delete…)
   en terminal, execute_code o en un script .py/.sh que el terminal vaya a ejecutar.
3. pre_verify (una vez por turno): si quedaron restos nuevos en el proyecto o tests que dependen del
   scratch, lo hace seguir con la lista concreta.

Es una barandilla contra errores, no una barrera: el agente puede editar este plugin y config.yaml.
"""

from __future__ import annotations

import logging
import os
import re
import shlex
import time
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)

HERMES_HOME = Path(os.environ.get("HERMES_HOME") or "/sandbox/.hermes")
SCRATCH = HERMES_HOME / "cache" / "scratch"
EXCLUDED = (HERMES_HOME, Path("/tmp"))  # lo de aquí no es un proyecto del usuario

CODE_EXT = {".py", ".js", ".ts", ".tsx", ".jsx", ".go", ".rs", ".java", ".rb"}
PROJECT_MARKERS = (".git", "pyproject.toml", "setup.py", "package.json", "Cargo.toml", "go.mod")
TEST_DIRS = ("tests", "test")
JUNK = (".coverage", ".coverage.*", "coverage.xml", "htmlcov", "*.egg-info", "src/*.egg-info", ".venv", "venv",
        ".ruff_cache", ".mypy_cache", ".pytest_cache")

DELETE_RE = re.compile(
    r"shutil\.rmtree|\bos\.(?:unlink|remove|rmdir|removedirs)\b|\.unlink\(|\.rmdir\("
    r"|\bfind\b[^\n;|&]*\s-delete\b|\bshred\b"
)
SCRATCH_REF_RE = re.compile(r"TMPDIR|\.hermes/cache/scratch")

_inicio: dict[str, float] = {}  # session_id -> primera vez que vimos la sesión
_bloqueados: dict[str, set[Path]] = {}  # session_id -> carpetas cuyo borrado recursivo bloqueó Hermes
BLOCKED_RECURSIVE = "BLOCKED: Command flagged as dangerous (recursive delete)"


def _t0(session_id: str) -> float:
    return _inicio.setdefault(session_id or "", time.time())


def session_cwd(*keys: str) -> Optional[str]:
    """cwd de la sesión según Hermes: los hooks corren en el gateway, cuyo cwd no es el de la sesión."""
    try:
        from tools.terminal_tool import get_session_cwd, resolve_task_overrides
    except Exception:
        return None
    for k in keys:
        if not k:
            continue
        try:
            c = (resolve_task_overrides(k) or {}).get("cwd") or get_session_cwd(k)
        except Exception:
            c = None
        if c:
            return str(c)
    return None


def _abs(path: Any, base: Optional[str]) -> Path:
    p = Path(str(path)).expanduser()
    return (p if p.is_absolute() else Path(base or os.getcwd()) / p).resolve()


def project_root(path: Any, base: Optional[str] = None) -> Optional[Path]:
    """Raíz del proyecto que contiene ``path`` (fuera de HERMES_HOME y /tmp), o None."""
    try:
        p = _abs(path, base)
    except Exception:
        return None
    if any(p.is_relative_to(x) for x in EXCLUDED):
        return None
    for d in [p, *p.parents] if p.is_dir() else p.parents:
        if d == d.parent:
            break
        if any((d / m).exists() for m in PROJECT_MARKERS):
            return d
    return None


def _edited_paths(tool_name: str, args: dict) -> list[str]:
    if tool_name not in ("write_file", "patch"):
        return []
    paths = [args["path"]] if args.get("path") else []
    # patch en modo V4A trae las rutas dentro del texto
    paths += re.findall(r"^\*\*\* (?:Update|Add) File: (.+)$", str(args.get("patch") or ""), re.M)
    return [p.strip() for p in paths]


def _baseline_ok(t0: float) -> bool:
    try:
        return any(f.stat().st_mtime >= t0 - 1 for f in SCRATCH.glob("fallas-antes*"))
    except OSError:
        return False


def _scripts_in_command(command: str) -> list[Path]:
    # shortcut: solo mira archivos .py/.sh nombrados en el comando; un borrado escondido más hondo pasa.
    if "pytest" in command:  # los tests del proyecto pueden usar os.remove legítimamente
        return []
    try:
        tokens = shlex.split(command)
    except ValueError:
        tokens = command.split()
    found = []
    for t in tokens:
        if t.endswith((".py", ".sh")):
            p = Path(t).expanduser()
            if p.is_file():
                found.append(p)
    return found


def _rm_targets(command: str, base: Optional[str]) -> list[Path]:
    """Rutas que tocan rm/rmdir/unlink en un comando, siguiendo `cd` dentro del mismo comando."""
    # shortcut: no entiende subshells, variables ni globs; basta para `cd X && rm -rf Y`.
    try:
        tokens = shlex.split(command)
    except ValueError:
        tokens = command.split()
    cwd, out, i = base, [], 0
    while i < len(tokens):
        t = tokens[i]
        if t == "cd" and i + 1 < len(tokens):
            cwd = str(_abs(tokens[i + 1], cwd))
            i += 2
            continue
        if os.path.basename(t) in ("rm", "rmdir", "unlink"):
            i += 1
            while i < len(tokens) and tokens[i] not in ("&&", "||", ";", "|"):
                if not tokens[i].startswith("-"):
                    out.append(_abs(tokens[i], cwd))
                i += 1
            continue
        i += 1
    return out


def _delete_match(tool_name: str, args: dict) -> Optional[str]:
    texts = []
    if tool_name == "terminal":
        cmd = str(args.get("command") or "")
        texts.append(cmd)
        for s in _scripts_in_command(cmd):
            try:
                texts.append(s.read_text(errors="replace")[:256 * 1024])
            except OSError:
                pass
    elif tool_name == "execute_code":
        texts.append(str(args.get("code") or ""))
    for t in texts:
        m = DELETE_RE.search(t)
        if m:
            return m.group(0)
    return None


def on_pre_tool_call(tool_name: str = "", args: Any = None, session_id: str = "", task_id: str = "", **_: Any):
    args = args if isinstance(args, dict) else {}
    t0 = _t0(session_id)
    base = session_cwd(task_id, session_id)

    hit = _delete_match(tool_name, args)
    if not hit and tool_name == "terminal" and _bloqueados.get(session_id):
        for p in _rm_targets(str(args.get("command") or ""), base):
            if any(p == d or p.is_relative_to(d) for d in _bloqueados[session_id]):
                hit = f"borrar dentro de {p.parent if p.is_file() else p}, que Hermes ya bloqueó"
                break
    if hit:
        logger.info("reglas_codigo: borrado por otra vía (%s) en %s -> aprobación", hit, tool_name)
        return {
            "action": "approve",
            "message": f"reglas_codigo: esto borra archivos ({hit}). Borrar requiere aprobación del usuario; "
                       "si no la hay, no busques otra forma: deja el archivo y nómbralo en el reporte.",
            "rule_key": "reglas_codigo:borrado",
        }

    for path in _edited_paths(tool_name, args):
        if Path(path).suffix.lower() not in CODE_EXT:
            continue
        root = project_root(path, base)
        if root is None or not any((root / d).is_dir() for d in TEST_DIRS):
            continue
        if _baseline_ok(t0):
            return None
        logger.info("reglas_codigo: edición de %s bloqueada sin línea base", path)
        return {
            "action": "block",
            "message": f"reglas_codigo: antes de editar código en {root} corre la suite COMPLETA con todas las "
                       "dependencias de desarrollo y guarda la lista de fallas en el scratch, p. ej. "
                       "`pytest -q --tb=no | grep ^FAILED > \"$TMPDIR/fallas-antes.txt\"` (vacío vale si no hay "
                       "fallas). Luego reintenta esta edición.",
        }
    return None


def _junk(root: Path, t0: float) -> list[str]:
    out = []
    for pat in JUNK:
        for p in root.glob(pat):
            try:
                if p.stat().st_mtime >= t0 - 1:
                    out.append(str(p.relative_to(root)))
            except OSError:
                pass
    return sorted(set(out))


def on_post_tool_call(tool_name: str = "", args: Any = None, result: Any = None, session_id: str = "",
                      task_id: str = "", **_: Any):
    """Recuerda qué carpetas no dejó borrar Hermes, para no aceptar después borrarlas archivo por archivo."""
    if tool_name != "terminal" or BLOCKED_RECURSIVE not in str(result or ""):
        return None
    cmd = str((args or {}).get("command") or "") if isinstance(args, dict) else ""
    _bloqueados.setdefault(session_id, set()).update(_rm_targets(cmd, session_cwd(task_id, session_id)))
    return None


def on_pre_verify(session_id: str = "", attempt: int = 0, changed_paths: Any = (), **_: Any):
    if attempt:
        return None  # un solo empujón por turno
    t0 = _t0(session_id)
    base = session_cwd(session_id)
    problemas = []
    changed_paths = [str(_abs(p, base)) for p in changed_paths or []]
    roots = {r for r in (project_root(p) for p in changed_paths) if r}
    for root in sorted(roots):
        junk = _junk(root, t0)
        if junk:
            problemas.append(f"- Restos generados en esta sesión dentro de {root}: {', '.join(junk)}. Bórralos; "
                             "si el borrado está bloqueado, déjalos y nómbralos en el reporte.")
    for p in changed_paths or []:
        path = Path(str(p))
        if path.suffix == ".py" and (path.name.startswith("test_") or "tests" in path.parts):
            try:
                if SCRATCH_REF_RE.search(path.read_text(errors="replace")):
                    problemas.append(f"- {path} depende del scratch (TMPDIR), que se poda a las 24 h: mueve lo que "
                                     "use a tests/ o dentro del test.")
            except OSError:
                pass
    if not problemas:
        return None
    logger.info("reglas_codigo: pre_verify con %d hallazgos", len(problemas))
    return {
        "action": "continue",
        "message": "reglas_codigo, revisión antes de cerrar:\n" + "\n".join(problemas)
                   + "\nCorrige esto y en el reporte da como cobertura principal la de la suite sola.",
    }


def register(ctx) -> None:
    ctx.register_hook("pre_tool_call", on_pre_tool_call)
    ctx.register_hook("post_tool_call", on_post_tool_call)
    ctx.register_hook("pre_verify", on_pre_verify)
