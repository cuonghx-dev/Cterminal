# cter shell integration for zsh
# Injected automatically — do not source manually

_cter_send() {
    local payload="$1"
    if command -v ncat >/dev/null 2>&1; then
        print -r -- "$payload" | ncat -U "$CTER_SOCKET_PATH" --send-only
    elif command -v socat >/dev/null 2>&1; then
        print -r -- "$payload" | socat - "UNIX-CONNECT:$CTER_SOCKET_PATH"
    elif command -v nc >/dev/null 2>&1; then
        # Some nc builds don't support unix sockets, but keep as a last-ditch fallback.
        #
        # Important: macOS/BSD nc will often wait for the peer to close the socket
        # after it has finished writing. cter keeps the connection open, so
        # a plain `nc -U` can hang indefinitely and leak background processes.
        #
        # Prefer flags that guarantee we exit after sending, and fall back to a
        # short timeout so we never block sidebar updates.
        if print -r -- "$payload" | nc -N -U "$CTER_SOCKET_PATH" >/dev/null 2>&1; then
            :
        else
            print -r -- "$payload" | nc -w 1 -U "$CTER_SOCKET_PATH" >/dev/null 2>&1 || true
        fi
    fi
}

# Throttle heavy work to avoid prompt latency.
typeset -g _CTER_PWD_LAST_PWD=""
typeset -g _CTER_GIT_LAST_PWD=""
typeset -g _CTER_GIT_LAST_RUN=0
typeset -g _CTER_GIT_JOB_PID=""
typeset -g _CTER_GIT_FORCE=0
typeset -g _CTER_GIT_HEAD_LAST_PWD=""
typeset -g _CTER_GIT_HEAD_PATH=""
typeset -g _CTER_GIT_HEAD_MTIME=0
typeset -g _CTER_HAVE_ZSTAT=0

typeset -g _CTER_PORTS_LAST_RUN=0
typeset -g _CTER_PORTS_JOB_PID=""
typeset -g _CTER_CMD_START=0
typeset -g _CTER_TTY_NAME=""

_cter_ensure_zstat() {
    # zstat is substantially cheaper than spawning external `stat`.
    if (( _CTER_HAVE_ZSTAT != 0 )); then
        return 0
    fi
    if zmodload -F zsh/stat b:zstat 2>/dev/null; then
        _CTER_HAVE_ZSTAT=1
        return 0
    fi
    _CTER_HAVE_ZSTAT=-1
    return 1
}

_cter_git_resolve_head_path() {
    # Resolve the HEAD file path without invoking git (fast; works for worktrees).
    local dir="$PWD"
    while true; do
        if [[ -d "$dir/.git" ]]; then
            print -r -- "$dir/.git/HEAD"
            return 0
        fi
        if [[ -f "$dir/.git" ]]; then
            local line gitdir
            line="$(<"$dir/.git")"
            if [[ "$line" == gitdir:* ]]; then
                gitdir="${line#gitdir:}"
                gitdir="${gitdir## }"
                gitdir="${gitdir%% }"
                [[ -n "$gitdir" ]] || return 1
                [[ "$gitdir" != /* ]] && gitdir="$dir/$gitdir"
                print -r -- "$gitdir/HEAD"
                return 0
            fi
        fi
        [[ "$dir" == "/" || -z "$dir" ]] && break
        dir="${dir:h}"
    done
    return 1
}

_cter_git_head_mtime() {
    local head_path="$1"
    [[ -n "$head_path" && -f "$head_path" ]] || { print -r -- 0; return 0; }

    if _cter_ensure_zstat; then
        typeset -A st
        if zstat -H st +mtime -- "$head_path" 2>/dev/null; then
            print -r -- "${st[mtime]:-0}"
            return 0
        fi
    fi

    # Fallback for environments where zsh/stat isn't available.
    if command -v stat >/dev/null 2>&1; then
        local mtime
        mtime="$(stat -f %m "$head_path" 2>/dev/null || stat -c %Y "$head_path" 2>/dev/null || echo 0)"
        print -r -- "$mtime"
        return 0
    fi

    print -r -- 0
}

_cter_ports_scan() {
    [[ -n "$CTER_PANEL_ID" ]] || return 0

    # Report listening TCP ports for the current shell session only (so a fresh
    # tab doesn't inherit unrelated machine-wide ports). We restrict the scan to
    # the current controlling TTY which keeps this cheap enough to run often.
    local -a ports
    local line name port

    # Best-effort: restrict to the current controlling TTY so a fresh tab doesn't
    # inherit unrelated machine-wide ports. This is a pragmatic heuristic that
    # works well for typical dev servers started from that shell.
    local tty_name pids_csv
    tty_name="$_CTER_TTY_NAME"
    if [[ -z "$tty_name" ]]; then
        local t
        t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ "$t" != "not a tty" ]] && tty_name="$t"
    fi

    if [[ -z "$tty_name" ]]; then
        _cter_send "clear_ports --tab=$CTER_TAB_ID --panel=$CTER_PANEL_ID"
        return 0
    fi

    pids_csv="$(ps -axo pid=,tty= 2>/dev/null | awk -v tty="$tty_name" '$2 == tty {print $1}' | tr '\n' ',' || true)"
    pids_csv="${pids_csv%,}"
    if [[ -z "$pids_csv" ]]; then
        _cter_send "clear_ports --tab=$CTER_TAB_ID --panel=$CTER_PANEL_ID"
        return 0
    fi

    while IFS= read -r line; do
        [[ "$line" == n* ]] || continue
        name="${line#n}"
        # Defensive: if the format ever includes a remote endpoint, keep the local side.
        name="${name%%->*}"
        port="${name##*:}"
        # Strip anything non-numeric (paranoia: "8000 (LISTEN)" etc).
        port="${port%%[^0-9]*}"
        [[ -n "$port" ]] && ports+=("$port")
    done < <(
        lsof -nP -a -p "$pids_csv" -iTCP -sTCP:LISTEN -F n 2>/dev/null || true
    )

    ports=("${(@u)ports}")
    ports=("${(@on)ports}")

    if (( ${#ports[@]} > 0 )); then
        _cter_send "report_ports ${(j: :)ports} --tab=$CTER_TAB_ID --panel=$CTER_PANEL_ID"
    else
        _cter_send "clear_ports --tab=$CTER_TAB_ID --panel=$CTER_PANEL_ID"
    fi
}

_cter_ports_kick() {
    # De-duped, async scans (with a short burst) so we still update when a command
    # runs in the foreground (no prompt updates while it is running).
    [[ -S "$CTER_SOCKET_PATH" ]] || return 0
    [[ -n "$CTER_TAB_ID" ]] || return 0
    [[ -n "$CTER_PANEL_ID" ]] || return 0
    if [[ -n "$_CTER_PORTS_JOB_PID" ]] && kill -0 "$_CTER_PORTS_JOB_PID" 2>/dev/null; then
        return 0
    fi
    _CTER_PORTS_LAST_RUN=$EPOCHSECONDS
    {
        # Scan over ~10 seconds so slow-starting servers (e.g. `npm run dev`)
        # still show ports while the command is in the foreground.
        sleep 0.5 2>/dev/null || true
        _cter_ports_scan
        sleep 1.0 2>/dev/null || true
        _cter_ports_scan
        sleep 1.5 2>/dev/null || true
        _cter_ports_scan
        sleep 2.0 2>/dev/null || true
        _cter_ports_scan
        sleep 2.5 2>/dev/null || true
        _cter_ports_scan
        sleep 2.5 2>/dev/null || true
        _cter_ports_scan
    } >/dev/null 2>&1 &!
    _CTER_PORTS_JOB_PID=$!
}

_cter_preexec() {
    if [[ -z "$_CTER_TTY_NAME" ]]; then
        local t
        t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ -n "$t" && "$t" != "not a tty" ]] && _CTER_TTY_NAME="$t"
    fi

    _CTER_CMD_START=$EPOCHSECONDS

    # Heuristic: git commands can change branch/dirty state without changing $PWD.
    local cmd="${1## }"
    if [[ "$cmd" == git\ * || "$cmd" == git ]]; then
        _CTER_GIT_FORCE=1
    fi

    # Ports can change due to long-running foreground commands (servers), so start
    # a short scan burst after command launch.
    _cter_ports_kick
}

_cter_precmd() {
    # Skip if socket doesn't exist yet
    [[ -S "$CTER_SOCKET_PATH" ]] || return 0
    [[ -n "$CTER_TAB_ID" ]] || return 0
    [[ -n "$CTER_PANEL_ID" ]] || return 0

    if [[ -z "$_CTER_TTY_NAME" ]]; then
        local t
        t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ -n "$t" && "$t" != "not a tty" ]] && _CTER_TTY_NAME="$t"
    fi

    local now=$EPOCHSECONDS
    local pwd="$PWD"
    local cmd_start="$_CTER_CMD_START"
    _CTER_CMD_START=0

    # CWD: keep the app in sync with the actual shell directory.
    # This is also the simplest way to test sidebar directory behavior end-to-end.
    if [[ "$pwd" != "$_CTER_PWD_LAST_PWD" ]]; then
        _CTER_PWD_LAST_PWD="$pwd"
        {
            # Quote to preserve spaces.
            local qpwd="${pwd//\"/\\\"}"
            _cter_send "report_pwd \"${qpwd}\" --tab=$CTER_TAB_ID --panel=$CTER_PANEL_ID"
        } >/dev/null 2>&1 &!
    fi

    # Git branch/dirty: update immediately on directory change, otherwise every ~3s.
    local should_git=0

    # Git branch can change without a `git ...`-prefixed command (aliases like `gco`,
    # tools like `gh pr checkout`, etc.). Detect HEAD changes and force a refresh.
    if [[ "$pwd" != "$_CTER_GIT_HEAD_LAST_PWD" ]]; then
        _CTER_GIT_HEAD_LAST_PWD="$pwd"
        _CTER_GIT_HEAD_PATH="$(_cter_git_resolve_head_path 2>/dev/null || true)"
        _CTER_GIT_HEAD_MTIME=0
    fi
    if [[ -n "$_CTER_GIT_HEAD_PATH" ]]; then
        local head_mtime
        head_mtime="$(_cter_git_head_mtime "$_CTER_GIT_HEAD_PATH" 2>/dev/null || echo 0)"
        if [[ -n "$head_mtime" && "$head_mtime" != 0 && "$head_mtime" != "$_CTER_GIT_HEAD_MTIME" ]]; then
            _CTER_GIT_HEAD_MTIME="$head_mtime"
            should_git=1
        fi
    fi

    if [[ "$pwd" != "$_CTER_GIT_LAST_PWD" ]]; then
        should_git=1
    elif (( _CTER_GIT_FORCE )); then
        should_git=1
    elif (( now - _CTER_GIT_LAST_RUN >= 3 )); then
        should_git=1
    fi

    if (( should_git )); then
        if [[ -n "$_CTER_GIT_JOB_PID" ]] && kill -0 "$_CTER_GIT_JOB_PID" 2>/dev/null; then
            : # previous update still running
        else
            _CTER_GIT_FORCE=0
            _CTER_GIT_LAST_PWD="$pwd"
            _CTER_GIT_LAST_RUN=$now
            {
                local branch dirty_opt=""
                branch=$(git branch --show-current 2>/dev/null)
                if [[ -n "$branch" ]]; then
                    local first
                    first=$(git status --porcelain -uno 2>/dev/null | head -1)
                    [[ -n "$first" ]] && dirty_opt="--status=dirty"
                    _cter_send "report_git_branch $branch $dirty_opt --tab=$CTER_TAB_ID"
                else
                    _cter_send "clear_git_branch --tab=$CTER_TAB_ID"
                fi
            } >/dev/null 2>&1 &!
            _CTER_GIT_JOB_PID=$!
        fi
    fi

    # Ports:
    # - Periodic scan to avoid stale values.
    # - Forced scan when a long-running command returns to the prompt (common when stopping a server).
    local cmd_dur=0
    if [[ -n "$cmd_start" && "$cmd_start" != 0 ]]; then
        cmd_dur=$(( now - cmd_start ))
    fi

    if (( cmd_dur >= 2 || now - _CTER_PORTS_LAST_RUN >= 10 )); then
        _cter_ports_kick
    fi
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _cter_preexec
add-zsh-hook precmd _cter_precmd

# Claude Code session tracking: record the session running in this terminal so cter can
# resume it with `claude --resume` after the app quits or crashes. Subcommands
# (`claude mcp`, `claude update`, ...) pass through untouched. Opt out with
# CTER_CLAUDE_HOOKS_DISABLED=1.
claude() {
    if [[ -z "${CTER_PANEL_ID:-}" || -z "${CTER_CLAUDE_SESSION_DIR:-}" \
        || -z "${CTER_SHELL_INTEGRATION_DIR:-}" || "${CTER_CLAUDE_HOOKS_DISABLED:-0}" == 1 ]]; then
        command claude "$@"
        return
    fi
    case "${1:-}" in
        agents|attach|auth|auto-mode|doctor|gateway|import|install|logs|mcp|plugin|plugins|purge|respawn|rm|setup-token|stop|kill|ultrareview|update|upgrade)
            command claude "$@"
            return
            ;;
    esac
    local settings='{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/bin/sh \"$CTER_SHELL_INTEGRATION_DIR/cter-claude-hook.sh\""}]}]}}'
    command claude --settings "$settings" "$@"
    local rc=$?
    # Claude ended while this shell lives on: the user closed the session, so don't resume
    # it. An app quit or crash kills the shell too and never reaches this line. 148 means
    # Claude was suspended (Ctrl-Z), not ended.
    if (( rc != 148 )); then
        command rm -f -- "$CTER_CLAUDE_SESSION_DIR/$CTER_PANEL_ID.json"
    fi
    return $rc
}
