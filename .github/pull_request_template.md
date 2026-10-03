## Summary

<!-- What changed, why, and which issue or user-visible behavior it addresses. -->

## Verification

<!-- Include tested commit, commands, result and unverified behavior. The verification
runner writes a local summary and logs; include its evidence location and a reviewed
summary here. A dirty-tree receipt is not a passing gate on the committed PR head.
Keep raw logs and machine paths local unless reviewed for sharing. -->

## Public-source checklist

- [ ] The change is independently buildable from this repository and does not depend
      on private source, services, history, or local-only files.
- [ ] New or changed third-party code and data have compatible licenses, provenance, and
      corresponding-source coverage; or this pull request does not affect them.
- [ ] I ran the narrowest relevant tests and listed them above, and `scripts/gate.sh`
      passed on this branch as it will merge. There is no hosted CI.
- [ ] The change contains no credentials, private data, real user content, personal paths,
      private repository identifiers, generated build products, or unreviewed logs.
- [ ] Security-sensitive details were reported privately rather than placed in this pull
      request or a public issue.
