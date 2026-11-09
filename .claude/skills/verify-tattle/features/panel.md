# Panel open and closed

Closing the panel keeps its views, so an open detail or a running Explain is still there when
it reopens, and stops their work: Processes and Ports stop reading, and the sampler and the
network readings, which keep running for the menu bar label and the history, stop reaching
the panel. Reopening shows the latest readings at once. Whether the panel is showing follows
its window being on screen, not its key status.

## Sub-features

- `pv-stop`: with the panel closed, a Time Profiler trace has no `PortsObserver.refresh`,
  `ProcessesObserver.refresh`, `ProcessUsageFallback`, `PanelView.body` or `ResourcesLine.body`.
- `pv-reopen`: a connection opened or a port bound while the panel was closed is in the panel
  on reopening.
- `pv-baseline`: the first Processes reading after the list was off screen, from a close or
  another tab, shows CPU as `–`; the next reading shows it again.
- `pv-detail`: a detail open at the close is still open on reopening.

## How to get to it (user POV)

- Click the eye to open the panel; click the eye again or click outside the panel to close it.

## Driving it with tattle-verify

Preconditions:

- Open run; doctor all `ok`. `pv-reopen`'s connection needs packet access only for its name.

- **Baseline.** `$V tab Processes`, `$V ax wait "apps and programs" 20`, wait 7 s, `$V save
  before`. `$V ax close`, wait 12 s, `$V ax open`, wait 1 s: the rows read `..., <memory>, –`.
  Wait 4 s: they carry a percentage again.
- **Detail.** On Processes, `$V ax press --prefix "macOS,"`, `$V ax close`, wait, `$V ax open`:
  `$V ax text` still has `Back` and the row's name.
- **Network on reopening.** `$V tab Network`, `$V ax close`, `$V connect named --hold 30`, wait 4 s,
  `$V ax open`. The heading's count has risen. The connection is under the terminal's app row
  (`Herdr Core` on the development Mac), as `example.com, <address>:80 · TCP · connected · nc`.
- **Ports on reopening.** `$V tab Ports`, `$V ax close`, `nc -l 49917 &`, wait 7 s, `$V ax open`,
  `$V ax wait 49917 4`. Kill that `nc` by its pid afterwards.
- **Work stops.** Close the panel on Processes, then on Ports. For each, `xctrace record
  --template 'Time Profiler' --attach <pid> --time-limit 30s --output t.trace`, export with
  `xctrace export --input t.trace --xpath
  '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'`, and search the XML for
  the symbols in `pv-stop`: none is there.

## Gotchas

- Proven 2026-11-09 on the development Mac, commit `6e86ade`: the reopening journeys in run
  `2026-11-09T131240`, and `pv-stop` in six closed traces (Ports and Processes, three runs).
- Key status does not follow the panel: another app activated without a click (`open -a Finder`)
  or Settings opened over the panel with Command-comma takes key from the panel and leaves it on
  screen, while the window's occlusion state stays visible. A click outside closes it. Escape
  does nothing. Opening and closing through the status item (accessibility press and a real
  click), a click outside, the `Settings...` button and five rapid cycles matched occlusion and
  `tattle-ax status`.
- Not driven: a real Command-Tab (a synthesized one does not drive the app switcher), sleep,
  the lock screen and Spaces.
- That no reading reaches a closed panel's views is also unit-tested (`PanelVisibilityTests`),
  and the baseline by `testTheFirstReadingOfARunIsABaselineWithNoCPU`.
- The first click on the eye while the Settings window is open does not open the panel; the
  next one does. Seen on `main` too.
