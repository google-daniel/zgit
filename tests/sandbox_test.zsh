#!/bin/zsh
# zgit v2.2 sandbox test — fake Drive + two fake Macs (HOME A / HOME B)
set -u
if [[ -z "${1:-}" ]]; then
  print -u2 "usage: zsh tests/sandbox_test.zsh /absolute/path/to/zgit"
  exit 1
fi
# 絶対パス化: runA/runB が cd した後も参照できるようにする。
# 相対パスを渡すと全ケースが rc=127 で潰れ、rc!=0 系アサーションが空振り PASS する。
ZGIT="${1:A}"
if [[ ! -f "$ZGIT" ]]; then print -u2 "ERROR: zgit script not found: $ZGIT"; exit 1; fi
zsh "$ZGIT" -h > /dev/null 2>&1 || { print -u2 "ERROR: zgit smoke test (-h) failed — aborting before vacuous PASSes"; exit 1; }
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

# ---- 19. --rename error cases ----
out=$(runA "$T/nowhere" --rename onlyone); rc=${out##*RC=}
[[ "$rc" != 0 ]] && ok "19a rename missing arg fails" || fail "19a rename missing arg fails"
expect_out "19b rename missing arg msg" "変更前と変更後のリポジトリ名を指定してください" "$out"
out=$(runA "$T/nowhere" --rename nosuchrepo newname); rc=${out##*RC=}
[[ "$rc" != 0 ]] && ok "19c rename nonexistent old fails" || fail "19c rename nonexistent old fails"
expect_out "19d rename nonexistent msg" "リポジトリが見つかりません" "$out"
git init --bare -q "$DRIVE/occupied.git"
out=$(runA "$T/nowhere" --rename exist2 occupied); rc=${out##*RC=}
[[ "$rc" != 0 ]] && ok "19e rename to existing name fails" || fail "19e rename to existing name fails"
expect_out "19f rename target-exists msg" "すでに存在します" "$out"
[[ -d "$DRIVE/exist2.git" ]] && ok "19g old repo untouched" || fail "19g old repo untouched"
out=$(runA "$T/nowhere" --rename exist2 exist2); rc=${out##*RC=}
[[ "$rc" != 0 ]] && ok "19h rename to same name fails" || fail "19h rename to same name fails"

# ---- 20. --rename URL mismatch: local remote pointing elsewhere must NOT be touched ----
mkdir -p "$T/dirX" && cd "$T/dirX" && git init -q && git remote add gdrive "$DRIVE/unrelated.git"
out=$(runA "$T/dirX" --rename exist2 exist3); rc=${out##*RC=}
check "20a rename with mismatched local url rc=0" 0 "$rc"
expect_out "20b mismatch info msg" "ローカルURLは変更していません" "$out"
[[ $(git -C "$T/dirX" remote get-url gdrive) == "$DRIVE/unrelated.git" ]] && ok "20c local url untouched" || fail "20c local url untouched"
[[ -d "$DRIVE/exist3.git" && ! -d "$DRIVE/exist2.git" ]] && ok "20d drive-side renamed" || fail "20d drive-side renamed"
out=$(runA "$T/nowhere" --rename exist3 exist4); rc=${out##*RC=}
check "20e rename outside any repo rc=0" 0 "$rc"
[[ -d "$DRIVE/exist4.git" ]] && ok "20f bare renamed outside repo" || fail "20f bare renamed outside repo"

# ---- 21. --rename with spaces updates matching local URL ----
git init --bare -q "$DRIVE/space app.git"
mkdir -p "$T/dirS" && cd "$T/dirS" && git init -q && git remote add gdrive "$DRIVE/space app.git"
out=$(runA "$T/dirS" --rename "space app" "space app 2"); rc=${out##*RC=}
check "21a rename spaced name rc=0" 0 "$rc"
[[ $(git -C "$T/dirS" remote get-url gdrive) == "$DRIVE/space app 2.git" ]] && ok "21b spaced url updated" || fail "21b spaced url updated"
[[ -d "$DRIVE/space app 2.git" ]] && ok "21c spaced bare exists" || fail "21c spaced bare exists"

# ---- 22. --rename to invalid target (mv failure) must fail loudly, not fake success ----
out=$(runA "$T/nowhere" --rename exist4 "sub/dir"); rc=${out##*RC=}
[[ "$rc" != 0 ]] && ok "22a rename to bad path fails" || fail "22a rename to bad path fails"
[[ -d "$DRIVE/exist4.git" ]] && ok "22b old repo intact after failed rename" || fail "22b old repo intact after failed rename"
expect_out "22c rename mv-failure msg" "移動に失敗しました" "$out"

# ---- 23. conflict via --save: manual resolve (rebase --continue) then --push ----
mkdir -p "$T/confA"
out=$(runA "$T/confA" --init confapp); rc=${out##*RC=}
check "23a init conflict-scenario repo" 0 "$rc"
print "base" > "$T/confA/a.txt"
out=$(runA "$T/confA" --save "base"); rc=${out##*RC=}
check "23b initial save" 0 "$rc"
mkdir -p "$T/confB"
out=$(runB "$T/confB" --clone confapp); rc=${out##*RC=}
check "23c clone on B" 0 "$rc"
[[ -f "$T/confB/confapp/a.txt" ]] && ok "23d cloned file present" || fail "23d cloned file present"
git -C "$T/confB/confapp" config user.email t@t; git -C "$T/confB/confapp" config user.name t
print "A-side" > "$T/confA/a.txt"
out=$(runA "$T/confA" --save "A change"); rc=${out##*RC=}
check "23e A saves first" 0 "$rc"
print "B-side" > "$T/confB/confapp/a.txt"
out=$(runB "$T/confB/confapp" --save "B change"); rc=${out##*RC=}
[[ "$rc" != 0 ]] && ok "23f B conflicting save fails" || fail "23f B conflicting save fails"
expect_out "23g manual-resolve guidance" "手動で解決" "$out"
[[ -d "$T/confB/confapp/.git/rebase-merge" || -d "$T/confB/confapp/.git/rebase-apply" ]] && ok "23h rebase in progress" || fail "23h rebase in progress"
print "resolved-1" > "$T/confB/confapp/a.txt"
git -C "$T/confB/confapp" add a.txt
GIT_EDITOR=true git -C "$T/confB/confapp" rebase --continue > /dev/null 2>&1
[[ $? == 0 ]] && ok "23i rebase continue" || fail "23i rebase continue"
out=$(runB "$T/confB/confapp" --push); rc=${out##*RC=}
check "23j push after resolve" 0 "$rc"
out=$(runA "$T/confA" --sync); rc=${out##*RC=}
check "23k A syncs resolution" 0 "$rc"
grep -q "resolved-1" "$T/confA/a.txt" && ok "23l resolved content on A" || fail "23l resolved content on A"

# ---- 24. conflict via --sync: manual resolve then --push ----
print "A2-side" > "$T/confA/a.txt"
out=$(runA "$T/confA" --save "A2 change"); rc=${out##*RC=}
check "24a A saves A2" 0 "$rc"
print "B2-side" > "$T/confB/confapp/a.txt"
git -C "$T/confB/confapp" add a.txt && git -C "$T/confB/confapp" commit -qm "B2 change"
out=$(runB "$T/confB/confapp" --sync); rc=${out##*RC=}
[[ "$rc" != 0 ]] && ok "24b B conflicting sync fails" || fail "24b B conflicting sync fails"
expect_out "24c conflict guidance" "コンフリクトまたはエラー" "$out"
print "resolved-2" > "$T/confB/confapp/a.txt"
git -C "$T/confB/confapp" add a.txt
GIT_EDITOR=true git -C "$T/confB/confapp" rebase --continue > /dev/null 2>&1
[[ $? == 0 ]] && ok "24d rebase continue" || fail "24d rebase continue"
out=$(runB "$T/confB/confapp" --push); rc=${out##*RC=}
check "24e push after resolve" 0 "$rc"
out=$(runA "$T/confA" --sync); rc=${out##*RC=}
check "24f A syncs final" 0 "$rc"
grep -q "resolved-2" "$T/confA/a.txt" && ok "24g final content on A" || fail "24g final content on A"

print "\n==== RESULT: $PASS passed, $FAIL failed ===="
[[ $FAIL == 0 ]]