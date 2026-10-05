# Account quota file

Agent Overlord reads one file, written by a live probe:

```bash
python3 scripts/quota_status.py
```

That command writes **`~/.notchmeter/quota.json`** and prints the same JSON. It does not choose an account. The Mac app and the marketing site are unchanged.

```json
{
  "updated_at": "ISO-8601",
  "accounts": [
    {
      "email": "string",
      "provider": "chatgpt",
      "state": "open",
      "remaining": null,
      "resets_at": null
    }
  ]
}
```

`provider` is `chatgpt`, `supergrok`, or `antigravity`. `state` is `open`, `exhausted`, or `unknown`.

`remaining` is a number only when the provider's response included one. `resets_at` is an ISO-8601 timestamp only when the response included one, otherwise `null`. A row that could not be probed is `unknown` with both fields `null`. A used-percent is not copied into `remaining`. A timestamp that was not in the response is not invented.

| email | provider rows |
| --- | --- |
| ascendmaui@gmail.com | supergrok, antigravity |
| johnmatveyev@gmail.com | chatgpt, supergrok, antigravity |
| 503meds@gmail.com | antigravity |
| ascendlifesc@gmail.com | antigravity |
| ascendlifeinsurance@gmail.com | antigravity |
| powerevllc@gmail.com | antigravity |
| jvmsalesllc@gmail.com | antigravity |

The probe reads tokens the provider's own client already stored. It never asks for a password, never writes a token, and never refreshes one. A missing or expired token stays `unknown`.

| provider | code | credential | request |
| --- | --- | --- | --- |
| chatgpt | `scripts/quota_status.py:probe_chatgpt` | `auth.json` in `$CODEX_HOME`, else `~/.config/codex`, else `~/.codex`, and only when that file's token names the roster email | `GET https://chatgpt.com/backend-api/wham/usage` |
| supergrok | `scripts/quota_status.py:probe_supergrok` | `~/.grok/auth.json` from `grok login` (`email` and access token `key`) | `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` |
| antigravity | `scripts/quota_status.py:probe_antigravity` | Google OAuth bearer in `token` or `access_token`, from `~/.agy-accounts/*/.gemini/antigravity-cli/antigravity-oauth-token` or `~/.gemini/oauth_creds.json` (also under a slot). Email comes from the `id_token`, otherwise from `ACCOUNT_EMAIL` in that same directory. An expired token stays `unknown`; this command does not refresh it | `POST https://<cloudcode-host>/v1internal:retrieveUserQuotaSummary` |

A SuperGrok response that succeeds and does not carry a remaining number is `open` with `remaining` null. That state applies to the probe that just ran. It is not reused later.

`scripts/fixtures/quota-observed-2026-10-04T0554-0400.json` is the observation from **5:54 AM ET on 2026-10-04** (`updated_at` `2026-10-04T05:54:00-04:00`). It is a test fixture. It is not the current file, and the probe does not read it.

```bash
python3 scripts/quota_status_test.py
```
