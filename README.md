# Claude Profiler

A macOS menu bar app for running several Claude Code accounts side by side, and seeing how much of each one's plan limits you've used.

Each profile is a shell alias that starts Claude Code with its own config folder, so every account keeps its own login, settings, history and memory:

```sh
claude-work      # signed in as you@work.com
claude-personal  # signed in as you@gmail.com
```

## Features

- **Profiles from the menu bar**: add, edit, copy or remove profiles without touching `~/.zshrc` by hand.
- **Live usage**: session and weekly limits for every signed-in profile, the same numbers `/usage` shows, with reset times in each profile's submenu, checked every 5 minutes per account. Each row's description line shows the session and weekly percentages, backing off if the service rate-limits.
- **Sign-in and plan**: each row shows the login Claude Code reports and the plan (such as Ultra, Max 20x or Team). A profile that isn't logged in shows Not logged in (or Login expired if its sign-in lapsed), with a red dot and a Log In action in its submenu. Sign-in is checked on every menu open and every 5 minutes.
- **Status dot**: green when signed in and usage is current, orange when signed in but usage can't be fetched right now, red when signed out or the sign-in expired, gray while checking. Usage bars in each profile's submenu are coloured by how full each limit is.
- **Notifications**: when a limit is approaching 80%, reaches 100%, or resets, and when a profile is logged out or logged in again. Each one names the login and plan, and limit alerts include the reset time. Turn them off, or show their details, in System Settings → Notifications → Claude Profiler.
- **One-click login**: Log In opens a terminal tab (Warp or Terminal) running `claude auth login` for that profile.
- **Display names**: give a profile a friendly name in the menu, separate from the alias you type.

## Requirements

- macOS 14.4 or later
- [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and on your `PATH`
- Xcode Command Line Tools (`xcode-select --install`) for `swiftc`
- zsh (the macOS default shell)

## Install

```sh
git clone https://github.com/azwedo/claude-profiler.git
cd claude-profiler
./build.sh
```

`build.sh` compiles the app into `~/Applications/Claude Profiler.app`, signs it locally, and installs a LaunchAgent so it starts at login and restarts if it quits. Run it again after pulling updates.

The first time Claude Profiler reads a profile's usage, macOS may ask for keychain access. Choose **Always Allow**. Allow notifications too if you want limit alerts.

## Usage

1. Click the Claude icon in the menu bar, then **Add Profile**.
2. Enter an alias (for example `claude-work`) and an optional display name.
3. Open a new terminal tab, or click the profile's **Log In**, and sign in.
4. Start that account any time with its alias. **Copy** puts `<alias> --dangerously-skip-permissions` on your clipboard.

New profiles copy your default profile's instructions and settings (`~/.claude/*.md`, `settings.json`, `skills`, `agents`, `commands`), never its login or history.

## How it works

- **Profiles** are aliases of the form `alias claude-work='CLAUDE_CONFIG_DIR=$HOME/.claude-work claude'`, kept between `# >>> claude accounts >>>` and `# <<< claude accounts <<<` in `~/.zshrc`. Claude Profiler creates that block the first time you add a profile.
- **The default profile** is plain `claude` using `~/.claude`. It appears if that folder exists. Removing it from the menu hides it until you run `defaults write com.azwedo.claude-profiler hideDefaultProfile -bool NO`.
- **Usage** comes from the same endpoint Claude Code's `/usage` uses, called with each profile's own login, which Claude Code stores in the macOS keychain. When a login's access token expires, Claude Profiler asks Claude Code to renew it by running `/usage`, which makes no model call and costs no tokens. A login Claude Code reports as gone shows Not logged in, with a Log In action.
- **Renaming an alias** keeps its folder, so the login stays valid.
- **Settings** are stored with `defaults` under `com.azwedo.claude-profiler`.

## Uninstall

```sh
launchctl bootout gui/$(id -u)/com.azwedo.claude-profiler
rm -rf ~/Applications/"Claude Profiler.app" ~/Library/LaunchAgents/com.azwedo.claude-profiler.plist
defaults delete com.azwedo.claude-profiler
```

Your profiles' aliases and folders are left in place.

## Disclaimer

Claude Profiler is an independent project and is not affiliated with or endorsed by Anthropic. Claude and the Claude logo are trademarks of Anthropic. The usage endpoint it reads is not a documented public API and may change.

## License

[MIT](LICENSE)
