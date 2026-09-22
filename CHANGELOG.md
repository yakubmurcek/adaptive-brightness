# Changelog

Notable changes, newest first. Dates are the day the work landed on `main`.

## 2026-09-22 — the resident daemon

**Ticks up to 6× faster while using about 4× less CPU.**

The scheduled task fired every two minutes, and each run spent ~1.2 s of CPU starting PowerShell,
parsing the scripts and JIT-compiling the DDC interop before doing a few milliseconds of real
work — roughly 878 s of CPU a day. Two minutes was also slow enough to visibly lag a passing
cloud, so it managed to be both expensive and sluggish.

It is now one resident process that sleeps between ticks. Sleeping costs nothing measurable
(0.000 s of CPU over two idle minutes, measured), so the tick could get much faster and much
cheaper at the same time: **~206 s of CPU per day**.

- Pace follows the work, not the clock: **20 s** while moving, doubling to a **180 s** ceiling once
  settled, **600 s** below the sun ramp, everything ×3 on battery.
- Network calls gated to **once per 10 minutes**. Open-Meteo publishes about every 15 minutes, so a
  20-second tick was fetching the same number dozens of times over. Only the *sky* term needs the
  network; the *sun* term is local geometry, free every tick.
- Uneventful ticks write nothing to the log, with a heartbeat every 30 minutes — otherwise a
  20-second tick becomes megabytes of `holding at 79%`.
- `config.json` is re-read when its timestamp changes, so edits still take effect without a
  reinstall now that the process outlives them.
- Monitor handles released on every path including early returns; a leak per tick would have
  exhausted the display driver within a day.
- Scheduler keeps a 15-minute repetition trigger, now as a watchdog rather than a tick. With
  `MultipleInstances IgnoreNew` it costs nothing while the daemon is alive.
- `Uninstall.ps1` stops the running instance before unregistering, so it cannot orphan a process
  that still holds monitor handles.

## 2026-09-22 — measure the sky, stop guessing it

**The rewrite this project exists for.** Sun altitude alone cannot tell a dazzling cloudless noon
from a dark grey one — both put the sun at the same height, so both got 100%, and overcast days
were painfully bright.

- **Clearness index.** `Kt = measured irradiance / clear-sky irradiance`, from Open-Meteo's
  `shortwave_radiation` over a locally computed Haurwitz clear-sky model. Being a ratio, it means
  the same thing in every season and at every latitude.
- **All decision logic extracted to `BrightnessCore.ps1` as pure functions** — no I/O, no clock
  reads — so the whole model is testable without a monitor, a network, or waiting for sunset.
- **EMA with a real time constant**, `α = 1 − e^(−Δt/τ)`, so unevenly spaced ticks are weighted
  correctly instead of the average quietly lying about how much it knows.
- **The staleness clock stops at night.** Kt is *undefined* after dark, not missing. Letting it
  decay overnight was a real bug: an overcast evening drifted to neutral and the panel came up
  near-full on a grey morning.
- **A guess is never persisted as a measurement**, so the first real reading after an outage
  cold-starts the average rather than being blended with an invented number.
- **Manual override detection.** Touch the monitor's own buttons and it stands down for two hours,
  then eases back on from where you left it.
- Rate limit, deadband and DDC glide to keep every correction unnoticeable.
- Unit and integration test suites.

## 2026-09-19 — first version

Sun-driven monitor brightness over DDC/CI: altitude ramp, scheduled task, installer. Superseded by
the rewrite above, and kept only as `Set-SunBrightness.ps1`.
