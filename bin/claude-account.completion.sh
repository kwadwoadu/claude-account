# shellcheck shell=bash
# Tab-completion for the claude-account CLI (bash + zsh).
# bash: source this from ~/.bashrc
# zsh:  source this from ~/.zshrc (it enables bashcompinit automatically)

_claude_account_complete() {
  local cur prev cmds dir names f
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  cmds="status list whoami who save switch use next swap usage pin unpin history --help --version"

  if [ "$COMP_CWORD" -eq 1 ]; then
    # shellcheck disable=SC2207  # word lists have no spaces; mapfile is missing in zsh
    COMPREPLY=($(compgen -W "$cmds" -- "$cur"))
    return
  fi

  # Second arg: offer only real credential copies. `switch` refuses anything
  # else, so a stray .json here would just hand the user a name that fails.
  case "$prev" in
    status|list)
      # shellcheck disable=SC2207
      COMPREPLY=($(compgen -W "--json" -- "$cur"))
      ;;
    switch|use|save|--slot)
      dir="${CLAUDE_ACCOUNTS_DIR:-$HOME/.claude-accounts}"
      names=""
      for f in "$dir"/*.json; do
        [ -e "$f" ] && grep -q 'claudeAiOauth' "$f" 2>/dev/null && names="$names $(basename "$f" .json)"
      done
      # shellcheck disable=SC2207
      COMPREPLY=($(compgen -W "$names" -- "$cur"))
      ;;
  esac
}

# zsh needs bashcompinit to understand `complete -F`.
if [ -n "${ZSH_VERSION:-}" ]; then
  autoload -U +X compinit  2>/dev/null && compinit  2>/dev/null
  autoload -U +X bashcompinit 2>/dev/null && bashcompinit 2>/dev/null
fi

complete -F _claude_account_complete claude-account 2>/dev/null
