#!/usr/bin/env python3
"""Write ~/.notchmeter/quota.json for Agent Overlord.

The file is the contract. Each row is one account and one provider. ``state``
is ``open`` or ``exhausted`` only after a live provider response. ``remaining``
is filled only with a number that response carried. ``resets_at`` is filled
only with a timestamp that response carried. Anything else is ``unknown`` with
both fields null.

This command reads OAuth tokens a provider's own client already stored. It
never asks for a password, never writes a token, and never refreshes one.
It does not choose which account should run a job.
"""

from __future__ import annotations

import base64
import json
import math
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Mapping

SCHEMA_KEYS = ("updated_at", "accounts")
ROW_KEYS = ("email", "provider", "state", "remaining", "resets_at")
STATES = ("open", "exhausted", "unknown")
PROVIDERS = ("chatgpt", "supergrok", "antigravity")

# Roster order is the file order. johnmatveyev has three provider rows.
ROSTER: tuple[tuple[str, str], ...] = (
    ("ascendmaui@gmail.com", "supergrok"),
    ("johnmatveyev@gmail.com", "chatgpt"),
    ("johnmatveyev@gmail.com", "supergrok"),
    ("johnmatveyev@gmail.com", "antigravity"),
    ("503meds@gmail.com", "antigravity"),
    ("ascendlifesc@gmail.com", "antigravity"),
    ("ascendlifeinsurance@gmail.com", "antigravity"),
    ("powerevllc@gmail.com", "antigravity"),
    ("jvmsalesllc@gmail.com", "antigravity"),
)

CHATGPT_URL = "https://chatgpt.com/backend-api/wham/usage"
SUPERGROK_URL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
CODE_ASSIST_HOSTS = (
    "daily-cloudcode-pa.googleapis.com",
    "cloudcode-pa.googleapis.com",
)
USER_AGENT = "Notchmeter-quota-status/1"
EXPIRY_SKEW = timedelta(seconds=30)
PLACEHOLDER_RESET = timedelta(hours=5)
PLACEHOLDER_TOLERANCE = timedelta(seconds=120)

PATH_CHATGPT = "scripts/quota_status.py:probe_chatgpt"
PATH_SUPERGROK = "scripts/quota_status.py:probe_supergrok"
PATH_ANTIGRAVITY = "scripts/quota_status.py:probe_antigravity"

Transport = Callable[[str, str, Mapping[str, str], bytes | None, float], tuple[int, bytes]]


@dataclass(frozen=True)
class Credential:
    email: str
    access_token: str
    expires_at: datetime | None
    source: str
    account_id: str | None = None
    logged_host: str | None = None


@dataclass(frozen=True)
class Note:
    email: str
    provider: str
    state: str
    detail: str
    code_path: str


def quota_path(home: Path) -> Path:
    return home / ".notchmeter" / "quota.json"


def number(value: object) -> int | float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if isinstance(value, float) and (math.isnan(value) or math.isinf(value)):
        return None
    return value


def parse_time(value: object) -> datetime | None:
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        try:
            parsed = datetime.fromisoformat(text)
        except ValueError:
            return None
        if parsed.tzinfo is None:
            return None
        return parsed.astimezone(timezone.utc)
    parsed_number = number(value)
    if parsed_number is None:
        return None
    seconds = parsed_number / 1000 if parsed_number > 10_000_000_000 else parsed_number
    try:
        return datetime.fromtimestamp(seconds, timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None


def iso_z(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def row(email: str, provider: str, state: str, remaining: int | float | None, resets_at: str | None) -> dict:
    if state not in STATES:
        raise ValueError(state)
    if provider not in PROVIDERS:
        raise ValueError(provider)
    if state == "unknown":
        remaining = None
        resets_at = None
    return {
        "email": email,
        "provider": provider,
        "state": state,
        "remaining": remaining,
        "resets_at": resets_at,
    }


def unknown_row(email: str, provider: str) -> dict:
    return row(email, provider, "unknown", None, None)


def jwt_payload(token: str) -> dict | None:
    parts = token.split(".")
    if len(parts) < 2:
        return None
    segment = parts[1]
    padded = segment + "=" * (-len(segment) % 4)
    try:
        raw = base64.urlsafe_b64decode(padded.encode("ascii"))
        payload = json.loads(raw)
    except (ValueError, json.JSONDecodeError, UnicodeError):
        return None
    return payload if isinstance(payload, dict) else None


def email_from_claims(claims: dict) -> str | None:
    for key in ("email", "Email"):
        value = claims.get(key)
        if isinstance(value, str) and "@" in value:
            return value.strip().lower()
    profile = claims.get("https://api.openai.com/profile")
    if isinstance(profile, dict):
        value = profile.get("email")
        if isinstance(value, str) and "@" in value:
            return value.strip().lower()
    return None


def display_path(path: Path, home: Path) -> str:
    try:
        relative = path.resolve().relative_to(home.resolve())
    except ValueError:
        return str(path)
    return "~/" + relative.as_posix()


def read_json(path: Path) -> dict | None:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def logged_code_assist_host(log_path: Path) -> str | None:
    try:
        size = log_path.stat().st_size
        with log_path.open("rb") as handle:
            if size > 65_536:
                handle.seek(size - 65_536)
            text = handle.read().decode("utf-8", errors="ignore")
    except OSError:
        return None
    found = re.findall(r"https://([a-z0-9.-]*cloudcode-pa\.googleapis\.com)", text, flags=re.IGNORECASE)
    if not found:
        return None
    host = found[-1].lower()
    return host if host in CODE_ASSIST_HOSTS else None


def _expired(expires_at: datetime | None, now: datetime) -> bool:
    return expires_at is not None and expires_at <= now + EXPIRY_SKEW


def discover_antigravity(home: Path, env: Mapping[str, str], now: datetime) -> tuple[list[Credential], list[Credential], int]:
    """Return (usable, expired, files whose email could not be read)."""
    roots = _antigravity_roots(home, env)
    usable: list[Credential] = []
    expired: list[Credential] = []
    nameless = 0
    seen: set[Path] = set()
    for root in roots:
        for token_path in (
            root / ".gemini" / "antigravity-cli" / "antigravity-oauth-token",
            root / ".gemini" / "oauth_creds.json",
        ):
            try:
                resolved = token_path.resolve()
            except OSError:
                resolved = token_path
            if resolved in seen or not token_path.is_file():
                continue
            seen.add(resolved)
            cred, named = _google_credential(token_path, root, home)
            if cred is None:
                if token_path.is_file():
                    nameless += 0 if named else 1
                continue
            if _expired(cred.expires_at, now):
                expired.append(cred)
            else:
                usable.append(cred)
    return usable, expired, nameless


def _antigravity_roots(home: Path, env: Mapping[str, str]) -> list[Path]:
    roots = [home]
    real = env.get("AGY_REAL_HOME", "").strip()
    if real:
        roots.append(Path(real).expanduser())
    found: list[Path] = []
    seen: set[Path] = set()
    for root in roots:
        if root in seen:
            continue
        seen.add(root)
        found.append(root)
        slots = root / ".agy-accounts"
        if not slots.is_dir():
            continue
        for child in sorted(slots.iterdir()):
            if child.is_dir() and child.name.startswith("acct"):
                found.append(child)
    return found


def _google_credential(token_path: Path, root: Path, home: Path) -> tuple[Credential | None, bool]:
    payload = read_json(token_path)
    if payload is None:
        return None, False
    token = payload.get("access_token")
    if not isinstance(token, str) or not token.strip():
        return None, False
    email = None
    id_token = payload.get("id_token")
    if isinstance(id_token, str):
        claims = jwt_payload(id_token)
        if claims:
            email = email_from_claims(claims)
    named = email is not None
    if email is None:
        email_file = root / "ACCOUNT_EMAIL"
        try:
            text = email_file.read_text(encoding="utf-8").strip().lower()
        except OSError:
            text = ""
        if "@" in text:
            email = text
    if email is None:
        return None, False
    log_path = root / ".gemini" / "antigravity-cli" / "cli.log"
    return Credential(
        email=email,
        access_token=token.strip(),
        expires_at=parse_time(payload.get("expiry_date")),
        source=display_path(token_path, home),
        logged_host=logged_code_assist_host(log_path),
    ), named


def discover_codex(home: Path, env: Mapping[str, str], now: datetime) -> tuple[list[Credential], list[Credential], int]:
    paths: list[Path] = []
    custom = env.get("CODEX_HOME", "").strip()
    if custom:
        paths.append(Path(custom).expanduser() / "auth.json")
    paths.append(home / ".config" / "codex" / "auth.json")
    paths.append(home / ".codex" / "auth.json")
    return _scan_auth_files(paths, home, now, _codex_credential)


def discover_supergrok(home: Path, env: Mapping[str, str], now: datetime) -> tuple[list[Credential], list[Credential], int]:
    paths: list[Path] = []
    custom = env.get("GROK_HOME", "").strip()
    if custom:
        paths.append(Path(custom).expanduser() / "auth.json")
    paths.append(home / ".grok" / "auth.json")
    usable: list[Credential] = []
    expired: list[Credential] = []
    nameless = 0
    seen: set[Path] = set()
    for path in paths:
        try:
            resolved = path.resolve()
        except OSError:
            resolved = path
        if resolved in seen or not path.is_file():
            continue
        seen.add(resolved)
        payload = read_json(path)
        if payload is None:
            nameless += 1
            continue
        entries = payload.values() if _is_entry_map(payload) else [payload]
        found_here = False
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            cred = _supergrok_entry(entry, path, home)
            if cred is None:
                continue
            found_here = True
            if _expired(cred.expires_at, now):
                expired.append(cred)
            else:
                usable.append(cred)
        if not found_here:
            nameless += 1
    return usable, expired, nameless


def _is_entry_map(payload: dict) -> bool:
    return any(isinstance(value, dict) and ("key" in value or "email" in value) for value in payload.values())


def _supergrok_entry(entry: dict, path: Path, home: Path) -> Credential | None:
    email = entry.get("email")
    token = entry.get("key")
    if not isinstance(email, str) or "@" not in email:
        return None
    if not isinstance(token, str) or not token.strip():
        return None
    return Credential(
        email=email.strip().lower(),
        access_token=token.strip(),
        expires_at=parse_time(entry.get("expires_at")),
        source=display_path(path, home),
    )


def _scan_auth_files(paths: list[Path], home: Path, now: datetime, parse) -> tuple[list[Credential], list[Credential], int]:
    usable: list[Credential] = []
    expired: list[Credential] = []
    nameless = 0
    seen: set[Path] = set()
    for path in paths:
        try:
            resolved = path.resolve()
        except OSError:
            resolved = path
        if resolved in seen or not path.is_file():
            continue
        seen.add(resolved)
        cred = parse(path, home)
        if cred is None:
            nameless += 1
            continue
        if _expired(cred.expires_at, now):
            expired.append(cred)
        else:
            usable.append(cred)
    return usable, expired, nameless


def _codex_credential(path: Path, home: Path) -> Credential | None:
    payload = read_json(path)
    if payload is None:
        return None
    tokens = payload.get("tokens")
    if not isinstance(tokens, dict):
        return None
    token = tokens.get("access_token")
    if not isinstance(token, str) or not token.strip():
        return None
    claims = jwt_payload(token) or {}
    id_token = tokens.get("id_token")
    if isinstance(id_token, str):
        claims = {**claims, **(jwt_payload(id_token) or {})}
    email = email_from_claims(claims)
    if email is None:
        return None
    account_id = tokens.get("account_id")
    if not isinstance(account_id, str) or not account_id:
        auth = claims.get("https://api.openai.com/auth")
        if isinstance(auth, dict) and isinstance(auth.get("chatgpt_account_id"), str):
            account_id = auth["chatgpt_account_id"]
        else:
            account_id = None
    return Credential(
        email=email,
        access_token=token.strip(),
        expires_at=parse_time(claims.get("exp")),
        source=display_path(path, home),
        account_id=account_id,
    )


def _remaining_number(document: dict) -> int | float | None:
    for key in ("remaining", "remainingFraction", "remainingCredits", "remaining_credits", "remaining_percent"):
        parsed = number(document.get(key))
        if parsed is not None:
            return parsed
    return None


def _fraction(value: object) -> int | float | None:
    parsed = number(value)
    if parsed is None or parsed < 0 or parsed > 1:
        return None
    return parsed


def classify_chatgpt(payload: dict) -> tuple[str, int | float | None, str | None]:
    windows = _chatgpt_windows(payload)
    if not windows:
        return "unknown", None, None
    exhausted = [window for window in windows if window["used"] >= 100]
    chosen = exhausted or windows
    remaining = next((window["remaining"] for window in chosen if window["remaining"] is not None), None)
    resets = [window["resets_at"] for window in chosen if window["resets_at"] is not None]
    resets_at = iso_z(min(resets)) if resets else None
    state = "exhausted" if exhausted else "open"
    return state, remaining, resets_at


def _chatgpt_windows(payload: dict) -> list[dict]:
    windows: list[dict] = []
    rate_limit = payload.get("rate_limit")
    if isinstance(rate_limit, dict):
        windows.extend(_rate_windows(rate_limit))
    extras = payload.get("additional_rate_limits")
    if isinstance(extras, list):
        for extra in extras:
            if not isinstance(extra, dict):
                continue
            nested = extra.get("rate_limit")
            windows.extend(_rate_windows(nested if isinstance(nested, dict) else extra))
    return windows


def _rate_windows(rate_limit: dict) -> list[dict]:
    windows: list[dict] = []
    for slot in ("primary_window", "secondary_window"):
        window = rate_limit.get(slot)
        if not isinstance(window, dict):
            continue
        used = number(window.get("used_percent"))
        if used is None or used < 0:
            continue
        windows.append({
            "used": used,
            "remaining": _remaining_number(window),
            "resets_at": parse_time(window.get("reset_at")),
        })
    return windows


def classify_supergrok(payload: dict) -> tuple[str, int | float | None, str | None]:
    config = payload.get("config")
    if not isinstance(config, dict):
        return "unknown", None, None
    remaining = _remaining_number(config)
    period = config.get("currentPeriod")
    reset_value = None
    if isinstance(period, dict):
        reset_value = period.get("end")
    if reset_value is None:
        reset_value = config.get("billingPeriodEnd")
    resets_at = parse_time(reset_value)
    reset_text = iso_z(resets_at) if resets_at is not None else None
    if remaining is not None:
        state = "exhausted" if remaining <= 0 else "open"
        return state, remaining, reset_text
    used = number(config.get("creditUsagePercent"))
    if used is not None and used >= 100:
        return "exhausted", None, reset_text
    return "open", None, reset_text


def classify_antigravity(payload: dict, now: datetime) -> tuple[str, int | float | None, str | None]:
    groups = payload.get("groups")
    if not isinstance(groups, list) or not groups:
        return "unknown", None, None
    buckets = _antigravity_buckets(groups)
    if not buckets:
        return "open", None, None
    if _placeholder(buckets, now):
        return "unknown", None, None
    zeros = [bucket for bucket in buckets if bucket["remaining"] == 0]
    if zeros:
        resets = [bucket["resets_at"] for bucket in zeros if bucket["resets_at"] is not None]
        return "exhausted", zeros[0]["remaining"], iso_z(min(resets)) if resets else None
    positive = [bucket for bucket in buckets if bucket["remaining"] is not None and bucket["remaining"] > 0]
    if positive:
        lowest = min(bucket["remaining"] for bucket in positive)
        carriers = [bucket for bucket in positive if bucket["remaining"] == lowest and bucket["resets_at"] is not None]
        reset_text = iso_z(min(bucket["resets_at"] for bucket in carriers)) if carriers else None
        return "open", lowest, reset_text
    resets = [bucket["resets_at"] for bucket in buckets if bucket["resets_at"] is not None]
    return "open", None, iso_z(min(resets)) if resets else None


def _antigravity_buckets(groups: list) -> list[dict]:
    buckets: list[dict] = []
    for group in groups:
        if not isinstance(group, dict):
            continue
        raw_buckets = group.get("buckets")
        if not isinstance(raw_buckets, list):
            continue
        for bucket in raw_buckets:
            if not isinstance(bucket, dict):
                continue
            remaining = _fraction(_direct_remaining(bucket))
            buckets.append({
                "remaining": remaining,
                "resets_at": parse_time(bucket.get("resetTime")),
            })
    return buckets


def _direct_remaining(bucket: dict) -> object:
    if "remainingFraction" in bucket:
        return bucket.get("remainingFraction")
    nested = bucket.get("remaining")
    if isinstance(nested, dict):
        if "remainingFraction" in nested:
            return nested.get("remainingFraction")
        if nested.get("case") == "remainingFraction":
            return nested.get("value")
    return None


def _placeholder(buckets: list[dict], now: datetime) -> bool:
    figured = [bucket for bucket in buckets if bucket["remaining"] is not None]
    if len(figured) < 2:
        return False
    if any(bucket["remaining"] < 0.999 for bucket in figured):
        return False
    if any(bucket["resets_at"] is None for bucket in figured):
        return False
    target = now + PLACEHOLDER_RESET
    return all(abs(bucket["resets_at"] - target) <= PLACEHOLDER_TOLERANCE for bucket in figured)


def exhaustion_message(body: bytes) -> str | None:
    text = body.decode("utf-8", errors="ignore")
    if len(text) > 4000:
        text = text[:4000]
    lowered = text.lower()
    phrases = (
        "quota exhausted",
        "quota exceeded",
        "usage limit reached",
        "usage limit exceeded",
        "out of credits",
        "no remaining quota",
        "resource_exhausted",
        "resource exhausted",
    )
    if not any(phrase in lowered for phrase in phrases):
        return None
    compact = " ".join(text.split())
    return compact[:240]


def _allowed(url: str) -> bool:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https":
        return False
    host = (parsed.hostname or "").lower()
    if host == "chatgpt.com" and parsed.path == "/backend-api/wham/usage":
        return True
    if host == "cli-chat-proxy.grok.com" and parsed.path == "/v1/billing":
        return True
    if host in CODE_ASSIST_HOSTS and parsed.path == "/v1internal:retrieveUserQuotaSummary":
        return True
    return False


def _request(transport: Transport, method: str, url: str, headers: dict[str, str], body: bytes | None) -> tuple[int, bytes] | None:
    if not _allowed(url):
        return None
    try:
        status, payload = transport(method, url, headers, body, 20)
    except (urllib.error.URLError, TimeoutError, OSError):
        return None
    return status, payload


def _json_body(payload: bytes) -> dict | None:
    try:
        parsed = json.loads(payload)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def probe_chatgpt(email: str, creds: list[Credential], expired: list[Credential], nameless: int, transport: Transport) -> tuple[dict, Note]:
    def call(cred: Credential) -> tuple[str, int | float | None, str | None] | None:
        return _call_chatgpt(cred, transport)

    return _probe_matching(
        email,
        "chatgpt",
        creds,
        expired,
        nameless,
        PATH_CHATGPT,
        "Codex auth.json",
        call,
    )


def probe_supergrok(email: str, creds: list[Credential], expired: list[Credential], nameless: int, transport: Transport) -> tuple[dict, Note]:
    def call(cred: Credential) -> tuple[str, int | float | None, str | None] | None:
        return _call_supergrok(cred, transport)

    return _probe_matching(
        email,
        "supergrok",
        creds,
        expired,
        nameless,
        PATH_SUPERGROK,
        "~/.grok/auth.json",
        call,
    )


def probe_antigravity(email: str, creds: list[Credential], expired: list[Credential], nameless: int, transport: Transport, now: datetime) -> tuple[dict, Note]:
    def call(cred: Credential) -> tuple[str, int | float | None, str | None] | None:
        return _call_antigravity(cred, transport, now)

    return _probe_matching(
        email,
        "antigravity",
        creds,
        expired,
        nameless,
        PATH_ANTIGRAVITY,
        "antigravity-oauth-token or oauth_creds.json",
        call,
    )


def _probe_matching(email, provider, creds, expired, nameless, code_path, label, call) -> tuple[dict, Note]:
    matched = [cred for cred in creds if cred.email == email]
    expired_matched = [cred for cred in expired if cred.email == email]
    if not matched and not expired_matched:
        detail = f"no {label} names this email"
        if nameless:
            detail += f"; {nameless} credential file(s) had no email and were not queried"
        return unknown_row(email, provider), Note(email, provider, "unknown", detail, code_path)
    if not matched and expired_matched:
        return unknown_row(email, provider), Note(
            email,
            provider,
            "unknown",
            f"stored access token in {expired_matched[0].source} is expired; this command does not refresh or store credentials",
            code_path,
        )
    readings = []
    for cred in matched:
        reading = call(cred)
        if reading is not None:
            readings.append((cred, reading))
    if not readings:
        return unknown_row(email, provider), Note(
            email,
            provider,
            "unknown",
            f"credential in {matched[0].source} did not return a quota document",
            code_path,
        )
    unique = {(state, remaining, resets_at) for _, (state, remaining, resets_at) in readings}
    if len(unique) != 1:
        return unknown_row(email, provider), Note(
            email,
            provider,
            "unknown",
            "live responses for this email disagreed, so none was chosen",
            code_path,
        )
    state, remaining, resets_at = readings[0][1]
    detail = f"live {state} from {readings[0][0].source}"
    return row(email, provider, state, remaining, resets_at), Note(email, provider, state, detail, code_path)


def _call_chatgpt(cred: Credential, transport: Transport) -> tuple[str, int | float | None, str | None] | None:
    headers = {
        "Authorization": f"Bearer {cred.access_token}",
        "Accept": "application/json",
        "User-Agent": USER_AGENT,
    }
    if cred.account_id:
        headers["ChatGPT-Account-Id"] = cred.account_id
    response = _request(transport, "GET", CHATGPT_URL, headers, None)
    if response is None:
        return None
    status, payload = response
    if status != 200:
        if exhaustion_message(payload):
            return "exhausted", None, None
        return None
    document = _json_body(payload)
    if document is None:
        return None
    state, remaining, resets_at = classify_chatgpt(document)
    if state == "unknown":
        return None
    return state, remaining, resets_at


def _call_supergrok(cred: Credential, transport: Transport) -> tuple[str, int | float | None, str | None] | None:
    headers = {
        "Authorization": f"Bearer {cred.access_token}",
        "Accept": "application/json",
        "User-Agent": USER_AGENT,
        "x-grok-client-mode": "cli",
    }
    response = _request(transport, "GET", SUPERGROK_URL, headers, None)
    if response is None:
        return None
    status, payload = response
    if status != 200:
        if exhaustion_message(payload):
            return "exhausted", None, None
        return None
    document = _json_body(payload)
    if document is None:
        return None
    return classify_supergrok(document)


def _call_antigravity(cred: Credential, transport: Transport, now: datetime) -> tuple[str, int | float | None, str | None] | None:
    hosts: list[str] = []
    if cred.logged_host in CODE_ASSIST_HOSTS:
        hosts.append(cred.logged_host)
    for host in CODE_ASSIST_HOSTS:
        if host not in hosts:
            hosts.append(host)
    headers = {
        "Authorization": f"Bearer {cred.access_token}",
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": "antigravity",
        "Client-Metadata": '{"ideType":"ANTIGRAVITY","platform":"MACOS","pluginType":"GEMINI"}',
    }
    saw_placeholder = False
    for host in hosts:
        url = f"https://{host}/v1internal:retrieveUserQuotaSummary"
        response = _request(transport, "POST", url, headers, b"{}")
        if response is None:
            continue
        status, payload = response
        if status in (401, 403):
            if status == 403 and exhaustion_message(payload):
                return "exhausted", None, None
            return None
        if status != 200:
            continue
        document = _json_body(payload)
        if document is None:
            continue
        state, remaining, resets_at = classify_antigravity(document, now)
        if state == "unknown" and remaining is None and _looks_like_summary(document):
            saw_placeholder = True
            continue
        if state == "unknown":
            continue
        return state, remaining, resets_at
    if saw_placeholder:
        return None
    return None


def _looks_like_summary(document: dict) -> bool:
    groups = document.get("groups")
    return isinstance(groups, list) and len(groups) > 0


def build_report(
    home: Path,
    *,
    env: Mapping[str, str] | None = None,
    now: datetime | None = None,
    transport: Transport | None = None,
) -> tuple[dict, list[Note]]:
    environment = env if env is not None else os.environ
    moment = now if now is not None else datetime.now(timezone.utc)
    client = transport if transport is not None else urllib_transport
    agy_ok, agy_expired, agy_nameless = discover_antigravity(home, environment, moment)
    codex_ok, codex_expired, codex_nameless = discover_codex(home, environment, moment)
    grok_ok, grok_expired, grok_nameless = discover_supergrok(home, environment, moment)
    accounts = []
    notes: list[Note] = []
    for email, provider in ROSTER:
        if provider == "chatgpt":
            built, note = probe_chatgpt(email, codex_ok, codex_expired, codex_nameless, client)
        elif provider == "supergrok":
            built, note = probe_supergrok(email, grok_ok, grok_expired, grok_nameless, client)
        elif provider == "antigravity":
            built, note = probe_antigravity(email, agy_ok, agy_expired, agy_nameless, client, moment)
        else:
            raise AssertionError(provider)
        accounts.append(built)
        notes.append(note)
    report = {"updated_at": iso_z(moment), "accounts": accounts}
    return report, notes


def urllib_transport(method: str, url: str, headers: Mapping[str, str], body: bytes | None, timeout: float) -> tuple[int, bytes]:
    request = urllib.request.Request(url, data=body, headers=dict(headers), method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def write_quota(path: Path, report: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o600)
    temporary.replace(path)
    os.chmod(path, 0o600)


def main(argv: list[str] | None = None, *, home: Path | None = None, env: Mapping[str, str] | None = None, transport: Transport | None = None, now: datetime | None = None) -> int:
    del argv
    root = home if home is not None else Path.home()
    report, notes = build_report(root, env=env, now=now, transport=transport)
    destination = quota_path(root)
    write_quota(destination, report)
    json.dump(report, sys.stdout, indent=2)
    sys.stdout.write("\n")
    for note in notes:
        print(f"{note.email} {note.provider} {note.state}: {note.detail} ({note.code_path})", file=sys.stderr)
    print(f"wrote {destination}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
