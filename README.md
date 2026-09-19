# Sun Brightness

Automatically sets your **external monitor's** brightness from the sun's position — bright in the
daytime, dim at night, with a long smooth fade through twilight.

No tray app, no service, no account. One PowerShell script and a scheduled task.

```
18:00  ████████████████████ 100%
19:00  █████████████░░░░░░░  67%
19:30  ████████░░░░░░░░░░░░  42%
20:00  ████░░░░░░░░░░░░░░░░  24%
20:20  ███░░░░░░░░░░░░░░░░░  20%
```

## How it works

- Computes the sun's **altitude** for your coordinates using the NOAA solar position algorithm —
  entirely offline, no API calls at runtime.
- Maps that altitude to a brightness level with a **smoothstep** curve: flat at both ends, eased in
  between, so there is no visible kink where the ramp meets full day or full night.
- Sends the result over **DDC/CI** (`dxva2.dll`) — the same channel your monitor's OSD buttons use —
  so it works on desktop monitors, not just laptop panels.
- Changes are **faded one point at a time**, so even a large correction glides instead of snapping.

## Requirements

- Windows 10/11, PowerShell 5.1 or 7+
- A monitor with **DDC/CI enabled** (check your monitor's OSD menu — it's often off by default)

## Install

```powershell
git clone https://github.com/yakubmurcek/sun-brightness.git
cd sun-brightness
.\Install.ps1
```

`Install.ps1` detects your approximate location by IP, writes `config.json`, and registers a
scheduled task that runs every 2 minutes and at logon.

Prefer not to be geolocated? Pass your coordinates directly:

```powershell
.\Install.ps1 -Latitude 40.7128 -Longitude -74.0060
```

## Configuration

Everything lives in `config.json`:

| Setting | Default | Meaning |
|---|---|---|
| `Latitude` / `Longitude` | *(from install)* | Decimal degrees. North and east positive. |
| `DayBrightness` | `100` | Percent, when the sun is high. |
| `NightBrightness` | `20` | Percent, after dark. |
| `RampLowDeg` | `-12.0` | Sun altitude (degrees) at which night level is reached. |
| `RampHighDeg` | `10.0` | Sun altitude at which day level is reached. |
| `GlideStepMs` | `25` | Milliseconds between 1-point fade steps. `0` = instant. |

**Want a longer, gentler transition?** Widen the gap between `RampLowDeg` and `RampHighDeg`.
`-18` to `12` stretches the evening fade to roughly three hours.

Changes take effect on the next run — no reinstall needed.

## Previewing

See what it *would* do, without touching your monitor:

```powershell
.\Set-SunBrightness.ps1 -TestTime (Get-Date -Hour 19 -Minute 30) -WhatIfOnly
```

Sweep the whole evening:

```powershell
0..11 | ForEach-Object {
    .\Set-SunBrightness.ps1 -TestTime (Get-Date -Hour 18).AddMinutes($_ * 15) -WhatIfOnly
}
```

## Logs

Every run appends to `brightness.log`:

```
[2026-09-19 19:30] sun altitude  -4.48 deg -> target 42%
  Dell U2720Q : 50 -> 42 (range 0-100)
```

## Uninstall

```powershell
.\Uninstall.ps1
```

Your monitor stays at whatever brightness it was last set to.

## Notes and limitations

- **Manual OSD changes get overridden** on the next tick. That's the trade-off for it being
  stateless — there's no "user override" detection.
- Monitors that report `no DDC/CI brightness support` are skipped. Multi-monitor setups all get the
  same level.
- Some monitors are slow to respond over DDC/CI; raise `GlideStepMs` if the fade looks choppy.
- Laptop internal panels generally don't expose DDC/CI. Windows handles those natively.

## License

MIT
