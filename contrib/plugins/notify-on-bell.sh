#!/usr/bin/env bash
# Example STEM plugin: desktop notification on bell/title events.
# Install: cp this file to ~/.config/stem/plugins/ and chmod +x it.
# STEM plugin protocol:
#   env: STEM_EVENT, STEM_CONFIG, STEM_PLUGIN_DIR, STEM_VERSION
#   stdin: event payload
#   stdout: commands like notify:, open:, write_pty:, reload_config

event="${STEM_EVENT:-}"
payload="$(cat)"

case "$event" in
  startup)
    # notify:STEM started
    ;;
  command)
    # Example: log commands (payload is the command line)
    # printf '%s\t%s\n' "$(date -Is)" "$payload" >> ~/.config/stem/command.log
    ;;
  bell)
    printf 'notify:Terminal bell\n'
    ;;
  *)
    ;;
esac
