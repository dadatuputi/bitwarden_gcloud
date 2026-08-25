#!/usr/bin/env sh
#
# Install the COS staged-update reboot timer. Run once. Needs sudo.

set -eu

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR=/var/lib/bitwarden_gcloud
UNIT_DIR=/etc/systemd/system

sudo mkdir -p "$INSTALL_DIR"
sudo install -m 0755 "$SRC_DIR/cos-update-reboot.sh" "$INSTALL_DIR/cos-update-reboot.sh"
sudo install -m 0644 "$SRC_DIR/cos-update-reboot.service" "$UNIT_DIR/cos-update-reboot.service"
sudo install -m 0644 "$SRC_DIR/cos-update-reboot.timer" "$UNIT_DIR/cos-update-reboot.timer"

sudo systemctl daemon-reload
sudo systemctl enable --now cos-update-reboot.timer

echo
echo "Installed. Next scheduled run:"
systemctl list-timers cos-update-reboot.timer --no-pager
