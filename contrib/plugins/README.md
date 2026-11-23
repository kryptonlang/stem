# STEM plugins

STEM plugins are simple executables in `~/.config/stem/plugins/` (or `plugin_dir` in config). They are language-agnostic: shell scripts, Python, compiled binaries - anything executable.

## Enable

In `~/.config/stem/stem.conf`:

```ini
plugins_enabled = true
plugin_dir = ~/.config/stem/plugins
```

## Events

STEM emits events by executing each plugin with:

- `STEM_EVENT` - event name (`startup`, `command`, `history_request`, `bell`, etc.)
- `STEM_CONFIG` - active config path
- `STEM_PLUGIN_DIR` - plugin directory
- `STEM_VERSION` - STEM version
- stdin - event payload (text)

## Commands (plugin stdout)

Plugins may emit commands, one per line:

| Command | Effect |
|---|---|
| `notify:<message>` | Desktop notification via `notify-send` |
| `open:<url-or-path>` | Open with `xdg-open` |
| `write_pty:<text>` | Write text to active terminal PTY |
| `set_title:<text>` | Request terminal title change |
| `reload_config` | Reload STEM config |

## Example

See `notify-on-bell.sh`. Install:

```bash
mkdir -p ~/.config/stem/plugins
cp contrib/plugins/notify-on-bell.sh ~/.config/stem/plugins/
chmod +x ~/.config/stem/plugins/notify-on-bell.sh
```