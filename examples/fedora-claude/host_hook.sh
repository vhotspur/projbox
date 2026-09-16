#!/bin/bash

# Runs on host

set -euo pipefail

staging="$1"

# Copy the long-lived token
if [ -e "$HOME/.config/.claude-long-lived" ]; then
    mkdir -p "$staging/.claude"
    cp "$HOME/.config/.claude-long-lived" "$staging/.claude/long-lived-token"
fi

