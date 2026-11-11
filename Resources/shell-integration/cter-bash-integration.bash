# cter shell integration for bash

_cter_send() {
    local payload="$1"
    if command -v ncat >/dev/null 2>&1; then
        printf '%s\n' "$payload" | ncat -U "$CTER_SOCKET_PATH" --send-only
    elif command -v socat >/dev/null 2>&1; then
        printf '%s\n' "$payload" | socat - "UNIX-CONNECT:$CTER_SOCKET_PATH"
    elif command -v nc >/dev/null 2>&1; then
        # Some nc builds don't support unix sockets, but keep as a last-ditch fallback.
        #
        # Important: macOS/BSD nc will often wait for the peer to close the socket
        # after it has finished writing. cter keeps the connection open, so
        # a plain `nc -U` can hang indefinitely and leak background processes.
        #
        # Prefer flags that guarantee we exit after sending, and fall back to a
        # short timeout so we never block sidebar updates.
        if printf '%s\n' "$payload" | nc -N -U "$CTER_SOCKET_PATH" >/dev/null 2>&1; then
            :
        else
            printf '%s\n' "$payload" | nc -w 1 -U "$CTER_SOCKET_PATH" >/dev/null 2>&1 || true
        fi
    fi
}

# Throttle heavy work to avoid prompt latency.
_CTER_PWD_LAST_PWD="${_CTER_PWD_LAST_PWD:-}"
_CTER_GIT_LAST_PWD="${_CTER_GIT_LAST_PWD:-}"
_CTER_GIT_LAST_RUN="${_CTER_GIT_LAST_RUN:-0}"
_CTER_GIT_JOB_PID="${_CTER_GIT_JOB_PID:-}"

_CTER_PORTS_LAST_RUN="${_CTER_PORTS_LAST_RUN:-0}"
_CTER_PORTS_JOB_PID="${_CTER_PORTS_JOB_PID:-}"

_cter_prompt_command() {
    [[ -S "$CTER_SOCKET_PATH" ]] || return 0
    [[ -n "$CTER_TAB_ID" ]] || return 0
    [[ -n "$CTER_PANEL_ID" ]] || return 0

    local now=$SECONDS
    local pwd="$PWD"
    local tty_name=""
    tty_name="$(tty 2>/dev/null || true)"
    tty_name="${tty_name##*/}"
    if [[ "$tty_name" == "not a tty" ]]; then
        tty_name=""
    fi

    # CWD: keep the app in sync with the actual shell directory.
    if [[ "$pwd" != "$_CTER_PWD_LAST_PWD" ]]; then
        _CTER_PWD_LAST_PWD="$pwd"
        {
            local qpwd="${pwd//\"/\\\"}"
            _cter_send "report_pwd \"${qpwd}\" --tab=$CTER_TAB_ID --panel=$CTER_PANEL_ID"
        } >/dev/null 2>&1 &
    fi

    # Git branch/dirty can change without a directory change (e.g. `git checkout`),
    # so update on every prompt (still async + de-duped by the running-job check).
    local should_git=1

    if (( should_git )); then
        if [[ -n "$_CTER_GIT_JOB_PID" ]] && kill -0 "$_CTER_GIT_JOB_PID" 2>/dev/null; then
            :
        else
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
            } >/dev/null 2>&1 &
            _CTER_GIT_JOB_PID=$!
        fi
    fi

    if (( now - _CTER_PORTS_LAST_RUN >= 10 )); then
        if [[ -n "$_CTER_PORTS_JOB_PID" ]] && kill -0 "$_CTER_PORTS_JOB_PID" 2>/dev/null; then
            : # previous scan still running
        else
            _CTER_PORTS_LAST_RUN=$now
            {
                local ports=()
                local pids_csv=""
                if [[ -n "$tty_name" ]]; then
                    pids_csv="$(ps -axo pid=,tty= 2>/dev/null | awk -v tty="$tty_name" '$2 == tty {print $1}' | tr '\n' ',' || true)"
                    pids_csv="${pids_csv%,}"
                fi

                if [[ -n "$pids_csv" ]]; then
                    local line name port
                    while IFS= read -r line; do
                        [[ "$line" == n* ]] || continue
                        name="${line#n}"
                        name="${name%%->*}"
                        port="${name##*:}"
                        port="${port%%[^0-9]*}"
                        [[ -n "$port" ]] && ports+=("$port")
                    done < <(
                        lsof -nP -a -p "$pids_csv" -iTCP -sTCP:LISTEN -F n 2>/dev/null || true
                    )
                fi

                if ((${#ports[@]} > 0)); then
                    local ports_sorted
                    ports_sorted=$(printf '%s\n' "${ports[@]}" | sort -n | uniq | tr '\n' ' ')
                    ports_sorted="${ports_sorted%% }"
                    _cter_send "report_ports $ports_sorted --tab=$CTER_TAB_ID --panel=$CTER_PANEL_ID"
                else
                    _cter_send "clear_ports --tab=$CTER_TAB_ID --panel=$CTER_PANEL_ID"
                fi
            } >/dev/null 2>&1 &
            _CTER_PORTS_JOB_PID=$!
        fi
    fi
}

_cter_install_prompt_command() {
    [[ -n "${_CTER_PROMPT_INSTALLED:-}" ]] && return 0
    _CTER_PROMPT_INSTALLED=1

    local decl
    decl="$(declare -p PROMPT_COMMAND 2>/dev/null || true)"
    if [[ "$decl" == "declare -a"* ]]; then
        local existing=0
        local item
        for item in "${PROMPT_COMMAND[@]}"; do
            [[ "$item" == "_cter_prompt_command" ]] && existing=1 && break
        done
        if (( existing == 0 )); then
            PROMPT_COMMAND=("_cter_prompt_command" "${PROMPT_COMMAND[@]}")
        fi
    else
        case ";$PROMPT_COMMAND;" in
            *";_cter_prompt_command;"*) ;;
            *)
                if [[ -n "$PROMPT_COMMAND" ]]; then
                    PROMPT_COMMAND="_cter_prompt_command;$PROMPT_COMMAND"
                else
                    PROMPT_COMMAND="_cter_prompt_command"
                fi
                ;;
        esac
    fi
}

_cter_install_prompt_command

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
