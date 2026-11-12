# App icon and menu bar glyph

The app bundle shows an eye as its icon wherever macOS draws it (Finder, lists of apps). The
menu bar item shows the same eye in one colour, in the menu bar's colour, and the eye struck
through when Tattle failed to start.

## Sub-features

- `ic-bundle`: macOS resolves the bundle's icon to the eye of `Resources/AppIcon.svg`, not
  the generic app icon.
- `ic-glyph`: the menu bar item is the eye, before the throughput numbers when they are on.
- `ic-failed`: after a failed start the menu bar item is the eye struck through.

## How to get to it (user POV)

- Look at the app in the Finder, and at the menu bar while Tattle runs.

## Driving it with tattle-verify

Preconditions: a run is open for `ic-bundle` and `ic-glyph`; no copy running for `ic-failed`.
Each needs Screen Recording permission for the terminal app.

- **Bundle icon.** Write the image `NSWorkspace.shared.icon(forFile:)` returns for the
  bundle's full path to a PNG and look at it. A relative path returns the generic document
  icon.
- **Glyph.** `$V ax close`, `screencapture -x <file>`, and look at the menu bar's right side.
- **Failed start.** Move the copy's data folder aside, make the folder again with a
  `tattle.sqlite` that is not a database, `open` the bundle, wait 6 s, `screencapture -x
  <file>`. Stop the copy by the pid of its exact path, move the folder out and the copy's own
  folder back.

## Gotchas

- macOS 26 draws the icon in its own rounded shape with a light edge, so the corners differ
  slightly from the drawing.
