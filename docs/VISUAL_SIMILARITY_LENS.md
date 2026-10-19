# Visual Similarity Lens — first version

Open a photo and swipe up or tap **Explore Related**. The sheet opens halfway,
with the reference photo above it, and can expand to a full browsing area.
Accessibility text sizes use the expanded sheet immediately.

Tapping a result opens that photo without changing the reference. Exploring
again pushes a new result page inside the same navigation stack. Back restores
the previous photo or result page, including its expanded result count, grid zoom and scroll
position. Closing the sheet restores the original photo; closing that photo
returns to the unchanged library, search or Color Universe.

## Search behavior

- Reads the reference's stored vector; no image inference or original-image
  download is required to search.
- Uses all authorized indexed photos, independently of the main search filters.
- Excludes the reference itself, inaccessible/hidden assets and stale versions.
- Displays up to 36 results initially, expanding in batches, with a maximum of
  240 ranked candidates. Scores are hidden in this experience.
- At the bottom, **Scroll up to load more similar matches** replaces the old
  More Possible Matches button. Pull 72 points beyond the resting bottom to arm
  **Release to load more**; release to reveal the next batch (including weaker
  candidates once close matches run out). Pull back below 72 points before
  releasing to cancel. Inertial overscroll never triggers loading.
- Empty and short result lists support the same gesture. When every candidate
  is visible, the footer reads **No more related photos**. VoiceOver exposes a
  **Load more similar matches** custom action on the footer.
- Each page owns its results. Cancellation and a generation check prevent late
  queries from publishing over newer ones. Deleted/inaccessible results are
  removed; an unavailable reference exits that exploration page.
- Missing vectors, read failures and empty results have separate states. Read
  failures can be retried; missing vectors can be queued through existing photo
  analysis. Existing indexing pause and network policies still apply.

## Gesture boundaries

- At normal photo scale: horizontal paging, upward exploration, downward return.
- While zoomed: dragging pans the image; it does not explore or dismiss.
- Short vertical drags cancel. The system sheet coordinates resizing and list
  scrolling; dismissing the sheet does not dismiss its underlying photo.
- Visible buttons and accessibility actions provide alternatives to gestures.

## Evaluation limits

The image-to-image relevance floor (0.78) and relative gap (0.08) are provisional
and independent of text-search settings. The existing simulator library contains
synthetic images and duplicates, so it verifies navigation and ranking mechanics,
not semantic quality in a representative personal library. Calibrate these bands
on labeled photo pairs before claiming a measured relevance rate.

Color, time/location lenses, duplicate grouping and generated explanations are
outside this first version. No new model, dependency or database migration was
introduced.

## Regression coverage

`RelatedPhotosTests` covers stored-vector retrieval, reference and permission
exclusions, incompatible dimensions, weak-result expansion, empty/error states,
retry, cancellation, late results, independent page state, swipe thresholds and
bottom-pull thresholds/cancellation for empty, short and long lists.

`SemanticPhotosUITests` covers button/swipe entry, continuous exploration and
backtracking, source search and Color Universe position preservation, panel-only
dismissal, retry, English accessibility text sizes, and exploration while the
original image cannot be loaded. Existing detail gestures, photo actions and
search score/position tests remain in the verification set.

## Previous version verification record

- Xcode 27.0, iPhone 17e simulator on iOS 26.5.
- 87 unit tests in 14 suites passed (the existing performance suite was excluded).
- 15 selected UI regression tests passed with no skips or failures.
- After releasing offscreen full-size images, the four affected photo, paging,
  continuous-navigation and Color Universe tests passed again.
- English accessibility-size layout was inspected from XCTest screenshots and
  rechecked after wrapping the reference text and shortening button copy.
- Release build for a generic iOS device passed with signing disabled. This is
  compile verification, not a physical-device performance or gesture evaluation.

Local evidence: `build/LensRegression.xcresult`, `build/LensFinal.xcresult`,
`build/LensLayout.xcresult`, and `build/lens-release-final.log`.

## Pull-up loading verification

- 10 tests passed across RelatedPhotosTests and LocalizationTests, including
  the 72-point threshold, retract-to-cancel, cancelled gestures, inertial
  overscroll, duplicate release and exhausted results with empty/short/long content.
- The new UI test passed: an empty close-match list ignores a short pull,
  reveals six weak matches on release after a longer pull, then stops loading.
- Six existing exploration UI regressions passed: entry, continuous backtracking,
  search position, Color Universe position, panel dismissal and English large text.
- English maximum accessibility text size was additionally tested with empty
  results; the new multiline footer remains visible and pulling loads results.
  Chinese and English screenshots were inspected.
- Generic-device Release build passed with signing disabled; physical-device
  pull feel and VoiceOver operation were not manually evaluated.

Evidence: `build/LensPullUp.xcresult`, `build/LensPullUpRegression.xcresult`,
`build/LensPullUpAccessibility.xcresult`, `build/lens-pull-up-release.log`.
