## Summary

One sentence describing what changed.

## Why

Explain the user or engineering problem.

## Verification

List exact commands and observed results. Separate unit or mock evidence from supervised hardware evidence.

- [ ] swift build
- [ ] swift test
- [ ] Python mock tests
- [ ] Shell mock tests
- [ ] plist validation
- [ ] Shell syntax check when .sh or .zsh files changed

## Safety and security

Describe effects on adapter control, thresholds, deadline, recovery, privileges, filesystem permissions, heat, and data loss.

- [ ] No real adapter or stress workload was activated by automated tests
- [ ] No custom root helper, sudo call, pmset mutation, or system-daemon write was added
- [ ] Recovery failures remain visible

## File movement

If files moved, list each destination: main repository, local archive, private ops, or local ignore. Write "None" when no migration occurred.

## Release truth

Mark each relevant claim as VERIFIED, SUPPORTED, HOLD, or NOT APPLICABLE.

## Notion follow-up

If Notion was unavailable, record what still needs to be copied back. Write "Not applicable" otherwise.
