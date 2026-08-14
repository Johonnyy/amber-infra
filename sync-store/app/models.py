"""Wire shapes, and the name rules the registry re-validates.

The request models here are the **server side** of contracts defined elsewhere:
``ServerDescriptor`` must accept exactly what
``agent_mcp.sync_client.build_descriptor`` emits, and the record served back must
carry the keys ``agent_mcp.registry.PeerRegistry.refresh`` reads. Neither can be
changed unilaterally; ``tests/test_contract_agent_mcp.py`` holds both ends together.

``ServerDescriptor`` allows extra fields on purpose. Registration is a fleet-wide
heartbeat: if a future version of the library adds a descriptor key, a store that
422s on it would silently de-register every app that upgraded, halfway through a
rollout, with the failure swallowed by ``register()``'s bare except. Accepting and
ignoring the unknown key is the only behaviour that degrades gracefully.
"""

from __future__ import annotations

import re

from pydantic import BaseModel, ConfigDict, Field, field_validator

#: Mirrors ``agent_mcp.schema.TOOL_NAME_RE``. Snake_case, starts with a letter.
_NAME_RE = re.compile(r"^[a-z][a-z0-9_]{0,39}$")

#: 64 - len("__") - 40, from ``agent_mcp.schema``. An app name is half of every
#: namespaced tool name ``<app>__<tool>``, and 64 is the provider ceiling for a
#: function name — so the app name gets a tighter cap than a tool name, or two
#: individually legal names combine into an illegal one. The client already checks
#: this; the store checks it again because a name that gets in here becomes a
#: namespace every agent in the ecosystem will try to use.
MAX_APP_NAME_LEN = 64 - 2 - 40


def validate_app_name(name: str) -> str:
    """Return ``name`` or raise ``ValueError``, matching ``agent_mcp.schema``."""
    if not name:
        raise ValueError("app name must not be empty")
    if len(name) > MAX_APP_NAME_LEN:
        raise ValueError(
            f"app name {name!r} is {len(name)} characters; the limit is "
            f"{MAX_APP_NAME_LEN} so that '<app>__<tool>' stays inside the "
            "64-character provider limit"
        )
    if "__" in name:
        raise ValueError(
            f"app name {name!r} contains '__', which agent_runtime uses as the "
            "<server>__<tool> namespace separator; use single underscores"
        )
    if name.endswith("_"):
        raise ValueError(f"app name {name!r} must not end with an underscore")
    if not _NAME_RE.match(name):
        raise ValueError(
            f"app name {name!r} must be snake_case: lowercase letters, digits and "
            "underscores, starting with a letter"
        )
    return name


class ServerDescriptor(BaseModel):
    """Exactly what ``sync_client.build_descriptor`` POSTs, no envelope."""

    # extra="allow" so a future library version's new field does not 422 a fleet
    # mid-rollout. See the module docstring.
    model_config = ConfigDict(extra="allow")

    name: str
    base_url: str
    mcp_path: str = "/mcp"
    version: str = ""
    tools: list[dict] = Field(default_factory=list)
    resources: list[dict] = Field(default_factory=list)

    @field_validator("name")
    @classmethod
    def _check_name(cls, value: str) -> str:
        return validate_app_name(value.strip())

    @field_validator("base_url")
    @classmethod
    def _check_base_url(cls, value: str) -> str:
        cleaned = value.strip().rstrip("/")
        if not cleaned:
            # register() refuses to send an empty base_url at all, so this only
            # catches a hand-rolled registration — but a record without one is
            # skipped silently by PeerRegistry, which is a bad way to find out.
            raise ValueError("base_url must not be empty")
        return cleaned


class RegisterResponse(BaseModel):
    """Never parsed by the real client — it only calls ``raise_for_status()``.

    This body exists for ``curl`` and for Aperture.
    """

    status: str = "ok"
    name: str
    created: bool
    last_seen: str


class TokenUpdate(BaseModel):
    """Set or clear the peer credential. ``""`` clears."""

    token: str = ""


class ConfigWrite(BaseModel):
    device_id: str = Field(min_length=1)
    #: A JSON object, not an array or scalar. The store never looks inside it; the
    #: one structural constraint exists so metadata keys could be added later
    #: without ambiguity about what the top level is.
    blob: dict


class ConfigRead(BaseModel):
    id: int | None
    device_id: str | None
    blob: dict | None
    created_at: str | None


class HealthResponse(BaseModel):
    status: str
    service: str
    version: str
