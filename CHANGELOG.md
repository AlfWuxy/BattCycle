# Changelog

All notable changes to BattCycle will be documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project intends to use semantic versioning after its first tagged release.

## [Unreleased]

## [0.1.0] - 2026-09-01

### Added

- Native macOS SwiftUI control surface
- Bounded charge and discharge state machine
- CPU and MLX GPU stress workloads
- Doctor, start, stop, status, and restore CLI
- Swift unit tests and hardware-free script mock tests
- Public architecture, privacy, safety, security, and contribution policies

### Security

- Removed the custom persistent root-helper design
- Delegated adapter control to a separately installed official batt 0.8+ daemon
- Added timed adapter auto-enable, strict configuration validation, and a 24-hour maximum run
- Added explicit recovery verification and user-only runtime storage
- Replaced the reclaimable directory lock with a descriptor-held kernel lock, verified instance token, and exact token-bearing engine/workload markers
- Moved stress workloads into their own authenticated PGID so Stop and Restore can target cleanup after engine-leader failure
- Added two bounded independent cleanup attempts before the final adapter-first idempotent fallback, preserving the original engine failure status
- Replaced ad hoc stop and workload-PGID file handling with no-follow, fsynced, atomic helpers and removed the writable cleanup-completion marker file
- Added a dependency-free CI scan for high-confidence secrets and workstation-specific user-home paths in the Git-tracked public tree
- Bound recovery marker discovery to the current numeric EUID while preserving exact role, token, command, and uniqueness checks
- Added an inherited support-directory lock, single-link lock-file validation, and repeated FD/path/inode/token checks so lock-path replacement fails closed without blocking adapter recovery
- Added hardware-free regression coverage for cross-UID marker rows and lock unlink, rename, and hard-link cases
- Replaced repeated full process-table liveness checks with direct PGID queries and covered the short leader-to-session startup window
- Isolated inline and dependency-probe Python imports from inherited working directories and fixed App-launched command CWD to `/`
- Added a Start-time guard against a different active macOS console account while keeping Stop and Restore available
- Hardened packaging with owner, permission, and directory-identity checks before publication, rollback, and recursive cleanup
- Moved the console-account check ahead of App dependency probes and added macOS ACL validation to packaging paths

### Known limitations

- Real hardware integration remains HOLD pending a supervised batt 0.8+ device test
- Source-only distribution; no notarized binary release
- Direct lifecycle scripts share the logged-in-user authority and remain unsupported as an ordinary Start workflow
- macOS only; the iPhone companion remains a read-only roadmap concept
