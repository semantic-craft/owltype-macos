# Domain Docs

How the engineering skills consume this repository's domain documentation.

## Before exploring, read these

- `CONTEXT.md` at the repository root, when it exists.
- `docs/adr/` entries relevant to the area being changed, when they exist.

If either location does not exist, proceed silently. Domain-modeling skills create them lazily when terminology or decisions are actually resolved.

## File structure

This repository uses a single-context layout:

```text
/
├── CONTEXT.md
├── docs/adr/
└── sources/
```

## Use the glossary's vocabulary

When output names a domain concept, use the term defined in `CONTEXT.md`. Do not drift to synonyms the glossary explicitly avoids.

If a needed concept is absent, reconsider whether the term belongs to the project or note the gap for domain modeling.

## Flag ADR conflicts

If output contradicts an existing ADR, surface the conflict explicitly rather than silently overriding it.
