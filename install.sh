#!/usr/bin/env bash
set -euo pipefail

# Ubuntu email notify installer (msmtp + notifiers)
# - Prompts for Gmail/Workspace SMTP user + App Password + recipient
# - Creates /root/.msmtprc and /etc/aiagent-mail/notify.conf
# - Installs a reboot email service + apt upgrade notifier
# - Installs helper CLI: aiagent-mail

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root (use: sudo bash install.sh)"; exit 1
  fi
}
require_root

# --- Prompt ---
read -rp "From email (Workspace/Gmail sender, e.g. admin@example.com): " SMTP_USER
read -rsp "App Password for ${SMTP_USER} (16 chars): " SMTP_PASS; echo
read -rp "Notification recipient (press Enter to use the same address): " NOTIFY_TO
NOTIFY_TO=${NOTIFY_TO:-$SMTP_USER}
SERVER_NAME_DEFAULT=$(hostname -f 2>/dev/null || hostname)
read -rp "Server name to show in subjects [${SERVER_NAME_DEFAULT}]: " SERVER_NAME
SERVER_NAME=${SERVER_NAME:-$SERVER_NAME_DEFAULT}

echo "== Installing packages =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y msmtp msmtp-mta mailutils ca-certificates

echo "== Creating config directory =="
install -d -m 0755 /etc/aiagent-mail

echo "== Writing /etc/aiagent-mail/notify.conf =="
cat > /etc/aiagent-mail/notify.conf <<EOF
# aiagent-mail config
TO="${NOTIFY_TO}"
FROM="${SMTP_USER}"
SERVER="${SERVER_NAME}"
EOF
chmod 0644 /etc/aiagent-mail/notify.conf

echo "== Writing /root/.msmtprc =="
cat > /root/.msmtprc <<EOF
# msmtp config for root (system jobs)
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account gmail
host           smtp.gmail.com
port           587
from           ${SMTP_USER}
user           ${SMTP_USER}
password       ${SMTP_PASS}

account default : gmail
EOF
chmod 600 /root/.msmtprc

# Optional: allow non-root users to send with their own config later, but system jobs use root config.
touch /var/log/msmtp.log && chown root:adm /var/log/msmtp.log && chmod 640 /var/log/msmtp.log

# Make 'mail' call msmtp correctly (reads To: from headers)
echo 'set sendmail=/usr/bin/msmtp -a default -t' > /etc/mail.rc

echo "== Installing reboot notifier script =="
cat > /usr/local/sbin/notify-reboot.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/aiagent-mail/notify.conf"
[ -f "$CONF" ] && . "$CONF"
# Fallbacks if conf missing
TO="${TO:-root@localhost}"
FROM="${FROM:-root@localhost}"
SERVER="${SERVER:-$(hostname)}"
UPTIME=$(uptime -p || true)
BOOT_TIME=$(who -b 2>/dev/null | awk '{print $3, $4}' || date -Is)
IPV4=$(hostname -I 2>/dev/null | awk '{print $1}')
BODY=$(printf "Server: %s\nTime: %s\nUptime: %s\nLast Boot: %s\nIPv4: %s\nKernel: %s\n" \
  "$SERVER" "$(date -Is)" "$UPTIME" "$BOOT_TIME" "${IPV4:-n/a}" "$(uname -r)")
printf "To: %s\nFrom: %s\nSubject: [%s] Rebooted\n\n%s\n" "$TO" "$FROM" "$SERVER" "$BODY" | msmtp -t
SH
chmod +x /usr/local/sbin/notify-reboot.sh

echo "== Installing systemd unit for reboot notifier =="
cat > /etc/systemd/system/reboot-notify.service <<'UNIT'
[Unit]
Description=Email notification on reboot
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/notify-reboot.sh

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable reboot-notify.service

echo "== Installing apt auto-upgrade + email script =="
cat > /usr/local/sbin/apt-auto-upgrade-and-notify.sh <<'AUG'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
CONF="/etc/aiagent-mail/notify.conf"; [ -f "$CONF" ] && . "$CONF"
SERVER="${SERVER:-$(hostname)}"
TO="${TO:-root@localhost}"
FROM="${FROM:-root@localhost}"
LOG="/var/log/apt-auto-upgrade.log"

BEFORE=$(apt list --upgradable 2>/dev/null | awk -F/ 'NR>1{print $1}')
START="$(date -Iseconds)"
{
  echo "== ${START} : starting update on ${SERVER} =="
  echo "Pending before: $(wc -w<<<\"$BEFORE\") -> $BEFORE"
} >> "$LOG"

apt-get update -qq
apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
apt-get -y autoremove --purge
apt-get -y autoclean

AFTER=$(apt list --upgradable 2>/dev/null | awk -F/ 'NR>1{print $1}')
REBOOT_NEEDED="no"
[ -f /var/run/reboot-required ] && REBOOT_NEEDED="yes"
END="$(date -Iseconds)"
{
  echo "Pending after : $(wc -w<<<\"$AFTER\") -> $AFTER"
  echo "Reboot required: ${REBOOT_NEEDED}"
  echo "== ${END} : update finished =="
  echo
} >> "$LOG"

SUMMARY=$(printf "%s\n\nPending before (%s): %s\n\nPending after (%s): %s\n\nReboot required: %s\nLog: %s\n" \
  "Apt auto-upgrade summary for ${SERVER}" \
  "$(wc -w<<<\"$BEFORE\")" "${BEFORE:-<none>}" \
  "$(wc -w<<<\"$AFTER\")"  "${AFTER:-<none>}" \
  "${REBOOT_NEEDED}" "$LOG")

printf "To: %s\nFrom: %s\nSubject: [%s] Apt auto-upgrade completed\n\n%s\n" "$TO" "$FROM" "$SERVER" "$SUMMARY" | msmtp -t
AUG
chmod +x /usr/local/sbin/apt-auto-upgrade-and-notify.sh

echo "== Installing helper CLI: aiagent-mail =="
cat > /usr/local/bin/aiagent-mail <<'CLI'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/aiagent-mail/notify.conf"
usage() {
  cat <<USAGE
aiagent-mail commands:
  test                 Send a test message
  reconfigure          Re-run SMTP/recipient prompts and update configs
  upgrade-now          Run apt auto-upgrade and email summary
  schedule-weekly      Add root cron: Wed 02:30 upgrade + email
  enable-reboot-mail   Enable reboot email service
  disable-reboot-mail  Disable reboot email service
  uninstall            Remove notifiers and config (keeps packages)
USAGE
}
cmd="${1:-}"; case "$cmd" in
  test)
    . "$CONF" 2>/dev/null || true
    TO="${TO:-root@localhost}"; FROM="${FROM:-root@localhost}"
    SERVER="${SERVER:-$(hostname)}"
    printf "To: %s\nFrom: %s\nSubject: [%s] aiagent-mail test\n\nThis is a test sent at %s\n" \
      "$TO" "$FROM" "$SERVER" "$(date -Is)" | msmtp -t
    echo "Test sent to $TO"
  ;;
  reconfigure)
    read -rp "From email: " SMTP_USER
    read -rsp "App Password for ${SMTP_USER}: " SMTP_PASS; echo
    read -rp "Notification recipient (blank = same): " NOTIFY_TO
    [ -z "${NOTIFY_TO}" ] && NOTIFY_TO="$SMTP_USER"
    SERVER_NAME_DEFAULT=$(hostname -f 2>/dev/null || hostname)
    read -rp "Server name [${SERVER_NAME_DEFAULT}]: " SERVER
    SERVER="${SERVER:-$SERVER_NAME_DEFAULT}"
    echo "Updating /etc/aiagent-mail/notify.conf"
    cat > "$CONF" <<EOF
TO="${NOTIFY_TO}"
FROM="${SMTP_USER}"
SERVER="${SERVER}"
EOF
    echo "Updating /root/.msmtprc"
    cat > /root/.msmtprc <<EOF
defaults
auth on
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile /var/log/msmtp.log
account gmail
host smtp.gmail.com
port 587
from ${SMTP_USER}
user ${SMTP_USER}
password ${SMTP_PASS}
account default : gmail
EOF
    chmod 600 /root/.msmtprc
    touch /var/log/msmtp.log && chown root:adm /var/log/msmtp.log && chmod 640 /var/log/msmtp.log
    echo "Done."
  ;;
  upgrade-now)
    /usr/local/sbin/apt-auto-upgrade-and-notify.sh
  ;;
  schedule-weekly)
    line='30 2 * * 3 /usr/local/sbin/apt-auto-upgrade-and-notify.sh >> /var/log/apt-auto-upgrade.log 2>&1'
    ( crontab -l 2>/dev/null | grep -v 'apt-auto-upgrade-and-notify.sh' ; echo "$line" ) | crontab -
    echo "Scheduled: $line"
  ;;
  enable-reboot-mail)
    systemctl enable --now reboot-notify.service
    echo "Enabled reboot-notify.service"
  ;;
  disable-reboot-mail)
    systemctl disable --now reboot-notify.service
    echo "Disabled reboot-notify.service"
  ;;
  uninstall)
    systemctl disable --now reboot-notify.service 2>/dev/null || true
    rm -f /etc/systemd/system/reboot-notify.service
    systemctl daemon-reload
    rm -f /usr/local/sbin/notify-reboot.sh
    rm -f /usr/local/sbin/apt-auto-upgrade-and-notify.sh
    rm -f /usr/local/bin/aiagent-mail
    rm -f /etc/aiagent-mail/notify.conf
    echo "Uninstalled notifier files. (msmtp packages left installed.)"
  ;;
  *) usage; exit 1;;
esac
CLI
chmod +x /usr/local/bin/aiagent-mail

echo "== Sending SMTP setup test =="
. /etc/aiagent-mail/notify.conf
printf "To: %s\nFrom: %s\nSubject: [%s] SMTP setup test\n\nInstaller test at %s\n" \
  "$TO" "$FROM" "$SERVER" "$(date -Is)" | msmtp -t || true

echo
echo "✔ Setup complete."
echo "  • Reboot emails are enabled (service: reboot-notify.service)."
echo "  • Run a manual upgrade email now:    sudo aiagent-mail upgrade-now"
echo "  • Schedule weekly upgrades:          sudo aiagent-mail schedule-weekly"
echo "  • Send a quick test email:           sudo aiagent-mail test"
echo "  • Reconfigure SMTP/recipient later:  sudo aiagent-mail reconfigure"
echo
