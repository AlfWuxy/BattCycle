# Asset provenance

Open-source publication covers code, documentation, and visual assets. Every shipped asset needs a reviewable origin and license.

## Inventory

| Asset | Origin evidence | License | State |
|---|---|---|---|
| packaging/icon-source.svg | Hand-authored by BattCycle contributors on 2026-09-01; stored with an SPDX license header | MIT | VERIFIED |
| packaging/icon-source.png | Mechanical 1024 by 1024 render of icon-source.svg | MIT, inherited from source | VERIFIED |
| README badges | Rendered remotely by GitHub and shields.io | Service-owned | Links only; no bundled copy |

Third-party executables and libraries such as batt, stress-ng, Python, and MLX are dependencies. BattCycle does not redistribute them.

## Acceptance rule

An asset is eligible for release when one of these conditions is documented:

- created by a contributor who licenses their rights under MIT
- sourced from a compatible open license with attribution
- generated for the project with a recorded tool, date, and contributor rights attestation
- clearly in the public domain

Unknown origin or unclear rights is HOLD. Removing the asset is preferred when provenance cannot be recovered.

## Updating assets

For each new asset, record:

- asset path
- creator or generator
- creation date
- source link or generation record when available
- license and required attribution

Derived files must point back to their editable source.
