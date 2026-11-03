# Legacy user-data migration

## Overview

Swift values and native filesystem/FFI adapters for scanning stable Rime sync exports, preparing a migration plan, staging its bytes and importing into the Rust engine's resource generation. Policy operations are delegated through `OwlStorageHost` to Rust.

## Interface

- `OwlRimeUserDBSnapshotReader.scan(root:)` / `scan(syncDirectory:)` return captures, issues and a source digest; snapshot metadata/entry/issue types are Codable values. [OwlRimeUserDBSnapshot.swift:OwlRimeUserDBSnapshotReader]
- `OwlUserMigration.makePlan` supplies scan/pin data to `user_migration_plan` and returns `OwlUserMigrationPlan`, including manifest, serialized records, captures and resolved sync directory. [OwlUserMigration.swift:OwlUserMigration]
- `OwlUserMigrationStage.prepare` delegates `user_migration_stage` and returns prepared/reused disposition, directory and record count. [OwlUserMigrationStage.swift:OwlUserMigrationStage]
- `OwlUserMigrationImport.run` delegates `user_migration_import` and returns an import report, resource generation and warnings; `OwlUserMigrationPrompt.confirm` presents the migration confirmation. [OwlUserMigrationImport.swift:OwlUserMigrationImport] [OwlUserMigrationImport.swift:OwlUserMigrationPrompt]

## Invariants

- The documented input boundary is stable `sync/<installation>/*.userdb.txt` snapshots, not live LevelDB directories. Scan policy is owned by `user_migration_scan`; Swift provides lstat/list/size/read effects. [OwlRimeUserDBSnapshot.swift:OwlRimeUserDBSnapshotReader.scan]
- The importer requires callers to stop sessions using the user root first; transaction rollback belongs to Rust. FFI strings and temporary preparation sessions are freed/destroyed after use. [OwlUserMigrationImport.swift:OwlUserMigrationImport.run] [OwlUserMigrationImport.swift:prepareGeneration]
- Stage files are atomically written, chmodded to 0600 and synchronized; directory synchronization opens with O_NOFOLLOW. Source-change, collision and unsafe-path errors are mapped from Rust stage failures. [OwlUserMigrationStage.swift:writeFile] [OwlUserMigrationStage.swift:syncDirectory] [OwlUserMigrationStage.swift:prepare]
- Migration record initialization fixes type to overlay and userInserted to false. [OwlUserMigration.swift:OwlUserMigrationRecord.init]

## Side Effects

- Scans source metadata and bytes; stage effects create/read/remove/write restricted files and directories and fsync them. [OwlRimeUserDBSnapshot.swift:scan] [OwlUserMigrationStage.swift:prepare]
- Resolves/digests/prepares resource generations and calls `owl_msime_user_migration_import`, which owns dictionary mutation. [OwlUserMigrationImport.swift:run] [OwlUserMigrationImport.swift:prepareGeneration]
- Displays a modal AppKit confirmation alert. [OwlUserMigrationImport.swift:OwlUserMigrationPrompt.confirm]

## Verification

From the repository root, run `make test` (the Makefile builds dependencies and prepares the dictionary seed before Xcode tests). This documentation pass did not execute the test target.
