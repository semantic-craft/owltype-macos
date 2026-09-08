# Candidate layout review — 2026-09-09

Status: the findings below describe the original implementation. See the repair
follow-up at the end for the subsequent fix.

Reviewed `ebb6e67b93f72ca5bc36f6876379ad3c5a3e4718..731872b9b68a10dec88df4b79162d55902fcfa89`.
The pinyin-spacing and scroll-alignment changes are combined in commit `731872b`.
The working tree was clean before review. This review does not modify application behavior.

The behavioral reference is the user's two task titles and the implementation commit's
description; the original tasks' full design discussions were not available in this review.
Findings about a complete column grid are conditional on that intended outcome.

## Standards

One documentation finding (P3): `sources/UI/OwlCandidatePanelView.swift:347` says the
pager does not participate in the row's natural width. It remains a child of the outer
`HStack`, following a spacer with a positive minimum length. Its width therefore still
contributes to that row. The commit description makes the same inaccurate claim.
Describe it as trailing alignment within the shared row width. Do not replace it with
an unreserved overlay: that would risk covering candidates and their hit targets.

No additional substantive standards or maintainability findings in the reviewed diff.
The shared label measurement and separate candidate/pager spacing are appropriately scoped.

## Spec

Two incomplete outcomes relative to the commit's stated grid and width goals:

1. **P2 — Mixed-length candidates still do not form aligned columns.**
   `sources/UI/OwlCandidatePanelView.swift:375` constructs each preview page as an
   independent `HStack`; the current page does the same at line 297. The new label slot
   equalizes only the label prefix. Candidate text, optional comments and current-row
   provenance tags still determine each pill's own width. For example, a first candidate
   “中华人民共和国” on one row and “中” on another place the second candidate at different
   x coordinates even with identical labels and spacing. This is an incomplete fix of
   the pre-existing issue, not a newly introduced text-width regression. If complete
   column alignment is required, share each column's maximum intrinsic width across
   visible pages. That adds blank space to shorter cells and may widen the panel;
   preserving compact rows instead requires explicitly limiting the alignment promise.

2. **P2 — The pager can still leave a blank tail on preview rows.**
   `sources/UI/OwlCandidatePanelView.swift:344-352` still adds the pager's width to the
   current row. When candidate widths are equal across rows and the preedit/minimum
   width does not dominate, the current row remains wider by the pager and its spacing.
   Stretching each row's frame aligns frame edges, not the last candidate's edge.
   Trailing alignment is useful when a preview row is wider, but it does not eliminate
   the old empty-tail case. A dedicated control column makes the tradeoff explicit;
   removing the tail would require a different control placement, such as a footer.

The spacing change itself has no identified functional regression: delimiter padding
is removed while the delimiter glyph remains, and candidate padding remains on both
sides of each pill. Pager spacing is kept separate. Preview label slots appropriately
remain blank because number keys select only the current page. The tradeoff is extra
horizontal space on preview rows whenever labels are displayed.

## Verification

- `make test DERIVED_DATA_PATH=build/gate-tests`: passed, 1,025 tests, zero failures.
  The Makefile excludes its named live-provider suites.
- `swiftlint lint --quiet`: exit 0, existing warnings remain; warnings in the reviewed
  production files concern unchanged lines.
- `git diff --check`: passed before the review record was added; checked again before commit.
- Existing added tests in `tests/OwlPanelContentTests.swift:723` verify label measurement;
  geometry tests verify parameter relationships. They do not assert rendered column
  coordinates or the pager's contribution to panel width.
- Findings above are based on source/layout structure, not an installed-input-method
  visual acceptance run. No install, release, merge to main, or full release gate was run.

Summary: Standards — one P3 documentation finding. Spec — two P2 incomplete layout
outcomes. Pinyin-spacing review passes; complete scroll-column alignment remains partial.

## Repair follow-up

The scroll view now uses SwiftUI `Grid` and page-identified `GridRow` views. Column
widths come from the widest complete candidate cell in each visible column, including
comments and provenance tags. Blank label slots still align text without promising
number-key selection on preview pages. Short final pages require no placeholder candidates.

Paging and expansion controls now occupy a trailing-aligned footer below the grid;
the footer omits the inline divider. It is absent when there are no controls. The
compact horizontal bar keeps its inline controls. This removes the current-row-only
pager tail, at the cost of a footer's height and blank space within shorter grid cells.
As before, candidates are not truncated. The total grid can be wider than any one
natural-width row when the longest cells fall in different columns.

`OwlScrollLayoutTests` measures accessibility frames from the real `NSHostingView`
rendering. It covers mixed text/comment/tag widths, all three candidate formats,
large text, previous and partial final pages, paging controls below candidates without
widening this grid, and no empty footer when controls are absent. Preview candidates
are grouped as one accessibility element, matching current-page candidates.

The synthetic rendering is inspected separately from installed-input-method acceptance;
this follow-up does not install or release the application.

Repair validation: `make test DERIVED_DATA_PATH=build/gate-tests` passed all 1,028
tests; SwiftLint exited 0 with existing warnings; `git diff --check` passed. Running
the three new layout tests against the original layout with the same accessibility
identifiers produced the expected failures: second-column drift of 55–154pt across
formats, and an 81pt width increase when paging controls were enabled. Restoring the
fixed layout made all three tests pass. The synthetic rendered panel was also inspected.

PR review follow-up: before the first page action, no preview rows exist. That state
now uses the compact row including inline paging controls; the shared grid and footer
are used only when preview rows are visible. A rendered-frame regression checks this
with multiple candidates and an available next page, not just the no-controls case.
