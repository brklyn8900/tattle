# Panel open and closed

Closing the panel keeps its views, so an open detail or a running Explain is still there when
it reopens, and stops their work: Processes and Ports stop reading, and the sampler and the
network readings, which keep running for the menu bar label and the history, stop reaching
the panel. On reopening, the resources line and the Network tab show the latest readings at
once; Processes and Ports show what they last read until their first sweep lands, a fraction
of a second later. Whether the panel is showing follows its window being on screen, not its
key status.

## Sub-features

- `pv-stop`: with the panel closed, a Time Profiler trace has no `PortsObserver.refresh`,
  `ProcessesObserver.refresh`, `ProcessUsageFallback`, `PanelView.body` or `ResourcesLine.body`.
- `pv-reopen`: a connection opened or a port bound while the panel was closed is in the panel
  on reopening.
- `pv-baseline`: the first Processes reading after the list was off screen, from a close or
  another tab, shows CPU as `–`, in the rows and as a `CPU –` row in a detail, so the detail
  keeps its layout. A list sorted by CPU keeps its order. The next reading follows about a
  second later and shows CPU again. A reading more than ten seconds after the previous one,
  as after a real sleep, shows `–` too.
- `pv-detail`: a detail open at the close is still open on reopening.

## How to get to it (user POV)

- Click the eye to open the panel; click the eye again or click outside the panel to close it.

## Driving it with tattle-verify

Preconditions:

- Open run; doctor all `ok`. `pv-reopen`'s connection needs packet access only for its name.

- **Baseline.** `$V tab Processes`, `$V ax wait "apps and programs" 20`, `$V ax press CPU`, wait
  8 s, `$V save before`. `$V ax close`, wait 10 s, `$V ax open`, and read at once: the rows read
  `..., <memory>, –`, in the order they had. About two seconds after opening they carry a
  percentage again. `$V ax text` is slow for this: sample the accessibility tree in a loop to
  see the `–` reading land.
- **Detail.** On Processes, `$V ax press --prefix "macOS,"`, `$V ax close`, wait, `$V ax open`:
  `$V ax text` still has `Back` and the row's name.
- **Network on reopening.** `$V tab Network`, `$V ax close`, `$V connect named --hold 30`, wait 4 s,
  `$V ax open`. The heading's count has risen. The connection is under the terminal's app row
  (`Herdr Core` on the development Mac), as `example.com, <address>:80 · TCP · connected · nc`.
- **Ports on reopening.** `$V tab Ports`, `$V ax close`, `nc -l 49917 &`, wait 7 s, `$V ax open`,
  `$V ax wait 49917 4`. Kill that `nc` by its pid afterwards.
- **Work stops.** Close the panel on Processes, on Ports and on Network, at the tab's root and
  with a detail pushed. For each, `xctrace record
  --template 'Time Profiler' --attach <pid> --time-limit 30s --output t.trace`, export with
  `xctrace export --input t.trace --xpath
  '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'`, and search the XML for
  the symbols in `pv-stop`: none is there.

## Gotchas

- Proven 2026-11-09. On the development Mac, commit `6e86ade`: the reopening journeys in run
  `2026-11-09T131240`, and `pv-stop` in six closed traces (Ports and Processes, three runs). On
  the test Mac, commit `c5e374f`, runs `2026-11-09T161254` and `2026-11-09T162043`: every path below,
  `pv-stop` closed on a Processes or Ports detail and on Network's root and a detail, the menu
  bar label moving while closed, and an Explain answered while closed or reopened mid-answer
  (one prompt each, the answer shown). On the test Mac, commit `e3cf612`, run `2026-11-09T164024`:
  `pv-baseline` by a timeline of the accessibility tree and a 30-second `pv-stop` trace closed on
  Processes. Copies in this Mac's `build/verify/runs/test-mac-2026-11-09/`.
- Key status does not follow the panel: another app activated without a click (`open -a Finder`)
  or Settings opened over the panel with Command-comma takes key from the panel and leaves it on
  screen, while the window's occlusion state stays visible. A click outside closes it. Escape
  does nothing. Opening and closing through the status item (accessibility press and a real
  click), a click outside, the `Settings...` button and five rapid cycles matched occlusion and
  `tattle-ax status`.
- On the test Mac a real Command-Tab and the administrator dialog, up and cancelled, leave the panel
  on screen and updating. Display sleep with the session locked and a move to a full-screen
  Space take it off screen; it comes back by itself, updating, on wake and on the move back.
- Not driven: a real system sleep (the test Mac's is off), a swipe between ordinary desktops, and any
  macOS before 26. The ten-second limit rests on `testAReadingLongAfterThePreviousHasNoCPU`.
  Nothing can force a missed occlusion change, so the re-read on attach and on becoming key is
  proven only not to disturb the paths above.
- `PanelVisibilityTests` covers the two read accessors, not the views; the reader and the
  loops' wiring rest on the runs above.
- The first click on the eye while the Settings window is open does not open the panel; the
  next one does. Seen on `main` too.
