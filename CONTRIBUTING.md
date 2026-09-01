# Contributing

Thanks for helping make BattCycle safer and easier to review.

## Ground rules

- Keep the application and engine unprivileged.
- Preserve the 20% lower bound and 24-hour maximum duration.
- Every adapter-disable request must have a timed auto-enable.
- Keep tests isolated from real adapter and stress commands.
- Surface recovery failures clearly.
- Keep iPhone work read-only until a separate threat model is approved.
- Write code comments in Chinese.

Changes that weaken a guardrail need a documented safety case and maintainer approval.

## Development setup

Requirements are listed in [README.md](README.md). External tools are unnecessary for unit and mock tests.

Run:

    swift build
    swift test
    /usr/bin/python3 -m unittest discover -s Tests/Scripts -p 'test_*.py'
    /bin/zsh Tests/Scripts/test_shell_mocks.sh

Validate scripts and metadata:

    find scripts -type f \( -name '*.sh' -o -name 'battcycle' \) -print0 |
      while IFS= read -r -d '' file; do /bin/zsh -n "$file"; done
    /usr/bin/python3 -m py_compile scripts/*.py
    plutil -lint packaging/Info.plist

Do not run a real cycle as part of routine development.

## Pull requests

Keep each pull request focused. Include:

1. A one-sentence summary
2. Why the change is needed
3. Exact verification commands and results
4. File destinations for any migration
5. bash or zsh syntax results for shell changes
6. A safety impact statement
7. Hardware verification labeled VERIFIED, HOLD, or NOT APPLICABLE

Use commit titles in this form:

    type: concise description

Accepted types include feat, fix, docs, style, refactor, and chore.

## Safety-sensitive changes

Changes to adapter control, configuration parsing, process cleanup, filesystem permissions, stop handling, deadlines, or dependency discovery require:

- negative tests
- mock recovery-failure tests
- a security review
- updated architecture or safety documentation

Real-device tests require a separate supervised plan. A passing mock suite never proves hardware acceptance.

## Documentation and assets

Keep claims within available evidence. New visual assets must be recorded in [docs/ASSET_PROVENANCE.md](docs/ASSET_PROVENANCE.md) before release.
