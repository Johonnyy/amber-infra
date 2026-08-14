"""The mirrored auth module, case for case.

``app/auth.py`` is a deliberate copy of ``agent_mcp.auth`` — see its docstring for
why. These cases mirror the original's suite, because the point of the copy is that
it behaves identically; ``tests/test_contract_agent_mcp.py`` then proves it over the
wire.
"""

from __future__ import annotations

import hmac

from app import auth
from app.auth import extract_bearer, fingerprint, parse_keys, verify_bearer, verify_token


def test_a_bare_token_is_parsed_with_a_fingerprint_caller_label():
    keys = parse_keys("abc123")
    assert keys == {"abc123": fingerprint("abc123")}
    assert keys["abc123"].startswith("sha256:")


def test_a_named_token_is_parsed_with_its_name():
    assert parse_keys("amber:abc123") == {"abc123": "amber"}


def test_several_keys_are_parsed_together():
    assert parse_keys("amber:a,Aperture:b,c") == {
        "a": "amber", "b": "Aperture", "c": fingerprint("c")
    }


def test_a_trailing_comma_is_not_a_footgun():
    assert parse_keys("amber:a, ,") == {"a": "amber"}


def test_an_empty_key_list_parses_to_nothing():
    assert parse_keys("") == {}
    assert parse_keys(None) == {}


def test_a_fingerprint_is_stable_and_does_not_contain_the_token():
    assert fingerprint("s3cret") == fingerprint("s3cret")
    assert "s3cret" not in fingerprint("s3cret")


def test_the_bearer_scheme_is_matched_case_insensitively():
    assert extract_bearer("bearer tok") == "tok"
    assert extract_bearer("BEARER  tok  ") == "tok"


def test_a_bare_token_without_the_bearer_scheme_is_rejected():
    """Accepting it would let a malformed header pass for a credential."""
    assert extract_bearer("tok") == ""
    assert extract_bearer("Basic tok") == ""
    assert extract_bearer(None) == ""


def test_no_configured_keys_rejects_everything():
    result = verify_bearer("Bearer anything", {})
    assert result.ok is False
    assert "SYNC_STORE_KEYS" in result.reason


def test_no_configured_keys_admits_anonymous_only_when_explicitly_allowed():
    result = verify_bearer(None, {}, allow_anonymous=True)
    assert result.ok is True
    assert result.caller == auth.CALLER_ANONYMOUS


def test_a_missing_header_is_rejected_when_keys_are_configured():
    result = verify_bearer(None, {"tok": "amber"})
    assert result.ok is False
    assert "Authorization" in result.reason


def test_an_unrecognised_token_is_rejected():
    result = verify_bearer("Bearer wrong", {"tok": "amber"})
    assert result.ok is False
    assert result.reason == "unrecognised bearer token"


def test_a_recognised_token_returns_its_caller_name():
    assert verify_bearer("Bearer tok", {"tok": "amber"}).caller == "amber"


def test_verification_checks_every_key_without_short_circuiting(monkeypatch):
    """Neither the wall-clock time nor the comparison count may leak a prefix."""
    calls = []
    real = hmac.compare_digest

    def counting(a, b):
        calls.append(b)
        return real(a, b)

    monkeypatch.setattr(auth.hmac, "compare_digest", counting)
    keys = {"a": "one", "b": "two", "c": "three"}
    assert verify_token("a", keys) == "one"
    assert len(calls) == len(keys)
