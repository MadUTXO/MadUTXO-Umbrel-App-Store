#!/bin/sh
export ROUTSTRD_DIR="${ROUTSTRD_DIR:-/data/routstrd}"
export HOME="${HOME:-/data/home}"

# Line editing and persistent command history (arrows, Ctrl-R) for the web
# terminal. /bin/sh on Debian is dash, which has neither; use bash when present.
if [ -w "$HOME" ]; then
    if ! grep -q 'routstr-managed' "$HOME/.bashrc" 2>/dev/null; then
        cat >> "$HOME/.bashrc" <<'BASHRC'
# routstr-managed: persistent history and line editing
export HISTFILE="$HOME/.bash_history"
export HISTSIZE=5000
export HISTFILESIZE=5000
shopt -s histappend
PROMPT_COMMAND="history -a"
BASHRC
    fi
fi

cat <<'BANNER'

  Routstr on Umbrel
  -----------------
  This is the official routstrd command line.

  Useful commands:
    routstrd status                         daemon and wallet status
    routstrd balance                        wallet balance
    routstrd receive 2100                   top up with Lightning (2100 sats)
    routstrd clients add -n "My Laptop"     create an API key for an agent
    routstrd clients list                   list API keys
    routstrd monitor                        usage dashboard (htop-like)
    routstrd --help                         all commands

  Point your agent (OpenCode, Hermes, ...) at this app's URL with the API key
  from "routstrd clients add".

  Scrolling and clipboard:
    mouse wheel                             scroll tmux history
    Ctrl-b [  ...  q                        keyboard scroll (copy-mode; q exits)
    left-drag                               select (copies to tmux buffer)
    right-click                             paste the tmux buffer
    Shift+left-drag                         select for the browser clipboard
    Ctrl+Shift+C / Ctrl+Shift+V             copy / paste (OS clipboard)

  Wallet recovery phrase (first run only):
    cat /data/routstrd/mnemonic.txt          view it, write it down offline
    rm  /data/routstrd/mnemonic.txt          delete it after writing it down

  Umbrel backups include the wallet database and this phrase (encrypted at
  rest). Treat backups as sensitive; deleting mnemonic.txt does not remove
  wallet data from backups already taken.

BANNER

if [ -x /bin/bash ]; then
    exec /bin/bash -i
fi
exec /bin/sh
