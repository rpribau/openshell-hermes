---
name: git-clone-restricted-network
description: Clone a git repo through policy.local in OpenShell.
version: 0.1.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [git, clone, policy.local, network-policy, sandbox, openshell]
    related_skills: [github, blocked-page-recovery]
---

# Clone a Git Repository Under a policy.local Network Gate

Acquire a remote git repository in an OpenShell/NemoClaw sandbox where outbound
network is denied by default and mediated through `http://policy.local`. The
workflow prefers `git clone` when policy allows it; otherwise it obtains a
narrow network rule for the exact host/binary, or falls back to downloading a
repository ZIP via an authorized binary (curl) and extracting it with Python.

This is a class-level skill for the recurring task "get this repo into the
sandbox" when `git clone` fails with a policy denial. It is not about GitHub
specifically — any host reachable through policy.local applies.

## When to Use

- `git clone <url> <dest>` fails with `CONNECT tunnel failed, response 403`
  or any `policy_denied` / OCSF NET:OPEN DENIED line for the git binary.
- You need a repository's files in `/sandbox/...` and egress is controlled by
  `policy.local` (the OpenShell sandbox-local policy API).

Don't use for:
- GitHub PRs/issues via `gh` (that's the `github` skill — different tool,
  different policy surface).
- Recovering a paywalled or WAF-blocked webpage (that's
  `blocked-page-recovery` — HTML surface, not git transport).
- A host with unrestricted egress — just `git clone` directly.

## Prerequisites

- `git` installed (`/usr/bin/git` and `/usr/lib/git-core/git-remote-http`).
- `curl` installed (`/usr/bin/curl`) — fallback path.
- Python 3 available for ZIP extraction when `unzip` is missing.
- The sandbox exposes `http://policy.local` (read `/etc/openshell/skills/
  policy_advisor.md` if you have never used it).

## Procedure

### 1. Try the direct clone first

Run `git clone <url> <dest>`. If it succeeds, stop — verification in step 6.

### 2. Read the denial and the current policy

If clone fails, gather evidence before proposing anything:

- `GET http://policy.local/v1/denials?last=10` — which binary, host, port,
  and policy were denied.
- `GET http://policy.local/v1/policy/current` — does the host:port already
  exist in some policy, and which binaries does it list?

### 3. Decide L7 REST vs L4 tunnel

Choose the rule shape by binary and host:

- **L7 REST** when the host has a documented REST surface and the binary can
  speak REST (`curl`, python `urllib`/`requests`). Propose `protocol: rest`,
  `enforcement: enforce`, exact host, exact port 443, `method: GET`, the
  smallest safe path (`/**` for public content), and exact binaries. No
  credential in scope → auto-approves under auto mode.
- **L4 `access: full`** when the binary's wire protocol is opaque to L7
  inspection (`/usr/bin/git`, `/usr/lib/git-core/git-remote-http`, `/usr/bin/
  ssh`, `/usr/bin/nc`). Propose exact host, exact port, `access: full`,
  exact binaries. This reaches review (human), not auto-approval.

Never propose access to link-local addresses (`169.254.0.0/16`, `fe80::/10`)
or metadata hostnames such as `metadata.google.internal`.

### 4. Avoid endpoint overlap conflicts

Do not create a second rule whose host:port duplicates an existing endpoint
in another policy with conflicting metadata (e.g. `github.com:443` already in
`brew-balanced` with `access: full` — a second git rule on the same host:port
is rejected as endpoint ambiguity). Work within the existing endpoint or pick
a distinct host.

### 5. Submit the proposal

`POST http://policy.local/v1/proposals` with:

```json
{
  "intent_summary": "<one line: what and why, public content / no creds>",
  "operations": [
    {
      "addRule": {
        "ruleName": "<snake_case>",
        "rule": {
          "name": "<snake_case>",
          "endpoints": [{
            "host": "<exact host>",
            "port": 443,
            ... rest rules or access: full ...
          }],
          "binaries": [{"path": "/usr/bin/..."}]
        }
      }
    }
  ]
}
```

Save `accepted_chunk_ids` from the 202 response. If `rejection_reasons` is
non-empty, fix those operations and resubmit before waiting.

### 6. Wait for the decision

For each accepted `chunk_id`:

`GET http://policy.local/v1/proposals/{chunk_id}/wait?timeout=300`

Act on the result:
- `approved` + `policy_reloaded: true` — retry the original denied action.
  If it still fails `policy_denied`, your rule did not match; re-read the
  denial.
- `approved` + `policy_reloaded: false` — re-issue the same `/wait` once
  with `timeout=30`. If still false, surface to the user.
- `rejected` — read `rejection_reason` and `validation_result`; address the
  specific feedback and submit a revised proposal.
- `pending` + `timed_out: true` — call `/wait` again.
- Non-2xx — surface to the user; do not retry without approval.

### 7. Fallback: ZIP via curl when git cannot be authorized

If `git`/`git-remote-http` cannot reach the host (wire protocol, human review
too slow), but `curl` is authorized for the content host, download the repo
ZIP and extract:

- `curl -sL --fail https://<codeload-host>/<org>/<repo>/zip/refs/heads/<branch>
  -o /tmp/repo.zip`
  (The ZIP may live on a different host than the HTML page — e.g.
  `codeload.github.com`, not `github.com`. Propose the rule for the actual
  content host.)
- Extract with Python `zipfile` — `unzip` is often not installed.
- Move the inner `<repo>-<branch>/` contents into `<dest>`.

### 8. Verify

- List `<dest>` and confirm the expected tree (e.g. `pyproject.toml`, `setup.py`,
  `src/`, `tests/`).
- Count files: `find <dest> -type f | wc -l`.
- Note: a ZIP fallback yields no `.git` — there is no git history, branches,
  or remote. Tell the user explicitly if they need a real git clone.

## Pitfalls

- `git clone` failing with `CONNECT tunnel failed, response 403` is a policy
deny on the tunnel, not a generic network outage. Do not retry blindly.
- `git-remote-http` is a wire protocol opaque to L7 inspection; an L4 rule
  for it grants unbounded reach and goes to human review — expect delay.
- Do not overlap an existing endpoint (same host:port) with a new rule of
  conflicting metadata; the prover rejects it as endpoint ambiguity.
- `unzip` may not be installed — extract ZIPs with Python `zipfile`, not the
  shell.
- Public-content L7 GET against a host with no credential in scope auto-
  approves; credentialed reach or new methods on credentialed hosts escalate
  to review.
- `codeload.github.com` is a distinct host from `github.com`; propose rules
  for the host that actually serves the bytes.

## Verification

The task is done when `<dest>` contains the repository's working tree and the
user has confirmed whether they need `.git` (history/remote) or just the
files. Report which path was used (git clone vs ZIP fallback) and whether a
`.git` is present.
