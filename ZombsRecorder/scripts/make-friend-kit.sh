#!/bin/bash
# Builds "dist/Zombs Recorder Kit.zip" for a friend's Mac: the app with your Kaggle setup code built in
# (no pasting needed) and "Setup Guide.html". The zip contains your Kaggle token: send it privately.
# usage: bash ZombsRecorder/scripts/make-friend-kit.sh [TOKEN_FILE]   (default: ~/.kaggle/access_token)
set -euo pipefail
cd "$(dirname "$0")/.."
token_file="${1:-$HOME/.kaggle/access_token}"
[[ -s "$token_file" ]] || { echo "error: no Kaggle token in $token_file" >&2; exit 1; }
token=$(tr -d '[:space:]' < "$token_file")
# Ask Kaggle whose token this is. The token goes through file descriptors, never onto a command line.
response=$(curl -fsS https://api.kaggle.com/v1/security.OAuthService/IntrospectToken -H "Content-Type: application/json" \
  -H @<(printf 'Authorization: Bearer %s\n' "$token") --data-binary @<(printf '{"token":"%s"}' "$token")) \
  || { echo "error: Kaggle did not accept the token in $token_file" >&2; exit 1; }
owner=$(plutil -extract username raw -o - - <<< "$response" 2>/dev/null || true)
[[ -n "$owner" && "$(plutil -extract active raw -o - - <<< "$response" 2>/dev/null)" == true ]] \
  || { echo "error: Kaggle reports the token in $token_file as inactive" >&2; exit 1; }
# Same format as Credentials.setupCode: "ZREC1:" + base64url JSON {owner, token}.
code="ZREC1:$(printf '{"owner":"%s","token":"%s"}' "$owner" "$token" | base64 | tr '+/' '-_' | tr -d '=\n')"

bash scripts/package.sh
kit="dist/Zombs Recorder Kit"
rm -rf "$kit" "$kit.zip"
mkdir -p "$kit"
ditto dist/ZombsRecorder.app "$kit/ZombsRecorder.app"
(umask 077; printf '%s' "$code" > "$kit/ZombsRecorder.app/Contents/Resources/setup-code.txt")
codesign --force --sign - "$kit/ZombsRecorder.app"
codesign --verify --deep --strict "$kit/ZombsRecorder.app"
cp "packaging/Setup Guide.html" "$kit/Setup Guide.html"
ditto -c -k --keepParent "$kit" "$kit.zip"
rm -rf "$kit"
printf '\nBuilt %s\nUploads from it go to %s'"'"'s Kaggle. It contains your Kaggle token: send it privately.\n' "$PWD/$kit.zip" "$owner"
