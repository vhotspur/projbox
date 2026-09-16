#!/bin/sh

# Runs inside the container (expects $home is set)

# Install Claude
su - "$username" -c "export HOME=$home;"'curl -fsSL https://claude.ai/install.sh | bash' \
  || echo "projbox: FATAL: Claude Code install failed - please, retry manually inside the container" >&2

# Prepare to use the long-lived token for API
mkdir -p "$home/.bashrc.d/"
cat > "$home/.bashrc.d/load-claude-long-lived-token" <<'EOF'
if [ -e "$HOME/.claude/long-lived-token" ]; then
    export CLAUDE_CODE_OAUTH_TOKEN="$( cat "$HOME/.claude/long-lived-token" )"
fi
EOF

echo "projbox: INFO: Claude Code install attempt finished for $username."  >&2
