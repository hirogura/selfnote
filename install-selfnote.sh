#!/bin/bash
set -e

# ファイルから直接実行された場合、スクリプト自身をダウンロードで上書きしながら
# 実行すると壊れるため、一時コピーから再実行する (curl | bash の場合は対象外)
if [ -z "${_SELFNOTE_REEXEC:-}" ] && [ -f "$0" ]; then
  export _SELFNOTE_REEXEC=1
  export _SELFNOTE_TMP
  _SELFNOTE_TMP=$(mktemp /tmp/selfnote-install.XXXXXX.sh)
  cp "$0" "$_SELFNOTE_TMP"
  exec bash "$_SELFNOTE_TMP" "$@"
fi
if [ -n "${_SELFNOTE_TMP:-}" ]; then
  trap 'rm -f "$_SELFNOTE_TMP"' EXIT
fi

INSTALL_DIR="/opt/selfnote"
DATA_DIR="/opt/lxd-data/note"
PORT=3342
TAILSCALE_PORT=3342
REPO="https://raw.githubusercontent.com/hirogura/selfnote/main"

echo "🔧 SelfNote インストール開始..."

if ! command -v node &>/dev/null; then
  echo "📦 Node.js インストール中..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi

echo "Node.js: $(node -v)"

mkdir -p "$INSTALL_DIR/public"
mkdir -p "$DATA_DIR"

DATA_BACKUP=""
DATA_REBUILT=""

# データディレクトリの権限修復。
# LXD 共有マウント等では GID がコンテナの userns にマップされていない
# (例: nogroup) と root でも書き込めないため、所有者の主グループに付け直す。
fix_data_dir() {
  local owner grp
  owner=$(stat -c %U "$DATA_DIR" 2>/dev/null || true)
  if [ -n "$owner" ] && [ "$owner" != "UNKNOWN" ] && id "$owner" &>/dev/null; then
    grp=$(id -gn "$owner" 2>/dev/null || true)
    if [ -n "$grp" ]; then
      # 所有者自身の権限で付け直す (root からの chown は不可の場合があるため)
      sudo -u "$owner" chown "$owner:$grp" "$DATA_DIR" 2>/dev/null || \
        chown "$owner:$grp" "$DATA_DIR" 2>/dev/null || true
    fi
  fi
  chown root:root "$DATA_DIR" 2>/dev/null || true
  chmod 755 "$DATA_DIR" 2>/dev/null || true
}

# 所有者 UID がコンテナの userns にマップされていない場合 (nobody/UNKNOWN と表示される)、
# コンテナ内 root でも chown/chmod は EPERM となり、書けも消せもしない。
# 一方で親ディレクトリ (例: /opt/lxd-data) は root で書き換えられることが多いので、
# 既存ディレクトリを退避して新しいディレクトリを作り直し、中身をコピーする。
rebuild_data_dir() {
  local backup
  backup="${DATA_DIR}.orphan-$(date +%Y%m%d%H%M%S)"
  if ! mv "$DATA_DIR" "$backup" 2>/dev/null; then
    return 1
  fi
  if ! mkdir -p "$DATA_DIR" 2>/dev/null; then
    mv "$backup" "$DATA_DIR" 2>/dev/null || true
    return 1
  fi
  chown root:root "$DATA_DIR" 2>/dev/null || true
  chmod 755 "$DATA_DIR" 2>/dev/null || true
  # 退避先の中身をコピー (所有権は引き継がず、新しい root 所有に揃える)
  cp -r --preserve=mode,timestamps "$backup/." "$DATA_DIR/" 2>/dev/null || true
  chown -R root:root "$DATA_DIR" 2>/dev/null || true
  # コピーで元ディレクトリのモードが付く場合があるので、書き込み可能に戻す
  chmod 755 "$DATA_DIR" 2>/dev/null || true
  DATA_REBUILT=1
  # 片付けられる場合は片付ける (userns 未マップだと中身を消せず残る)
  rm -rf "$backup" 2>/dev/null || true
  if [ -e "$backup" ]; then
    DATA_BACKUP="$backup"
  fi
  return 0
}

if ! touch "$DATA_DIR/.write-test" 2>/dev/null; then
  echo "⚠️  $DATA_DIR への書き込みに失敗しました。権限の修復を試みます..."
  fix_data_dir
  if ! touch "$DATA_DIR/.write-test" 2>/dev/null; then
    echo "  → 所有者がコンテナの userns にマップされていないため、ディレクトリを作り直します..."
    if ! rebuild_data_dir; then
      echo "❌ $DATA_DIR への書き込みに失敗しました (権限/UID squashing等の可能性)。インストールを中止します。"
      echo "   ヒント: LXD ホスト側で 'sudo chown 1000000:1000000 $DATA_DIR' 等を実行して所有者を修復してください。"
      exit 1
    fi
  fi
  if ! touch "$DATA_DIR/.write-test" 2>/dev/null; then
    echo "❌ $DATA_DIR への書き込みに失敗しました (権限/UID squashing等の可能性)。インストールを中止します。"
    echo "   ヒント: $DATA_DIR の所有者・グループがこの環境に存在するユーザーか確認してください。"
    exit 1
  fi
  if [ -n "$DATA_REBUILT" ]; then
    echo "  ✓ $DATA_DIR を作り直して権限を修復しました"
    if [ -n "$DATA_BACKUP" ]; then
      echo "    旧ディレクトリ: $DATA_BACKUP (中身はコピー済み。不要なら LXD ホスト側で削除してください)"
    fi
  else
    echo "  ✓ $DATA_DIR の権限を修復しました"
  fi
fi
rm -f "$DATA_DIR/.write-test"

systemctl stop selfnote 2>/dev/null || true

echo "📥 ファイルを取得中..."
for f in public/favicon.svg server.js package.json public/index.html install-selfnote.sh; do
  echo "  -> $f"
  curl -fsSL "$REPO/$f" -o "$INSTALL_DIR/$f"
done
chmod +x "$INSTALL_DIR/install-selfnote.sh"

echo "📥 アイコンファイルを取得中..."
for f in public/selfnote-icon.png; do
  if curl -fsSL --connect-timeout 10 --max-time 30 "$REPO/$f" -o "$INSTALL_DIR/$f"; then
    echo "  -> $f OK"
  else
    echo "  -> $f スキップ（まだリポジトリにありません）"
  fi
done

node --check "$INSTALL_DIR/server.js"

cat > /etc/systemd/system/selfnote.service <<EOF
[Unit]
Description=SelfNote v1.5.2 Markdown Editor
After=network.target

[Service]
Type=simple
ExecStart=$(which node) $INSTALL_DIR/server.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable selfnote
systemctl start selfnote

echo ""
echo "==> tailscale serve を設定..."

if command -v tailscale &>/dev/null; then
  tailscale serve --https=${TAILSCALE_PORT} off 2>/dev/null || true
  tailscale serve --bg --https=${TAILSCALE_PORT} "http://127.0.0.1:${PORT}" || {
      echo "⚠️  tailscale serve の設定に失敗しました（手動で設定してください）"
      echo "     tailscale serve --bg --https=${TAILSCALE_PORT} http://127.0.0.1:${PORT}"
  }
  echo "  ✓ tailscale serve 設定完了"
else
  echo "  ⚠️  tailscale が見つかりません。tailscale serve の設定をスキップします"
fi

sleep 1
if systemctl is-active --quiet selfnote; then
  echo "  ✓ selfnote.service 起動確認OK"
  # アップデート完了を通知 (server.js の起動時クリアと二重化し、確実に polling を終わらせる)
  rm -f /tmp/selfnote-update.flag
else
  echo "  ⚠️  selfnote.service が起動していません。'journalctl -u selfnote -n 30' を確認してください"
fi

IP=$(hostname -I | awk '{print $1}')
HOSTNAME=$(hostname)
TAILSCALE_DOMAIN=$(tailscale status --json 2>/dev/null | grep -oP '"DNSName"\s*:\s*"[^"]*"' | head -1 | grep -oP '"[^"]*"$' | tr -d '"' | sed 's/\.$//')
if [ -z "$TAILSCALE_DOMAIN" ]; then
  TAILSCALE_DOMAIN="(tailscale未設定)"
fi

echo ""
echo "✅ SelfNote v1.5.2 インストール完了!"
echo ""
echo "URL: https://${TAILSCALE_DOMAIN}:${TAILSCALE_PORT}"
echo ""
echo "📁 データ: $DATA_DIR"
echo "📂 インストール: $INSTALL_DIR"
echo ""
echo "コマンド:"
echo "  systemctl start selfnote   # 起動"
echo "  systemctl stop selfnote    # 停止"
echo "  systemctl restart selfnote # 再起動"
echo "  journalctl -u selfnote -f  # ログ確認"