# zgit 🚀

**Use Google Drive as your git server — sync projects across multiple Macs, seamlessly.**

zgit is a small zsh wrapper around `git` that treats a folder in your Google Drive as a set of bare repositories. No server, no SSH keys, no subscription: your Drive folder *is* the remote. Options starting with `--` are zgit commands; anything else is passed through to `git` untouched.

```bash
# Mac A
cd ~/projects/myapp
zgit --init myapp        # init + link to a bare repo on Drive
zgit --save "first version"

# Mac B
cd ~/projects
zgit --clone myapp

# ...after working on Mac B
zgit --sync              # stash -> pull (rebase) -> pop -> push

# back on Mac A
zgit --sync
```

## How it works

Each project lives on Drive as a bare repository (`<repo>.git`) inside a "base" folder. zgit resolves that base folder at runtime, then behaves like plain git:

```text
Google Drive / ... / Mac/remote_dev_env/
├── myapp.git      ← bare repo (the "remote")
├── other.git
└── ...
```

## Installation

### Quick install (recommended)

```bash
git clone https://github.com/google-daniel/zgit.git
cd zgit
./install.sh
```

The installer (v2.1):

1. installs the `zgit` binary to `/usr/local/bin` (asks for your password once via `sudo`)
2. installs tab-completion to `~/.zsh/completions/_zgit`
3. adds the completion path to your `~/.zshrc` (only if missing)

It also supports:

```bash
./install.sh --uninstall   # remove the tool, keep repos on Drive
./install.sh --purge       # remove the tool AND delete repos on Drive (destructive, asks twice)
./install.sh --help
```

### Manual install

```bash
sudo install -m 755 zgit /usr/local/bin/zgit
mkdir -p ~/.zsh/completions && cp _zgit ~/.zsh/completions/_zgit
# add to ~/.zshrc:  fpath=(~/.zsh/completions $fpath)  and  autoload -Uz compinit && compinit
```

### Requirements

- macOS with the Google Drive desktop app signed in
- zsh and git
- `sudo` for the install step

## Configuration (v2.1)

zgit needs to know your **base folder**. It resolves it in this order:

1. `ZGIT_BASE` environment variable
2. `base=<path>` line in `~/.config/zgit/config` (next candidate: `~/.zgitrc`)
3. Auto-detection: `~/Library/CloudStorage/GoogleDrive-*/.../Mac/remote_dev_env`

Check what is currently resolved:

```bash
zgit --config
# ⚙️  zgit base 設定 (解決順: ZGIT_BASE env → 設定ファイル → 自動検出)
#   Source : 自動検出 (glob)
#   Base   : /Users/you/Library/CloudStorage/GoogleDrive-you@gmail.com/マイドライブ/Mac/remote_dev_env
#   Repos  : 15 (.git)
```

If your Drive layout differs from the auto-detect pattern (non-Japanese folder names, custom folder), set the base explicitly:

```bash
# one-off / shell profile
export ZGIT_BASE="~/Library/CloudStorage/GoogleDrive-you@gmail.com/My Drive/Mac/remote_dev_env"

# or persistently
mkdir -p ~/.config/zgit
echo 'base=~/Library/CloudStorage/GoogleDrive-you@gmail.com/My Drive/Mac/remote_dev_env' > ~/.config/zgit/config
```

Config file notes: lines starting with `#` and blank lines are ignored, spaces around `=` are fine, and `~` is expanded.

## Commands

| Command | Description |
|---|---|
| `zgit --init <repo>` | init the current directory and link it to a new bare repo on Drive |
| `zgit --clone <repo>` | clone a repo from Drive (remote is named `gdrive`) |
| `zgit --list` | list repos stored on Drive |
| `zgit --save [msg]` | `add .` + commit + push in one shot; refuses nothing when clean |
| `zgit --sync` | stash → `pull --rebase` → pop → push — for switching between Macs |
| `zgit --info` | branch, remote, uncommitted changes **+ `git fsck` health check** |
| `zgit --config` | show the resolved base path and where it came from |
| `zgit --log` | pretty commit tree |
| `zgit --push` / `--pull` | push/pull the current branch |
| `zgit --rename <old> <new>` | rename a repo on Drive (updates local `gdrive` URL if it matches) |
| `zgit --delete <repo>` | delete a bare repo from Drive (asks twice) |
| `zgit <any git command>` | transparent passthrough: `zgit status`, `zgit diff`, ... |

## Health check (v2.1)

Drive sync can silently corrupt git objects. `zgit --info` runs `git fsck` and warns early:

```text
🩺 fsck   : ✅ 健全 (破損オブジェクトなし)
```

On a damaged repo it prints the offending objects so you can re-push or restore. Skip the check when you don't need it (large repos can take a moment):

```bash
ZGIT_NO_FSCK=1 zgit --info
```

## Shell completion

Tab-completion offers zgit options and, for `--clone` / `--delete` / `--rename`, the repository names that actually exist on your Drive. It is installed by `install.sh` and enabled after `source ~/.zshrc`.

## Uninstall

```bash
./install.sh --uninstall   # tool only — repos on Drive are kept
./install.sh --purge       # tool + all repos on Drive (destructive!)
```

---

## 日本語セクション

### 概要

**Google Drive をリモートサーバー（ベアリポジトリ）として扱い、複数台の Mac 間でプロジェクトを同期する CLI** です。`--` から始まるオプションが zgit 専用、それ以外は標準 `git` としてそのまま透過実行されます。

### インストール

```bash
git clone https://github.com/google-daniel/zgit.git
cd zgit
./install.sh    # 本体を /usr/local/bin へ、補完を ~/.zsh/completions へ（sudo 1回）
```

完了後 `source ~/.zshrc` で補完が有効になります。除去は `./install.sh --uninstall`（ツールのみ）／`./install.sh --purge`（Drive上のデータも削除・破壊的）。

### base パス設定（v2.1）

リポジトリを置く Drive 上のフォルダ（base）は次の順で解決されます:

1. 環境変数 `ZGIT_BASE`
2. `~/.config/zgit/config` の `base=<path>` 行（次点 `~/.zgitrc`）
3. 自動検出: `~/Library/CloudStorage/GoogleDrive-*/マイ*/Mac/remote_dev_env`

```bash
zgit --config   # 現在の解決結果（ソース・パス・リポジトリ数）を表示
```

日本語環境以外（`My Drive` など）や別フォルダ構成では、`ZGIT_BASE` か config ファイルで明示指定してください:

```bash
echo 'base=~/Library/CloudStorage/GoogleDrive-you@gmail.com/My Drive/Mac/remote_dev_env' > ~/.config/zgit/config
```

### 主なコマンド

| コマンド | 動作 |
|---|---|
| `zgit --init <repo>` | 現在のディレクトリを初期化し Drive に紐付け |
| `zgit --clone <repo>` | Drive からクローン |
| `zgit --list` | Drive 上のリポジトリ一覧 |
| `zgit --save [msg]` | add + commit + push を一括（爆速保存） |
| `zgit --sync` | stash → pull(rebase) → pop → push（端末切替時） |
| `zgit --info` | ブランチ・リモート・未コミット変更 + `git fsck` 健全性チェック |
| `zgit --config` | base パスの解決結果を表示 |
| `zgit --log` | コミット履歴をツリー表示 |
| `zgit --push` / `--pull` | 現在のブランチの push / pull |
| `zgit --rename` / `--delete` | Drive 上のリポジトリ名変更 / 削除 |
| `zgit <git コマンド>` | 標準 git として透過実行 |

### 健全性チェック（v2.1）

Drive 同期による git オブジェクトの破損を `zgit --info` が `git fsck` で早期検出します。大規模リポジトリで不要な場合は `ZGIT_NO_FSCK=1 zgit --info` でスキップできます。

## License

MIT — see [LICENSE](LICENSE).