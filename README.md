# Multi-Account Switcher for Codex CLI

A simple tool to manage and switch between multiple Codex CLI accounts on macOS, Linux, WSL, and native Windows.

## Features

- **Multi-account management**: Add, remove, and list Codex CLI accounts
- **Quick switching**: Switch between accounts with simple commands
- **Cross-platform**: Works on macOS, Linux, WSL, and native Windows
- **Secure storage**: Uses system keychain (macOS) or protected files (Linux/WSL/Windows)
- **ChatGPT OAuth & API key support**: Works with both authentication methods

## Installation

Download the script directly:

```bash
curl -O https://raw.githubusercontent.com/rehldev/cdxSwitch/main/cdxswitch.sh
chmod +x cdxswitch.sh
```

On native Windows, use `cdxswitch.cmd` / `cdxswitch.ps1` instead of the Bash script.

## Usage

### Basic Commands

```bash
# Add current account to managed accounts
./cdxswitch.sh --add-account

# List all managed accounts
./cdxswitch.sh --list

# Switch to next account in sequence
./cdxswitch.sh --switch

# Switch to specific account by number or email
./cdxswitch.sh --switch-to 2
./cdxswitch.sh --switch-to user2@example.com

# Remove an account
./cdxswitch.sh --remove-account user2@example.com

# Show help
./cdxswitch.sh --help
```

### First Time Setup

1. **Log into Codex CLI** with your first account (`codex login`)
2. Run `./cdxswitch.sh --add-account` to add it to managed accounts
3. **Log out** and log into Codex CLI with your second account (`codex login`)
4. Run `./cdxswitch.sh --add-account` again
5. Now you can switch between accounts with `./cdxswitch.sh --switch`
6. **Important**: After each switch, restart Codex CLI to use the new authentication

> **What gets switched:** Account credentials and authentication tokens (`auth.json`).
> **What stays shared on this machine:** Codex's local configuration (`config.toml`), history, and project settings.

### API Key Accounts

For accounts authenticated with API keys (`codex login --with-api-key`), the account is identified by the last 4 characters of the key (e.g., `apikey-Ab3x`). All switching works the same way.

## Requirements

- Bash 3.2+
- `jq` (JSON processor)

### Installing Dependencies

**macOS:**

```bash
brew install jq
```

**Ubuntu/Debian:**

```bash
sudo apt install jq
```

**Windows PowerShell:**

- No extra dependencies required for `cdxswitch.ps1`
- Run through `cdxswitch.cmd` or PowerShell with `-ExecutionPolicy Bypass`

### Codex Home Directory

If you use a custom Codex home directory, set the `CODEX_HOME` environment variable:

```bash
CODEX_HOME=/custom/path ./cdxswitch.sh --add-account
```

## How It Works

The switcher stores account authentication data separately:

- **macOS**: Credentials in Keychain (service: "Codex Auth"), backups in `~/.codex-switch-backup/`
- **Linux/WSL/Windows**: Credentials in `~/.codex/auth.json`, backups in `~/.codex-switch-backup/` with restricted permissions

When switching accounts, it:

1. Backs up the current account's `auth.json` (and keychain entry on macOS)
2. Restores the target account's credentials from its saved backup
3. Updates `~/.codex/auth.json` (and keychain on macOS) with the target account's tokens
4. Your `config.toml` settings remain untouched (they're not account-specific)

## Credential Storage Modes

Codex CLI supports different credential storage modes via `cli_auth_credentials_store` in `config.toml`:

| Mode | Behavior with cdxSwitch |
|------|------------------------|
| `auto` (default) | Fully supported - reads keychain first, falls back to file |
| `file` | Fully supported - reads/writes `auth.json` directly |
| `keyring` | Supported on macOS via system Keychain |
| `ephemeral` | Not supported (credentials are in-memory only) |

## Troubleshooting

### If a switch fails

- Check that you have accounts added: `./cdxswitch.sh --list`
- Verify Codex CLI is closed before switching
- Try switching back to your original account

### If you can't add an account

- Make sure you're logged into Codex CLI first (`codex login`)
- Check that you have `jq` installed
- Verify you have write permissions to your home directory

### If Codex CLI doesn't recognize the new account

- Make sure you restarted Codex CLI after switching
- Check the current account: `./cdxswitch.sh --list` (look for "(active)")

## Cleanup/Uninstall

To stop using this tool and remove all data:

1. Note your current active account: `./cdxswitch.sh --list`
2. Remove the backup directory: `rm -rf ~/.codex-switch-backup`
3. Delete the script: `rm cdxswitch.sh`

Your current Codex CLI login will remain active.

## Security Notes

- Credentials stored in macOS Keychain or files with 600 permissions
- Authentication files are stored with restricted permissions (600)
- The tool requires Codex CLI to be closed during account switches

## License

MIT License - see LICENSE file for details
