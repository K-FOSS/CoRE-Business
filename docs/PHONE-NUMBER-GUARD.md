# Phone-number commit guard

The repository provides client-side Git hooks in `.githooks/` to catch common
phone-number formats before they enter a commit. The `pre-commit` hook scans
added lines in the staged diff. The `commit-msg` hook scans the proposed commit
message. When a match is found, the hook blocks the commit and reports only
the file and line; it does not print the detected number.

Enable the hooks for this checkout with:

```sh
git config --local core.hooksPath .githooks
```

The guard checks E.164-style numbers and common North American formats,
including compact, spaced, dashed, dotted, and parenthesized forms. It permits
the reserved fictitious NANPA range 555-0100 through 555-0199 for examples;
NANPA documents these as non-working numbers reserved for entertainment and
advertising. See [NANPA's 555 line number guidance](https://nanpa.com/numbering/555-line-numbers).
The guard scans staged additions rather than the full repository, so existing
unrelated text does not prevent a commit. Review a reported line and remove or
redact the number before committing.

This is a local safeguard, not an absolute repository policy: Git permits
`--no-verify`, and another checkout does not inherit this checkout's local Git
configuration. Configure `core.hooksPath` in each checkout. Enforcing the rule
for every contributor requires a server-side receive hook or equivalent
repository-host policy as well.

The scanner can produce false positives for number-like identifiers and can
miss unusual phone-number formats. Do not use it as a substitute for reviewing
staged changes for personal information.
