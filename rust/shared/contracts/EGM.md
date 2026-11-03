# Shared contracts

## Overview

Shared wire and punctuation fixtures consumed across Rust/native boundaries. The retained code-bearing child is [punctuation/EGM.md](punctuation/EGM.md); `agent-bridge/` contains schema/sample data and human documentation rather than production implementation.

## Interface

`punctuation/policy.json` defines contract version 4 character mappings, alternating quotes, nested book marks and style variants; `punctuation/policy.h` exposes the corresponding native table interface. Agent bridge implementation lives in `../../crates/owl-agent-mcp/src` and `../../crates/owl-app-core/src/agent.rs`.

## Invariants

Treat shared fixtures as cross-language contracts. Keep the punctuation JSON and native table representation aligned. Agent schemas/examples do not execute validation themselves; the implementation owners define runtime checks.

## Side Effects

These contract files have no runtime I/O of their own.

## Verification

Inspect consumers and their existing contract tests when changing fixtures. Documentation bootstrap did not run a fixture generator or change generated headers.
