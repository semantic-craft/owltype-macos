# Candidate and settings themes

## Overview

Static light/dark palettes and skin metadata shared by the candidate and settings interfaces.

## Interface

- `OwlCandidateTheme` adds stanford, wuda, xiada, illinois, illinoisflame, nyu, yale and harvard palettes to the shenda palette defined in Candidates. [OwlThemes.swift:OwlCandidateTheme]
- `OwlSkin` exposes nine cases with `displayName`, `tag`, `theme` and `swatch`; `Font.owlSerif` supplies the system serif design. [OwlThemes.swift:OwlSkin] [OwlThemes.swift:Font.owlSerif]

## Invariants

- `deepred` resolves to the shenda theme; Illinois uses an orange swatch even though its light theme accent is navy. [OwlThemes.swift:OwlSkin.theme] [OwlThemes.swift:OwlSkin.swatch]

## Side Effects

- None.

## Verification

From the repository root, run `make test` (the Makefile builds dependencies and prepares the dictionary seed before Xcode tests). This documentation pass did not execute the test target.
