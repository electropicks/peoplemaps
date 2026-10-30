#!/bin/zsh
# Kept for old habits: Scripts/verify.sh is the entry point.
exec "$(dirname "$0")/verify.sh" ${1:+--ui "$1"}
