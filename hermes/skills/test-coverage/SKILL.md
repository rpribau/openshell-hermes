---
name: test-coverage
description: "Use when increasing coverage of an existing Python module."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [testing, coverage, unit-tests, mocks, legacy-code]
    related_skills: [test-driven-development, systematic-debugging]
---

# Test Coverage of an Existing Module

## When to Use

Use this skill when the goal is to increase measured coverage of an already-written Python module (e.g. `src/requests/adapters.py` from 34% to 99%) without network access, by writing unit tests that exercise real code paths and mock out external dependencies.

Not for writing brand-new features (that is TDD) and not for debugging a live failure (that is systematic-debugging).

## Procedure — do the steps in this order

### 1. Establish a baseline

Run coverage against the target module with the existing test suite so you know the starting number and which lines are missing.

```bash
# From the repo root, using the project's interpreter
python -m pytest tests/ -q --cov=<imported.package.name> --cov-report=term-missing
```

Note the module's total lines and uncovered line numbers. The package name is the import name (e.g. `requests`), not a filesystem path like `src.requests` — coverage reports import names.

### 2. Build a working interpreter that imports the module under test

If the repo installs a different version of the package in site-packages than the one under `src/`, an editable install pointing at `src/` is required so coverage measures the right file.

```bash
python -m venv /tmp/<env-name>
/tmp/<env-name>/bin/python -m pip install --quiet pytest pytest-cov pytest-mock
/tmp/<env-name>/bin/python -m pip install --quiet -e .   # from repo root
```

Verify: `python -c "import <package>; print(<package>.__file__)"` must print a path under `src/`, not site-packages.

### 3. Write tests that construct real objects and mock external deps

Prefer constructing real in-process objects (PreparedRequest, HTTPAdapter, etc.) and mocking only the external boundary (urllib3 connections, pools, sockets). Do not spin up real servers or hit httpbin for a coverage-only task — those tests are slow, flaky, and add little line coverage.

Write one test per behavior branch. Group by module section with clear comment headers.

### 4. Run the new test file and confirm every test passes

```bash
python -m pytest tests/test_<module>.py -q --cov=<package> --cov-report=term-missing
```

Confirm the count goes up and the missing-line list shrinks.

### 5. Lint the test file

```bash
python -m ruff check tests/test_<module>.py
python -m ruff check --fix tests/test_<module>.py   # fix import-order / unused imports
```

Re-run tests after `--fix` to confirm nothing broke.

### 6. Close the loop

When coverage stops improving meaningfully, stop. Report the final percentage, the remaining uncovered lines and why each is unreachable (e.g. a stub that needs a missing dependency installed).

## Pitfalls

**urllib3 exception constructors are version-specific.** `ProxyError(message, error)`, `ClosedPoolError(pool, message)`, `ReadTimeoutError(pool, url, message)`, `NewConnectionError(conn, message)`, `MaxRetryError(pool, url, reason)` all take positional args in fixed orders. Passing the wrong number of args raises `TypeError` at test-setup time, not a clean assertion failure. Check `inspect.signature(exc.__init__)` before constructing.

**`NewConnectionError` inside `MaxRetryError` maps to `ConnectionError`, not `ConnectTimeout`.** In `requests.adapters.HTTPAdapter.send`, the `ConnectTimeout` branch requires `e.reason` to be a `ConnectTimeoutError` that is NOT also a `NewConnectionError`. A bare `NewConnectionError` falls through to `ConnectionError`. Assert the exception the code actually raises, not the one you expect from the urllib3 docs.

**`DEFAULT_POOLSIZE`, `DEFAULT_CA_BUNDLE_PATH`, etc. are module-level constants in `requests.adapters`, not class attributes.** Import them from `requests.adapters` directly; `HTTPAdapter.DEFAULT_POOLSIZE` does not exist.

**`get_connection_with_tls_context` lets `LocationValueError` from the poolmanager propagate** — it only converts `LocationValueError` raised by `build_connection_pool_key_attributes`, not the one raised inside `poolmanager.connection_from_host`. A URL with no host raises `LocationValueError` directly, not `InvalidURL`.

**A URL with an invalid port (`:notaport`) is rejected by `PreparedRequest.prepare()` before it ever reaches `get_connection_with_tls_context`.** To cover the `ValueError → InvalidURL` branch at adapters.py:490-491, mock `build_connection_pool_key_attributes` to raise `ValueError` instead of trying to feed a bad URL through `prepare()`.

**`--cov=<path>` vs `--cov=<import-name>`**: use the import name (`requests`), not a filesystem path (`src.requests`), or coverage reports "module never imported" and collects no data.

**A stub that depends on a missing optional dependency is unreachable without uninstalling that dependency.** The SOCKS stub at `adapters.py:66` raises `InvalidSchema` only when `SOCKSProxyManager` import fails (PySocks absent). With PySocks installed the real class is used and the stub line is unreachable. Do not force coverage of lines that require breaking the environment.

## Verification Checklist

- [ ] Baseline coverage captured before writing tests
- [ ] New test file passes in full (`69 passed` or equivalent)
- [ ] Coverage percentage increased and missing-line list shrank
- [ ] `ruff check tests/test_<module>.py` reports `All checks passed!`
- [ ] Tests re-run green after any `ruff --fix`
- [ ] Remaining uncovered lines each have a documented reason they are unreachable

## Support files

- `references/urllib3-exception-constructors.md` — condensed constructor signatures for the urllib3 exceptions raised/handled in `requests.adapters`, so future sessions do not re-derive them.
"""