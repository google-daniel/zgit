#!/bin/zsh
# ============================================================================
#  zgit Installer for macOS  (v2.2, 2026-11)
#
#  使い方:
#    ./install.sh              # インストール / 更新
#    ./install.sh --uninstall  # ツールだけ完全除去（Drive上のリポジトリは残す）
#    ./install.sh --purge      # ツール除去 + Drive上のリポジトリ（データ）も削除
#    ./install.sh --help       # このヘルプ
#
#  v2.2 変更点:
#    - --save/--push/--pull/--sync を早期ガード: git repo 外・gdrive リモート無し・
#      detached HEAD で「分かりやすいエラー」で即中断（コミット取り残しを防止）
#    - --init を冪等化: 既存リポジトリを検出して git init をスキップ、既存 gdrive
#      リモートを壊さず、失敗時に Drive 上へゴミ bare repo を残さない
#    - 確認プロンプト (y/N) を非対話環境でも安全側に（/dev/tty → stdin 順、読めなければキャンセル）
#    - --list: 空白を含むリポジトリ名に対応 / --info: git repo 外で親切メッセージ
#      / --clone: clone 失敗を確実に exit 1 へ伝播
#
#  v2.1 変更点:
#    - base パスを 3 段階で解決: 環境変数 ZGIT_BASE → ~/.config/zgit/config
#      の base= 行（次点 ~/.zgitrc）→ 自動検出 glob
#    - 埋め込み zgit 本体を v2.1 に更新（--config 追加 / --info に git fsck 追加）
#    - タブ補完に --config 対応、リポジトリ列挙も v2.1 の base 解決に統一
#    - このスクリプトと同じフォルダに zgit / _zgit があればそれを優先使用
#      （無ければ埋め込み版で動作 — Drive 上からの単体実行にも対応）
#
#  v2 変更点:
#    - GDriveパスをハードコード廃止 → 実行時に glob で解決（NFD/NFC・メール名変化に耐性）
#    - --sync: stash pop 失敗時に push しない・明示警告
#    - --save: 変更ゼロで失敗しない（"変更なし"で終了）
#    - 更新時: 既存と同一なら skip、差分があれば .bak を残して上書き
#    - --uninstall / --purge: バイナリ・補完・.zshrc・zcompdump をクリーン除去
# ============================================================================

ZGIT_BIN="/usr/local/bin/zgit"
COMP_DIR="$HOME/.zsh/completions"
COMP_FILE="$COMP_DIR/_zgit"
ZSHRC="$HOME/.zshrc"
SCRIPT_DIR="${0:A:h}"

# --- base ディレクトリの動的解決（v2.1: env → config → glob。本体と同一ロジック） ---
function resolve_gdrive_base() {
    local d base cfg line key val
    # 1) 環境変数 ZGIT_BASE
    if [[ -n "$ZGIT_BASE" ]]; then
        base="$ZGIT_BASE"
        [[ "$base" == "~/"* ]] && base="${HOME}${base#\~}"
        [[ "$base" != /* ]] && base="$(pwd)/$base"
        print -r -- "$base"
        return 0
    fi
    # 2) 設定ファイル (~/.config/zgit/config, ~/.zgitrc)
    for cfg in "$HOME/.config/zgit/config" "$HOME/.zgitrc"; do
        if [[ -f $cfg ]]; then
            while IFS= read -r line || [[ -n "$line" ]]; do
                line="${line%$'\r'}"
                line="${line#"${line%%[![:space:]]*}"}"
                line="${line%"${line##*[![:space:]]}"}"
                [[ -z "$line" || "$line" == \#* ]] && continue
                key="${line%%=*}"
                val="${line#*=}"
                key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
                val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
                if [[ "${key:l}" == "base" && -n "$val" ]]; then
                    [[ "$val" == "~/"* ]] && val="${HOME}${val#\~}"
                    [[ "$val" != /* ]] && val="$(pwd)/$val"
                    print -r -- "$val"
                    return 0
                fi
            done < "$cfg"
        fi
    done
    # 3) 自動検出（NFD/NFC・メール名変化に耐性）
    setopt NULL_GLOB
    for d in "$HOME"/Library/CloudStorage/GoogleDrive-*/マイ*/Mac/remote_dev_env; do
        if [[ -d $d ]]; then
            print -r -- "$d"
            return 0
        fi
    done
    return 1
}

# ============================================================
#  アンインストール / パージ
# ============================================================
if [[ "$1" == "--uninstall" || "$1" == "--purge" ]]; then
    MODE="$1"
    print -P "%F{cyan}====================================================%f"
    if [[ $MODE == --purge ]]; then
        print -P "%F{red}  zgit Uninstall + PURGE（データ削除あり）%f"
    else
        print -P "%F{cyan}  zgit Uninstall（リポジトリデータは保持）%f"
    fi
    print -P "%F{cyan}====================================================%f"
    echo ""

    print -P "%F{yellow}【 削除対象 】%f"
    [[ -f $ZGIT_BIN ]]  && echo "  - $ZGIT_BIN"
    [[ -f $COMP_FILE ]] && echo "  - $COMP_FILE"
    [[ -f $ZSHRC ]]     && echo "  - $ZSHRC の zgit 関連行（削除前にバックアップ）"
    echo "  - ~/.zcompdump*（補完キャッシュ）"

    PURGE_BASE=""
    if [[ $MODE == --purge ]]; then
        if PURGE_BASE=$(resolve_gdrive_base); then
            N=$(ls -1 "$PURGE_BASE" 2>/dev/null | wc -l | tr -d ' ')
            echo "  - [WARN] データ: $PURGE_BASE（$N 項目）"
        else
            echo "  - （Gdrive base は見つからなかった → データ削除なし）"
        fi
    fi
    echo ""
    print -P "%F{red}この操作は元に戻せません。続行しますか？ (y/N)%f"
    read -q "REPLY? " < /dev/tty
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print -P "%F{cyan}キャンセルしました。何も削除していません。%f"
        exit 0
    fi

    TS=$(date +%Y%m%d-%H%M%S)

    # 1. 本体（削除前に installer と同じフォルダに .bak を保存）
    if [[ -f $ZGIT_BIN ]]; then
        cp "$ZGIT_BIN" "$SCRIPT_DIR/zgit.bak.$TS" 2>/dev/null
        sudo rm -f "$ZGIT_BIN"
        print -P "%F{green}[OK] zgit本体を削除しました（バックアップ: $SCRIPT_DIR/zgit.bak.$TS）%f"
    else
        print -P "%F{cyan}[INFO] zgit本体は存在しませんでした%f"
    fi

    # 2. 補完スクリプト（フォルダが空なら一緒に削除）
    if [[ -f $COMP_FILE ]]; then
        rm -f "$COMP_FILE"
        print -P "%F{green}[OK] 補完スクリプトを削除しました%f"
    fi
    rmdir "$COMP_DIR" 2>/dev/null

    # 3. .zshrc の zgit 関連行（バックアップ → 3行種別を削除）
    if [[ -f $ZSHRC ]]; then
        cp "$ZSHRC" "$SCRIPT_DIR/.zshrc.bak.$TS"
        sed -i '' \
            -e '/^[[:space:]]*# zgit/d' \
            -e '/fpath=.*\.zsh\/completions/d' \
            -e '/^autoload -Uz compinit && compinit$/d' \
            "$ZSHRC"
        print -P "%F{green}[OK] .zshrc の zgit 行を削除しました（バックアップ: $SCRIPT_DIR/.zshrc.bak.$TS）%f"
    fi

    # 4. 補完キャッシュ（zsh の NOMATCH 回避）
    (setopt null_glob; rm -f ~/.zcompdump*)

    # 5. （--purge のみ）Drive上のリポジトリを二重確認して削除
    if [[ $MODE == --purge && -n $PURGE_BASE ]]; then
        echo ""
        print -P "%F{yellow}【 削除されるリポジトリ 】%f"
        ls -1 "$PURGE_BASE"
        echo ""
        print -P "%F{red}[WARN] これらのリポジトリ（データ）をすべて削除します。本当に続行しますか？ (y/N)%f"
        read -q "REPLY2? " < /dev/tty
        echo ""
        if [[ $REPLY2 =~ ^[Yy]$ ]]; then
            rm -rf "$PURGE_BASE"
            print -P "%F{green}[OK] リポジトリデータを削除しました%f"
        else
            print -P "%F{cyan}データ削除はキャンセルしました（ツール側の除去は完了）%f"
        fi
    fi

    echo ""
    print -P "%F{cyan}アンインストール完了！設定を反映するには: %F{magenta}source ~/.zshrc%f"
    exit 0
fi

if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo "使い方: $0 [--uninstall | --purge]"
    echo "  (引数なし)   : zgit をインストール/更新"
    echo "  --uninstall  : ツールを完全除去（Drive上のリポジトリは保持）"
    echo "  --purge      : ツール除去 + Drive上のリポジトリ（データ）も削除"
    echo ""
    echo "base パス設定 (v2.1) — 解決順:"
    echo "  1) 環境変数 ZGIT_BASE"
    echo "  2) ~/.config/zgit/config の base=<path> 行 (次点: ~/.zgitrc)"
    echo "  3) 自動検出: ~/Library/CloudStorage/GoogleDrive-*/マイ*/Mac/remote_dev_env"
    echo "  確認コマンド: zgit --config"
    exit 0
fi

# ============================================================
#  インストール / 更新
# ============================================================
print -P "%F{cyan}====================================================%f"
print -P "%F{cyan}  zgit Installer for macOS (v2.1)%f"
print -P "%F{cyan}====================================================%f"
echo ""

# --- 事前チェック: base 解決（v2.1: env → config → 自動検出） ---
if ! resolve_gdrive_base > /dev/null; then
    print -P "%F{yellow}[WARN] Gdrive base を解決できませんでした%f"
    print "   解決順: 1) 環境変数 ZGIT_BASE → 2) ~/.config/zgit/config の base= → 3) 自動検出"
    print "   設定例: echo 'base=~/path/to/remote_dev_env' > ~/.config/zgit/config"
    print "   （インストール自体は続行します。zgit 実行時に再解決されます）"
    echo ""
fi

TMP_ZGIT=""
TMP_COMP=""

# [1/3] zgit 本体のソース決定（同梱 zgit 優先 → 埋め込み版フォールバック）
print -P "%F{yellow}[1/3] zgit本体をインストールしています...%f"
if [[ -f "$SCRIPT_DIR/zgit" ]]; then
    SRC_ZGIT="$SCRIPT_DIR/zgit"
    print -P "%F{cyan}   同梱の zgit 本体を使用します: $SRC_ZGIT%f"
else
    TMP_ZGIT="$(mktemp "${TMPDIR:-/tmp}/zgit.XXXXXX")"
    cat > "$TMP_ZGIT" << 'EOF_ZGIT'
#!/bin/zsh
# zgit - The Seamless Git Wrapper for Google Drive (v2.2)
# v2.2: safer guards & scripting-friendly prompts:
#       - --save/--push/--pull/--sync fail fast with clear errors when outside a
#         git repo, without a gdrive remote, or on a detached HEAD
#       - --init is idempotent: detects existing repos, never strands an orphan
#         bare repo on Drive, never clobbers an existing gdrive remote
#       - confirmation prompts fall back gracefully in non-interactive shells
#       - --list handles repository names containing spaces; --info is friendly
#         outside a git repo; --clone propagates clone failure
# v2.1: base path is now configurable (env ZGIT_BASE > config file > auto-detect),
#       new `zgit --config` to show the resolved base, and `zgit --info` runs a
#       git fsck health check (skippable with ZGIT_NO_FSCK=1).

# 未マッチ glob をエラーにせず空展開に（自動検出の glob が miss しても継続）
setopt NULL_GLOB

# ------------------------------------------------------------------
# base path resolution
# ------------------------------------------------------------------

function zgit_config_file() {
    # 最初に見つかった設定ファイルのパスを返す
    local f
    for f in "$HOME/.config/zgit/config" "$HOME/.zgitrc"; do
        if [[ -f $f && -r $f ]]; then
            print -r -- "$f"
            return 0
        fi
    done
    return 1
}

function zgit_expand_path() {
    # ~ を展開し、相対パスなら絶対パス化して返す
    local p="$1"
    if [[ "$p" == "~" ]]; then
        p="$HOME"
    elif [[ "$p" == "~/"* ]]; then
        p="${HOME}${p#\~}"
    fi
    if [[ "$p" != /* ]]; then
        p="$(pwd)/$p"
    fi
    print -r -- "$p"
}

function zgit_trim() {
    # 前後の空白を削除（EXTENDED_GLOB に依存しない安全なトリム）
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    print -r -- "$s"
}

function zgit_base_from_config() {
    # 設定ファイルから base=<path> の値を読んで返す（# コメント・空白行は無視）
    local cfg="$1" line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line=$(zgit_trim "$line")
        [[ -z "$line" || "$line" == \#* ]] && continue
        key=$(zgit_trim "${line%%=*}")
        val=$(zgit_trim "${line#*=}")
        if [[ "${key:l}" == "base" && -n "$val" ]]; then
            zgit_expand_path "$val"
            return 0
        fi
    done < "$cfg"
    return 1
}

# GDrive base を解決: 1) ZGIT_BASE 2) config 3) 自動検出（NFD/NFC・メール名変化に耐性）
function gdrive_base() {
    local d base
    # 1) 環境変数 ZGIT_BASE
    if [[ -n "$ZGIT_BASE" ]]; then
        zgit_expand_path "$ZGIT_BASE"
        return 0
    fi
    # 2) 設定ファイル (~/.config/zgit/config, ~/.zgitrc)
    local cfg
    if cfg=$(zgit_config_file) && [[ -n "$cfg" ]]; then
        if base=$(zgit_base_from_config "$cfg"); then
            print -r -- "$base"
            return 0
        fi
    fi
    # 3) 自動検出（現行の glob ロジック）
    for d in "$HOME"/Library/CloudStorage/GoogleDrive-*/マイ*/Mac/remote_dev_env; do
        if [[ -d $d ]]; then
            print -r -- "$d"
            return 0
        fi
    done
    return 1
}

function require_gdrive_base() {
    local base
    if ! base=$(gdrive_base); then
        print -P "%F{red}[ERROR] Gdrive base を解決できませんでした%f"
        print "   解決順: 1) 環境変数 ZGIT_BASE → 2) ~/.config/zgit/config の base= → 3) 自動検出"
        print "   自動検出の期待パス: ~/Library/CloudStorage/GoogleDrive-*/マイ*/Mac/remote_dev_env"
        print "   設定例: export ZGIT_BASE=\"~/Library/CloudStorage/GoogleDrive-xxx/My Drive/Mac/remote_dev_env\""
        print "   または: echo 'base=~/path/to/remote_dev_env' >> ~/.config/zgit/config"
        exit 1
    fi
    print -r -- "$base"
}

if [[ -z "$1" || "$1" == "-h" || "$1" == "--help" ]]; then
    print -P "%F{cyan}====================================================%f"
    print -P "%F{cyan}  zgit - The Seamless Git Wrapper for Google Drive%f"
    print -P "%F{cyan}====================================================%f"
    echo ""
    print -P "%F{yellow}【 概要 】%f"
    echo "  Google Driveをリモートサーバー(ベアリポジトリ)として扱い、"
    echo "  複数台のMac間でプロジェクトを簡単に同期するためのCLIツールです。"
    echo "  zgit独自の機能は「--」から始まるオプションで実行します。"
    echo "  普段使っている標準の git コマンドはそのまま zgit 経由で使えます。"
    echo ""
    print -P "%F{yellow}【 zgit 専用オプション 】%f"
    print -P "  %F{green}--init <repo>%f  : 現在のディレクトリを初期化し、Gdriveに紐付け"
    print -P "  %F{green}--clone <repo>%f : Gdriveから既存のリポジトリを現在の場所にクローン"
    print -P "  %F{green}--list%f         : Gdrive上に保存されているリポジトリの一覧を表示"
    print -P "  %F{green}--delete <repo>%f: Gdrive上のリポジトリを削除 (別名: --rm)"
    print -P "  %F{green}--rename <o> <n>%f: Gdrive上のリポジトリ名を変更"
    print -P "  %F{green}--save [msg]%f   : add ., commit, push を一括実行 (作業の爆速保存)"
    print -P "  %F{green}--sync%f         : Gdriveからのpull(rebase)とpushを一括実行 (端末切り替え時)"
    print -P "  %F{green}--info%f         : ブランチ・Gdrive接続・未コミット変更 + git fsck 健全性チェック"
    print -P "  %F{green}--config%f       : baseパスの解決結果 (ソース・パス・リポジトリ数) を表示"
    print -P "  %F{green}--log%f          : コミット履歴をツリー状できれいに表示"
    print -P "  %F{green}--push%f         : 現在のブランチをGdriveへプッシュ"
    print -P "  %F{green}--pull%f         : Gdriveから現在のブランチへプル"
    echo ""
    print -P "%F{yellow}【 base パス設定 (解決順) 】%f"
    echo "  1) 環境変数 ZGIT_BASE"
    echo "  2) ~/.config/zgit/config の base=<path> 行 (次点: ~/.zgitrc)"
    echo "  3) 自動検出: ~/Library/CloudStorage/GoogleDrive-*/マイ*/Mac/remote_dev_env"
    echo "  ※ --info の fsck チェックは ZGIT_NO_FSCK=1 でスキップできます"
    echo ""
    print -P "%F{yellow}【 標準 Git コマンド (透過実行) 】%f"
    print -P "  %F{green}<any command>%f  : オプション(--)をつけない場合は標準gitとして動作します"
    echo ""
    exit 0
fi

COMMAND=$1
shift

function setup_gdrive_dir() {
    if [[ ! -d "$BASE" ]]; then
        mkdir -p "$BASE"
        print -P "%F{green}Created Gdrive base directory: $BASE%f"
    fi
}

function get_current_branch() {
    git branch --show-current 2>/dev/null
}

function require_gdrive_remote() {
    # --save/--push/--pull/--sync の共通ガード: git repo 内かつ gdrive remote があるか
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        print -P "%F{red}[ERROR] ここは Git リポジトリではありません (zgit --init <repo> で始めてください)%f"
        return 1
    fi
    if ! git remote get-url gdrive > /dev/null 2>&1; then
        print -P "%F{red}[ERROR] このリポジトリに gdrive リモートがありません (zgit --init <repo> で紐付けてください)%f"
        return 1
    fi
}

function zgit_confirm() {
    # 対話確認: /dev/tty → stdin の順に読む。どちらも読めない非対話環境では 1 を返す（=No で安全側）
    # tty があるときは read -k1（1キー即決）、無いときは read -r（"echo y | zgit --delete" 等のパイプ対応）
    local REPLY
    if { read -k1 "REPLY? " < /dev/tty } 2>/dev/null; then
        echo ""
        [[ "$REPLY" =~ ^[Yy]$ ]] && return 0
        return 1
    fi
    if read -r REPLY 2>/dev/null; then
        REPLY="${REPLY#"${REPLY%%[![:space:]]*}"}"
        [[ "$REPLY" =~ ^[Yy]$ ]] && return 0
        return 1
    fi
    print -P "%F{yellow}[INFO] 対話ターミナルがないため確認できません — キャンセル扱いにします%f"
    return 1
}

case "$COMMAND" in
    --config)
        print -P "%F{cyan}zgit base 設定 (解決順: ZGIT_BASE env → 設定ファイル → 自動検出)%f"
        zc_resolved=""
        zc_src="(未解決)"
        if [[ -n "$ZGIT_BASE" ]]; then
            zc_resolved=$(zgit_expand_path "$ZGIT_BASE")
            zc_src="環境変数 ZGIT_BASE (raw: $ZGIT_BASE)"
        else
            zc_cfg=""
            if zc_cfg=$(zgit_config_file) && [[ -n "$zc_cfg" ]]; then
                zc_fb=""
                if zc_fb=$(zgit_base_from_config "$zc_cfg"); then
                    zc_resolved="$zc_fb"
                    zc_src="設定ファイル: $zc_cfg"
                fi
            fi
        fi
        if [[ -z "$zc_resolved" ]]; then
            for zc_d in "$HOME"/Library/CloudStorage/GoogleDrive-*/マイ*/Mac/remote_dev_env; do
                if [[ -d $zc_d ]]; then
                    zc_resolved="$zc_d"
                    zc_src="自動検出 (glob)"
                    break
                fi
            done
        fi
        if [[ -n "$zc_resolved" ]]; then
            print "  Source : $zc_src"
            print "  Base   : $zc_resolved"
            if [[ -d "$zc_resolved" ]]; then
                zc_n=$(ls -1 "$zc_resolved" 2>/dev/null | grep -c '\.git$')
                print "  Repos  : ${zc_n:-0} (.git)"
            else
                print -P "  %F{yellow}[WARN] ディレクトリが存在しません (--init 実行時に作成されます)%f"
            fi
        else
            print -P "  %F{red}[ERROR] base を解決できませんでした%f"
            print "  設定例: export ZGIT_BASE=\"~/Library/CloudStorage/GoogleDrive-xxx/My Drive/Mac/remote_dev_env\""
            print "  または: echo 'base=~/path/to/remote_dev_env' > ~/.config/zgit/config"
            exit 1
        fi
        ;;
    --init)
        REPO_NAME=$1
        if [[ -z "$REPO_NAME" ]]; then print -P "%F{red}[ERROR] リポジトリ名を指定してください%f"; exit 1; fi
        BASE=$(require_gdrive_base) || exit 1
        setup_gdrive_dir
        GDRIVE_REPO="$BASE/$REPO_NAME.git"
        if [[ -d "$GDRIVE_REPO" ]]; then print -P "%F{red}[ERROR] Gdrive上に既に存在します%f"; exit 1; fi
        # v2.2: 事前チェックをすべて通してから bare repo を作る（失敗時のゴミを防ぐ）
        if [[ -d .git ]] && git remote get-url gdrive > /dev/null 2>&1; then
            print -P "%F{red}[ERROR] このリポジトリは既に gdrive に紐付いています: $(git remote get-url gdrive)%f"
            exit 1
        fi
        if ! git init --bare "$GDRIVE_REPO" > /dev/null; then
            print -P "%F{red}[ERROR] Gdrive上の bare リポジトリ作成に失敗しました: $GDRIVE_REPO%f"
            exit 1
        fi
        if [[ -d .git ]]; then
            print -P "%F{cyan}[INFO] 既存の Git リポジトリを検出 — git init をスキップします%f"
            git remote add gdrive "$GDRIVE_REPO"
        else
            git init > /dev/null || { print -P "%F{red}[ERROR] git init に失敗しました%f"; exit 1; }
            git remote add gdrive "$GDRIVE_REPO"
        fi
        print -P "%F{green}[OK] Initialized local repo and linked to Gdrive.%f"

        if [[ ! -f .gitignore ]]; then
            print -P "%F{yellow}[INFO] .gitignore が見つかりません。macOS用の汎用的な .gitignore を作成しますか？ (y/N)%f"
            if zgit_confirm; then
                echo ".DS_Store" > .gitignore
                echo "node_modules/" >> .gitignore
                echo "*.log" >> .gitignore
                print -P "%F{green}.gitignore を作成しました%f"
            fi
        fi
        ;;
    --clone)
        REPO_NAME=$1
        if [[ -z "$REPO_NAME" ]]; then print -P "%F{red}[ERROR] リポジトリ名を指定してください%f"; exit 1; fi
        BASE=$(require_gdrive_base) || exit 1
        GDRIVE_REPO="$BASE/$REPO_NAME.git"
        if [[ ! -d "$GDRIVE_REPO" ]]; then print -P "%F{red}[ERROR] リポジトリが見つかりません%f"; exit 1; fi
        print -P "%F{cyan}Cloning $REPO_NAME...%f"
        git clone "$GDRIVE_REPO" "$REPO_NAME" || exit 1
        cd "$REPO_NAME" && git remote rename origin gdrive
        ;;
    --list|-l)
        BASE=$(require_gdrive_base) || exit 1
        print -P "%F{cyan}Gdrive上のリポジトリ一覧:%f"
        repos=$(ls -1 "$BASE" 2>/dev/null | grep '\.git$' | sed 's/\.git$//')
        [[ -z "$repos" ]] && echo "  (リポジトリなし)" || while IFS= read -r repo; do print -P "  - %F{green}$repo%f"; done <<< "$repos"
        ;;
    --delete|--rm)
        REPO_NAME=$1
        if [[ -z "$REPO_NAME" ]]; then print -P "%F{red}[ERROR] リポジトリ名を指定してください%f"; exit 1; fi
        BASE=$(require_gdrive_base) || exit 1
        GDRIVE_REPO="$BASE/$REPO_NAME.git"
        if [[ ! -d "$GDRIVE_REPO" ]]; then print -P "%F{red}[ERROR] Gdrive上にリポジトリが見つかりません: $REPO_NAME%f"; exit 1; fi
        print -P "%F{yellow}[WARN] 本当に Gdrive 上の '$REPO_NAME' リポジトリを削除しますか？ (y/N)%f"
        if zgit_confirm; then
            rm -rf "$GDRIVE_REPO"
            print -P "%F{green}削除しました: $REPO_NAME%f"
        else
            print -P "%F{cyan}キャンセルしました%f"
        fi
        ;;
    --rename)
        OLD_NAME=$1
        NEW_NAME=$2
        if [[ -z "$OLD_NAME" || -z "$NEW_NAME" ]]; then print -P "%F{red}[ERROR] 変更前と変更後のリポジトリ名を指定してください (例: zgit --rename old_name new_name)%f"; exit 1; fi
        BASE=$(require_gdrive_base) || exit 1
        OLD_REPO="$BASE/$OLD_NAME.git"
        NEW_REPO="$BASE/$NEW_NAME.git"
        if [[ ! -d "$OLD_REPO" ]]; then print -P "%F{red}[ERROR] Gdrive上にリポジトリが見つかりません: $OLD_NAME%f"; exit 1; fi
        if [[ -d "$NEW_REPO" ]]; then print -P "%F{red}[ERROR] 変更後の名前はすでに存在します%f"; exit 1; fi
        if ! mv "$OLD_REPO" "$NEW_REPO"; then
            print -P "%F{red}[ERROR] Gdrive上のリポジトリ移動に失敗しました: $OLD_REPO -> $NEW_REPO%f"
            exit 1
        fi
        print -P "%F{green}リポジトリ名を変更しました: $OLD_NAME -> $NEW_NAME%f"
        CURRENT_URL=$(git remote get-url gdrive 2>/dev/null)
        if [[ "$CURRENT_URL" == "$OLD_REPO" ]]; then
            git remote set-url gdrive "$NEW_REPO"
            print -P "%F{green}ローカルのgdriveリモートURLも更新しました%f"
        else
            print -P "%F{yellow}[INFO] 現在のリポジトリのgdrive URLが異なっていたためローカルURLは変更していません%f"
        fi
        ;;
    --push)
        require_gdrive_remote || exit 1
        BRANCH=$(get_current_branch)
        [[ -z "$BRANCH" ]] && { print -P "%F{red}[ERROR] ブランチがありません (detached HEAD?)%f"; exit 1; }
        print -P "%F{cyan}Pushing to Gdrive ($BRANCH)...%f"
        git push gdrive "$BRANCH" "$@"
        ;;
    --pull)
        require_gdrive_remote || exit 1
        BRANCH=$(get_current_branch)
        [[ -z "$BRANCH" ]] && { print -P "%F{red}[ERROR] ブランチがありません (detached HEAD?)%f"; exit 1; }
        print -P "%F{cyan}Pulling from Gdrive ($BRANCH)...%f"
        git pull gdrive "$BRANCH" "$@"
        ;;
    --save)
        require_gdrive_remote || exit 1
        BRANCH=$(get_current_branch)
        [[ -z "$BRANCH" ]] && { print -P "%F{red}[ERROR] ブランチがありません (detached HEAD?) — --save を実行できません%f"; exit 1; }
        if [[ $# -eq 0 ]]; then
            MSG="Auto commit from $(hostname -s) at $(date +'%Y-%m-%d %H:%M:%S')"
        else
            MSG="$*"
        fi
        git add .
        if git diff --cached --quiet; then
            print -P "%F{cyan}[INFO] コミットする変更はありません%f"
            exit 0
        fi
        if ! git commit -m "$MSG"; then
            print -P "%F{red}[ERROR] commit に失敗しました（push は実行していません）%f"
            exit 1
        fi
        BRANCH=$(get_current_branch)
        if ! git push gdrive "$BRANCH" 2>/dev/null; then
            # リモートに自分より新しいコミットがある（別マシンで保存済み）→ rebaseして再試行
            print -P "%F{yellow}[INFO] pushが拒否されました。リモートをrebaseしてから再試行します...%f"
            if ! git pull --rebase gdrive "$BRANCH"; then
                print -P "%F{red}[ERROR] rebaseにコンフリクトが発生しました。手動で解決し、完了後に 'git rebase --continue' と 'zgit --push' を実行してください。%f"
                exit 1
            fi
            if ! git push gdrive "$BRANCH"; then
                print -P "%F{red}[ERROR] push に失敗しました（ローカルの commit は残っています）%f"
                exit 1
            fi
        fi
        print -P "%F{green}[OK] Saved and pushed!%f"
        ;;
    --sync)
        require_gdrive_remote || exit 1
        BRANCH=$(get_current_branch)
        [[ -z "$BRANCH" ]] && { print -P "%F{red}[ERROR] ブランチがありません (detached HEAD?)%f"; exit 1; }
        STASHED=false
        if [[ -n $(git status -s) ]]; then
            git stash push -m "zgit --sync $(date +'%Y-%m-%d %H:%M:%S')" > /dev/null
            STASHED=true
        fi

        # リモートにこのブランチがまだない（初回同期）場合は pull をスキップして push だけ実行
        if git ls-remote --exit-code gdrive "refs/heads/$BRANCH" > /dev/null 2>&1; then
            if ! git pull --rebase gdrive "$BRANCH"; then
                print -P "%F{red}[ERROR] コンフリクトまたはエラーが発生しました。手動で解決し、完了後に git rebase --continue と zgit --push を実行してください。%f"
                if [[ "$STASHED" == true ]]; then
                    print -P "%F{yellow}[WARN] 未処理の自動stashが残っています（'git stash pop' で復元）:%f"
                    git stash list | head -5
                fi
                exit 1
            fi
        else
            print -P "%F{cyan}[INFO] リモートに $BRANCH ブランチがないため pull をスキップします（初回同期）%f"
        fi

        if [[ "$STASHED" == true ]]; then
            if ! git stash pop; then
                print -P "%F{red}[ERROR] 自動stashの復元(stash pop)に失敗しました（競合）。push は実行していません。%f"
                print -P "   競合を手動解決後: 'git stash drop' → 'zgit --push'"
                print -P "%F{yellow}   stash list:%f"
                git stash list | head -5
                exit 1
            fi
        fi
        if ! git push gdrive "$BRANCH"; then
            print -P "%F{red}[ERROR] push に失敗しました%f"
            exit 1
        fi
        print -P "%F{green}Sync complete!%f"
        ;;
    --info)
        echo "Dir    : $(pwd)"
        if ! git rev-parse --git-dir > /dev/null 2>&1; then
            print -P "%F{yellow}Branch : (ここは Git リポジトリではありません — zgit --init <repo> で始められます)%f"
            exit 0
        fi
        echo "Branch : $(get_current_branch)"
        echo "Remote : $(git remote get-url gdrive 2>/dev/null)"
        git status -s
        # git fsck による健全性チェック（Drive同期での bare repo 破損 early-warning）
        if [[ -z "$ZGIT_NO_FSCK" ]] && git rev-parse --git-dir > /dev/null 2>&1; then
            fsck_out=$(git fsck --no-progress 2>&1)
            fsck_rc=$?
            if (( fsck_rc == 0 )); then
                fsck_err=$(printf '%s\n' "$fsck_out" | grep -v '^dangling' || true)
                if [[ -z "$fsck_err" ]]; then
                    print -P "%F{green}fsck   : [OK] 健全 (破損オブジェクトなし)%f"
                else
                    print -P "%F{yellow}fsck   : [WARN] 警告あり (dangling 以外の出力)%f"
                    printf '%s\n' "$fsck_err" | head -10
                fi
            else
                print -P "%F{red}fsck   : [ERROR] 破損の可能性があります (Drive同期を確認してください)%f"
                printf '%s\n' "$fsck_out" | head -15
            fi
        fi
        ;;
    --log)
        git log --graph --oneline --decorate --all --color
        ;;
    -*)
        print -P "%F{red}[ERROR] 不明なオプション: $COMMAND%f"
        exit 1
        ;;
    *)
        git "$COMMAND" "$@"
        ;;
esac
EOF_ZGIT
    SRC_ZGIT="$TMP_ZGIT"
    print -P "%F{yellow}   同梱の zgit が見つからないため埋め込み版 (v2.2) を使用します%f"
fi

if [[ -f $ZGIT_BIN ]]; then
    if diff -q "$SRC_ZGIT" "$ZGIT_BIN" > /dev/null 2>&1; then
        print -P "%F{cyan}[INFO] 既存の zgit は新バージョンと同一です — 更新をスキップ%f"
    else
        cp "$ZGIT_BIN" "$SCRIPT_DIR/zgit.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null
        print -P "%F{yellow}[WARN] 既存の zgit と差分があります。旧版を .bak として保存して上書きします。%f"
    fi
fi
sudo install -m 755 "$SRC_ZGIT" "$ZGIT_BIN"
[[ -n "$TMP_ZGIT" ]] && rm -f "$TMP_ZGIT"
print -P "%F{green}[OK] zgit本体を $ZGIT_BIN に配置し、実行権限を付与しました。%f"

# [2/3] タブ補完スクリプトのインストール（同梱 _zgit 優先 → 埋め込み版フォールバック）
print -P "%F{yellow}[2/3] タブ補完スクリプトをインストールしています...%f"
mkdir -p "$COMP_DIR"
if [[ -f "$SCRIPT_DIR/_zgit" ]]; then
    cp "$SCRIPT_DIR/_zgit" "$COMP_FILE"
    print -P "%F{cyan}   同梱の補完スクリプトを使用します: $SCRIPT_DIR/_zgit%f"
else
    cat > "$COMP_FILE" << 'EOF_COMP'
#compdef zgit

_zgit() {
    local state line

    _arguments -C \
        '--init[Gdriveに新しいリポジトリを作成して紐付け]:repository_name: ' \
        '--clone[Gdriveからリポジトリをクローン]:repository_name:->repos' \
        '(--list -l)'{--list,-l}'[Gdrive上のリポジトリ一覧を表示]' \
        '(--delete --rm)'{--delete,--rm}'[Gdrive上のリポジトリを削除]:repository_name:->repos' \
        '--rename[Gdrive上のリポジトリ名を変更]:old_name:->repos:new_name: ' \
        '--save[変更を一括でコミット＆プッシュ (爆速保存)]:commit_message: ' \
        '--sync[Gdriveと最新状態を同期 (端末移動用)]' \
        '--info[現在の状態とGdriveの紐付け・fsck健全性を確認]' \
        '--config[baseパスの解決結果 (ソース・パス・リポジトリ数) を表示]' \
        '--log[コミット履歴をツリー状に表示]' \
        '--push[現在のブランチをGdriveへプッシュ]' \
        '--pull[Gdriveから現在のブランチへプル]' \
        '*::arg:->args'

    case "$state" in
        repos)
            local -a repos=()
            local base cfg line val
            # v2.1: base 解決は ZGIT_BASE env → ~/.config/zgit/config → 自動検出
            if [[ -n "$ZGIT_BASE" ]]; then
                base="${ZGIT_BASE}"
                [[ "$base" == "~/"* ]] && base="${HOME}${base#\~}"
            elif [[ -f "$HOME/.config/zgit/config" ]]; then
                base=""
                while IFS= read -r line || [[ -n "$line" ]]; do
                    line="${line%$'\r'}"
                    line="${line#"${line%%[![:space:]]*}"}"
                    line="${line%"${line##*[![:space:]]}"}"
                    [[ -z "$line" || "$line" == \#* ]] && continue
                    [[ "${line%%=*}" != base ]] && continue
                    val="${line#*=}"
                    val="${val#"${val%%[![:space:]]*}"}"
                    val="${val%"${val##*[![:space:]]}"}"
                    [[ "$val" == "~/"* ]] && val="${HOME}${val#\~}"
                    base="$val"
                    break
                done < "$HOME/.config/zgit/config"
            else
                base=""
                for base in "$HOME"/Library/CloudStorage/GoogleDrive-*/マイ*/Mac/remote_dev_env; do
                    [[ -d $base ]] && break
                    base=""
                done
            fi
            if [[ -n "$base" && -d $base ]]; then
                repos=($(ls -1 "$base" 2>/dev/null | grep '\.git$' | sed 's/\.git$//'))
            fi
            if (( ${#repos[@]} > 0 )); then
                _describe -t repositories 'Gdrive repositories' repos
            fi
            ;;
        args)
            _files
            ;;
    esac
}

_zgit "$@"
EOF_COMP
fi
print -P "%F{green}[OK] 補完スクリプトを $COMP_FILE に配置しました。%f"

# [3/3] .zshrc の設定確認と追記（2行を個別判定）
print -P "%F{yellow}[3/3] .zshrc の設定を確認しています...%f"
if [[ ! -f $ZSHRC ]]; then
    touch "$ZSHRC"
fi
if ! grep -q "fpath=.*\.zsh/completions" "$ZSHRC" 2>/dev/null; then
    {
        echo ""
        echo "# zgit auto-completion"
        echo "fpath=(~/.zsh/completions \$fpath)"
    } >> "$ZSHRC"
    print -P "%F{green}[OK] .zshrc に fpath 設定を追記しました。%f"
else
    print -P "%F{cyan}[OK] .zshrc の fpath 設定は既に存在します。%f"
fi
if ! grep -q "^autoload -Uz compinit && compinit$" "$ZSHRC" 2>/dev/null; then
    echo "autoload -Uz compinit && compinit" >> "$ZSHRC"
    print -P "%F{green}[OK] .zshrc に compinit 設定を追記しました。%f"
else
    print -P "%F{cyan}[OK] .zshrc の compinit 設定は既に存在します。%f"
fi

# キャッシュのクリア（zsh の NOMATCH 回避）
(setopt null_glob; rm -f ~/.zcompdump*)

echo ""
print -P "%F{cyan}インストールが完了しました！（v2.1）%f"
print -P ""
print -P "%F{yellow}【 base パス設定 (v2.1) 】%f"
print "  解決順: 1) 環境変数 ZGIT_BASE → 2) ~/.config/zgit/config の base= → 3) 自動検出"
print "  現在の解決結果の確認: zgit --config"
print "  自動検出が合わない場合の設定例:"
print '    echo "base=~/Library/CloudStorage/GoogleDrive-you@gmail.com/My Drive/Mac/remote_dev_env" > ~/.config/zgit/config'
print -P ""
print -P "以下のコマンドを実行して設定を反映させてください："
print -P "%F{magenta}source ~/.zshrc%f"
