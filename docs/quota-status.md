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

`remaining` is a number only when the provider's response included one. `resets_at` is an ISO-8601 timestamp only when the response included one, otherwise `null`. A row that could not be probed is `unknown` with both fields `null`. A used-percent, including SuperGrok `creditUsagePercent`, is not copied into `remaining`. A timestamp that was not in the response is not invented.

| email | provider rows |
| --- | --- |
| ascendmaui@gmail.com | supergrok, antigravity |
| johnmatveyev@gmail.com | chatgpt, supergrok, antigravity |
| 503meds@gmail.com | antigravity |
| ascendlifesc@gmail.com | antigravity |
| ascendlifeinsurance@gmail.com | antigravity |
| powerevllc@gmail.com | antigravity |
| jvmsalesllc@gmail.com | antigravity |

The probe reads tokens the provider's own client already stored. It never asks for a password and never embeds an OAuth client secret. An expired access token is refreshed only when that client's own refresh token is already on disk and the OAuth client can be found without a prompt. A missing token, a missing license, or a refresh that cannot run stays `unknown`.

Antigravity's Google client id and secret are read at runtime from `strings` on the `agy` binary (`which agy`). The client id that works for account slots starts with `1071006060591-`. `NOTCHMETER_AGY_OAUTH_CLIENT_ID` and `NOTCHMETER_AGY_OAUTH_CLIENT_SECRET` override that discovery. The secret is not written into git. A refreshed Google access token is used for the probe and is not written back.

Codex expiry comes from the access token's `exp` claim. The id token's `exp` is ignored, because it is older and would mark a live ChatGPT login expired. Email comes from the id token or the access token. Refresh is `POST https://auth.openai.com/oauth/token` with the public client id `app_EMoamEEZ73f0CkXaXp7hrann`. The new access token stays in memory.

SuperGrok refresh is `POST https://auth.x.ai/oauth2/token` with `grant_type=refresh_token`, the entry's `refresh_token`, and its `oidc_client_id` (live logins use `b1a00492-073a-47ea-816f-4c329264a828`). The new access token, refresh token, and `expires_at` are written back to that entry (`key` is the access token). `creditUsagePercent` selects `open` below 100 and `exhausted` at 100. It is not stored as `remaining`. `resets_at` comes from `currentPeriod.end` when that field is present.

| provider | code | credential | request |
| --- | --- | --- | --- |
| chatgpt | `scripts/quota_status.py:probe_chatgpt` | `auth.json` in `$CODEX_HOME`, else `~/.config/codex`, else `~/.codex`, and only when that file's token names the roster email. Expiry is the access token's `exp` | `GET https://chatgpt.com/backend-api/wham/usage` after a silent refresh when the access token is expired |
| supergrok | `scripts/quota_status.py:probe_supergrok` | `~/.grok/auth.json` from `grok login` (`email`, access token `key`, `refresh_token`, `oidc_client_id`) | `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` after `POST https://auth.x.ai/oauth2/token` when the access token is expired |
| antigravity | `scripts/quota_status.py:probe_antigravity` | Google bearer from `token.access_token`, a string `token`, or `access_token`, in `~/.agy-accounts/*/.gemini/antigravity-cli/antigravity-oauth-token` or `~/.gemini/oauth_creds.json` (also under a slot). `token.refresh_token` and `token.expiry` are read from the nested object. Email comes from the `id_token`, otherwise from `ACCOUNT_EMAIL` in that same directory. Quota requests send `User-Agent: antigravity` and `Client-Metadata: {"ideType":"ANTIGRAVITY","platform":"MACOS","pluginType":"GEMINI"}` | `POST https://<cloudcode-host>/v1internal:retrieveUserQuotaSummary` after a silent Google refresh when the slot token is expired |

A SuperGrok response that succeeds and does not carry a remaining number is `open` with `remaining` null. That state applies to the probe that just ran. It is not reused later.

`scripts/fixtures/quota-observed-2026-10-04T0554-0400.json` is the observation from **5:54 AM ET on 2026-10-04** (`updated_at` `2026-10-04T05:54:00-04:00`). It is a test fixture. It is not the current file, and the probe does not read it.

```bash
python3 scripts/quota_status_test.py
```
