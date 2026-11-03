# Shared Rust/native inputs

## Overview

The retained subtree contains cross-language contract definitions rather than executable runtime ownership. See [contracts/EGM.md](contracts/EGM.md) for punctuation and Agent wire-fixture navigation.

## Interface

Consumers use contract data/header files from `contracts/`; runtime policy belongs to the Rust crates and native adapters.

## Invariants

Changes to shared representations require checking both language consumers. This directory does not replace package-level implementation contracts.

## Side Effects

No runtime side effects; consumers compile or read these inputs.

## Verification

Use the consuming packages' contract tests and native verification. No runtime tests were executed for this documentation bootstrap.
