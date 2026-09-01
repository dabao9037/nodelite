#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

make_runner() {
  local runner="$1"
  mkdir -p "$(dirname "$runner")"
  sed '/^command="${1:-}"/,$d' "$ROOT/install.sh" >"$runner"
  cat >>"$runner" <<'EOF'
save_installer "$TEST_DESTINATION"
EOF
  chmod 0755 "$runner"
}

# Exact installed-menu update case: /opt/nodelite/install.sh is commonly run
# from its own directory as `bash install.sh`, making BASH_SOURCE relative while
# INSTALL_DIR/install.sh is absolute. They are the same path/inode even though
# the strings differ. The pre-fix installer dies here with a same-file error.
SAME_DIR="$TMP/same-path"
SAME_RUNNER="$SAME_DIR/install.sh"
make_runner "$SAME_RUNNER"
same_hash="$(sha256sum "$SAME_RUNNER" | awk '{print $1}')"
same_inode="$(stat -c '%d:%i' "$SAME_RUNNER")"
(
  cd "$SAME_DIR"
  TEST_DESTINATION="$SAME_RUNNER" bash install.sh
)
test "$same_hash" = "$(sha256sum "$SAME_RUNNER" | awk '{print $1}')"
test "$same_inode" = "$(stat -c '%d:%i' "$SAME_RUNNER")"

# Different path, same inode: a hard link must also be recognized as the same
# file, rather than being replaced by install(1).
INODE_DIR="$TMP/same-inode"
INODE_RUNNER="$INODE_DIR/source.sh"
INODE_DEST="$INODE_DIR/destination.sh"
make_runner "$INODE_RUNNER"
ln "$INODE_RUNNER" "$INODE_DEST"
inode_before="$(stat -c '%d:%i' "$INODE_RUNNER")"
TEST_DESTINATION="$INODE_DEST" bash "$INODE_RUNNER"
test "$inode_before" = "$(stat -c '%d:%i' "$INODE_RUNNER")"
test "$inode_before" = "$(stat -c '%d:%i' "$INODE_DEST")"

# A genuinely different destination must still receive a real executable copy.
COPY_DIR="$TMP/different"
COPY_RUNNER="$COPY_DIR/source.sh"
COPY_DEST="$COPY_DIR/copy/install.sh"
make_runner "$COPY_RUNNER"
copy_hash="$(sha256sum "$COPY_RUNNER" | awk '{print $1}')"
copy_inode="$(stat -c '%d:%i' "$COPY_RUNNER")"
TEST_DESTINATION="$COPY_DEST" bash "$COPY_RUNNER"
test -x "$COPY_DEST"
test "$copy_hash" = "$(sha256sum "$COPY_DEST" | awk '{print $1}')"
test "$copy_inode" != "$(stat -c '%d:%i' "$COPY_DEST")"
bash -n "$COPY_DEST"

printf 'INSTALLER_SAME_FILE_AND_DISTINCT_COPY_OK\n'
