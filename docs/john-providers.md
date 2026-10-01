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

## Detection paths (MacBook Pro, 2026-10-01)

- ChatGPT: `/Applications/ChatGPT.app` (bundle id observed as `com.openai.codex`), `~/Library/Application Support/OpenAI`, CrashReporter `ChatGPT_*.plist`
- Grok: `/Applications/Grok Bot.app`, `~/Library/Application Support/Grok Bot`
- Hermes: `~/Library/Application Support/Hermes`
- OpenClaw: `~/Library/Application Support/OpenClaw`, `openclaw-dashboard`, `/Applications/OpenClaw Dashboard.app`

## ChatGPT four weekly resets

`ChatGPTProvider.weeklyWindowIDs`: `chatgpt_week_1` … `chatgpt_week_4`.  
Advisor `johnRouting` prefers burning empty weeks (`usedFraction < 0.15`) when readings exist.

**Gap:** reverse-document ChatGPT chat usage endpoint or desktop store (distinct from Codex’s chatgpt.com/codex usage).

## Local run (unsigned smoke)

```bash
git clone https://github.com/ascendmaui/notchmeter.git ~/Projects/notchmeter
cd ~/Projects/notchmeter
git checkout feat/john-providers-chatgpt-heavy   # or main once merged
scripts/build.sh run
```

Requires Xcode / Swift toolchain. Ad-hoc signed; Gatekeeper may need right-click → Open once.

## Vercel

Upstream marketing site is Amir-Hackett’s (notchmeter.com). **No production promote** from this fork without John’s OK. Preview-only if a docs site is ever attached.
