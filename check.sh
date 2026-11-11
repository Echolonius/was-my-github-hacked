#!/usr/bin/env bash
# shellcheck disable=SC2016
# (SC2016: the jq and awk programs below sit in single quotes on purpose; the dollar names in
# them belong to jq and awk, not to the shell.)
#
# check.sh: a read-only checker for the signs in the guide "Was my GitHub account hacked?"
#   https://github.com/Echolonius/was-my-github-hacked
#
# Skim this file before you run it. What it promises:
#   * It only reads. One function, ghget, talks to GitHub, and it can only ask questions.
#     tests/static-readonly.sh fails if anything else in this file could reach GitHub.
#   * It prints names and dates only: never a secret's value, never a key, never a webhook's
#     full address (those often contain passwords).
#   * It writes only inside a temporary folder, which it removes when it ends.
#   * It downloads nothing, updates nothing and reports to nobody.
#   * It never says your account is safe: read the last part of its report.
#   * Every name GitHub sends back (branches, commit messages, descriptions and so on) could
#     have been chosen by an attacker, so it is cleaned before it is printed and never run.
#
# It needs the GitHub CLI, signed in, and the standard tools found on macOS, Linux and in
# Git Bash on Windows. It keeps to old bash (3.2, the one macOS ships) on purpose.

LC_ALL=C
export LC_ALL

VERSION="0.1 (beta)"
GUIDE="https://github.com/Echolonius/was-my-github-hacked"
US=$(printf '\037') # separates fields inside this script; cleaned text can never contain it

DAYS=90
MAX_REPOS=200
NO_FORKS=0
QUIET=0
REPO_ARGS=""

usage() {
  cat <<EOF
Was my GitHub account hacked? Read-only checker $VERSION

Usage: bash check.sh [--days N] [--repo OWNER/NAME]... [--max-repos N] [--no-forks] [--quiet]

  --days N           how far back to look: 1 to 365, default 90 (the same as GitHub's security log)
  --repo OWNER/NAME  check only this repository; repeat it for more. The account checks still run.
  --max-repos N      check at most N repositories, most recently pushed first (default 200)
  --no-forks         skip forks (by default forks get the settings checks only)
  --quiet            no progress messages
  --help, --version

It only reads, through the GitHub CLI, which must be installed and signed in.
Exit codes: 0 nothing flagged, 1 something to check, 2 act now, 3 could not run.
Guide: $GUIDE
EOF
}

stop() { # could not run: say why, exit 3
  printf 'check.sh: %s\n' "$1" >&2
  exit 3
}

is_number() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}

# ---- options -------------------------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --days)
      [ $# -ge 2 ] || stop "--days needs a number, for example: --days 30"
      DAYS=$2
      shift 2
      ;;
    --days=*)
      DAYS=${1#--days=}
      shift
      ;;
    --repo)
      [ $# -ge 2 ] || stop "--repo needs a name, for example: --repo OWNER/NAME"
      REPO_ARGS="$REPO_ARGS$2
"
      shift 2
      ;;
    --repo=*)
      REPO_ARGS="$REPO_ARGS${1#--repo=}
"
      shift
      ;;
    --max-repos)
      [ $# -ge 2 ] || stop "--max-repos needs a number, for example: --max-repos 50"
      MAX_REPOS=$2
      shift 2
      ;;
    --max-repos=*)
      MAX_REPOS=${1#--max-repos=}
      shift
      ;;
    --no-forks)
      NO_FORKS=1
      shift
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    --version)
      printf 'check.sh %s\n' "$VERSION"
      exit 0
      ;;
    *)
      stop "unknown option '$1'. Try: bash check.sh --help"
      ;;
  esac
done

if ! is_number "$DAYS" || [ "${#DAYS}" -gt 4 ]; then
  stop "--days must be a number from 1 to 365"
fi
DAYS=$((10#$DAYS))
if [ "$DAYS" -lt 1 ] || [ "$DAYS" -gt 365 ]; then
  stop "--days must be a number from 1 to 365"
fi
if ! is_number "$MAX_REPOS" || [ "${#MAX_REPOS}" -gt 6 ]; then
  stop "--max-repos must be a number, 1 or more"
fi
MAX_REPOS=$((10#$MAX_REPOS))
if [ "$MAX_REPOS" -lt 1 ]; then
  stop "--max-repos must be a number, 1 or more"
fi

REPO_MODE=0
if [ -n "$REPO_ARGS" ]; then
  REPO_MODE=1
  while IFS= read -r one; do
    [ -n "$one" ] || continue
    case "$one" in
      */*/* | /* | */ | ./* | ../* | */. | */.. | *[!A-Za-z0-9._/-]*)
        stop "--repo must look like OWNER/NAME, not '$one'"
        ;;
      */*) ;;
      *)
        stop "--repo must look like OWNER/NAME, not '$one'"
        ;;
    esac
  done <<EOF
$REPO_ARGS
EOF
fi

# ---- the only door to GitHub ---------------------------------------------------------------

# Every question to GitHub goes through this one function, and it can only read.
ghget() { gh api --method GET -H "Accept: application/vnd.github+json" "$@"; }

if ! gh --version >/dev/null 2>&1; then
  stop "the GitHub CLI was not found. Install it from https://cli.github.com , sign in, then run this again."
fi

TMP=$(mktemp -d 2>/dev/null) || TMP=""
case "$TMP" in
  '' | /) stop "could not make a temporary folder" ;;
esac
trap 'rm -r "$TMP" 2>/dev/null' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! gh auth status >"$TMP/auth" 2>&1; then
  stop "you are not signed in to GitHub in this terminal.
Sign in with the GitHub CLI first, then run this again. How: $GUIDE#run-the-checker-beta"
fi

API_CALLS=0   # questions asked
ANSWERED=0    # questions GitHub answered
API_ERR=""    # why the last question failed: "HTTP 404", "rate limit" or "no answer"
RATE_STOP=0   # 1 once GitHub says the hourly limit is used up

# api FILE ARGS...: ask GitHub and keep the answer in FILE. Returns 1 if there was no answer.
# When a question fails the CLI prints the error text where the answer would go, so a failed
# answer is thrown away, never read.
api() {
  local out=$1
  shift
  API_CALLS=$((API_CALLS + 1))
  if ghget "$@" >"$TMP/raw" 2>"$TMP/err" </dev/null; then
    tr -d '\r' <"$TMP/raw" >"$out"
    ANSWERED=$((ANSWERED + 1))
    API_ERR=""
    return 0
  fi
  : >"$out"
  API_ERR=$(sed -n 's/.*(HTTP \([0-9][0-9][0-9]\)).*/HTTP \1/p' "$TMP/err" | head -n 1)
  if grep -i -q 'rate limit' "$TMP/err" || [ "$API_ERR" = "HTTP 429" ]; then
    API_ERR="rate limit"
    RATE_STOP=1
  elif [ -z "$API_ERR" ]; then
    API_ERR="no answer"
  fi
  return 1
}

progress() {
  [ "$QUIET" -eq 1 ] || printf '%s\n' "$1" >&2
}

plural() { # plural 1 key keys -> "1 key"; plural 3 key keys -> "3 keys"
  if [ "$1" -eq 1 ]; then
    printf '%s %s' "$1" "$2"
  else
    printf '%s %s' "$1" "$3"
  fi
}

# ---- how answers are read (jq, built into the GitHub CLI) ------------------------------------
#
# c       cleans text before it is used: control characters and invisible direction marks are
#         dropped (a crafted name must not be able to repaint your terminal) and it is cut to
#         a sensible length. A tab becomes a space.
# utc     turns any of GitHub's date formats into one form, in UTC. No clock is read here: the
#         start of the window is worked out once, at start-up, and passed in as "since".
# inwin   says whether a date is inside the window: "new", "old" or "nodate".
# host    keeps only the server name of an address.

JQ_DEFS='
def c(n): tostring | explode
  | map(if . == 9 then 32 else . end
        | select((. >= 32 and . < 127)
                 or (. > 159 and (. < 8203 or . > 8207) and (. < 8232 or . > 8238)
                     and (. < 8294 or . > 8297) and . != 65279)))
  | implode | .[0:n];
def c: c(120);
def n2: tostring | if length < 2 then "0" + . else . end;
def epoch:
  tostring
  | (if endswith("Z") then 0
     elif ((.[-6:-5] == "+" or .[-6:-5] == "-") and .[-3:-2] == ":")
       then (if .[-6:-5] == "-" then -1 else 1 end)
            * ((.[-5:-3] | tonumber) * 3600 + (.[-2:] | tonumber) * 60)
     elif (.[-5:-4] == "+" or .[-5:-4] == "-")
       then (if .[-5:-4] == "-" then -1 else 1 end)
            * ((.[-4:-2] | tonumber) * 3600 + (.[-2:] | tonumber) * 60)
     else error("zone") end) as $off
  | (.[0:4] | tonumber) as $y | (.[5:7] | tonumber) as $mo | (.[8:10] | tonumber) as $d
  | (.[11:13] | tonumber) as $h | (.[14:16] | tonumber) as $mi | (.[17:19] | tonumber) as $s
  | (if $mo <= 2 then $y - 1 else $y end) as $yy
  | ($yy / 400 | floor) as $era
  | ($yy - $era * 400) as $yoe
  | (((153 * (if $mo > 2 then $mo - 3 else $mo + 9 end) + 2) / 5 | floor) + $d - 1) as $doy
  | ($yoe * 365 + ($yoe / 4 | floor) - ($yoe / 100 | floor) + $doy) as $doe
  | ($era * 146097 + $doe - 719468) * 86400 + $h * 3600 + $mi * 60 + $s - $off;
def iso:
  floor
  | (. / 86400 | floor) as $days | (. - $days * 86400) as $rem
  | ($days + 719468) as $z
  | ($z / 146097 | floor) as $era
  | ($z - $era * 146097) as $doe
  | (($doe - ($doe / 1460 | floor) + ($doe / 36524 | floor) - ($doe / 146096 | floor)) / 365
     | floor) as $yoe
  | ($doe - (365 * $yoe + ($yoe / 4 | floor) - ($yoe / 100 | floor))) as $doy
  | ((5 * $doy + 2) / 153 | floor) as $mp
  | ($doy - ((153 * $mp + 2) / 5 | floor) + 1) as $d
  | (if $mp < 10 then $mp + 3 else $mp - 9 end) as $mo
  | ($yoe + $era * 400 + (if $mo <= 2 then 1 else 0 end)) as $y
  | "\($y)-\($mo | n2)-\($d | n2)T\($rem / 3600 | floor | n2):\(($rem % 3600) / 60 | floor | n2):\($rem % 60 | n2)Z";
def utc: try (epoch | iso) catch "";
def day: utc | if . == "" then "?" else .[0:10] end;
def secn: try epoch catch 0;
def inwin: utc | if . == "" then "nodate" elif . >= since then "new" else "old" end;
def first_of(s): (split(s) | .[0]) // "";
def host: (. // "") | tostring
  | (if contains("://") then (split("://") | .[1:] | join("://")) else . end)
  | first_of("/") | first_of("?") | first_of("#")
  | ((split("@") | .[-1]) // "")
  | (if startswith("[") then first_of("]") + "]" else first_of(":") end)
  | c(80) | if . == "" then "(no address)" else . end;
'

JQ_ROW='def row: [
  ((.owner.login | tostring | @uri) + "/" + (.name | tostring | @uri)),
  (.full_name | c(140)),
  (.created_at | utc),
  (.pushed_at | utc),
  (if .fork == true then "fork" else "own" end),
  (if .archived == true then "archived" else "live" end),
  ((.visibility // (if .private == true then "private" else "public" end)) | c(20)),
  (.default_branch // "" | c(250)),
  (.description // "" | c(120))
] | join("\u001f");'

JQ_EVENTS='"#\(length)",
(.[] | select(.type == "PublicEvent") | select((.created_at | inwin) != "old")
 | [ (.created_at | day), (.repo.name // "?" | c(140)) ] | join("\u001f"))'

JQ_KEYS='.[] | [ (.created_at | inwin), (.created_at | day), (.title // "" | c(80)) ] | join("\u001f")'

JQ_HOOKS='.[] | [
  ([ (.created_at | inwin), (.updated_at // .created_at | inwin) ]
   | if any(. == "new") then "new" elif any(. == "nodate") then "nodate" else "old" end),
  (.created_at | day),
  (.updated_at // .created_at | day),
  (if .active == false then "switched off" else "active" end),
  (.config.url | host)
] | join("\u001f")'

JQ_DEPLOY_KEYS='.[] | [
  (.created_at | inwin), (.created_at | day),
  (if .read_only == false then "it can write" else "read-only" end),
  (.title // "" | c(80))
] | join("\u001f")'

JQ_INVITATIONS='.[] | [
  (.created_at | inwin), (.created_at | day),
  (.invitee.login // "?" | c(60)), (.inviter.login // "?" | c(60)), (.permissions // "?" | c(20))
] | join("\u001f")'

JQ_COLLABORATORS='.[] | [
  (.login // "?" | c(60)), (if .permissions.push == true then "push" else "read" end)
] | join("\u001f")'

JQ_RUNNERS='.runners[] | [ (.name // "?" | c(80)), (.os // "?" | c(20)), (.status // "?" | c(20)) ] | join("\u001f")'

JQ_ACTIVITY='"#\(length)",
(.[] | select((.timestamp | inwin) != "old") | [
  (.timestamp | utc), (.timestamp | secn | tostring),
  (.activity_type // "?" | c(30)),
  (.ref // "" | c(250)),
  (.ref // "" | tostring | ltrimstr("refs/heads/") | @uri),
  (.actor.login // "?" | c(60)),
  (.before // "" | c(40)), (.after // "" | c(40))
] | join("\u001f"))'

JQ_WORKFLOWS='.workflows[]
| select((.path // "" | tostring | startswith("dynamic/")) | not)
| (.created_at | inwin) as $w | select($w != "old")
| [ $w, (.created_at | day), (.created_at | secn | tostring), (.state // "?" | c(30)), (.path // "?" | c(200)) ]
| join("\u001f")'

JQ_FOLDER='.[] | select(.type == "file") | (.path // "" | c(200))'

JQ_COMMITS='.[] | (.commit.committer.date // .commit.author.date) as $d | [
  (.sha // "" | c(40)), ($d | day), ($d | secn | tostring),
  ((.commit.message // "" | tostring | split("\n") | .[0]) // "" | c(100))
] | join("\u001f")'

# Looks only at job files (.github/workflows/). "dump" means a line that was ADDED contains
# toJSON(secrets), in any letter case, with or without spaces: that sends out every secret at once.
JQ_COMMIT='.files[]? | select(.filename // "" | tostring | startswith(".github/workflows/")) | [
  (.filename | c(200)),
  (.status // "?" | c(20)),
  (if (.patch // "" | tostring | split("\n")
       | map(select(startswith("+")) | ascii_downcase | split(" ") | join("") | split("\t") | join(""))
       | any(contains("tojson(secrets)")))
   then "dump"
   elif (.patch == null and (.additions // 0) > 0) then "unread"
   else "ok" end)
] | join("\u001f")'

JQ_RELEASES='.[] | select(.draft != true)
| (.published_at | secn) as $p | (.tag_name // "?" | c(80)) as $tag
| .assets[]? | (.updated_at // .created_at) as $t
| select(($t | inwin) != "old")
| ($t | secn) as $s
| (if ($p <= 0 or $s <= 0) then [ "nodate", $tag, (.name // "?" | c(120)), "?", "0" ]
   elif ($s - $p) > 3600 then [ "late", $tag, (.name // "?" | c(120)), ($t | day), (($s - $p) / 3600 | floor | tostring) ]
   else empty end)
| join("\u001f")'

JQ_SECRETS='.secrets[] | [ (.name // "?" | c(80)), (.updated_at | day) ] | join("\u001f")'

# Reads one repository's activity list (newest first) and works out, without asking GitHub
# anything more:
#   C  counts          F  force pushes on the main branch
#   S  branches that were created and deleted again within an hour and never merged
#   B  the other branches whose job files should be looked at (at most 5, newest first)
# A deleted branch counts as merged when a pull request was merged in the 10 minutes before
# it was deleted, or when its last commit is also on another branch.
AWK_ACTIVITY='
function tipseen(sha, r,    j) {
  if (sha == "" || sha ~ /^0+$/) return 0
  for (j = 1; j <= n; j++) if (ref[j] != r && (aft[j] == sha || bef[j] == sha)) return 1
  return 0
}
BEGIN { FS = "\037"; def = ENVIRON["CHK_DEFREF"]; hm = 0; sm = 0; fk = ""; fc = 0; n = 0; page = 0 }
/^#/ { page = substr($0, 2) + 0; next }
{ n++; utc[n] = $1; ep[n] = $2 + 0; typ[n] = $3; ref[n] = $4; uri[n] = $5; who[n] = $6; bef[n] = $7; aft[n] = $8 }
END {
  for (i = n; i >= 1; i--) {
    t = typ[i]; r = ref[i]
    if (t == "push") np++
    else if (t == "force_push") nf++
    else if (t == "branch_creation") nc++
    else if (t == "branch_deletion") nd++
    else if (t == "pr_merge" || t == "merge_queue_merge") { nm++; hm = 1; lm = ep[i] }
    if (r != def && substr(r, 1, 11) == "refs/heads/") {
      state[r] = "live"
      if (t == "branch_creation") { born[r] = ep[i]; bornby[r] = who[i]; hasborn[r] = 1 }
      if (t == "branch_deletion") {
        merged = 0
        if (hm == 1 && ep[i] >= lm && ep[i] - lm <= 600 && (hasborn[r] != 1 || lm >= born[r])) merged = 1
        if (merged == 0 && tipseen(bef[i], r)) merged = 1
        state[r] = (merged == 1) ? "merged" : "gone"
        tip[r] = bef[i]
        if (hasborn[r] == 1 && ep[i] >= born[r] && ep[i] - born[r] <= 3600) {
          if (merged == 1) sm++
          else printf "S\037%s\037%s\037%d\037%s\037%s\n", substr(r, 12), substr(utc[i], 1, 10), int((ep[i] - born[r]) / 60), bornby[r], who[i]
        }
        hasborn[r] = 0
      }
    }
    if (t == "force_push" && r == def) {
      k = substr(utc[i], 1, 10) "\037" who[i]
      if (k == fk) fc++
      else { if (fc > 0) printf "F\037%s\037%d\n", fk, fc; fk = k; fc = 1 }
    }
  }
  if (fc > 0) printf "F\037%s\037%d\n", fk, fc
  nb = 0; more = 0
  for (i = 1; i <= n; i++) {
    r = ref[i]
    if (r == def || substr(r, 1, 11) != "refs/heads/" || seen[r] == 1) continue
    seen[r] = 1
    if (state[r] == "merged") continue
    if (nb >= 5) { more++; continue }
    if (state[r] == "gone") {
      if (length(tip[r]) == 40 && tip[r] ~ /^[0-9a-f]+$/ && tip[r] !~ /^0+$/) { nb++; printf "B\037sha\037%s\037%s\n", substr(r, 12), tip[r] }
    } else { nb++; printf "B\037name\037%s\037%s\n", substr(r, 12), uri[i] }
  }
  printf "C\037%d\037%d\037%d\037%d\037%d\037%d\037%d\037%d\037%s\n", np, nc, nd, nf, nm, sm, more, page, (n > 0 ? substr(utc[n], 1, 10) : "")
}'

# The same file name, or the same commit message, in three or more repositories within 24 hours.
AWK_BULK='
BEGIN { FS = "\037"; nk = 0 }
{
  k = $1 "\037" $2
  if (!(k in first)) { first[k] = NR; nk++; order[nk] = k }
  key[NR] = k; ep[NR] = $3 + 0; day[NR] = $4; repo[NR] = $5
}
END {
  for (a = 1; a <= nk; a++) {
    k = order[a]; best = 0; bestday = ""
    for (i = first[k]; i <= NR; i++) {
      if (key[i] != k) continue
      split("", inwin); cnt = 0
      for (j = first[k]; j <= NR; j++) {
        if (key[j] != k) continue
        if (ep[j] >= ep[i] && ep[j] - ep[i] <= 86400 && !(repo[j] in inwin)) { inwin[repo[j]] = 1; cnt++ }
      }
      if (cnt > best) { best = cnt; bestday = day[i] }
    }
    if (best >= 3) printf "%s\037%d\037%s\n", k, best, bestday
  }
}'

# ---- where findings are kept until the report is printed --------------------------------------

N_ACT=0

chk() { printf '%s\037%s\n' "$2" "$3" >>"$TMP/chk.$1"; }    # chk KIND WHERE TEXT
cnc() { printf '%s\037%s (%s)\n' "$1" "$2" "$3" >>"$TMP/cnc"; } # cnc WHERE WHAT WHY
note() { printf '    %s\n' "$1" >>"$TMP/info.account"; }
frag() { R_INFO="$R_INFO${R_INFO:+; }$1"; }

act_open() { # act_open WHERE HEADLINE: start one ACT NOW finding
  N_ACT=$((N_ACT + 1))
  {
    [ "$N_ACT" -eq 1 ] || printf '\n'
    printf '  %s\n    %s\n' "$1" "$2"
  } >>"$TMP/act"
}
act_item() { printf '      %s\n' "$1" >>"$TMP/act"; }
act_line() { printf '    %s\n' "$1" >>"$TMP/act"; }

failed() { cnc "$R_NAME" "$1" "$API_ERR"; }

# known-bad.txt holds names used in past attacks. It ships next to this file and is never
# fetched. It can only RAISE a finding these checks already made; a name alone finds nothing.
case "$0" in
  */*) HERE=${0%/*} ;;
  *) HERE=. ;;
esac
KB_LOADED=0
if [ -r "$HERE/known-bad.txt" ]; then
  tr -d '\r' <"$HERE/known-bad.txt" | awk '
    BEGIN { FS = "|" }
    /^[ \t]*#/ || NF < 2 { next }
    {
      k = $1; p = $2; l = $3
      gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", p); gsub(/^[ \t]+|[ \t]+$/, "", l)
      if (l == "") l = "a known attack"
      if (k != "" && p != "") printf "%s\037%s\037%s\n", k, tolower(p), l
    }' >"$TMP/kb"
  KB_LOADED=1
fi

# kb_match KIND TEXT: prints the attack's label when a known-bad entry of that kind is inside TEXT
kb_match() {
  [ -s "$TMP/kb" ] || return 1
  KB_TEXT=$2 awk -v kind="$1" '
    BEGIN { FS = "\037"; t = tolower(ENVIRON["KB_TEXT"]); found = 0 }
    found == 0 && $1 == kind && index(t, $2) > 0 { print $3; found = 1 }
    END { exit (found == 1 ? 0 : 1) }' "$TMP/kb"
}

bulk() { printf '%s\037%s\037%s\037%s\037%s\n' "$1" "$2" "$3" "$4" "$R_NAME" >>"$TMP/bulk"; }

# ---- start-up ---------------------------------------------------------------------------------

progress "Checking who is signed in..."
if ! api "$TMP/a" user --jq '.login'; then
  stop "GitHub did not answer ($API_ERR). Nothing was checked."
fi
LOGIN=$(head -n 1 "$TMP/a")
case "$LOGIN" in
  '' | *[!A-Za-z0-9-]*) stop "GitHub's answer about who is signed in was not understood. Nothing was checked." ;;
esac

# The start of the window, worked out once from GitHub's clock. Everything later compares with
# this fixed moment.
if ! api "$TMP/a" rate_limit --jq "(now - ($DAYS * 86400)) | todate"; then
  stop "GitHub did not answer ($API_ERR). Nothing was checked."
fi
SINCE=$(head -n 1 "$TMP/a")
case "$SINCE" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
  *) stop "GitHub's answer about the date was not understood. Nothing was checked." ;;
esac
SINCE_DAY=${SINCE%%T*}
JQ_LIB="def since: \"$SINCE\"; $JQ_DEFS"

if ! api "$TMP/a" rate_limit --jq '.resources.core.remaining'; then
  stop "GitHub did not answer ($API_ERR). Nothing was checked."
fi
REMAINING=$(head -n 1 "$TMP/a")
if ! is_number "$REMAINING" || [ "${#REMAINING}" -gt 9 ]; then
  REMAINING=0
fi
ANSWERED=0

if [ "$KB_LOADED" -eq 0 ]; then
  note "known-bad.txt was not found next to check.sh, so nothing was compared with the names used"
  note "  in past attacks."
fi

# ---- account: your repository list, and new repositories ---------------------------------------

progress "Reading your repository list..."
LIST_OK=1
N_ALL=0
if ! api "$TMP/repos" --paginate "user/repos?affiliation=owner&sort=created&direction=desc&per_page=100" --jq "$JQ_LIB $JQ_ROW .[] | row"; then
  LIST_OK=0
  : >"$TMP/repos"
  cnc "Your account" "the list of your repositories" "$API_ERR"
fi

if [ "$LIST_OK" -eq 1 ]; then
  N_ALL=$(awk 'END { print NR + 0 }' "$TMP/repos")
  N_ALL_FORKS=$(awk 'BEGIN { FS = "\037" } $5 == "fork" { n++ } END { print n + 0 }' "$TMP/repos")
  N_ALL_ARCH=$(awk 'BEGIN { FS = "\037" } $6 == "archived" { n++ } END { print n + 0 }' "$TMP/repos")
  note "Repositories you own: $N_ALL ($(plural "$N_ALL_FORKS" fork forks), $N_ALL_ARCH archived)."

  awk -v since="$SINCE" 'BEGIN { FS = "\037" } $3 != "" && ($3 "") >= since' "$TMP/repos" >"$TMP/newrepos"
  NEW_FORKS=0
  while IFS="$US" read -r _slug name created _pushed kind _arch vis _def desc; do
    if [ "$kind" = fork ]; then
      NEW_FORKS=$((NEW_FORKS + 1))
      continue
    fi
    if label=$(kb_match repo "${name#*/} $desc"); then
      detail="$vis, created ${created%%T*}"
      if [ -n "$desc" ]; then
        detail="$detail, description: \"$desc\""
      fi
      act_open "$name" "A new repository has a name or description used in a known attack: $label."
      act_item "$detail"
      act_line "Why it matters: that attack creates repositories like this one to publish what it stole."
      act_line "Do this first: lock the attacker out and change your secrets (the guide's first section)."
      act_line "  Keep a record of this repository for GitHub Support before you delete it."
      act_line "Guide: $GUIDE#someone-is-in-my-account-right-now"
    else
      chk new-repos "Your account" "$name ($vis, created ${created%%T*})"
    fi
  done <"$TMP/newrepos"
  if [ "$NEW_FORKS" -gt 0 ]; then
    note "New forks (your copies of other people's repositories) in the window: $NEW_FORKS."
  fi
fi

# ---- account: repositories switched from private to public -------------------------------------

FEED_NOTE="GitHub's activity feed only holds about 300 recent events, so an older switch is invisible here."
FEED_NOTE2="Your security log shows them all: search it for action:repo.access"

if [ "$RATE_STOP" -eq 0 ]; then
  progress "Reading your recent activity feed..."
  : >"$TMP/pub"
  PUB_OK=1
  page=1
  while [ "$page" -le 3 ]; do
    if api "$TMP/a" "users/$LOGIN/events?per_page=100&page=$page" --jq "$JQ_LIB $JQ_EVENTS"; then
      grep -v '^#' "$TMP/a" >>"$TMP/pub"
      got=$(sed -n 's/^#\([0-9][0-9]*\)$/\1/p' "$TMP/a" | head -n 1)
      if ! is_number "$got" || [ "$got" -eq 0 ]; then
        break
      fi
    else
      PUB_OK=0
      cnc "Your account" "repositories switched from private to public" "$API_ERR"
      break
    fi
    page=$((page + 1))
  done
  sort -u "$TMP/pub" >"$TMP/pub.u"
  N_PUB=$(awk 'END { print NR + 0 }' "$TMP/pub.u")
  if [ "$N_PUB" -ge 3 ]; then
    act_open "Your account" "$N_PUB repositories were switched from private to public."
    while IFS="$US" read -r day name; do
      act_item "$name, $day"
    done <"$TMP/pub.u"
    act_line "Why it matters: if you didn't do this, your private code, and any secrets (keys and"
    act_line "  passwords) inside it, are now open to everyone. One attack did exactly this."
    act_line "Do this first: make them private again (each repository's Settings), then change every"
    act_line "  secret that was in their code."
    act_line "Note: $FEED_NOTE"
    act_line "  $FEED_NOTE2"
    act_line "Guide: $GUIDE#4-clean-up"
  elif [ "$N_PUB" -ge 1 ]; then
    while IFS="$US" read -r day name; do
      chk went-public "Your account" "$name, $day"
    done <"$TMP/pub.u"
    chk went-public "Your account" "Note: $FEED_NOTE"
    chk went-public "Your account" "  $FEED_NOTE2"
  elif [ "$PUB_OK" -eq 1 ]; then
    note "No repository was switched from private to public, as far as GitHub's activity feed shows."
    note "  $FEED_NOTE"
    note "  $FEED_NOTE2"
  fi
fi

# ---- account: keys -------------------------------------------------------------------------------

KEYS_TEXT=""
KEYS_NEW=0
KEYS_OK=1

check_keys() { # check_keys ENDPOINT "one key" "many keys" SHOW-TITLE
  local w day title total=0
  if api "$TMP/a" "users/$LOGIN/$1?per_page=100" --jq "$JQ_LIB $JQ_KEYS"; then
    while IFS="$US" read -r w day title; do
      total=$((total + 1))
      case "$w" in
        new)
          KEYS_NEW=$((KEYS_NEW + 1))
          if [ "$4" -eq 1 ] && [ -n "$title" ]; then
            chk keys "Your account" "$2 \"$title\", added $day"
          else
            chk keys "Your account" "$2, added $day"
          fi
          ;;
        nodate)
          cnc "Your account" "when one $2 was added: look at https://github.com/settings/keys" "GitHub gave no date"
          ;;
      esac
    done <"$TMP/a"
    KEYS_TEXT="$KEYS_TEXT${KEYS_TEXT:+, }$(plural "$total" "$2" "$3")"
  else
    KEYS_OK=0
    cnc "Your account" "$3" "$API_ERR"
  fi
}

if [ "$RATE_STOP" -eq 0 ]; then
  progress "Reading your keys..."
  check_keys keys "SSH login key" "SSH login keys" 0
fi
if [ "$RATE_STOP" -eq 0 ]; then
  check_keys gpg_keys "GPG key" "GPG keys" 0
fi
if [ "$RATE_STOP" -eq 0 ]; then
  check_keys ssh_signing_keys "SSH signing key" "SSH signing keys" 1
fi
if [ -n "$KEYS_TEXT" ]; then
  if [ "$KEYS_NEW" -gt 0 ]; then
    note "Keys on your account: $KEYS_TEXT. Added in the window: $KEYS_NEW (see CHECK THIS)."
  elif [ "$KEYS_OK" -eq 1 ]; then
    note "Keys on your account: $KEYS_TEXT. None were added in the window."
  else
    note "Keys on your account: $KEYS_TEXT."
  fi
fi

# ---- which repositories to check ----------------------------------------------------------------

N_SCOPE=0       # repositories in scope
N_SKIP_ARCH=0   # archived: nobody can push to them
N_SKIP_FORK=0   # --no-forks
N_SKIP_MAX=0    # beyond --max-repos
N_SKIP_PLAN=0   # left out because the hourly limit would not stretch

: >"$TMP/cand"
if [ "$REPO_MODE" -eq 1 ]; then
  while IFS= read -r one; do
    [ -n "$one" ] || continue
    [ "$RATE_STOP" -eq 0 ] || continue
    WANT=$one awk 'BEGIN { FS = "\037"; w = tolower(ENVIRON["WANT"]) } tolower($1) == w { print; exit }' "$TMP/repos" >"$TMP/one"
    if [ ! -s "$TMP/one" ]; then
      if ! api "$TMP/one" "repos/$one" --jq "$JQ_LIB $JQ_ROW row"; then
        N_SCOPE=$((N_SCOPE + 1))
        cnc "$one" "this repository" "$API_ERR"
        continue
      fi
    fi
    cat "$TMP/one" >>"$TMP/cand"
  done <<EOF
$REPO_ARGS
EOF
  awk 'BEGIN { FS = "\037" } !seen[tolower($1)]++' "$TMP/cand" >"$TMP/cand.u"
else
  cat "$TMP/repos" >"$TMP/cand.u"
fi
N_SCOPE=$((N_SCOPE + $(awk 'END { print NR + 0 }' "$TMP/cand.u")))

awk 'BEGIN { FS = "\037" } $6 != "archived"' "$TMP/cand.u" >"$TMP/live"
N_SKIP_ARCH=$(($(awk 'END { print NR + 0 }' "$TMP/cand.u") - $(awk 'END { print NR + 0 }' "$TMP/live")))

if [ "$NO_FORKS" -eq 1 ]; then
  awk 'BEGIN { FS = "\037" } $5 != "fork"' "$TMP/live" >"$TMP/live2"
  N_SKIP_FORK=$(($(awk 'END { print NR + 0 }' "$TMP/live") - $(awk 'END { print NR + 0 }' "$TMP/live2")))
else
  cat "$TMP/live" >"$TMP/live2"
fi

# most recently pushed first
awk 'BEGIN { FS = "\037" } { print $4 "\037" $0 }' "$TMP/live2" | sort -r |
  awk '{ print substr($0, index($0, "\037") + 1) }' >"$TMP/sorted"
head -n "$MAX_REPOS" "$TMP/sorted" >"$TMP/capped"
N_SKIP_MAX=$(($(awk 'END { print NR + 0 }' "$TMP/sorted") - $(awk 'END { print NR + 0 }' "$TMP/capped")))

# Plan: 5 questions for every repository, about 11 more for one of your own that changed in the
# window. If GitHub's hourly allowance would not stretch that far, check fewer and say so.
PLAN=$((REMAINING - 40))
awk -v since="$SINCE" -v plan="$PLAN" '
  BEGIN { FS = "\037"; used = 0 }
  {
    changed = ($5 == "own" && $4 != "" && ($4 "") >= since) ? "changed" : "quiet"
    used += (changed == "changed") ? 16 : 5
    if (used > plan) exit
    print $0 "\037" changed
  }' "$TMP/capped" >"$TMP/work"
N_WORK=$(awk 'END { print NR + 0 }' "$TMP/work")
N_SKIP_PLAN=$(($(awk 'END { print NR + 0 }' "$TMP/capped") - N_WORK))

# ---- one repository: settings (forks too) ------------------------------------------------------

SECRETS_DONE=0
SECRETS=""

# The NAMES of the secrets a repository's jobs can read, asked for only when a finding needs them.
repo_secrets() {
  [ "$SECRETS_DONE" -eq 0 ] || return 0
  SECRETS_DONE=1
  if api "$TMP/s" "repos/$R_SLUG/actions/secrets?per_page=100" --jq "$JQ_LIB $JQ_SECRETS"; then
    SECRETS=$(awk 'BEGIN { FS = "\037" } { s = s (NR > 1 ? ", " : "") $1 " (last changed " $2 ")" } END { print s }' "$TMP/s")
    if [ -z "$SECRETS" ]; then
      SECRETS="none are stored in this repository"
    fi
  else
    SECRETS="the list could not be read ($API_ERR): look under Settings, Secrets and variables, Actions"
    failed "the names of its secrets"
  fi
}

settings_checks() {
  local w created updated active host old oldhosts can title who inviter perm login level pushers readers rname os status label

  # webhooks
  if api "$TMP/a" "repos/$R_SLUG/hooks?per_page=100" --jq "$JQ_LIB $JQ_HOOKS"; then
    old=0
    oldhosts=""
    while IFS="$US" read -r w created updated active host; do
      case "$w" in
        new)
          if [ "$created" = "$updated" ]; then
            chk webhooks "$R_NAME" "sends to $host, added $created, $active"
          else
            chk webhooks "$R_NAME" "sends to $host, added $created, last changed $updated, $active"
          fi
          ;;
        nodate) cnc "$R_NAME" "when the webhook to $host was added" "GitHub gave no date" ;;
        *)
          old=$((old + 1))
          oldhosts="$oldhosts${oldhosts:+, }$host"
          ;;
      esac
    done <"$TMP/a"
    if [ "$old" -gt 0 ]; then
      frag "$(plural "$old" "older webhook" "older webhooks") (to $oldhosts)"
    fi
  else
    failed "webhooks"
    [ "$RATE_STOP" -eq 0 ] || return 1
  fi

  # deploy keys
  if api "$TMP/a" "repos/$R_SLUG/keys?per_page=100" --jq "$JQ_LIB $JQ_DEPLOY_KEYS"; then
    old=0
    while IFS="$US" read -r w created can title; do
      case "$w" in
        new) chk deploy-keys "$R_NAME" "\"$title\", added $created, $can" ;;
        nodate) cnc "$R_NAME" "when the deploy key \"$title\" was added" "GitHub gave no date" ;;
        *) old=$((old + 1)) ;;
      esac
    done <"$TMP/a"
    if [ "$old" -gt 0 ]; then
      frag "$(plural "$old" "older deploy key" "older deploy keys")"
    fi
  else
    failed "deploy keys"
    [ "$RATE_STOP" -eq 0 ] || return 1
  fi

  # invitations that are still waiting
  if api "$TMP/a" "repos/$R_SLUG/invitations?per_page=100" --jq "$JQ_LIB $JQ_INVITATIONS"; then
    old=0
    while IFS="$US" read -r w created who inviter perm; do
      case "$w" in
        new) chk invitations "$R_NAME" "$who was invited by $inviter on $created ($perm access)" ;;
        nodate) cnc "$R_NAME" "when $who was invited" "GitHub gave no date" ;;
        *) old=$((old + 1)) ;;
      esac
    done <"$TMP/a"
    if [ "$old" -gt 0 ]; then
      frag "$(plural "$old" "older invitation" "older invitations") still waiting"
    fi
  else
    failed "invitations"
    [ "$RATE_STOP" -eq 0 ] || return 1
  fi

  # collaborators: there is no date for these, so they are only listed
  if api "$TMP/a" "repos/$R_SLUG/collaborators?affiliation=direct&per_page=100" --jq "$JQ_LIB $JQ_COLLABORATORS"; then
    pushers=""
    readers=""
    while IFS="$US" read -r login level; do
      if [ "$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')" = "$R_OWNER_LC" ]; then
        continue
      fi
      if [ "$level" = push ]; then
        pushers="$pushers${pushers:+, }$login"
      else
        readers="$readers${readers:+, }$login"
      fi
    done <"$TMP/a"
    if [ -n "$pushers" ]; then
      frag "people who can push here: $pushers"
    fi
    if [ -n "$readers" ]; then
      frag "people who can read here: $readers"
    fi
  else
    failed "collaborators"
    [ "$RATE_STOP" -eq 0 ] || return 1
  fi

  # self-hosted runners
  if api "$TMP/a" "repos/$R_SLUG/actions/runners?per_page=100" --jq "$JQ_LIB $JQ_RUNNERS"; then
    while IFS="$US" read -r rname os status; do
      if label=$(kb_match runner "$rname"); then
        repo_secrets
        act_open "$R_NAME" "A self-hosted runner has a name used in a known attack: $label."
        act_item "\"$rname\" ($os, $status)"
        act_line "Why it matters: a runner is a computer allowed to run your automatic jobs (workflows)."
        act_line "  This one runs them, with your secrets, on the attacker's machine."
        act_line "Do this first: change every secret in this repository (list below), THEN remove the"
        act_line "  runner under Settings, Actions, Runners."
        act_line "Secrets this job could read: $SECRETS"
        act_line "Guide: $GUIDE#3-change-every-secret-the-attacker-could-have-read"
      else
        chk runners "$R_NAME" "\"$rname\" ($os, $status)"
      fi
    done <"$TMP/a"
  else
    failed "self-hosted runners"
    [ "$RATE_STOP" -eq 0 ] || return 1
  fi
  return 0
}

# ---- one repository: what changed (your own repositories that were pushed to in the window) ----

verb() {
  case "$1" in
    added) printf 'added' ;;
    removed) printf 'removed' ;;
    renamed) printf 'renamed' ;;
    *) printf 'changed' ;;
  esac
}

# commits_from QUERY-END BRANCH-LABEL ORDER WHAT: list the commits that touched job files
commits_from() {
  local sha day ep msg
  if api "$TMP/a" "repos/$R_SLUG/commits?path=.github/workflows&since=$SINCE&per_page=30$1" --jq "$JQ_LIB $JQ_COMMITS"; then
    while IFS="$US" read -r sha day ep msg; do
      printf '%s\037%s\037%s\037%s\037%s\037%s\n' "$sha" "$day" "$ep" "$msg" "$2" "$3" >>"$TMP/commits"
    done <"$TMP/a"
  elif [ "$API_ERR" = "HTTP 409" ] && [ -z "$1" ]; then
    : # an empty repository: there are no commits to list
  else
    failed "$4"
    [ "$RATE_STOP" -eq 0 ] || return 1
  fi
  return 0
}

change_checks() {
  local period k f1 f2 f3 f4 f5 f6 f7 f8 f9 text listing need w day ep state path extra label
  local sha msg branch files hit hitlabel fn st v shown hidden unopened wf_new wf_edit tag asset hours
  period=quarter
  if [ "$DAYS" -gt 90 ]; then
    period=year
  fi
  wf_new=0
  wf_edit=0
  : >"$TMP/branches"
  : >"$TMP/commits"
  : >"$TMP/dump"
  : >"$TMP/kbhit"

  # 1. the activity list: pushes, force pushes, branches made and deleted
  if api "$TMP/a" "repos/$R_SLUG/activity?time_period=$period&per_page=100" --jq "$JQ_LIB $JQ_ACTIVITY"; then
    CHK_DEFREF="refs/heads/$R_DEFAULT" awk "$AWK_ACTIVITY" "$TMP/a" >"$TMP/b"
    while IFS="$US" read -r k f1 f2 f3 f4 f5 f6 f7 f8 f9; do
      case "$k" in
        F)
          if [ "$f3" -gt 1 ]; then
            chk force-push "$R_NAME" "on $R_DEFAULT: $f1 by $f2 ($f3 times)"
          else
            chk force-push "$R_NAME" "on $R_DEFAULT: $f1 by $f2"
          fi
          ;;
        S)
          if [ "$f3" -lt 1 ]; then
            text="less than a minute"
          else
            text=$(plural "$f3" minute minutes)
          fi
          chk short-branches "$R_NAME" "$f1: made by $f4, deleted by $f5 after $text, on $f2"
          ;;
        B) printf '%s\037%s\037%s\n' "$f1" "$f2" "$f3" >>"$TMP/branches" ;;
        C)
          text="$(plural "$f1" push pushes), $(plural "$f2" "branch made" "branches made"), $f3 deleted, $(plural "$f5" "pull request merged" "pull requests merged")"
          if [ "$f6" -gt 0 ]; then
            text="$text; $(plural "$f6" "short-lived branch was" "short-lived branches were") merged (normal pull-request work)"
          fi
          if [ "$f8" -ge 100 ]; then
            text="$text; only the newest 100 entries were read, back to $f9"
          fi
          if [ "$f7" -gt 0 ]; then
            text="$text; job files on $(plural "$f7" "more branch were" "more branches were") not read"
          fi
          frag "$text"
          ;;
      esac
    done <"$TMP/b"
  else
    failed "branch activity"
    [ "$RATE_STOP" -eq 0 ] || return 1
  fi

  # 2. new job files (workflows)
  if api "$TMP/w" "repos/$R_SLUG/actions/workflows?per_page=100" --jq "$JQ_LIB $JQ_WORKFLOWS"; then
    need=$(awk 'BEGIN { FS = "\037" } $1 == "new" && $4 != "deleted" { n++ } END { print n + 0 }' "$TMP/w")
    listing=unknown
    if [ "$need" -gt 0 ]; then
      # which job files are on the main branch right now? One listing answers it for all of them.
      if api "$TMP/ls" "repos/$R_SLUG/contents/.github/workflows" --jq "$JQ_LIB $JQ_FOLDER"; then
        listing=read
      elif [ "$API_ERR" = "HTTP 404" ]; then
        listing=empty
      else
        failed "which job files are on the main branch now"
        [ "$RATE_STOP" -eq 0 ] || return 1
      fi
    fi
    while IFS="$US" read -r w day ep state path; do
      if [ "$w" = nodate ]; then
        cnc "$R_NAME" "when the job file $path first appeared" "GitHub gave no date"
        continue
      fi
      extra=""
      case "$state" in
        active) ;;
        deleted) extra="; it appeared and was removed again, which is what attackers do after stealing" ;;
        disabled_manually) extra=", switched off by hand" ;;
        disabled_inactivity) extra=", switched off by GitHub after no activity" ;;
        *) extra=", state: $state" ;;
      esac
      if [ "$state" != deleted ] && [ "$listing" != unknown ]; then
        if [ "$listing" = empty ] || ! WF_PATH=$path awk 'BEGIN { p = ENVIRON["WF_PATH"]; found = 0 } $0 == p { found = 1 } END { exit (found == 1 ? 0 : 1) }' "$TMP/ls"; then
          extra="$extra; it is not on the main branch now: it appeared and was removed again, or it only exists on another branch"
        fi
      fi
      bulk file "$path" "$ep" "$day"
      wf_new=1
      if label=$(kb_match workflow "$path"); then
        printf '%s\037%s\n' "$label" "$path, first seen $day$extra" >>"$TMP/kbhit"
      else
        chk new-workflows "$R_NAME" "$path, first seen $day$extra"
      fi
    done <"$TMP/w"
  else
    failed "new automatic job (workflow) files"
    [ "$RATE_STOP" -eq 0 ] || return 1
  fi

  # 3. commits that changed job files: on the main branch, then on up to 5 other branches
  commits_from "" "$R_DEFAULT" 1 "changes to job files on $R_DEFAULT" || return 1
  while IFS="$US" read -r k f1 f2; do
    if [ "$k" = sha ]; then
      commits_from "&sha=$f2" "$f1 (a deleted branch)" 0 "changes to job files on the deleted branch $f1" || return 1
    else
      commits_from "&sha=$f2" "$f1" 1 "changes to job files on the branch $f1" || return 1
    fi
  done <"$TMP/branches"

  awk 'BEGIN { FS = "\037" } !seen[$1]++' "$TMP/commits" >"$TMP/commits.u"
  # open at most 10 of them: the ones from deleted branches first, then the newest
  awk 'BEGIN { FS = "\037" } { print $6 " " $3 " " $1 }' "$TMP/commits.u" | sort -k1,1n -k2,2nr | head -n 10 |
    awk '{ print $3 }' >"$TMP/open"

  shown=0
  hidden=0
  unopened=0
  while IFS="$US" read -r sha day ep msg branch _order; do
    case "$sha" in
      '' | *[!0-9a-f]*) continue ;;
    esac
    files=""
    hit=0
    hitlabel=""
    if grep -q -x "$sha" "$TMP/open"; then
      if api "$TMP/d" "repos/$R_SLUG/commits/$sha" --jq "$JQ_LIB $JQ_COMMIT"; then
        while IFS="$US" read -r fn st v; do
          files="$files${files:+, }${fn##*/}"
          bulk file "$fn" "$ep" "$day"
          case "$v" in
            dump)
              hit=1
              printf '%s\n' "$fn, $(verb "$st") $day in commit ${sha:0:7} on branch $branch (\"$msg\")" >>"$TMP/dump"
              ;;
            unread) cnc "$R_NAME" "the change to $fn in commit ${sha:0:7}" "too large to read" ;;
          esac
          if [ -z "$hitlabel" ] && label=$(kb_match workflow "$fn"); then
            hitlabel=$label
          fi
        done <"$TMP/d"
      else
        failed "the contents of commit ${sha:0:7}"
        [ "$RATE_STOP" -eq 0 ] || return 1
      fi
    else
      unopened=$((unopened + 1))
    fi
    bulk message "$msg" "$ep" "$day"
    if [ -z "$hitlabel" ] && label=$(kb_match message "$msg"); then
      hitlabel=$label
    fi
    text="$day ${sha:0:7} on $branch: \"$msg\""
    if [ -n "$files" ]; then
      text="$text ($files)"
    fi
    if [ "$hit" -eq 1 ]; then
      continue
    fi
    if [ -n "$hitlabel" ]; then
      printf '%s\037%s\n' "$hitlabel" "$text" >>"$TMP/kbhit"
      continue
    fi
    wf_edit=1
    if [ "$shown" -lt 8 ]; then
      shown=$((shown + 1))
      chk workflow-edits "$R_NAME" "$text"
    else
      hidden=$((hidden + 1))
    fi
  done <"$TMP/commits.u"
  if [ "$hidden" -gt 0 ]; then
    chk workflow-edits "$R_NAME" "... and $(plural "$hidden" "more commit" "more commits") that changed job files"
  fi
  if [ "$unopened" -gt 0 ]; then
    frag "$(plural "$unopened" "commit that changed job files was" "commits that changed job files were") listed but not opened (10 at most are)"
  fi

  # a job file that sends out every secret: ACT NOW
  if [ -s "$TMP/dump" ]; then
    repo_secrets
    act_open "$R_NAME" "An automatic job (workflow) file sends out ALL of this repository's secrets."
    while IFS= read -r text; do
      act_item "$text"
    done <"$TMP/dump"
    act_line "Why it matters: a job like this copies your keys and passwords to someone else."
    act_line "Do this first: change every secret in this repository (list below), THEN delete the file."
    act_line "Secrets this job could read: $SECRETS"
    act_line "Guide: $GUIDE#3-change-every-secret-the-attacker-could-have-read"
  fi
  # a job file or commit message that matches a known attack: ACT NOW
  if [ -s "$TMP/kbhit" ]; then
    repo_secrets
    label=$(awk 'BEGIN { FS = "\037" } !seen[$1]++ { s = s (s == "" ? "" : ", ") $1 } END { print s }' "$TMP/kbhit")
    act_open "$R_NAME" "A change to its automatic jobs (workflows) matches a known attack: $label."
    while IFS="$US" read -r _label text; do
      act_item "$text"
    done <"$TMP/kbhit"
    act_line "Why it matters: this is how that attack copied secrets (keys and passwords) out of"
    act_line "  repositories."
    act_line "Do this first: change every secret in this repository (list below), THEN delete the job"
    act_line "  file if it is still there."
    act_line "Secrets this job could read: $SECRETS"
    act_line "Guide: $GUIDE#3-change-every-secret-the-attacker-could-have-read"
  fi
  [ "$RATE_STOP" -eq 0 ] || return 1
  # the secrets a job could read, once, next to the first job finding for this repository
  if [ "$wf_new" -eq 1 ] && [ -s "$TMP/chk.new-workflows" ] && grep -q "^$R_NAME$US" "$TMP/chk.new-workflows"; then
    repo_secrets
    chk new-workflows "$R_NAME" "secrets this job could read (change these first): $SECRETS"
  elif [ "$wf_edit" -eq 1 ]; then
    repo_secrets
    chk workflow-edits "$R_NAME" "secrets this job could read (change these first): $SECRETS"
  fi
  [ "$RATE_STOP" -eq 0 ] || return 1

  # 4. release files added or replaced long after the release was published
  if api "$TMP/a" "repos/$R_SLUG/releases?per_page=30" --jq "$JQ_LIB $JQ_RELEASES"; then
    while IFS="$US" read -r k tag asset day hours; do
      case "$k" in
        late) chk releases "$R_NAME" "a file in release $tag ($asset) was added or replaced $(plural "$hours" hour hours) after it was published, on $day" ;;
        nodate) cnc "$R_NAME" "when the file $asset in release $tag was added" "GitHub gave no date" ;;
      esac
    done <"$TMP/a"
  else
    failed "releases"
    [ "$RATE_STOP" -eq 0 ] || return 1
  fi
  return 0
}

# ---- go through the repositories -----------------------------------------------------------------

N_DONE=0
N_QUIET=0
N_CUT=0
: >"$TMP/info.repos"
i=0
while IFS="$US" read -r R_SLUG R_NAME _created _pushed R_KIND _arch _vis R_DEFAULT _desc R_CHANGED <&3; do
  i=$((i + 1))
  if [ "$RATE_STOP" -eq 1 ]; then
    N_CUT=$((N_CUT + 1))
    continue
  fi
  case "$R_SLUG" in
    */*/* | /* | */ | ./* | ../* | */. | */.. | *[!A-Za-z0-9._/-]* | '')
      cnc "$R_NAME" "this repository" "its name has characters this tool does not expect"
      continue
      ;;
  esac
  progress "[$i/$N_WORK] $R_NAME"
  R_OWNER_LC=$(printf '%s' "${R_NAME%%/*}" | tr '[:upper:]' '[:lower:]')
  R_INFO=""
  SECRETS_DONE=0
  SECRETS=""
  if settings_checks; then
    if [ "$R_CHANGED" = changed ]; then
      change_checks
    fi
  fi
  if [ "$RATE_STOP" -eq 1 ]; then
    N_CUT=$((N_CUT + 1))
  else
    N_DONE=$((N_DONE + 1))
  fi
  if [ -n "$R_INFO" ]; then
    printf '    %s: %s\n' "$R_NAME" "$R_INFO" >>"$TMP/info.repos"
  elif [ "$RATE_STOP" -eq 0 ]; then
    N_QUIET=$((N_QUIET + 1))
  fi
done 3<"$TMP/work"

if [ "$RATE_STOP" -eq 1 ]; then
  if [ "$ANSWERED" -eq 0 ]; then
    stop "GitHub's hourly request limit is used up. Nothing was checked. Try again in an hour."
  fi
  cnc "Stopped early" "GitHub's hourly request limit ran out, so $(plural "$((N_CUT + N_SKIP_PLAN))" "repository was" "repositories were") not checked, or not fully. Run this again in an hour" "rate limit"
fi

# ---- the same change in many repositories ---------------------------------------------------------

if [ -s "$TMP/bulk" ]; then
  awk "$AWK_BULK" "$TMP/bulk" >"$TMP/bulk.out"
  BULK_N=$(awk 'BEGIN { FS = "\037"; m = 0 } $3 + 0 > m { m = $3 + 0 } END { print m }' "$TMP/bulk.out")
  if [ "$BULK_N" -ge 3 ]; then
    shown=0
    while IFS="$US" read -r kind key count day; do
      shown=$((shown + 1))
      [ "$shown" -le 6 ] || continue
      if [ "$kind" = file ]; then
        chk bulk "Your account" "the job file $key: $count repositories, starting $day"
      else
        chk bulk "Your account" "the commit message \"$key\": $count repositories, starting $day"
      fi
    done <"$TMP/bulk.out"
    if [ "$shown" -gt 6 ]; then
      chk bulk "Your account" "... and $((shown - 6)) more like these"
    fi
  fi
else
  BULK_N=0
fi

# ---- the report ---------------------------------------------------------------------------------

# meta KIND COUNT: the words that go with one kind of CHECK THIS finding
meta() {
  local places
  places=$(plural "$2" repository repositories)
  case "$1" in
    bulk)
      M_HEAD="The same change hit $BULK_N repositories within a day.
  If that wasn't you doing maintenance, treat it as an attack."
      M_WHY="an attack pushes one change to every repository a stolen sign-in can reach, within
      minutes. Owners doing maintenance do the same, so this tool cannot tell which it was."
      M_DO="if you didn't make this change everywhere yourself, start with the guide's first
      section, \"Someone is in my account right now\"."
      M_LINK="someone-is-in-my-account-right-now"
      ;;
    new-workflows)
      M_HEAD="New automatic job (workflow) files in $places"
      M_WHY="a job file you didn't add is the most common sign of a hijacked account. Such a job
      can copy your secrets (the keys and passwords your jobs use) to someone else."
      M_DO="open each file on GitHub. If you didn't add it, change that repository's secrets
      first, then delete the file."
      M_LINK="3-change-every-secret-the-attacker-could-have-read"
      ;;
    workflow-edits)
      M_HEAD="Changes to automatic job (workflow) files in $places"
      M_WHY="an attacker can also change a job you already have so that it sends your secrets
      out. This tool cannot judge what a change was for."
      M_DO="open each commit (github.com/OWNER/REPO/commit/ID). If you didn't make it, change
      that repository's secrets first, then undo the change."
      M_LINK="3-change-every-secret-the-attacker-could-have-read"
      ;;
    short-branches)
      M_HEAD="Branches made and deleted again within an hour, never merged, in $places"
      M_WHY="attackers push a job file on a throwaway branch, let it run once, then delete the
      branch to hide it."
      M_DO="if you didn't make the branch, look at github.com/OWNER/REPO/actions for jobs you
      didn't start, and change that repository's secrets."
      M_LINK="part-b-your-repositories-about-10-minutes"
      ;;
    runners)
      M_HEAD="Self-hosted runners in $places"
      M_WHY="a runner is a computer allowed to run your automatic jobs. One you didn't add runs
      them, with your secrets, on someone else's machine. Runners are rare on personal accounts."
      M_DO="if you didn't add it, change that repository's secrets, then remove the runner
      under Settings, Actions, Runners."
      M_LINK="4-clean-up"
      ;;
    went-public)
      if [ "$2" -eq 1 ]; then
        M_HEAD="1 repository was switched from private to public"
      else
        M_HEAD="$2 repositories were switched from private to public"
      fi
      M_WHY="a private repository made public shows its code, and any secrets inside it, to
      everyone."
      M_DO="if you didn't do it, make it private again (the repository's Settings), then change
      any secret that was in its code."
      M_LINK="4-clean-up"
      ;;
    new-repos)
      if [ "$2" -eq 1 ]; then
        M_HEAD="1 new repository was created in your account"
      else
        M_HEAD="$2 new repositories were created in your account"
      fi
      M_WHY="attacks create repositories to publish what they stole, or to run jobs from."
      M_DO="if you didn't create one, keep a record of it for GitHub Support, then delete it."
      M_LINK="part-b-your-repositories-about-10-minutes"
      ;;
    keys)
      M_HEAD="$(plural "$2" "new key" "new keys") on your account"
      M_WHY="a key you didn't add lets someone else push code as you, or sign commits as you."
      M_DO="remove any key you don't recognise at https://github.com/settings/keys"
      M_LINK="someone-is-in-my-account-right-now"
      ;;
    webhooks)
      M_HEAD="Webhooks added or changed in $places"
      M_WHY="a webhook sends news of everything that happens in a repository to another server."
      M_DO="if you didn't add it, remove it under the repository's Settings, Webhooks."
      M_LINK="4-clean-up"
      ;;
    deploy-keys)
      M_HEAD="Deploy keys added in $places"
      M_WHY="a deploy key is an SSH key that opens one repository. If it can write, it can push
      code there."
      M_DO="if you didn't add it, remove it under the repository's Settings, Deploy keys."
      M_LINK="4-clean-up"
      ;;
    invitations)
      M_HEAD="Invitations still waiting in $places"
      M_WHY="once the invited person accepts, they can change the repository."
      M_DO="if you didn't invite them, cancel the invitation under the repository's Settings,
      Collaborators."
      M_LINK="4-clean-up"
      ;;
    force-push)
      M_HEAD="History was rewritten (a force push) on the main branch of $places"
      M_WHY="a force push replaces what was there before, so it can remove or hide changes."
      M_DO="if you didn't do it, open github.com/OWNER/REPO/activity?activity_type=force_push to
      see what was replaced."
      M_LINK="part-b-your-repositories-about-10-minutes"
      ;;
    releases)
      M_HEAD="Release files added or replaced long after publication, in $places"
      M_WHY="swapping a download for a tampered one reaches everyone who installs it. Normal
      automation uploads within seconds."
      M_DO="if you didn't upload it, delete that file, publish a clean release and tell the people
      who use it."
      M_LINK="5-check-what-you-publish"
      ;;
  esac
}

KINDS="bulk new-workflows workflow-edits short-branches runners went-public new-repos keys webhooks deploy-keys invitations force-push releases"

N_CHK=0
for kind in $KINDS; do
  if [ -s "$TMP/chk.$kind" ]; then
    N_CHK=$((N_CHK + 1))
  fi
done

SCOPE_NOTE=""
scope() { SCOPE_NOTE="$SCOPE_NOTE${SCOPE_NOTE:+, }$1"; }
[ "$N_SKIP_ARCH" -eq 0 ] || scope "$N_SKIP_ARCH archived skipped"
[ "$N_SKIP_FORK" -eq 0 ] || scope "$(plural "$N_SKIP_FORK" fork forks) skipped"
[ "$N_SKIP_MAX" -eq 0 ] || scope "$N_SKIP_MAX beyond --max-repos"
[ "$N_SKIP_PLAN" -eq 0 ] || scope "$N_SKIP_PLAN left out: GitHub's hourly request limit is nearly used up"
[ "$N_CUT" -eq 0 ] || scope "$N_CUT not finished: the request limit ran out"
if [ -n "$SCOPE_NOTE" ]; then
  SCOPE_NOTE=" ($SCOPE_NOTE)"
fi

report() {
  local kind count
  printf 'Was my GitHub account hacked? Read-only checker %s\n' "$VERSION"
  printf 'Account: %s     Window: last %s (since %s, dates in UTC)\n' "$LOGIN" "$(plural "$DAYS" day days)" "$SINCE_DAY"
  if [ "$REPO_MODE" -eq 1 ]; then
    printf 'Repositories checked: %s of the %s you named%s\n' "$N_DONE" "$N_SCOPE" "$SCOPE_NOTE"
  else
    printf 'Repositories checked: %s of %s%s\n' "$N_DONE" "$N_SCOPE" "$SCOPE_NOTE"
  fi
  printf '%s\n' "This tool only reads. It can't see your security log, sessions, tokens or apps: check those on"
  printf '%s\n' "the web (links below)."

  printf '\nACT NOW (%s)\n' "$N_ACT"
  if [ "$N_ACT" -eq 0 ]; then
    printf '  Nothing found by these checks.\n'
  else
    cat "$TMP/act"
  fi

  if [ "$N_CHK" -eq 0 ]; then
    printf '\nCHECK THIS (0)\n  Nothing found by these checks.\n'
  else
    printf '\nCHECK THIS (%s)   Did you do each of these? If not, treat it as ACT NOW.\n' "$N_CHK"
    for kind in $KINDS; do
      [ -s "$TMP/chk.$kind" ] || continue
      case "$kind" in
        bulk) count=$BULK_N ;;
        went-public) count=$(grep -c -v "$US\\(Note:\\|  \\)" "$TMP/chk.$kind") ;;
        new-repos | keys) count=$(awk 'END { print NR + 0 }' "$TMP/chk.$kind") ;;
        *) count=$(awk 'BEGIN { FS = "\037" } !seen[$1]++ { n++ } END { print n + 0 }' "$TMP/chk.$kind") ;;
      esac
      meta "$kind" "$count"
      printf '\n  %s\n' "$M_HEAD"
      awk 'BEGIN { FS = "\037"; last = "" }
        $1 == "Your account" { print "      " $2; next }
        { if ($1 != last) { print "      " $1; last = $1 } print "        " $2 }' "$TMP/chk.$kind"
      printf '    Why it matters: %s\n' "$M_WHY"
      printf '    What to do: %s\n' "$M_DO"
      printf '    Guide: %s#%s\n' "$GUIDE" "$M_LINK"
    done
  fi

  printf '\nFOR YOUR INFORMATION\n'
  printf '  Your account\n'
  if [ -s "$TMP/info.account" ]; then
    cat "$TMP/info.account"
  fi
  printf '  Your repositories\n'
  if [ -s "$TMP/info.repos" ]; then
    cat "$TMP/info.repos"
  fi
  if [ "$N_QUIET" -gt 0 ]; then
    if [ -s "$TMP/info.repos" ]; then
      printf '    %s: nothing else to report.\n' "$(plural "$N_QUIET" "other repository" "other repositories")"
    else
      printf '    %s: nothing else to report.\n' "$(plural "$N_QUIET" repository repositories)"
    fi
  elif [ ! -s "$TMP/info.repos" ]; then
    printf '    No repository was checked.\n'
  fi

  if [ -s "$TMP/cnc" ]; then
    count=$(awk 'BEGIN { FS = "\037" } !seen[$1]++ { n++ } END { print n + 0 }' "$TMP/cnc")
    printf '\nCOULD NOT CHECK (%s)\n' "$count"
    awk 'BEGIN { FS = "\037"; n = 0 }
      { if (!($1 in at)) { n++; at[$1] = n; name[n] = $1; text[n] = $2 } else text[at[$1]] = text[at[$1]] ", " $2 }
      END { for (i = 1; i <= n; i++) print "  " name[i] ": " text[i] }' "$TMP/cnc"
    printf '  None of these counts as a pass. HTTP 403 or 404 usually means this sign-in is not allowed to\n'
    printf '  read that setting.\n'
  else
    printf '\nCOULD NOT CHECK (0)\n  Every question these checks asked got an answer.\n'
  fi

  printf '\nWHAT THIS DOES NOT PROVE\n'
  printf '%s\n' "  These checks found the signs above (or none). That does not prove your account is clean: an"
  printf '%s\n' "  attacker who only read your code, or who cleaned up after themselves, leaves nothing a tool"
  printf '%s\n' "  can see. Now do the checks no tool can do:"
  printf '%s\n' "    Security log   https://github.com/settings/security-log"
  printf '%s\n' "    Sessions       https://github.com/settings/sessions"
  printf '%s\n' "    Tokens         https://github.com/settings/tokens  and  https://github.com/settings/personal-access-tokens"
  printf '%s\n' "    Apps           https://github.com/settings/applications  and  https://github.com/settings/installations"
  printf '  Full guide: %s\n' "$GUIDE"
  printf '%s\n' "  This report may name your private repositories. Don't paste it in public."
}

# Last line of defence: nothing but plain text reaches the terminal.
report | tr -d '\000-\010\013-\037\177'

progress "Done: $API_CALLS questions asked, all of them read-only."

if [ "$N_ACT" -gt 0 ]; then
  exit 2
elif [ "$N_CHK" -gt 0 ]; then
  exit 1
fi
exit 0
