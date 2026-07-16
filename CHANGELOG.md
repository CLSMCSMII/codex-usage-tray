# Changelog

All notable changes to Codex Usage Tray are documented here. Releases before v1.4.3 were published retrospectively from the repository's versioned commit history.

## [1.4.3] - 2026-07-16

- Replaced the slow `Get-Content -Tail` fallback with shared-read .NET streaming.
- Reduced refresh time on a large local session history from about 43 seconds to about 1 second.
- Allowed fallback reads while Codex is actively writing a session file.
- Moved launcher, updater, and Startup working directories outside the installation folder to prevent update locks.
- Added clearer installer stage diagnostics and regression coverage.

## [1.4.2] - 2026-07-16

- Changed account labels to show only the email address and plan.
- Displayed friendly plan names such as Free, Plus, Pro, Business, and Enterprise.
- Mapped the internal `team` plan identifier to Business.

## [1.4.1] - 2026-07-16

- Used the standalone Codex CLI for adding another ChatGPT account.
- Avoided launching the protected Codex executable bundled with the Microsoft Store ChatGPT app.
- Added actionable installation guidance when the standalone CLI is unavailable.

## [1.4.0] - 2026-07-16

- Added selectable ChatGPT accounts to the tray menu.
- Added browser-based sign-in for additional accounts using separate `CODEX_HOME` profiles.
- Remembered the selected profile without copying tokens into tray settings.
- Refreshed each account's quota independently.

## [1.3.0] - 2026-07-15

- Added a per-session single-instance mutex and stricter stale-usage rejection.
- Bound approved updates to an exact archive version and SHA-256 hash.
- Verified updater parent process identity before replacing files.
- Added complete-installation rollback and downgrade protection.
- Prevented update mutation before mutex ownership and preserved pending archives safely.
- Expanded updater, installer, parser, and regression tests.

## [1.2.3] - 2026-07-15

- Started the tray through a windowless launcher.
- Prevented a leftover PowerShell or Windows Terminal window after launch and update.

## [1.2.2] - 2026-07-13

- Added an up-to-date confirmation showing current and latest versions.
- Allowed the confirmation window to close with Escape.

## [1.2.1] - 2026-07-13

- Added cache busting for GitHub source archives.
- Prevented stale `main.zip` content from producing incorrect update results.

## [1.2.0] - 2026-07-13

- Renamed the updater action to **Check for update**.
- Compared current and latest versions before offering installation.
- Separated update checking from installation approval.

## [1.1.0] - 2026-07-13

- Switched the primary usage source to live ChatGPT Codex usage data.
- Kept local Codex session JSONL data as a read-only fallback.
- Corrected quota mismatches caused by relying only on local session snapshots.

## [1.0.3] - 2026-07-13

- Replaced the battery-shaped tray icon with a full-height box.
- Improved consistency with Windows network and sound tray icons.

## [1.0.2] - 2026-07-13

- Enlarged the tray icon and percentage text for better readability.

## [1.0.1] - 2026-07-13

- Allowed the usage and reset-credit window to close with Escape.

## [1.0.0] - 2026-07-13

- Introduced the Windows system tray application, installer, and uninstaller.
- Added non-blocking background refreshes.
- Displayed remaining quota as a numeric tray icon.
- Added the usage/reset-credit details window and local-time expirations.
- Added the first in-place GitHub updater and visible application version.
- Published English-only documentation.

[1.4.3]: https://github.com/CLSMCSMII/codex-usage-tray/releases/tag/v1.4.3
[1.4.2]: https://github.com/CLSMCSMII/codex-usage-tray/releases/tag/v1.4.2
[1.4.1]: https://github.com/CLSMCSMII/codex-usage-tray/releases/tag/v1.4.1
[1.4.0]: https://github.com/CLSMCSMII/codex-usage-tray/releases/tag/v1.4.0
[1.3.0]: https://github.com/CLSMCSMII/codex-usage-tray/releases/tag/v1.3.0
[1.2.3]: https://github.com/CLSMCSMII/codex-usage-tray/releases/tag/v1.2.3
[1.2.2]: https://github.com/CLSMCSMII/codex-usage-tray/releases/tag/v1.2.2
[1.2.1]: https://github.com/CLSMCSMII/codex-usage-tray/releases/tag/v1.2.1
[1.2.0]: https://github.com/CLSMCSMII/codex-usage-tray/releases/tag/v1.2.0
[1.1.0]: https://github.com/CLSMCSMII/codex-usage-tray/releases/tag/v1.1.0
[1.0.3]: https://github.com/CLSMCSMII/codex-usage-tray/releases/tag/v1.0.3
[1.0.2]: https://github.com/CLSMCSMII/codex-usage-tray/releases/tag/v1.0.2
[1.0.1]: https://github.com/CLSMCSMII/codex-usage-tray/releases/tag/v1.0.1
[1.0.0]: https://github.com/CLSMCSMII/codex-usage-tray/releases/tag/v1.0.0
