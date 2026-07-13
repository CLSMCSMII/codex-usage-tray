# Codex Usage Tray for Windows

A lightweight Windows system tray app that reads the latest usage percentage from local Codex session files in read-only mode and displays the remaining quota as a battery icon next to the clock.

ChatGPT Business workspaces are supported. The displayed value is the limit reported by the Codex client for the signed-in user and workspace (often identified by `plan_type: team`). It is not the combined usage of every workspace member.

## Features

- Displays the remaining percentage as a large, high-contrast battery level with a number inside the tray icon
- Opens a left-click details window with every available usage reset and reset-credit expiration date
- Provides a right-click **Update from GitHub** action that validates, replaces, and restarts the app in place
- Shows the usage window and reset time in the context menu
- Refreshes automatically every 60 seconds
- Uses color-coded remaining quota: green above 30%, orange at 11-30%, and red at 10% or below
- Reads the Codex OAuth access token only after a left-click details request; it is never displayed, logged, or stored by this app
- Does not send data outside the computer

> **Important:** OpenAI does not currently document a public API for retrieving a regular user's remaining ChatGPT subscription or Codex quota percentage. This app therefore reads the `rate_limits` events written by the Codex client under `%USERPROFILE%\.codex\sessions`. This file format is an implementation detail and may change in a future Codex release.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1, included with Windows
- Codex signed in and used at least once on the computer

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

## Project structure

```text
CodexUsageTray/
  src/CodexUsageTray.ps1   Tray app and usage parser
  src/Updater.ps1          In-place GitHub updater and rollback helper
  tests/Parser.Tests.ps1   Parser smoke test with fixture data
  tests/Updater.Tests.ps1  Isolated updater integration test
  Install.ps1              Per-user installer and Startup setup
  Uninstall.ps1            Per-user uninstaller
  LICENSE                  MIT License
```

## Data source and security

The default provider searches only recent `*.jsonl` files under `%CODEX_HOME%\sessions` or `%USERPROFILE%\.codex\sessions`. It parses only objects containing `payload.type = token_count` and `payload.rate_limits`. Prompt and response content is neither retained nor displayed.

When the user left-clicks the tray icon, the app reads the existing Codex access token from `%CODEX_HOME%\auth.json` or `%USERPROFILE%\.codex\auth.json` and sends it only to `https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` over HTTPS. The token and response are kept in memory only. This ChatGPT backend endpoint is not a documented public API and may change or stop working without notice.

## Updating from GitHub

Right-click the tray icon and select **Update from GitHub**. After confirmation, the updater downloads the `main` branch from `CLSMCSMII/codex-usage-tray` over HTTPS, validates every required project file, closes the old process, replaces the installation in place, and starts the new process. If replacement fails, it restores the previous app script and restarts it.

The updater does not remove or recreate the Startup shortcut, and it keeps the same executable, script path, tooltip, and icon identity so Windows can retain the visible system-tray placement. Windows owns tray ordering, so exact placement cannot be guaranteed across major Windows or Explorer changes.

Because this mechanism runs code downloaded from the repository, protect the GitHub account and repository with strong authentication and review changes before publishing them.

OpenAI API usage should be implemented as a separate provider because API usage is not the same as a ChatGPT or Codex subscription quota. Such a provider should call the Organization Usage or Costs API with an Admin API key stored in Windows Credential Manager or protected with DPAPI. Never put a key in source code, configuration files, or logs. The API provides token and cost totals; displaying those totals as a percentage requires a user-defined budget.

For ChatGPT Business owners and administrators, the Compliance API can provide workspace-level Codex audit activity when enabled and permitted by workspace policy. It is not an API for retrieving the same remaining quota percentage shown on the Codex Usage page. This version therefore does not request or store workspace administrator credentials.

## Troubleshooting

- **No Codex usage data:** Open Codex, run one task, and select **Refresh now**.
- **Custom Codex location:** Set the `CODEX_HOME` environment variable to the Codex data directory, then restart the app.
- **Stale icon after an abnormal exit:** Move the pointer over the old icon position and Windows should remove it.

## License

MIT
