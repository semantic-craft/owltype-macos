# Candidate layout review — 2026-09-09

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
