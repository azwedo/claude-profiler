# Claude Profiler

A macOS menu bar app for running several Claude Code accounts side by side, and seeing how much of each one's plan limits you've used.

Each profile is a shell alias that starts Claude Code with its own config folder, so every account keeps its own login, settings, history and memory:

```sh
claude-work      # signed in as you@work.com
claude-personal  # signed in as you@gmail.com
```

## Features

- **Profiles from the menu bar**: add, edit, copy or remove profiles without touching `~/.zshrc` by hand.
- **Live usage**: session and weekly limits for every signed-in profile, the same numbers `/usage` shows, checked every 5 minutes per account, backing off if the service rate-limits.
- **Colour-coded status**: green, orange or red dot per profile, with usage bars in each profile's submenu.
- **Notifications**: when a limit passes 80%, hits 100%, or resets, and when a profile gets signed out.
- **One-click login**: Log In opens a terminal tab (Warp or Terminal) running `claude auth login` for that profile.
- **Display names**: give a profile a friendly name in the menu, separate from the alias you type.
- **Configuration**: show or hide emails, usage, aliases, logged-out profiles, the default profile and notifications.

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
- **The default profile** is plain `claude` using `~/.claude`. It appears if that folder exists, and can be hidden under Configuration.
- **Usage** comes from the same endpoint Claude Code's `/usage` uses, called with each profile's own login, which Claude Code stores in the macOS keychain. Claude Profiler only reads that login; it never refreshes or changes it. A profile you haven't used for about 8 hours shows as idle until you run it again.
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
