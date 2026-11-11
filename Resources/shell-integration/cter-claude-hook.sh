#!/bin/sh
# Claude Code SessionStart hook injected by cter's `claude` shell function.
#
# Stores the hook payload (session_id, cwd, transcript_path) as
# $CTER_CLAUDE_SESSION_DIR/$CTER_PANEL_ID.json so cter can run
# `claude --resume <session_id>` in this terminal after the app quits or crashes.
# Runs on startup, /resume, /clear and compaction, so the file always names the
# session that is currently open. Prints nothing: SessionStart stdout becomes
# Claude context.

[ -n "$CTER_PANEL_ID" ] && [ -n "$CTER_CLAUDE_SESSION_DIR" ] || exit 0

payload=$(cat) || exit 0
[ -n "$payload" ] || exit 0

mkdir -p "$CTER_CLAUDE_SESSION_DIR" 2>/dev/null || exit 0
file="$CTER_CLAUDE_SESSION_DIR/$CTER_PANEL_ID.json"
tmp="$file.$$.tmp"
if printf '%s\n' "$payload" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
fi
exit 0
