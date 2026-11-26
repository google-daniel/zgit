#!/bin/zsh
# zgit v2.2 sandbox test — fake Drive + two fake Macs (HOME A / HOME B)
set -u
ZGIT="$1"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); print "PASS: $1" }
fail() { FAIL=$((FAIL+1)); print "FAIL: $1" }
check() { # desc, expected_rc, actual_rc
  if [[ "$2" == "$3" ]]; then ok "$1 (rc=$3)"; else fail "$1 (want rc=$2 got rc=$3)"; fi
}
expect_out() { # desc, pattern, output
  if print -r -- "$3" | grep -q "$2"; then ok "$1"; else fail "$1 — no match: $2 / out: ${3//[$'\n']/ | }"; fi
}

T=$(mktemp -d)
DRIVE="$T/drive/remote_dev_env"
export ZGIT_BASE="$DRIVE"
HOMEA="$T/homeA"; HOMEB="$T/homeB"
mkdir -p "$HOMEA" "$HOMEB"

runA() { ( cd "$1" && shift; HOME=$HOMEA zsh "$ZGIT" "$@" 2>&1 ); echo "RC=$?" }
runB() { ( cd "$1" && shift; HOME=$HOMEB zsh "$ZGIT" "$@" 2>&1 ); echo "RC=$?" }

# ---- 1. init + save on Mac A
mkdir -p "$T/projA" && cd "$T/projA" && git init -q && git config user.email t@t && git config user.name t
out=$(runA "$T/projA" --init myapp); rc=${out##*RC=}
check "1a init new repo" 0 "$rc"
out=$(print "hello" > a.txt; runA "$T/projA" --save "first"); rc=${out##*RC=}
check "1b save first" 0 "$rc"
expect_out "1c save msg" "Saved and pushed" "$out"

# ---- 2. clone on Mac B, save from B
mkdir -p "$T/workB"
out=$(runB "$T/workB" --clone myapp); rc=${out##*RC=}
check "2a clone on Mac B" 0 "$rc"
[[ -f "$T/workB/myapp/a.txt" ]] && ok "2b cloned file present" || fail "2b cloned file present"
git -C "$T/workB/myapp" config user.email t@t; git -C "$T/workB/myapp" config user.name t
print "world" > "$T/workB/myapp/b.txt"
out=$(runB "$T/workB/myapp" --save "from B"); rc=${out##*RC=}
check "2c save from B" 0 "$rc"
expect_out "2c2 pushed" "Saved and pushed" "$out"

# ---- 3. sync on A pulls B's commit
out=$(runA "$T/projA" --sync); rc=${out##*RC=}
check "3a sync on A" 0 "$rc"
[[ $(git -C "$T/projA" log --oneline | wc -l | tr -d ' ') == 2 ]] && ok "3b got B commit" || fail "3b got B commit"

# ---- 4. conflicting saves: A commits, B commits same file, A sync → clear error, no push
print "A-change" >> "$T/projA/a.txt"; git -C "$T/projA" commit -aqm "A conflict"
print "B-change" >  "$T/workB/myapp/a.txt"
out=$(runB "$T/workB/myapp" --save "B conflict"); rc=${out##*RC=}
check "4a B saves conflicting" 0 "$rc"
out=$(runA "$T/projA" --sync); rc=${out##*RC=}
[[ "$rc" != 0 ]] && ok "4b sync conflict fails" || fail "4b sync conflict fails"
expect_out "4c conflict error msg" "コンフリクトまたはエラー" "$out"
git -C "$T/projA" rebase --abort 2>/dev/null
BR=$(git -C "$T/projA" branch --show-current)
git -C "$T/projA" reset -q --hard "gdrive/$BR"   # 競合テストで作ったローカル競合コミットを破棄して後続テストをクリーンに

# ---- 5. non-conflicting both-sides change syncs cleanly
print "x" > "$T/projA/b.txt"; git -C "$T/projA" add .; git -C "$T/projA" commit -qm "A adds b"
print "y" > "$T/workB/myapp/c.txt"; out=$(runB "$T/workB/myapp" --save "B adds c"); rc=${out##*RC=}
check "5a B adds c" 0 "$rc"
out=$(runA "$T/projA" --sync); rc=${out##*RC=}
check "5b A syncs cleanly" 0 "$rc"

# ---- 6. --save in plain git repo (no gdrive remote): clear error, NO commit stranded
mkdir -p "$T/plain" && cd "$T/plain" && git init -q && git config user.email t@t && git config user.name t
print "p" > p.txt
out=$(runA "$T/plain" --save "should fail"); rc=${out##*RC=}
[[ "$rc" != 0 ]] && ok "6a save w/o remote fails" || fail "6a save w/o remote fails"
expect_out "6b friendly remote error" "gdrive リモートがありません" "$out"
[[ -z $(git -C "$T/plain" log --oneline 2>/dev/null) ]] && ok "6c no stranded commit" || fail "6c no stranded commit"

# ---- 7. --push outside any git repo
mkdir -p "$T/nowhere"
out=$(runA "$T/nowhere" --push); rc=${out##*RC=}
[[ "$rc" != 0 ]] && ok "7a push outside repo fails" || fail "7a push outside repo fails"
expect_out "7b friendly not-a-repo error" "Git リポジトリではありません" "$out"

# ---- 8. --info outside repo → friendly, exit 0
out=$(runA "$T/nowhere" --info); rc=${out##*RC=}
check "8a info outside repo rc=0" 0 "$rc"
expect_out "8b friendly info" "Git リポジトリではありません" "$out"

# ---- 9. --info inside repo shows fsck line
out=$(runA "$T/projA" --info); rc=${out##*RC=}
check "9a info inside repo" 0 "$rc"
expect_out "9b fsck OK line" "fsck" "$out"

# ---- 10. --list handles repo names with spaces
git init --bare -q "$DRIVE/my repo.git"
out=$(runA "$T/nowhere" --list); rc=${out##*RC=}
check "10a list rc=0" 0 "$rc"
expect_out "10b spaced name listed" "my repo" "$out"

# ---- 11. --init on already-linked repo errors, no orphan bare
out=$(runA "$T/projA" --init myapp2); rc=${out##*RC=}
[[ "$rc" != 0 ]] && ok "11a init already-linked fails" || fail "11a init already-linked fails"
[[ ! -d "$DRIVE/myapp2.git" ]] && ok "11b no orphan bare repo" || fail "11b no orphan bare repo"

# ---- 12. --init in existing repo WITHOUT remote → links it, save works
mkdir -p "$T/existing" && cd "$T/existing" && git init -q && git config user.email t@t && git config user.name t
print "e" > e.txt
out=$(runA "$T/existing" --init exist); rc=${out##*RC=}
check "12a init existing unlinked repo" 0 "$rc"
out=$(runA "$T/existing" --save "linked"); rc=${out##*RC=}
check "12b save after linking" 0 "$rc"

# ---- 13. --delete non-interactive → cancel, repo survives
out=$(runA "$T/nowhere" --delete "my repo" </dev/null); rc=${out##*RC=}
check "13a delete cancel rc=0" 0 "$rc"
[[ -d "$DRIVE/my repo.git" ]] && ok "13b repo survived cancel" || fail "13b repo survived cancel"

# ---- 14. --delete with piped y → deletes (spaced name also exercises quoted paths)
out=$(print y | runA "$T/nowhere" --delete "my repo"); rc=${out##*RC=}
check "14a delete with y rc=0" 0 "$rc"
[[ ! -d "$DRIVE/my repo.git" ]] && ok "14b repo deleted" || fail "14b repo deleted"

# ---- 15. --rename updates local remote URL
out=$(runA "$T/existing" --rename exist exist2); rc=${out##*RC=}
check "15a rename rc=0" 0 "$rc"
[[ $(git -C "$T/existing" remote get-url gdrive) == "$DRIVE/exist2.git" ]] && ok "15b remote url updated" || fail "15b remote url updated"

# ---- 16. --config with ZGIT_BASE
out=$(runA "$T/nowhere" --config); rc=${out##*RC=}
check "16a config rc=0" 0 "$rc"
expect_out "16b config shows env source" "ZGIT_BASE" "$out"

# ---- 17. detached HEAD --save fails clean
git -C "$T/projA" checkout -q --detach HEAD~0
out=$(runA "$T/projA" --save "detached"); rc=${out##*RC=}
[[ "$rc" != 0 ]] && ok "17a detached save fails" || fail "17a detached save fails"
expect_out "17b detached msg" "detached HEAD" "$out"
git -C "$T/projA" checkout -q - 2>/dev/null || git -C "$T/projA" checkout -q main 2>/dev/null || git -C "$T/projA" checkout -q master 2>/dev/null

# ---- 18. help + log
out=$(runA "$T/nowhere" -h); rc=${out##*RC=}
check "18a help rc=0" 0 "$rc"
out=$(runA "$T/projA" --log); rc=${out##*RC=}
check "18b log rc=0" 0 "$rc"

print "\n==== RESULT: $PASS passed, $FAIL failed ===="
[[ $FAIL == 0 ]]