# Contributing

Issues and pull requests are welcome. This is a small project, so the bar is simple: leave the
code easier to understand than you found it.

## The one structural rule

**Decision logic goes in `BrightnessCore.ps1`, and it stays pure.** No network, no DDC, no file
reads, no `Get-Date`. Same inputs, same outputs, always.

Everything else — config, state, HTTP, DDC/CI, logging, the daemon loop — lives in
`Set-AdaptiveBrightness.ps1`.

This split is the reason a twenty-hour network outage, a full year of sunrises and an eight-hour
broken-cloud day can all be tested in milliseconds with no monitor attached. A clock read or an
HTTP call in the core would quietly cost that, so anything new that decides *what the brightness
should be* belongs in the core, and anything that decides *how to find out* or *how to apply it*
does not.

## Before opening a PR

```powershell
pwsh -File .\Tests\Run-Tests.ps1                                    # must pass
pwsh -File .\Tools\New-CurveChart.ps1                               # if you changed the model
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

CI runs the first and last of those on Windows for every push and pull request.

Run the integration suite too if you touched the DDC/CI path or the daemon loop. It needs a real
monitor, moves its brightness while it runs, and restores everything afterwards:

```powershell
pwsh -File .\Tests\Run-IntegrationTests.ps1
```

## Tests

New behaviour wants a test. Existing behaviour that you change wants the test that pinned it
updated, not deleted.

The assertions read as sentences on purpose — `'a stale cache drifts toward the fallback'`, not
`'test_kt_decay_3'`. A failing test should tell you what the software got wrong without you having
to open the file.

## Analyzer exclusions

`PSScriptAnalyzerSettings.psd1` excludes a handful of rules, each with a written reason. If you
need another exclusion, add the reason with it. An analyzer config full of silent suppressions is
worth nothing.

## Things that would genuinely help

- **Plane-of-array irradiance.** Global *horizontal* irradiance under-reads a low sun blazing
  through a west-facing window. Correcting that needs the window's azimuth and tilt.
- **A second irradiance source**, so Open-Meteo is not a single point of failure.
- **Per-monitor levels.** Every attached display currently gets the same percentage.
- **Waking immediately on resume from sleep**, rather than at the next scheduled tick.
