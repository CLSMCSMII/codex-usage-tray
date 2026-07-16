# Codex Usage Tray for Windows

Current version: **1.4.2**

A lightweight Windows system tray app that reads the latest usage percentage from local Codex session files in read-only mode and displays the remaining quota as a battery icon next to the clock.

ChatGPT Business workspaces are supported. The displayed value is the limit reported by the Codex client for the signed-in user and workspace (often identified by `plan_type: team`). It is not the combined usage of every workspace member.

## Features

- Displays the remaining percentage as a large, high-contrast battery level with a number inside the tray icon
- Shows the selected ChatGPT email and plan at the top of the right-click menu, such as `user@example.com (Business)`, and switches quota independently between saved account profiles
- Opens a left-click details window with every available usage reset and reset-credit expiration date
- Provides a right-click **Check for update** action that reports whether the app is current and shows both version numbers when an update is available
- Starts through a windowless launcher so Windows Terminal or PowerShell does not remain open
- Shows its semantic version in the right-click menu, usage window title, and tooltip
- Closes the usage and reset-credit window when **Escape** is pressed
- Shows the usage window and reset time in the context menu
- Refreshes automatically every 60 seconds
- Uses color-coded remaining quota: green above 30%, orange at 11-30%, and red at 10% or below
- Reads the Codex OAuth access token for live usage refreshes and left-click reset-credit requests; it is never displayed, logged, or stored by this app
- Sends authenticated requests only to the ChatGPT usage and reset-credit endpoints; it does not upload prompt or response content
- Rejects expired local snapshots instead of displaying stale quota data
- Prevents duplicate tray instances for the same signed-in Windows session

> **Important:** OpenAI does not currently document a public API for retrieving a regular user's remaining ChatGPT subscription or Codex quota percentage. This app therefore reads the `rate_limits` events written by the Codex client under `%USERPROFILE%\.codex\sessions`. This file format is an implementation detail and may change in a future Codex release.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1, included with Windows
- Codex signed in and used at least once on the computer
- The standalone Codex CLI installed when adding another account through the tray menu. The `codex.exe` bundled inside the Microsoft Store ChatGPT app is protected by Windows and cannot be launched directly for a separate login.

## Installation

1. Right-click `Install.ps1` and select **Run with PowerShell**, or open PowerShell in this folder and run:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
   ```

2. The installer copies the app to `%LOCALAPPDATA%\CodexUsageTray` and starts it immediately.
3. If the icon is hidden under the `^` menu, drag it next to the clock.

The installer creates a shortcut in the current user's Startup folder. Administrator privileges are not required.

To uninstall:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1
```

## Development

Run the app directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\CodexUsageTray.ps1
```

Run the parser smoke test without opening the UI:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Parser.Tests.ps1
```

Run the updater and regression tests:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Updater.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Regression.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Syntax.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Accounts.Tests.ps1
```

## Project structure

```text
CodexUsageTray/
  src/CodexUsageTray.ps1   Tray app and usage parser
  src/Updater.ps1          In-place GitHub updater and rollback helper
  Launcher.vbs             Windowless app launcher
  tests/Parser.Tests.ps1   Parser smoke test with fixture data
  tests/Accounts.Tests.ps1 Multi-account profile and settings tests
  tests/Updater.Tests.ps1  Isolated updater integration test
  tests/Regression.Tests.ps1 Runtime, deployment-safety, and documentation regressions
  tests/Syntax.Tests.ps1   PowerShell parser validation for every script
  Install.ps1              Per-user installer and Startup setup
  Uninstall.ps1            Per-user uninstaller
  LICENSE                  MIT License
```

## Data source and security

The primary provider requests current usage from `https://chatgpt.com/backend-api/wham/usage` over HTTPS using the existing Codex access token. If live usage is unavailable, the fallback provider searches recent `*.jsonl` files under `%CODEX_HOME%\sessions` or `%USERPROFILE%\.codex\sessions` and parses only objects containing `payload.type = token_count` and `payload.rate_limits`. Prompt and response content is neither retained nor displayed.

The app reads the existing Codex access token from `%CODEX_HOME%\auth.json` or `%USERPROFILE%\.codex\auth.json` and sends it only to the ChatGPT usage and reset-credit endpoints over HTTPS. The token and responses are kept in memory only. These ChatGPT backend endpoints are not documented public APIs and may change or stop working without notice.

## Multiple ChatGPT accounts

Right-click the tray icon and select the email and plan at the top of the menu. Choose an existing account to display its quota, or choose **Add account...** and complete ChatGPT sign-in in the browser. The selected account remains above the **Refreshing...** or remaining-usage row. Personal plans are shown as Free, Plus, or Pro; the `team` plan identifier is shown as Business.

If only the Microsoft Store ChatGPT app is installed, **Add account...** offers to open the official standalone Codex CLI installation instructions. After installing the standalone CLI, choose **Add account...** again.

Codex exposes one active cached login per `CODEX_HOME`, so each additional account is signed into a separate profile under `%LOCALAPPDATA%\CodexUsageTrayAccounts`. The tray app stores only the selected profile path in `%LOCALAPPDATA%\CodexUsageTrayData\settings.json`; it does not copy tokens or identity data into that settings file. Each profile's `auth.json` is created and managed by the Codex login command and must be protected like a password. App updates and uninstalling the tray app do not delete these account profiles.

## Updating from GitHub

Right-click the tray icon and select **Check for update**. The check runs in the background and displays a confirmation when the installed version is already current; press **OK** or **Escape** to close it. When a newer version exists on the `main` branch of `CLSMCSMII/codex-usage-tray`, the app downloads that exact commit once, validates every required file and PowerShell script, records the archive SHA-256, and asks whether to install that specific archive. The updater verifies the approved version and SHA-256 again, stages the complete installation, closes the old process, and replaces the installation. If deployment or restart fails, it restores the complete previous installation before restarting it.

The updater does not remove or recreate the Startup shortcut, and it keeps the same executable, script path, tooltip, and icon identity so Windows can retain the visible system-tray placement. Windows owns tray ordering, so exact placement cannot be guaranteed across major Windows or Explorer changes.

The SHA-256 check prevents the archive from changing between approval and installation. GitHub and the repository owner remain the update trust root, so protect the GitHub account and repository with strong authentication and review changes before publishing them.

OpenAI API usage should be implemented as a separate provider because API usage is not the same as a ChatGPT or Codex subscription quota. Such a provider should call the Organization Usage or Costs API with an Admin API key stored in Windows Credential Manager or protected with DPAPI. Never put a key in source code, configuration files, or logs. The API provides token and cost totals; displaying those totals as a percentage requires a user-defined budget.

For ChatGPT Business owners and administrators, the Compliance API can provide workspace-level Codex audit activity when enabled and permitted by workspace policy. It is not an API for retrieving the same remaining quota percentage shown on the Codex Usage page. This version therefore does not request or store workspace administrator credentials.

## Troubleshooting

- **No Codex usage data:** Open Codex, run one task, and select **Refresh now**.
- **Custom Codex location:** Set the `CODEX_HOME` environment variable to the Codex data directory, then restart the app.
- **Stale icon after an abnormal exit:** Move the pointer over the old icon position and Windows should remove it.

## License

MIT
