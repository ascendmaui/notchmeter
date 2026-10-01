# John / ascendmaui providers (fork notes)

Fork: https://github.com/ascendmaui/notchmeter  
Upstream: https://github.com/Amir-Hackett/notchmeter (MIT)

## Goals

1. Track **all** AI platforms John uses on his Macs.
2. Lean **SUPER heavy on ChatGPT** — ChatGPT Plus/Pro chat has **four weekly usage resets**; prefer burning empty weeks before other platforms.
3. When **Sol 5.6**, **Astra**, or **Luna** exist as tools with readable meters, prefer those models for best-quality work (`PreferredModels` + Advisor).
4. **Do not** promote a production Vercel alias for this fork without asking John.

## New ToolIDs

| ToolID | Product | Provider | Status |
| --- | --- | --- | --- |
| `chatgpt` | ChatGPT chat (not Codex) | `ChatGPTProvider` | Stub: detects app / OpenAI support; four weekly window IDs reserved |
| `grok` | Standalone Grok / xAI (Grok Bot.app) | `GrokProvider` | Stub: detects app / Application Support; **not** Cursor’s Grok Bot seat |
| `hermes` | Hermes | `HermesProvider` | Stub: `~/Library/Application Support/Hermes` |
| `openclaw` | OpenClaw + Dashboard | `OpenClawProvider` | Stub: Application Support + Dashboard.app |

Sol / Astra / Luna are **not** ToolIDs yet — only Advisor/PreferredModels stubs.

## Detection paths (MacBook Pro / Max, 2026-10-01)

- **ChatGPT**: `/Applications/ChatGPT.app` (bundle id observed as `com.openai.codex`), `~/Library/Application Support/OpenAI`, CrashReporter `ChatGPT_*.plist`
- **Grok**: `/Applications/Grok Bot.app`, `~/Library/Application Support/Grok Bot`, `~/Library/Application Support/Grok Build Desktop`
- **Hermes**: `~/Library/Application Support/Hermes`
- **OpenClaw**: `~/Library/Application Support/OpenClaw`, `openclaw-dashboard`, `/Applications/OpenClaw Dashboard.app`

## ChatGPT Four Weekly Resets & ChatGPTHeavyMetrics

`ChatGPTProvider.weeklyWindowIDs`: `chatgpt_week_1` … `chatgpt_week_4`.  
Advisor `johnRouting` prefers burning empty weeks (`usedFraction < 0.15`) when readings exist.

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

- `Tests/NotchmeterTests/JohnProvidersTests.swift`: 21 tests covering provider properties, paths, filesystem detection, stub exceptions, ShareCard and PanelTheme visual palettes, and Advisor routing edge cases.
- `Tests/NotchmeterTests/ChatGPTMetricsTests.swift`: 7 tests covering slot state classification, staggered reset optimization, active burn targets, cycle exhaustion, and serialization.
- `Tests/NotchmeterTests/ProbeHarnessTests.swift`: 6 tests covering path inspection helpers, live probe execution, simulation scenarios, and report formatting.

## Local run (unsigned smoke)

```bash
git clone https://github.com/ascendmaui/notchmeter.git ~/Projects/notchmeter
cd ~/Projects/notchmeter
git checkout feat/max-agy4-notchmeter-0820
scripts/probe-harness.sh
scripts/build.sh run
```

Requires Xcode / Swift toolchain. Ad-hoc signed; Gatekeeper may need right-click → Open once.

## Vercel

Upstream marketing site is Amir-Hackett’s (notchmeter.com). **No production promote** from this fork without John’s OK. Preview-only if a docs site is ever attached.
