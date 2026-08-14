"""Bearer-token verification — a deliberate mirror of ``agent_mcp.auth``.

**This is a copy, and the copy is the design.** The obvious alternative is to
``pip install agent-mcp-py`` and ``from agent_mcp.auth import verify_bearer``. That
was considered and rejected, for four reasons worth writing down so nobody "fixes"
it later:

1. **Availability blast radius.** Every app in the ecosystem calls this service to
   register and to discover peers, so it must be the most boring, most available
   process on Server A. ``agent-mcp-py`` declares ``mcp>=2.0,<3`` — an SDK
   regression would take out discovery for everything at once, through a dependency
   this service uses for forty lines of string comparison.
2. **Dependency direction.** The library's clients call this service. Depending on
   the library inverts that and creates a re-pinning cycle: no store fix without
   choosing a library commit, no library bump without re-pinning the store.
3. **It was built to be copied.** ``agent-mcp-py``'s own conventions call ``auth.py``
   a leaf module of "pure functions with no third-party imports". Nothing here needs
   a package boundary.
4. **Drift is caught by the wire, not by the import.** ``tests/test_contract_agent_mcp.py``
   drives the *real* ``agent_mcp`` client against a live instance of this service, so
   a divergence fails CI at the layer that actually matters. That test is the entire
   reason ``agent-mcp-py`` is a dev-only dependency.

Two rules carried over unchanged:

* **Fail closed.** No configured keys means every call is rejected, not that auth is
  off. ``allow_anonymous`` is the explicit opt-out, for local development only.
* **Never log a token, not even truncated.** Keys may be written ``name:token`` and
  the name is what gets logged; a bare token falls back to a ``sha256:`` fingerprint
  that identifies a caller across log lines without being reversible.

Two deliberate deviations from the original: ``header_value`` is dropped (Starlette
lowercases header names, so FastAPI callers never need it) and so is
``CALLER_LOCAL`` (this service has no stdio or in-process path — every call arrives
over HTTP).
"""

from __future__ import annotations

import hashlib
import hmac
import logging
from collections.abc import Mapping
from dataclasses import dataclass

logger = logging.getLogger(__name__)

CALLER_ANONYMOUS = "anonymous"
#: Stamped on a log line for a call refused before it authenticated, so a rejected
#: attempt still leaves a trace rather than vanishing.
CALLER_UNAUTHENTICATED = "unauthenticated"

#: The realm advertised on a 401. Deviates from agent-mcp-py's "agent-mcp" on
#: purpose — nothing parses the realm, and naming the service is more useful in a
#: browser prompt or a curl trace.
REALM = "sync-store"


@dataclass(frozen=True)
class AuthResult:
    ok: bool
    caller: str
    reason: str = ""


def fingerprint(token: str) -> str:
    """A stable, non-reversible label for a caller presenting a bare token."""
    return "sha256:" + hashlib.sha256(token.encode("utf-8")).hexdigest()[:8]


def parse_keys(raw: str | None) -> dict[str, str]:
    """Parse a comma-separated key list into ``{token: caller_name}``.

    Accepts both the plain form (``"abc123,def456"``) and a ``name:token`` form
    (``"amber:abc123,lucidity:def456"``) that makes a registration attributable.
    Blank entries and surrounding whitespace are ignored so a trailing comma in a
    ``.env`` file is not a footgun.
    """
    keys: dict[str, str] = {}
    for entry in (raw or "").split(","):
        entry = entry.strip()
        if not entry:
            continue
        name, sep, token = entry.partition(":")
        if sep and token.strip():
            keys[token.strip()] = name.strip() or fingerprint(token.strip())
        else:
            keys[entry] = fingerprint(entry)
    return keys


def extract_bearer(header: str | None) -> str:
    """Pull the token out of an ``Authorization`` value.

    Tolerates extra internal whitespace and odd casing of the scheme. A bare token
    with no ``Bearer`` scheme is rejected — accepting it would mean a malformed
    header could be mistaken for a valid credential.
    """
    if not header:
        return ""
    scheme, _, rest = header.strip().partition(" ")
    if scheme.lower() != "bearer":
        return ""
    return rest.strip()


def verify_token(token: str, keys: Mapping[str, str]) -> str | None:
    """Return the caller name for ``token``, or ``None``.

    Compares against **every** key with :func:`hmac.compare_digest` and without
    short-circuiting, so neither the wall-clock time nor the number of comparisons
    leaks which prefix was correct.
    """
    match: str | None = None
    for known, caller in keys.items():
        if hmac.compare_digest(token, known):
            match = caller
    return match


def verify_bearer(
    header: str | None,
    keys: Mapping[str, str],
    *,
    allow_anonymous: bool = False,
) -> AuthResult:
    """Authenticate one inbound request from its ``Authorization`` header."""
    if not keys:
        if allow_anonymous:
            return AuthResult(True, CALLER_ANONYMOUS)
        return AuthResult(
            False,
            "",
            "no bearer keys configured (set SYNC_STORE_KEYS, or "
            "SYNC_STORE_ALLOW_ANONYMOUS=true for local development)",
        )

    token = extract_bearer(header)
    if not token:
        # agent_mcp.sync_client omits the Authorization header entirely when its
        # token is empty, so this is the branch an unconfigured app lands in.
        if allow_anonymous:
            return AuthResult(True, CALLER_ANONYMOUS)
        return AuthResult(False, "", "missing or malformed Authorization header")

    caller = verify_token(token, keys)
    if caller is None:
        return AuthResult(False, "", "unrecognised bearer token")
    return AuthResult(True, caller)
