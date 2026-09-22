# Adaptive Brightness

Sets your **external monitor's** brightness from the sun's position *and how bright the sky
actually is* — full brightness in direct sun, noticeably lower under thick cloud, dim at night,
with a long smooth fade through twilight.

No tray app, no service, no account, no API key. Two PowerShell scripts and a scheduled task.

```
clear noon      ████████████████████ 100%
broken cloud    ███████████████░░░░░  77%
heavy overcast  ███████████░░░░░░░░░  55%
dusk            ████░░░░░░░░░░░░░░░░  22%
night           ██░░░░░░░░░░░░░░░░░░   9%
```

## Why not just use the sun's position?

That's what this project used to do, and it was wrong about half the time. The sun's altitude is
pure geometry — it cannot tell a dazzling cloudless noon from a dark grey one. Both put the sun
at the same height, so both got 100%, and on overcast days the screen was painfully bright.

So the sky has to be measured, not inferred.

## How it works

Two signals, each doing the job it is actually good at.

**1. Sun altitude decides day versus night.** Computed offline with the NOAA solar position
algorithm, so this half never depends on a network. A smoothstep ramp across twilight keeps the
transition gentle and free of any kink where it meets full day or full night.

**2. The clearness index decides what "day" is worth today.**

```
Kt = measured irradiance / clear-sky irradiance
```

The numerator is `shortwave_radiation` from [Open-Meteo](https://open-meteo.com) — real global
horizontal irradiance in W/m², free and keyless. The denominator is a Haurwitz clear-sky model
computed locally from the sun's altitude.

Because it is a *ratio*, Kt means the same thing in every season and at every latitude:

| Kt | Sky |
|---|---|
| 0.90 – 1.00 | cloudless |
| 0.60 – 0.90 | thin or broken cloud |
| 0.35 – 0.60 | properly cloudy |
| 0.10 – 0.30 | heavy overcast |

This is why raw W/m² is *not* used directly: 250 W/m² is a dull, dim day in July and a blinding
clear noon in January. The ratio cancels that out.

The two combine as:

```
brightness = Night + (DayCeiling(Kt) - Night) × SunFactor(altitude)
```

Night is the floor when the sun is down, so **cloud cover correctly stops mattering after dark**.

## Staying smooth

Weather data is jumpy — consecutive readings can differ by 40%. Three independent layers keep the
panel calm anyway:

| Layer | Default | What it stops |
|---|---|---|
| **EMA on Kt** | τ = 30 min | Chasing every passing cloud. Uses a real time constant, so an unevenly spaced or long-delayed tick is weighted correctly. |
| **Rate limit** | 3 %/min | Any single correction becoming a visible jolt. A 45-point swing takes ~15 min. |
| **Deadband** | 4 % | Endless 61–62–61 ticking on data noise. |
| **DDC glide** | 25 ms/point | The move itself looking like a step. |

Measured over a simulated 8-hour broken-cloud day with ±0.3 Kt noise: **12 brightness changes,
largest step 5.5 points, total excursion 12 points**. Over a full clear day, no step exceeds
6 points.

## When the data isn't there

A brightness controller must never fail loudly, and must never pretend to know things.

- **Network down, reading under 3 h old** — the cached value is held unchanged.
- **Network down longer** — Kt eases toward a neutral 0.5 over ~1 h. It never jumps.
- **Never had a reading** — a neutral 0.5 is used, and deliberately *not* remembered, so the first
  real reading is adopted outright instead of being averaged against a guess.
- **After dark** — Kt is undefined, not missing, so the last known sky is frozen rather than aged
  out. An overcast evening therefore stays overcast until dawn, which is a far better morning
  prior than any fixed constant.
- **Sun below ~5°** — irradiance ratios are numerical noise down there, so no reading is taken.
- **Long sleep or hibernation** — fresh data is allowed to dominate the average, but the *actuator*
  gets a separate capped elapsed time (`MaxCatchUpMinutes`), so waking up produces a brisk
  correction rather than a snap.

## Manual control

The panel is read before it is written. A level we did not command means you reached for the
monitor's own buttons, so the script stands down for `OverrideMinutes` (default 2 h) instead of
fighting you every two minutes. It then eases on from where you left it.

```powershell
.\Set-AdaptiveBrightness.ps1 -Pause           # stop adjusting; survives reboots
.\Set-AdaptiveBrightness.ps1 -Resume
.\Set-AdaptiveBrightness.ps1 -ClearOverride   # take control back now
.\Set-AdaptiveBrightness.ps1 -Status          # what it thinks, touching nothing
```

## Requirements

- Windows 10/11, PowerShell 5.1 or 7+ (7 is used automatically if installed)
- A monitor with **DDC/CI enabled** — check its OSD menu, it is often off by default
- Internet access for the sky reading. Without it you get sun-only behaviour, safely.

## Install

```powershell
git clone https://github.com/yakubmurcek/sun-brightness.git
cd sun-brightness
.\Install.ps1
```

`Install.ps1` finds your approximate location by IP, writes `config.json`, registers a task that
runs every 2 minutes and at logon, and retires the older sun-only task if it is still present.

Prefer not to be geolocated? Pass coordinates directly:

```powershell
.\Install.ps1 -Latitude 40.7128 -Longitude -74.0060
```

## Configuration

Everything lives in `config.json`. Changes take effect on the next tick — no reinstall.

| Setting | Default | Meaning |
|---|---|---|
| `Latitude` / `Longitude` | *(from install)* | Decimal degrees, north and east positive. |
| `DayBrightness` | `100` | Percent under a cloudless sky. |
| `OvercastBrightness` | `55` | Percent under heavy overcast, sun still up. **Tune this first.** |
| `NightBrightness` | `9` | Percent after dark. |
| `MinBrightness` / `MaxBrightness` | `5` / `100` | Hard envelope; nothing escapes it. |
| `RampLowDeg` | `-12.0` | Sun altitude at which the night level is reached. |
| `RampHighDeg` | `14.0` | Sun altitude at which the full day level is reached. |
| `KtLow` | `0.25` | Kt at or below which `OvercastBrightness` is used. |
| `KtHigh` | `0.95` | Kt at or above which `DayBrightness` is used. |
| `KtFallback` | `0.50` | Assumed sky when nothing is known. |
| `KtTauMinutes` | `30.0` | Sky smoothing time constant. Raise to react more slowly. |
| `KtMaxAgeMinutes` | `180.0` | How long a cached reading is trusted before it decays. |
| `MaxRatePerMinute` | `3.0` | Maximum percentage points of change per minute. |
| `DeadbandPct` | `4.0` | Moves smaller than this are skipped. |
| `GlideStepMs` | `25` | Milliseconds between 1-point fade steps. `0` = instant. |
| `OverrideTolerancePct` | `6.0` | Gap from our commanded level that counts as you intervening. |
| `OverrideMinutes` | `120` | How long to stand down after you intervene. |
| `MaxCatchUpMinutes` | `10.0` | Caps the change budget after a long gap. |
| `TimeoutSec` | `10` | Weather request timeout. |

### Tuning it to your taste

The one number most worth adjusting is `OvercastBrightness`. Watch what it picks on a grey day,
decide what you actually wanted, and set it there.

To see the whole response curve without waiting for the weather:

```powershell
foreach ($kt in 0.05, 0.25, 0.5, 0.75, 0.95) {
    .\Set-AdaptiveBrightness.ps1 -SimulateKt $kt -WhatIfOnly
}
```

Want a longer twilight fade? Widen the gap between `RampLowDeg` and `RampHighDeg`.
Want it to react faster to clouds, at the cost of more movement? Lower `KtTauMinutes` and raise
`MaxRatePerMinute`.

## Tests

```powershell
pwsh -File .\Tests\Run-Tests.ps1              # 102 tests, no monitor or network needed
pwsh -File .\Tests\Run-IntegrationTests.ps1   # 31 tests against the real monitor
```

All decision logic is in `BrightnessCore.ps1` as pure functions, so a whole simulated day, a
three-hour outage, or a cloud bank arriving at noon all run in milliseconds. The suite covers
sunrise-to-midnight sweeps, clear versus overcast days, noisy broken cloud (asserting bounded
oscillation), network loss and recovery, the overnight hold, and manual override.

The integration suite drives the real DDC/CI path — override detection, pause/resume, corrupt
state, offline operation. **It moves your monitor brightness while it runs** and restores the
level and state file when it finishes.

## Logs

`brightness.log`, UTF-8, rotated at 1 MB:

```
2026-09-22 12:07:45 [info ] sun  39.17 deg | GHI 380 of 634 W/m2, cloud 64%, direct 47% | Kt 0.60 (live (cold start)) | ceiling 77% | target 77%
2026-09-22 12:07:46 [act  ] 100% -> 77% (stepping toward target)
2026-09-22 12:07:48 [info ]   Generic PnP Monitor : 100 -> 77 raw (range 0-100)
```

Every line shows the measurement, the derived Kt, where it came from, and why the level moved or
did not. `cloud` and `direct` are logged for diagnosis only — they explain why a sky that *looks*
cloudy can still read bright (broken cloud with the sun visible).

`state.json` holds the smoothed Kt, the last commanded level, and any override or pause.

## Known limitations

- **The sky reading is regional, not your window.** Open-Meteo gives conditions for your grid
  cell, not the light in your room. A local shower or a building shadow will not register.
  A hardware ambient-light sensor would; this machine has none.
- **Irradiance is a forecast-model value** on a 15-minute grid, typically interpolated and
  sometimes up to ~15 minutes behind reality. With a 30-minute smoothing constant that is
  deliberate, not accidental — but a sudden squall shows up late.
- **It does not know which way your window faces.** Global *horizontal* irradiance is used, so a
  low sun blazing directly through a west window reads lower than it feels. Raising
  `OvercastBrightness` or narrowing the Kt window compensates crudely; true correction would need
  the plane-of-array irradiance for your window's azimuth.
- **Room lighting is invisible to it.** Turning on a lamp at midnight changes nothing.
- **Multi-monitor setups all get the same level**, and monitors reporting no DDC/CI support are
  skipped. Laptop internal panels generally do not expose DDC/CI; Windows handles those natively.
- **Override detection cannot tell you from another program.** Anything else that sets brightness
  over DDC/CI looks like a manual change and will trigger a 2-hour stand-down.
- **The first grey morning after a fresh install** briefly runs on the neutral fallback until the
  sun clears ~5° and a real reading arrives. Afterwards the overnight hold prevents this.
- **DDC/CI is slow and not always reliable.** Some monitors ignore rapid writes or drop them under
  load; raise `GlideStepMs` if a fade looks choppy.

## License

MIT
