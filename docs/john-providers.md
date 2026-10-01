# John / ascendmaui providers (fork notes)

Fork: https://github.com/ascendmaui/notchmeter  
Upstream: https://github.com/Amir-Hackett/notchmeter (MIT)

## Goals

1. Track **all** AI platforms John uses on his Macs.
2. Lean **SUPER heavy on ChatGPT** — ChatGPT Plus/Pro chat has **four weekly usage resets**; prefer burning empty weeks before other platforms.
3. Track **multi-account Antigravity** across all 7 roster identities (`agy`, `agy2`–`agy7`), reading tokens directly from `.gemini/antigravity-cli/antigravity-oauth-token` and reporting per-account quotas in `--probe --json`.
4. When **Sol 5.6**, **Astra**, or **Luna** exist as tools with readable meters, prefer those models for best-quality work (`PreferredModels` + Advisor).
5. **Do not** promote a production Vercel alias for this fork without asking John.

## ToolIDs

| ToolID | Product | Provider | Status |
| --- | --- | --- | --- |
| `antigravity` | Google Antigravity (multi-account) | `CodeAssistProvider` + `AntigravityAccounts` | **Live multi-account probe**: detects all slots (`agy` through `agy7`), probes 5h/weekly quotas, extracts JWT emails |
| `chatgpt` | ChatGPT chat (not Codex) | `ChatGPTProvider` | **ChatGPT-heavy probe**: 4 weekly reset windows, env/file override support, heavy burn routing |
| `grok` | Standalone Grok / xAI (Grok Bot.app) | `GrokProvider` | Stub: detects app / Application Support; **not** Cursor’s Grok Bot seat |
| `hermes` | Hermes | `HermesProvider` | Stub: `~/Library/Application Support/Hermes` |
| `openclaw` | OpenClaw + Dashboard | `OpenClawProvider` | Stub: Application Support + Dashboard.app |

Sol / Astra / Luna are **not** ToolIDs yet — only Advisor/PreferredModels stubs.

## Multi-Account Antigravity

Antigravity uses slot-isolated HOME directories (`~/.agy-accounts/acctN`) or the default home. Notchmeter automatically discovers all slots, detects the active slot via environment (`AGY_ACCOUNT_SLOT`), and reads `antigravity-oauth-token`:

- Default slot: `agy` (`~/.gemini/antigravity-cli`)
- Multi-account slots: `agy2` through `agy7` in `~/.agy-accounts/acct*`
- Rotation order: `agy`, `agy6` (powerevllc), `agy3` (503meds), `agy2` (ascendmaui), `agy4` (ascendlifesc), `agy5` (ascendlifeinsurance), `agy7` (jvmsalesllc)
- Circular rotation sequence: `recommendedNextSlot(accounts:startingAfter:)` preserves progression forward from the active slot (`agy4` -> `agy5` -> `agy7` -> `agy` -> `agy6` -> `agy3` -> `agy2`)
- Host auto-resolution: inspects each slot's `cli.log` to use the metered endpoint (`daily-cloudcode-pa.googleapis.com` vs `cloudcode-pa.googleapis.com`) and prioritizes metered responses over placeholder responses
- Extracts Google account email from `ACCOUNT_EMAIL` or unencrypted `id_token` JWT claims
- Concurrently queries Google Code Assist (`retrieveUserQuotaSummary`) for 5h session and 7d weekly windows
- Report fields in `--probe --json`:
  - `antigravityAccounts`:
    - `total`: total slots configured
    - `signedIn`: slots with valid tokens
    - `currentSlot` / `activeSlot`: active slot (e.g. `agy4`)
    - `currentEmail` / `activeEmail`: active account email
    - `activeHasClaudeRoom`: whether active slot Claude session is < 95% used
    - `activeHasGeminiRoom`: whether active slot Gemini session is < 95% used
    - `activeClaudeSessionUsed` & `activeClaudeSessionResetsAt`: live active slot session figures
    - `activeGeminiSessionUsed` & `activeGeminiSessionResetsAt`: live active slot session figures
    - `rotationOrder`: `["agy", "agy6", "agy3", "agy2", "agy4", "agy5", "agy7"]`
    - `claudeAvailableCount`: slots with Claude & GPT session headroom
    - `geminiAvailableCount`: slots with Gemini session headroom
    - `recommendedNextSlot`: next slot in rotation order with headroom
    - `recommendedNextEmail`: email of recommended slot
    - `rotationAdvice`: human & agent readable guidance string
    - `earliestClaudeResetSlot`, `earliestClaudeResetAt`, `earliestClaudeResetsInSeconds`: earliest Claude session reset across accounts
    - `earliestGeminiResetSlot`, `earliestGeminiResetAt`, `earliestGeminiResetsInSeconds`: earliest Gemini session reset across accounts
    - `slots`: array of slot objects with `slot`, `email`, `status`, `isCurrent`, `hasClaudeRoom`, `hasGeminiRoom`, `claudeSessionRoom`, `geminiSessionRoom`, `claudeSessionUsed`, `claudeSessionResetsAt`, `claudeSessionResetsInSeconds`, `geminiSessionUsed`, `geminiSessionResetsAt`, `geminiSessionResetsInSeconds`, `claudeWeeklyUsed`, `claudeWeeklyResetsAt`, `geminiWeeklyUsed`, `geminiWeeklyResetsAt`
  - Under `tools[antigravity]`:
    - `accountCount`, `signedInCount`, `currentSlot`, `currentEmail`, `activeSlot`, `activeEmail`, `activeHasClaudeRoom`, `activeHasGeminiRoom`, `recommendedNextSlot`, `recommendedNextEmail`, `claudeAvailableCount`, `geminiAvailableCount`, `earliestClaudeResetSlot`, `earliestClaudeResetAt`, `earliestClaudeResetsInSeconds`
    - `accounts`: full array of accounts with per-window usage fractions, headroom fractions, and ISO8601 reset timestamps
- Advisor:
  - When the current slot exhausts its Claude & GPT session, `Advisor.johnRouting` advises rotating to the next ready slot (e.g. `[agy5]`). If all are exhausted, it advises using Gemini models or ChatGPT and reports the earliest reset time.
  - Proactively advises when the current slot Claude session reaches >= 75% used with the upcoming rotation slot.

## ChatGPT Four Weekly Resets & Heavy Burn

`ChatGPTProvider` reserves `chatgpt_week_1` … `chatgpt_week_4` and reports:
- `chatgptHeavy: true`
- `burnPriority: 1`
- `weeklyResetsCount: 4`
- `emptyResetsCount: N`
- `burnedResetsCount: N`
- `inProgressResetsCount: N`
- `activeWindowID`: ID of first available weekly reset (e.g. `chatgpt_week_1`)
- `activeWindowLabel`: clean label string of active reset (e.g. "Weekly reset 1")
- `emptyWindowIDs`: list of unspent weekly reset IDs
- `headroomFractions`: array of remaining room per weekly reset
- `nextResetAt` & `nextResetInSeconds`: earliest reset timestamp and seconds
- `burnAdvice`: routing guidance (e.g. "Burn Weekly reset 1 (empty, priority 1)")
- `Advisor.johnRouting` automatically prioritizes burning empty ChatGPT weekly resets before other platforms.
- Overrides:
  - Environment: `NOTCHMETER_CHATGPT_USAGE="0.0,0.1,0.0,0.0"`
  - Reset cadence: `NOTCHMETER_CHATGPT_RESET_HOURS="24,48,72,96"`
  - File: `~/Library/Application Support/OpenAI/chatgpt-usage.json`

## Local Run

```bash
git clone https://github.com/ascendmaui/notchmeter.git ~/Projects/notchmeter
cd ~/Projects/notchmeter
git checkout feat/john-providers-chatgpt-heavy
swift test --filter JohnProvidersTests
.build/debug/Notchmeter --probe --json
```

## Vercel

Upstream marketing site is Amir-Hackett’s (notchmeter.com). **No production promote** from this fork without John’s OK.
