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

## Detection paths (MacBook Pro / Max, 2026-10-01)

- **ChatGPT**: `/Applications/ChatGPT.app` (bundle id observed as `com.openai.codex`), `~/Library/Application Support/OpenAI`, CrashReporter `ChatGPT_*.plist`
- **Grok**: `/Applications/Grok Bot.app`, `~/Library/Application Support/Grok Bot`, `~/Library/Application Support/Grok Build Desktop`
- **Hermes**: `~/Library/Application Support/Hermes`
- **OpenClaw**: `~/Library/Application Support/OpenClaw`, `openclaw-dashboard`, `/Applications/OpenClaw Dashboard.app`

## Multi-Account Antigravity

Antigravity uses slot-isolated HOME directories (`~/.agy-accounts/acctN`) or the default home. Notchmeter automatically discovers all slots, detects the active slot via environment (`AGY_ACCOUNT_SLOT`), and reads `antigravity-oauth-token`:

- Default slot: `agy` (`~/.gemini/antigravity-cli`)
- Multi-account slots: `agy2` through `agy7` in `~/.agy-accounts/acct*`
- Rotation order: `agy`, `agy6` (powerevllc), `agy3` (503meds), `agy2` (ascendmaui), `agy4` (ascendlifesc), `agy5` (ascendlifeinsurance), `agy7` (jvmsalesllc)
- Extract Google account email from `ACCOUNT_EMAIL` or unencrypted `id_token` JWT payload
- Concurrently queries Google Code Assist (`retrieveUserQuotaSummary`) for 5h session and 7d weekly windows
- Report fields in `--probe --json`:
  - `antigravityAccounts`:
    - `total`: total slots configured
    - `signedIn`: slots with valid tokens
    - `currentSlot`: active slot (e.g. `agy4`)
    - `currentEmail`: active account email
    - `rotationOrder`: `["agy", "agy6", "agy3", "agy2", "agy4", "agy5", "agy7"]`
    - `claudeAvailableCount`: slots with Claude & GPT session headroom
    - `geminiAvailableCount`: slots with Gemini session headroom
    - `recommendedNextSlot`: next slot in rotation order with headroom
    - `recommendedNextEmail`: email of recommended slot
    - `earliestClaudeResetSlot` & `earliestClaudeResetAt`: earliest reset across exhausted accounts
    - `slots`: array of slot objects with `slot`, `email`, `status`, `isCurrent`, `hasClaudeRoom`, `hasGeminiRoom`, `claudeSessionUsed`, `claudeSessionResetsAt`, `geminiSessionUsed`, `geminiSessionResetsAt`, `claudeWeeklyUsed`, `claudeWeeklyResetsAt`, `geminiWeeklyUsed`, `geminiWeeklyResetsAt`
  - Under `tools[antigravity]`:
    - `accountCount`, `signedInCount`, `currentSlot`, `currentEmail`, `recommendedNextSlot`, `recommendedNextEmail`, `claudeAvailableCount`, `geminiAvailableCount`
    - `accounts`: full array of accounts with per-window usage fractions and ISO8601 reset timestamps
- Advisor:
  - When the current slot exhausts its Claude & GPT session, `Advisor.johnRouting` advises rotating to the next ready slot (e.g. `[agy6]`). If all are exhausted, it advises using Gemini models or ChatGPT and reports the earliest reset time.

## ChatGPT Four Weekly Resets & ChatGPTHeavyMetrics / Heavy Burn

`ChatGPTProvider` reserves `chatgpt_week_1` … `chatgpt_week_4` and reports:
- `chatgptHeavy: true`
- `burnPriority: 1`
- `weeklyResetsCount: 4`
- `emptyResetsCount: N`
- `burnedResetsCount: N`
- `inProgressResetsCount: N`
- `activeWindowID`: ID of first available weekly reset (e.g. `chatgpt_week_1`)
- `activeWindowLabel`: label of active reset
- `emptyWindowIDs`: list of unspent weekly reset IDs
- `burnAdvice`: routing guidance (e.g. "Burn weekly reset Weekly reset 1 (empty, priority 1)")
- `Advisor.johnRouting` automatically prioritizes burning empty ChatGPT weekly resets before other platforms.
- Overrides:
  - Environment: `NOTCHMETER_CHATGPT_USAGE="0.0,0.1,0.0,0.0"`
  - File: `~/Library/Application Support/OpenAI/chatgpt-usage.json`

The `ChatGPTHeavyMetrics` model (`Sources/Notchmeter/ChatGPTMetrics.swift`) tracks multi-window status across the 4-week reset cycle:
- **Slot States**:
  - `empty`: `< 0.15` used — fresh quota, primary burn target
  - `active`: `0.15` to `< 0.90` used — in-flight burn
  - `exhausted`: `>= 0.90` used — spent for this cycle
  - `unmetered`: no utilization figure published yet
- **Active Burn Target Selection**:
  - Automatically identifies which of the 4 slots to burn next.
  - Prioritizes empty slots resetting soonest so that pending resets do not erase unburned allowance.
  - Falls back to active slots with greatest headroom, or signals cycle exhaustion (`routeElsewhere`).
- **Cycle Capacity**: Computes equivalent weeks remaining (`0.0` to `4.0`), average cycle utilization, and concise status lines.
- **Reporting Integration**: Surfaced in `UsageReading.chatGPTHeavyMetrics`, `UsageReport`'s `chatgptMetrics` dictionary, and `notchmeter` CLI status lines.

## Probe Harness

The `ProbeHarness` (`Sources/Notchmeter/ProbeHarness.swift` and `scripts/probe-harness.sh`) provides automated diagnostics and inspection:
- **Live Probe**: Audits filesystem detection paths for all 12 providers, verifies app bundles and Application Support directories, measures probe latency, and runs Advisor routing.
- **Synthetic Scenarios**: Simulates multi-window states without network/disk side-effects:
  - `freshStubs`: unmetered stub state (`ProviderError.nothingYet`)
  - `chatGPTPristine`: 4 clean weekly slots (100% capacity)
  - `chatGPTStaggered`: staggered reset dates and utilization levels (verifying active target selection)
  - `chatGPTExhausted`: all weekly slots exhausted (verifying warning advice)
- **Script**: Run via `./scripts/probe-harness.sh` or `swift test --filter ProbeHarnessTests`.

## Unit Test Coverage

- `Tests/NotchmeterTests/JohnProvidersTests.swift`: Comprehensive tests covering provider properties, paths, filesystem detection, stub exceptions, ShareCard and PanelTheme visual palettes, Antigravity multi-account rotation, and Advisor routing edge cases.
- `Tests/NotchmeterTests/ChatGPTMetricsTests.swift`: 7 tests covering slot state classification, staggered reset optimization, active burn targets, cycle exhaustion, and serialization.
- `Tests/NotchmeterTests/ProbeHarnessTests.swift`: 6 tests covering path inspection helpers, live probe execution, simulation scenarios, and report formatting.

## Local Run

```bash
git clone https://github.com/ascendmaui/notchmeter.git ~/Projects/notchmeter
cd ~/Projects/notchmeter
git checkout feat/max-agy4-notchmeter-0820
swift test --filter JohnProvidersTests
swift test --filter ChatGPTMetricsTests
swift test --filter ProbeHarnessTests
./scripts/probe-harness.sh
scripts/build.sh run
```

Requires Xcode / Swift toolchain. Ad-hoc signed; Gatekeeper may need right-click → Open once.

## Vercel

Upstream marketing site is Amir-Hackett’s (notchmeter.com). **No production promote** from this fork without John’s OK.
