"""Autoprueba del plugin reglas_codigo. Uso: python3 -I hermes/plugins/prueba_reglas_codigo.py"""

import importlib.util
import os
import sys
import tempfile
import time
from pathlib import Path

base = Path(tempfile.mkdtemp()).resolve()
home = base / "home"
(home / "cache" / "scratch").mkdir(parents=True)
os.environ["HERMES_HOME"] = str(home)

spec = importlib.util.spec_from_file_location(
    "reglas_codigo", Path(__file__).parent / "reglas_codigo" / "__init__.py")
rc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rc)
rc.EXCLUDED = (home,)  # el temporal del sistema puede estar bajo /tmp

proj = base / "proj"
(proj / "tests").mkdir(parents=True)
(proj / "pyproject.toml").write_text("")
sin_tests = base / "otro"
sin_tests.mkdir()
(sin_tests / "pyproject.toml").write_text("")
S = "s1"


def act(r):
    return r.get("action") if isinstance(r, dict) else None


# 1. Línea base (incluye ruta relativa al cwd de la sesión, que no es el del proceso)
rc.session_cwd = lambda *keys: str(proj)
assert act(rc.on_pre_tool_call("patch", {"path": "tests/test_a.py"}, session_id=S, task_id=S)) == "block"
assert act(rc.on_pre_tool_call("write_file", {"path": str(proj / "tests/test_a.py")}, session_id=S)) == "block"
assert act(rc.on_pre_tool_call("patch", {"patch": f"*** Update File: {proj}/src/m.py\n"}, session_id=S)) == "block"
assert rc.on_pre_tool_call("write_file", {"path": str(proj / "README.md")}, session_id=S) is None
assert rc.on_pre_tool_call("write_file", {"path": str(home / "cache/scratch/probe.py")}, session_id=S) is None
assert rc.on_pre_tool_call("write_file", {"path": str(sin_tests / "m.py")}, session_id=S) is None
viejo = home / "cache/scratch/fallas-antes-viejo.txt"
viejo.write_text("")
os.utime(viejo, (time.time() - 3600,) * 2)
assert act(rc.on_pre_tool_call("write_file", {"path": str(proj / "tests/test_a.py")}, session_id=S)) == "block"
(home / "cache/scratch/fallas-antes.txt").write_text("")
assert rc.on_pre_tool_call("write_file", {"path": str(proj / "tests/test_a.py")}, session_id=S) is None

# 2. Borrados por otra vía
script = home / "cache/scratch/rm_egg.py"
script.write_text("import shutil\nshutil.rmtree('x')\n")
assert act(rc.on_pre_tool_call("terminal", {"command": f"python3 {script}"}, session_id=S)) == "approve"
assert act(rc.on_pre_tool_call("execute_code", {"code": "import os; os.unlink('a')"}, session_id=S)) == "approve"
assert act(rc.on_pre_tool_call("terminal", {"command": "find . -name '*.pyc' -delete"}, session_id=S)) == "approve"
assert rc.on_pre_tool_call("terminal", {"command": f"pytest {script}"}, session_id=S) is None
assert rc.on_pre_tool_call("terminal", {"command": "rm -f .coverage"}, session_id=S) is None
assert rc.on_pre_tool_call("terminal", {"command": "find . -name '*.py'"}, session_id=S) is None
egg = proj / "src/requests.egg-info"
egg.mkdir(parents=True)
(egg / "PKG-INFO").write_text("")
rc.on_post_tool_call("terminal", {"command": "cd /otro && rm -rf " + str(egg)}, S, session_id=S)
assert rc.on_post_tool_call("terminal", {"command": "rm -rf src/requests.egg-info"},
                            rc.BLOCKED_RECURSIVE + " but ...", session_id=S) is None
assert act(rc.on_pre_tool_call("terminal", {"command": f"cd {proj} && rm src/requests.egg-info/PKG-INFO"},
                               session_id=S)) == "approve"
assert act(rc.on_pre_tool_call("terminal", {"command": "rmdir src/requests.egg-info"}, session_id=S)) == "approve"
assert rc.on_pre_tool_call("terminal", {"command": "rm -f .coverage"}, session_id=S) is None
assert rc.on_pre_tool_call("terminal", {"command": "rm -rf /x/y"}, session_id="otra") is None
(egg / "PKG-INFO").unlink()
egg.rmdir()

# 3. Revisión al cerrar
t = proj / "tests/test_a.py"
t.write_text("def test_x():\n    assert 1\n")
assert rc.on_pre_verify(session_id=S, attempt=0, changed_paths=[str(t)]) is None
(proj / ".coverage").write_text("")
r = rc.on_pre_verify(session_id=S, attempt=0, changed_paths=[str(t)])
assert act(r) == "continue" and ".coverage" in r["message"], r
assert rc.on_pre_verify(session_id=S, attempt=1, changed_paths=[str(t)]) is None
(proj / ".coverage").unlink()
t.write_text("import os\nD = os.environ['TMPDIR']\n")
r = rc.on_pre_verify(session_id=S, attempt=0, changed_paths=[str(t)])
assert act(r) == "continue" and "scratch" in r["message"], r
r = rc.on_pre_verify(session_id=S, attempt=0, changed_paths=["tests/test_a.py"])  # relativa
assert act(r) == "continue" and "scratch" in r["message"], r

print("autoprueba reglas_codigo: OK")
