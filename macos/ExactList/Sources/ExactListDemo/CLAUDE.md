# ExactListDemo

`make demo-list`. This is where the checks happen that the suite can't make:
pixels as the render server composites them, and real VoiceOver speech. SPEC
§13 names this checklist; go through it before a PR that changes behaviour.
The same scenarios can be captured frame by frame, off screen, with
`make record-list` (`../../CLAUDE.md` §0); the app and the recordings share
`ExactListDemoSupport`.

## Look

The window shows the list beside a plain `NSTableView` holding the same rows,
and each scenario runs on both: compare them. Run each toolbar scenario and
watch it at normal speed, then with the Accessibility Inspector's
slow-animation setting, or with Shift held on systems that honour it.

- **stream**: rows arrive at the bottom, and the viewport follows without a
  jump. The rows at the top slide out of view; none vanishes before it has. Scroll up a little and the arrivals stop moving what you're reading.
  Scroll back to the end and following resumes.
- **growLastRow**: the last row grows while the viewport follows. Nothing
  behind it flickers.
- **toggleClicked**: the header you clicked stays under the pointer while the
  content opens below it, including at the very bottom of the list. The
  card's border and corners follow its height on every frame, and the text
  never runs across the border. Collapsing is expanding played backwards:
  the text is covered line by line, and nothing appears or vanishes at
  either end.
- **churnAbove**: rows come and go above the viewport, and what you're
  reading never moves. Run it again while scrolling with two fingers on the
  trackpad, and let go mid-flick: the gesture and its momentum carry on
  smoothly from wherever each commit put the offset, with no jump back (S4).
- **toggleSidebar**: while the sidebar animates, the text reflows every frame.
  The row at the top keeps its reading position, and no blank area appears at
  any moment.
- **loadLarge**: 10 000 rows load, and the scroller is right from the first
  frame. Dragging the knob to the end lands on the last row.
- **scrollToTop**: the rows scroll by, the scroller's knob moves with them,
  and the list is never blank mid-flight.
- **Reduce Motion** (System Settings › Accessibility › Display): with it on,
  run **churnAbove** and **toggleClicked** again. Every update lands at once,
  with no motion (M1).

## Listen

Turn on VoiceOver (⌘F5).

- VO-arrow moves row by row and announces the position ("row 3 of 50").
- Moving past the last visible row scrolls the list and keeps reading.
- After **churnAbove**, VoiceOver focus stays on the row it was on.
