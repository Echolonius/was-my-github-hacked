#!/usr/bin/env bash
# Fails if check.sh could reach GitHub in any way other than its one read-only function, or if
# it contains a command that could send data somewhere or run text as code.
# usage: bash tests/static-readonly.sh [path to check.sh]

f=${1:-check.sh}
fail=0

say() {
  printf 'static-readonly: %s\n' "$1" >&2
  fail=1
}

# Lines of code only: drop comment lines.
code=$(grep -v -E '^[[:space:]]*#' "$f")

# 1. "gh" as a command may appear only in these three exact places.
left=$(printf '%s\n' "$code" \
  | grep -E '(^|[^A-Za-z0-9_./-])gh([[:space:]]|$)' \
  | grep -v -F 'ghget() { gh api --method GET -H "Accept: application/vnd.github+json" "$@"; }' \
  | grep -v -F 'if ! gh --version >/dev/null 2>&1; then' \
  | grep -v -F 'if ! gh auth status >"$TMP/auth" 2>&1; then')
if [ -n "$left" ]; then
  say "the GitHub CLI is called outside the one read-only function:"
  printf '%s\n' "$left" >&2
fi

# 2. The read-only function must be exactly as expected, once.
n=$(printf '%s\n' "$code" | grep -c -F 'ghget() { gh api --method GET -H "Accept: application/vnd.github+json" "$@"; }')
[ "$n" -eq 1 ] || say "the read-only function ghget is missing or was changed"

# 3. Only one --method anywhere, and no flag that sends fields or changes the request.
n=$(printf '%s\n' "$code" | grep -c -e '--method')
[ "$n" -eq 1 ] || say "--method appears $n times; it may appear only inside ghget"
for flag in ' -X' '--field' '--raw-field' '--input' ' -f ' ' -F ' '--request'; do
  if printf '%s\n' "$code" | grep -q -F -e "$flag"; then
    say "forbidden flag found: $flag"
  fi
done

# 4. No way to run text as code, hide a command name, or talk to another server.
#    (The help text says "bash check.sh"; those words are text, not a command.)
code=$(printf '%s\n' "$code" | sed 's/bash check\.sh/check.sh/g')
for word in 'eval' 'exec' 'source' 'curl' 'wget' 'ssh' 'scp' 'nc' 'telnet' 'command' 'env' 'xargs' 'bash' 'sh'; do
  if printf '%s\n' "$code" | grep -q -E "(^|[;&|(\`[:space:]])$word[[:space:]]"; then
    say "forbidden command found: $word"
  fi
done

if [ "$fail" -eq 0 ]; then
  printf 'static-readonly: ok (%s only reads)\n' "$f"
fi
exit "$fail"
