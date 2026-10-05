#!/usr/bin/env python3
"""Tests for the Agent Overlord quota file.

The JSON file under scripts/fixtures/ is the 5:54 AM ET observation from
2026-10-04. It is not a live reading and the probe must not load it.
"""

from __future__ import annotations

import base64
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import quota_status as quota

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "scripts" / "fixtures" / "quota-observed-2026-10-04T0554-0400.json"
NOW = datetime(2026, 10, 4, 15, 0, tzinfo=timezone.utc)
LATER = "2026-12-01T00:00:00Z"


def jwt(payload: dict) -> str:
    body = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=")
    return f"h.{body}.s"


class RecordingTransport:
    def __init__(self, handler):
        self.handler = handler
        self.calls = []

    def __call__(self, method, url, headers, body, timeout):
        self.calls.append((method, url, dict(headers), body, timeout))
        status, payload = self.handler(method, url, headers, body)
        if isinstance(payload, (dict, list)):
            payload = json.dumps(payload).encode()
        return status, payload


def refuse(method, url, headers, body):
    raise AssertionError(f"unexpected probe {method} {url}")


class ContractTests(unittest.TestCase):
    def test_roster_and_empty_machine_are_unknown(self):
        with tempfile.TemporaryDirectory() as tmp:
            report, notes = quota.build_report(
                Path(tmp),
                env={},
                now=NOW,
                transport=RecordingTransport(refuse),
            )
        self.assertEqual(report["updated_at"], "2026-10-04T15:00:00Z")
        self.assertEqual(
            [(row["email"], row["provider"]) for row in report["accounts"]],
            list(quota.ROSTER),
        )
        for built in report["accounts"]:
            self.assertEqual(set(built), set(quota.ROW_KEYS))
            self.assertEqual(built["state"], "unknown")
            self.assertIsNone(built["remaining"])
            self.assertIsNone(built["resets_at"])
        self.assertTrue(all(note.state == "unknown" for note in notes))
        self.assertEqual(set(report), set(quota.SCHEMA_KEYS))

    def test_historical_observation_is_labeled_and_not_used_live(self):
        observed = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.assertEqual(observed["updated_at"], "2026-10-04T05:54:00-04:00")
        by_key = {(row["email"], row["provider"]): row for row in observed["accounts"]}
        self.assertEqual(len(by_key), 9)
        self.assertNotIn(("ascendmaui@gmail.com", "antigravity"), by_key)
        chatgpt = by_key[("johnmatveyev@gmail.com", "chatgpt")]
        self.assertEqual(chatgpt["state"], "exhausted")
        self.assertIsNone(chatgpt["remaining"])
        self.assertEqual(chatgpt["resets_at"], "2026-10-04T06:37:00-04:00")
        observed_antigravity = (
            "johnmatveyev@gmail.com",
            "503meds@gmail.com",
            "ascendlifesc@gmail.com",
            "ascendlifeinsurance@gmail.com",
            "powerevllc@gmail.com",
            "jvmsalesllc@gmail.com",
        )
        for email in observed_antigravity:
            row = by_key[(email, "antigravity")]
            self.assertEqual(row["state"], "exhausted")
            self.assertIsNone(row["remaining"])
            self.assertEqual(row["resets_at"], "2026-10-07T16:32:00-04:00")
        for email in ("ascendmaui@gmail.com", "johnmatveyev@gmail.com"):
            row = by_key[(email, "supergrok")]
            self.assertEqual(row["state"], "open")
            self.assertIsNone(row["remaining"])
            self.assertIsNone(row["resets_at"])
        source = (ROOT / "scripts" / "quota_status.py").read_text(encoding="utf-8")
        self.assertNotIn("quota-observed-2026-10-04", source)
        self.assertNotIn("05:54:00-04:00", source)
        self.assertNotIn("06:37:00-04:00", source)
        self.assertNotIn("16:32:00-04:00", source)
        with tempfile.TemporaryDirectory() as tmp:
            live, _notes = quota.build_report(Path(tmp), env={}, now=NOW, transport=RecordingTransport(refuse))
        self.assertNotEqual(live["updated_at"], observed["updated_at"])
        self.assertTrue(all(row["state"] == "unknown" for row in live["accounts"]))
        self.assertTrue(all(row["resets_at"] is None for row in live["accounts"]))

    def test_command_writes_home_quota_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            stdout = io.StringIO()
            stderr = io.StringIO()
            with redirect_stdout(stdout), redirect_stderr(stderr):
                code = quota.main(home=home, env={}, now=NOW, transport=RecordingTransport(refuse))
            self.assertEqual(code, 0)
            written = json.loads((home / ".notchmeter" / "quota.json").read_text(encoding="utf-8"))
            self.assertEqual(written, json.loads(stdout.getvalue()))
            self.assertEqual(written["updated_at"], "2026-10-04T15:00:00Z")
            mode = (home / ".notchmeter" / "quota.json").stat().st_mode & 0o777
            self.assertEqual(mode, 0o600)


class ClassifierTests(unittest.TestCase):
    def test_chatgpt_used_percent_is_not_copied_into_remaining(self):
        state, remaining, resets_at = quota.classify_chatgpt({
            "rate_limit": {
                "primary_window": {"used_percent": 12.5, "reset_at": 1_800_000_000, "limit_window_seconds": 18000},
                "secondary_window": {"used_percent": 40, "reset_at": 1_800_086_400},
            }
        })
        self.assertEqual(state, "open")
        self.assertIsNone(remaining)
        self.assertEqual(resets_at, "2027-01-15T08:00:00Z")

    def test_chatgpt_exhaustion_keeps_provider_reset_and_optional_remaining(self):
        state, remaining, resets_at = quota.classify_chatgpt({
            "rate_limit": {
                "primary_window": {"used_percent": 100, "remaining": 0, "reset_at": 1_800_000_000},
            }
        })
        self.assertEqual((state, remaining, resets_at), ("exhausted", 0, "2027-01-15T08:00:00Z"))

    def test_chatgpt_without_windows_is_unknown(self):
        self.assertEqual(quota.classify_chatgpt({"plan_type": "plus", "rate_limit": {}}), ("unknown", None, None))

    def test_supergrok_success_without_remaining_is_open(self):
        self.assertEqual(quota.classify_supergrok({"config": {"creditUsagePercent": 11.2}}), ("open", None, None))
        self.assertEqual(quota.classify_supergrok({"config": {}}), ("open", None, None))

    def test_supergrok_reports_a_remaining_field_and_a_real_reset(self):
        state, remaining, resets_at = quota.classify_supergrok({
            "config": {
                "remaining": 40,
                "creditUsagePercent": 60,
                "currentPeriod": {"type": "WEEKLY", "end": "2026-10-11T06:00:00Z"},
            }
        })
        self.assertEqual((state, remaining, resets_at), ("open", 40, "2026-10-11T06:00:00Z"))

    def test_supergrok_full_pool_is_exhausted_without_inventing_remaining(self):
        state, remaining, resets_at = quota.classify_supergrok({
            "config": {
                "creditUsagePercent": 100,
                "currentPeriod": {"end": "2026-10-11T06:00:00Z"},
            }
        })
        self.assertEqual((state, remaining, resets_at), ("exhausted", None, "2026-10-11T06:00:00Z"))

    def test_antigravity_fraction_and_reset_pass_through(self):
        state, remaining, resets_at = quota.classify_antigravity({
            "groups": [{
                "displayName": "Gemini models",
                "buckets": [
                    {"window": "5h", "remainingFraction": 0.25, "resetTime": "2026-10-04T18:00:00Z"},
                    {"window": "weekly", "remainingFraction": 0.5, "resetTime": "2026-10-08T18:00:00Z"},
                ],
            }]
        }, NOW)
        self.assertEqual((state, remaining, resets_at), ("open", 0.25, "2026-10-04T18:00:00Z"))

    def test_antigravity_zero_fraction_is_exhausted(self):
        state, remaining, resets_at = quota.classify_antigravity({
            "groups": [{
                "displayName": "Claude and GPT models",
                "buckets": [{"window": "5h", "remainingFraction": 0, "resetTime": "2026-11-01T00:00:00Z"}],
            }]
        }, NOW)
        self.assertEqual((state, remaining, resets_at), ("exhausted", 0, "2026-11-01T00:00:00Z"))

    def test_antigravity_placeholder_is_not_a_full_quota(self):
        reset = (NOW + timedelta(hours=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
        state, remaining, resets_at = quota.classify_antigravity({
            "groups": [{
                "displayName": "Gemini models",
                "buckets": [
                    {"window": "5h", "remainingFraction": 1, "resetTime": reset},
                    {"window": "weekly", "remainingFraction": 1, "resetTime": reset},
                ],
            }]
        }, NOW)
        self.assertEqual((state, remaining, resets_at), ("unknown", None, None))

    def test_out_of_range_fraction_is_not_clamped(self):
        state, remaining, _resets = quota.classify_antigravity({
            "groups": [{"displayName": "Gemini models", "buckets": [{"window": "5h", "remainingFraction": 1.4}]}]
        }, NOW)
        self.assertEqual(state, "open")
        self.assertIsNone(remaining)


class ProbeTests(unittest.TestCase):
    def test_credentials_are_matched_by_email_and_tokens_stay_out_of_the_file(self):
        secret = "super-secret-access-token"
        refresh = "super-secret-refresh-token"
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            grok = home / ".grok"
            grok.mkdir()
            (grok / "auth.json").write_text(json.dumps({
                "one": {"key": secret, "refresh_token": refresh, "email": "ascendmaui@gmail.com", "expires_at": LATER},
                "two": {"key": secret + "-john", "email": "johnmatveyev@gmail.com", "expires_at": LATER},
                "other": {"key": secret + "-other", "email": "someone-else@example.com", "expires_at": LATER},
            }), encoding="utf-8")
            codex = home / ".codex"
            codex.mkdir()
            (codex / "auth.json").write_text(json.dumps({
                "tokens": {
                    "access_token": jwt({"exp": 1_800_000_000}),
                    "refresh_token": refresh,
                    "id_token": jwt({"email": "johnmatveyev@gmail.com", "exp": 1_800_000_000}),
                    "account_id": "acct_john",
                }
            }), encoding="utf-8")
            slot = home / ".agy-accounts" / "acct3" / ".gemini" / "antigravity-cli"
            slot.mkdir(parents=True)
            (slot / "antigravity-oauth-token").write_text(json.dumps({
                "access_token": secret + "-agy",
                "refresh_token": refresh,
                "expiry_date": 1_800_000_000_000,
                "id_token": jwt({"email": "503meds@gmail.com"}),
            }), encoding="utf-8")
            # A file that names a different person than its id_token must not be queried as John.
            misfile = home / ".gemini"
            misfile.mkdir()
            (misfile / "oauth_creds.json").write_text(json.dumps({
                "access_token": secret + "-mis",
                "id_token": jwt({"email": "other@example.com"}),
            }), encoding="utf-8")
            (home / "ACCOUNT_EMAIL").write_text("johnmatveyev@gmail.com", encoding="utf-8")

            def handler(method, url, headers, body):
                token = headers["Authorization"].removeprefix("Bearer ")
                if token.endswith("-john") or "acct_john" in headers.get("ChatGPT-Account-Id", ""):
                    if "wham/usage" in url:
                        return 200, {"rate_limit": {"primary_window": {"used_percent": 100, "reset_at": 1_800_000_000}}}
                    return 200, {"config": {"creditUsagePercent": 100, "currentPeriod": {"end": "2026-10-11T06:00:00Z"}}}
                if token == secret:
                    return 200, {"config": {}}
                if token.endswith("-agy"):
                    return 200, {"groups": [{"displayName": "Gemini models", "buckets": [
                        {"window": "5h", "remainingFraction": 0.4, "resetTime": "2026-11-02T00:00:00Z"},
                    ]}]}
                if token.endswith("-mis"):
                    raise AssertionError("queried a token whose email is not on the roster")
                raise AssertionError(token)

            transport = RecordingTransport(handler)
            report, _notes = quota.build_report(home, env={}, now=NOW, transport=transport)
        encoded = json.dumps(report)
        self.assertNotIn(secret, encoded)
        self.assertNotIn(refresh, encoded)
        by_key = {(row["email"], row["provider"]): row for row in report["accounts"]}
        self.assertEqual(by_key[("ascendmaui@gmail.com", "supergrok")], {
            "email": "ascendmaui@gmail.com",
            "provider": "supergrok",
            "state": "open",
            "remaining": None,
            "resets_at": None,
        })
        self.assertEqual(by_key[("johnmatveyev@gmail.com", "chatgpt")]["state"], "exhausted")
        self.assertIsNone(by_key[("johnmatveyev@gmail.com", "chatgpt")]["remaining"])
        self.assertEqual(by_key[("johnmatveyev@gmail.com", "chatgpt")]["resets_at"], "2027-01-15T08:00:00Z")
        self.assertEqual(by_key[("johnmatveyev@gmail.com", "supergrok")]["state"], "exhausted")
        self.assertIsNone(by_key[("johnmatveyev@gmail.com", "supergrok")]["remaining"])
        self.assertEqual(by_key[("503meds@gmail.com", "antigravity")]["state"], "open")
        self.assertEqual(by_key[("503meds@gmail.com", "antigravity")]["remaining"], 0.4)
        self.assertEqual(by_key[("johnmatveyev@gmail.com", "antigravity")]["state"], "unknown")
        self.assertIsNone(by_key[("johnmatveyev@gmail.com", "antigravity")]["remaining"])
        hosts = {url.split("/")[2] for _method, url, _headers, _body, _timeout in transport.calls}
        self.assertTrue(hosts <= {
            "chatgpt.com",
            "cli-chat-proxy.grok.com",
            "daily-cloudcode-pa.googleapis.com",
            "cloudcode-pa.googleapis.com",
        })

    def test_antigravity_oauth_token_uses_token_field_and_account_email(self):
        """The CLI file is ``token`` / ``auth_method`` / ``id_token``, not ``access_token``."""
        slots = {
            "acct2": "ascendmaui@gmail.com",
            "acct3": "503meds@gmail.com",
            "acct4": "ascendlifesc@gmail.com",
            "acct5": "ascendlifeinsurance@gmail.com",
            "acct6": "powerevllc@gmail.com",
            "acct7": "jvmsalesllc@gmail.com",
        }
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            written = []
            for name, email in slots.items():
                slot = home / ".agy-accounts" / name
                (slot / ".gemini" / "antigravity-cli").mkdir(parents=True)
                (slot / "ACCOUNT_EMAIL").write_text(email + "\n", encoding="utf-8")
                bearer = f"agy-bearer-{name}"
                # acct2 has no email claim, so the address has to come from ACCOUNT_EMAIL.
                claims = {"sub": name} if name == "acct2" else {"email": email, "exp": 1_800_000_000}
                path = slot / ".gemini" / "antigravity-cli" / "antigravity-oauth-token"
                path.write_text(json.dumps({
                    "token": bearer,
                    "auth_method": "google",
                    "id_token": jwt(claims),
                    "refresh_token": "do-not-refresh",
                }), encoding="utf-8")
                written.append(path.read_text(encoding="utf-8"))

            def handler(method, url, headers, body):
                token = headers["Authorization"].removeprefix("Bearer ")
                self.assertTrue(token.startswith("agy-bearer-"))
                self.assertNotIn("do-not-refresh", token)
                self.assertNotIn("refresh_token", headers.get("Authorization", ""))
                fraction = int(token.removeprefix("agy-bearer-acct")) / 10
                return 200, {"groups": [{"displayName": "Gemini models", "buckets": [
                    {"window": "5h", "remainingFraction": fraction, "resetTime": "2026-12-02T00:00:00Z"},
                ]}]}

            transport = RecordingTransport(handler)
            report, notes = quota.build_report(home, env={}, now=NOW, transport=transport)
            for path, original in zip(
                [home / ".agy-accounts" / name / ".gemini" / "antigravity-cli" / "antigravity-oauth-token" for name in slots],
                written,
            ):
                self.assertEqual(path.read_text(encoding="utf-8"), original)
        by_key = {(row["email"], row["provider"]): row for row in report["accounts"]}
        for index, email in enumerate(slots.values(), start=2):
            built = by_key[(email, "antigravity")]
            self.assertEqual(built["state"], "open")
            self.assertEqual(built["remaining"], index / 10)
            self.assertEqual(built["resets_at"], "2026-12-02T00:00:00Z")
        self.assertTrue(all(note.state == "open" for note in notes if note.provider == "antigravity" and note.email in slots.values()))
        self.assertNotIn("do-not-refresh", json.dumps(report))

    def test_expired_antigravity_token_is_not_refreshed(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            slot = home / ".agy-accounts" / "acct2"
            token_dir = slot / ".gemini" / "antigravity-cli"
            token_dir.mkdir(parents=True)
            (slot / "ACCOUNT_EMAIL").write_text("ascendmaui@gmail.com\n", encoding="utf-8")
            path = token_dir / "antigravity-oauth-token"
            path.write_text(json.dumps({
                "token": jwt({"exp": 1_500_000_000}),
                "auth_method": "google",
                "id_token": jwt({"email": "ascendmaui@gmail.com", "exp": 1_500_000_000}),
                "refresh_token": "do-not-refresh",
            }), encoding="utf-8")
            original = path.read_text(encoding="utf-8")
            transport = RecordingTransport(refuse)
            report, notes = quota.build_report(home, env={}, now=NOW, transport=transport)
            self.assertEqual(path.read_text(encoding="utf-8"), original)
        self.assertEqual(transport.calls, [])
        row = next(item for item in report["accounts"] if item["email"] == "ascendmaui@gmail.com" and item["provider"] == "antigravity")
        self.assertEqual(row["state"], "unknown")
        self.assertIsNone(row["remaining"])
        self.assertIsNone(row["resets_at"])
        detail = next(note.detail for note in notes if note.email == "ascendmaui@gmail.com" and note.provider == "antigravity")
        self.assertIn("expired", detail)
        self.assertNotIn("do-not-refresh", json.dumps(report))

    def test_expired_token_is_not_sent(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            path = home / ".grok"
            path.mkdir()
            (path / "auth.json").write_text(json.dumps({
                "one": {"key": "still-secret", "email": "ascendmaui@gmail.com", "expires_at": "2020-01-01T00:00:00Z"},
            }), encoding="utf-8")
            transport = RecordingTransport(refuse)
            report, notes = quota.build_report(home, env={}, now=NOW, transport=transport)
        self.assertEqual(transport.calls, [])
        row = next(item for item in report["accounts"] if item["email"] == "ascendmaui@gmail.com")
        self.assertEqual(row["state"], "unknown")
        self.assertIsNone(row["resets_at"])
        self.assertIn("expired", notes[0].detail)
        self.assertNotIn("still-secret", json.dumps(report))

    def test_license_refusal_is_not_exhaustion(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            token_dir = home / ".gemini" / "antigravity-cli"
            token_dir.mkdir(parents=True)
            (token_dir / "antigravity-oauth-token").write_text(json.dumps({
                "access_token": "ya29.live",
                "expiry_date": 1_800_000_000_000,
                "id_token": jwt({"email": "powerevllc@gmail.com"}),
            }), encoding="utf-8")

            def handler(method, url, headers, body):
                return 403, {"error": {"message": "You do not have a valid license of this product"}}

            report, notes = quota.build_report(home, env={}, now=NOW, transport=RecordingTransport(handler))
        row = next(item for item in report["accounts"] if item["email"] == "powerevllc@gmail.com")
        self.assertEqual(row["state"], "unknown")
        self.assertIsNone(row["remaining"])
        self.assertIsNone(row["resets_at"])
        self.assertTrue(any(note.email == "powerevllc@gmail.com" and note.state == "unknown" for note in notes))

    def test_explicit_quota_exhausted_message_has_no_invented_reset(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            token_dir = home / ".gemini" / "antigravity-cli"
            token_dir.mkdir(parents=True)
            (token_dir / "antigravity-oauth-token").write_text(json.dumps({
                "access_token": "ya29.live",
                "expiry_date": 1_800_000_000_000,
                "id_token": jwt({"email": "jvmsalesllc@gmail.com"}),
            }), encoding="utf-8")

            def handler(method, url, headers, body):
                return 403, {"error": {"message": "quota exhausted"}}

            report, _notes = quota.build_report(home, env={}, now=NOW, transport=RecordingTransport(handler))
        row = next(item for item in report["accounts"] if item["email"] == "jvmsalesllc@gmail.com")
        self.assertEqual(row["state"], "exhausted")
        self.assertIsNone(row["remaining"])
        self.assertIsNone(row["resets_at"])

    def test_placeholder_host_is_skipped_for_a_metered_host(self):
        reset = (NOW + timedelta(hours=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            token_dir = home / ".gemini" / "antigravity-cli"
            token_dir.mkdir(parents=True)
            (token_dir / "cli.log").write_text("https://evil.example/steal\n", encoding="utf-8")
            (token_dir / "antigravity-oauth-token").write_text(json.dumps({
                "access_token": "ya29.live",
                "expiry_date": 1_800_000_000_000,
                "id_token": jwt({"email": "ascendlifesc@gmail.com"}),
            }), encoding="utf-8")

            def handler(method, url, headers, body):
                self.assertNotIn("evil.example", url)
                if url.startswith("https://daily-cloudcode-pa.googleapis.com"):
                    return 200, {"groups": [{"displayName": "Gemini models", "buckets": [
                        {"window": "5h", "remainingFraction": 1, "resetTime": reset},
                        {"window": "weekly", "remainingFraction": 1, "resetTime": reset},
                    ]}]}
                return 200, {"groups": [{"displayName": "Gemini models", "buckets": [
                    {"window": "weekly", "remainingFraction": 0, "resetTime": "2026-12-01T00:00:00Z"},
                ]}]}

            transport = RecordingTransport(handler)
            report, _notes = quota.build_report(home, env={}, now=NOW, transport=transport)
        row = next(item for item in report["accounts"] if item["email"] == "ascendlifesc@gmail.com")
        self.assertEqual(row["state"], "exhausted")
        self.assertEqual(row["remaining"], 0)
        self.assertEqual(row["resets_at"], "2026-12-01T00:00:00Z")
        self.assertEqual(len(transport.calls), 2)

    def test_disagreeing_responses_stay_unknown(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            first = home / ".codex"
            second = home / ".config" / "codex"
            first.mkdir()
            second.mkdir(parents=True)
            for directory, marker in ((first, "one"), (second, "two")):
                (directory / "auth.json").write_text(json.dumps({
                    "tokens": {
                        "access_token": jwt({"email": "johnmatveyev@gmail.com", "exp": 1_800_000_000, "marker": marker}),
                    }
                }), encoding="utf-8")

            def handler(method, url, headers, body):
                token = headers["Authorization"].removeprefix("Bearer ")
                payload = token.split(".")[1] + "=" * (-len(token.split(".")[1]) % 4)
                claims = json.loads(base64.urlsafe_b64decode(payload))
                used = 100 if claims["marker"] == "one" else 10
                return 200, {"rate_limit": {"primary_window": {"used_percent": used, "reset_at": 1_800_000_000}}}

            report, notes = quota.build_report(home, env={}, now=NOW, transport=RecordingTransport(handler))
        row = next(item for item in report["accounts"] if item["provider"] == "chatgpt")
        self.assertEqual(row["state"], "unknown")
        self.assertIsNone(row["remaining"])
        self.assertIsNone(row["resets_at"])
        self.assertIn("disagreed", next(note.detail for note in notes if note.provider == "chatgpt"))


if __name__ == "__main__":
    unittest.main()
