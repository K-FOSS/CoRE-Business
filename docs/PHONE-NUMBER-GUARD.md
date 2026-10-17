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
including compact, spaced, dashed, dotted, and parenthesized forms. It scans
staged additions rather than the full repository, so existing unrelated text
does not prevent a commit. Review a reported line and remove or redact the
number before committing.

This is a local safeguard, not an absolute repository policy: Git permits
`--no-verify`, and another checkout does not inherit this checkout's local Git
configuration. Configure `core.hooksPath` in each checkout. Enforcing the rule
for every contributor requires a server-side receive hook or equivalent
repository-host policy as well.

The scanner can produce false positives for number-like identifiers and can
miss unusual phone-number formats. Do not use it as a substitute for reviewing
staged changes for personal information.
