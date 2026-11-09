# urllib3 exception constructor signatures (for mocking in requests.adapters tests)

Condensed from `inspect.signature(exc.__init__)` on the installed urllib3 version.

| Exception | Signature | Notes |
|---|---|---|
| `NewConnectionError` | `(self, conn, message)` | positional: pool/conn object, then message string |
| `ConnectTimeoutError` | `(self, /, *args, **kwargs)` | flexible; accepts message |
| `ReadTimeoutError` | `(self, pool, url, message)` | three positional args |
| `ProxyError` | `(self, message, error)` | message string, then cause exception or None |
| `ClosedPoolError` | `(self, pool, message)` | pool object, then message |
| `InvalidHeader` | `(self, /, *args, **kwargs)` | flexible |
| `SSLError` | `(self, /, *args, **kwargs)` | flexible |
| `HTTPError` | `(self, /, *args, **kwargs)` | base class, flexible |
| `MaxRetryError` | `(self, pool, url, reason=None)` | pool, url string, optional exception |
| `LocationValueError` | `(self, /, *args, **kwargs)` | flexible |
| `ResponseError` | `(self, /, *args, **kwargs)` | flexible |

Rule: always verify against the installed urllib3 with `inspect.signature` before constructing an exception in a test. A wrong arg count raises `TypeError` at test setup, masking the behavior under test.
