#!/usr/bin/env bash
set -euo pipefail

# Always read prompts from the real terminal (even when piped)
prompt() { local var="$1" msg="$2" silent="${3:-0}"; 
  if [ "$silent" = "1" ]; then
    read -r -s -p "$msg" "$var" < /dev/tty; echo
  else
    read -r -p "$msg" "$var" < /dev/tty
  fi
}

require_root() { [ "$(id -u)" -eq 0 ] || { echo "Run as root (use: sudo bash install.sh)"; exit 1; }; }
require_root

# Allow env overrides for non-interactive runs
SMTP_USER="${AIAGENT_FROM_EMAIL:-}"
SMTP_PASS="${AIAGENT_APP_PASSWORD:-}"
NOTIFY_TO="${AIAGENT_NOTIFY_TO:-}"
SERVER_NAME="${AIAGENT_SERVER_NAME:-}"

# Prompt only if not provided via env
[ -n "$SMTP_USER" ] || prompt SMTP_USER "From email (Workspace/Gmail): "
[ -n "$SMTP_PASS" ] || prompt SMTP_PASS  "App Password for ${SMTP_USER} (16 chars): " 1
[ -n "$NOTIFY_TO" ] || { prompt NOTIFY_TO "Notification recipient (blank = same): "; NOTIFY_TO="${NOTIFY_TO:-$SMTP_USER}"; }
[ -n "$SERVER_NAME" ] || { DEF=$(hostname -f 2>/dev/null || hostname); prompt SERVER_NAME "Server name shown in subjects [${DEF}]: "; SERVER_NAME="${SERVER_NAME:-$DEF}"; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y msmtp msmtp-mta mailutils ca-certificates

install -d -m 0755 /etc/aiagent-mail

cat > /etc/aiagent-mail/notify.conf <<EOF
TO="${NOTIFY_TO}"
FROM="${SMTP_USER}"
SERVER="${SERVER_NAME}"
EOF
chmod 0644 /etc/aiagent-mail/notify.conf

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

echo 'set sendmail=/usr/bin/msmtp -a default -t' > /etc/mail.rc

# Reboot notifier
cat > /usr/local/sbin/notify-reboot.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/aiagent-mail/notify.conf"; [ -f "$CONF" ] && . "$CONF"
TO="${TO:-root@localhost}"; FROM="${FROM:-root@localhost}"; SERVER="${SERVER:-$(hostname)}"
UPTIME=$(uptime -p || true); BOOT=$(who -b 2>/dev/null | awk '{print $3, $4}' || date -Is)
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
BODY=$(printf "Server: %s\nTime: %s\nUptime: %s\nLast Boot: %s\nIPv4: %s\nKernel: %s\n" "$SERVER" "$(date -Is)" "$UPTIME" "$BOOT" "${IP:-n/a}" "$(uname -r)")
printf "To: %s\nFrom: %s\nSubject: [%s] Rebooted\n\n%s\n" "$TO" "$FROM" "$SERVER" "$BODY" | msmtp -t
SH
chmod +x /usr/local/sbin/notify-reboot.sh

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

# Upgrade notifier
cat > /usr/local/sbin/apt-auto-upgrade-and-notify.sh <<'AUG'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
CONF="/etc/aiagent-mail/notify.conf"; [ -f "$CONF" ] && . "$CONF"
SERVER="${SERVER:-$(hostname)}"; TO="${TO:-root@localhost}"; FROM="${FROM:-root@localhost}"
LOG="/var/log/apt-auto-upgrade.log"
BEFORE=$(apt list --upgradable 2>/dev/null | awk -F/ 'NR>1{print $1}')
START="$(date -Iseconds)"; { echo "== ${START} : starting update on ${SERVER} =="; echo "Pending before: $(wc -w<<<\"$BEFORE\") -> $BEFORE"; } >> "$LOG"
apt-get update -qq
apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
apt-get -y autoremove --purge
apt-get -y autoclean
AFTER=$(apt list --upgradable 2>/dev/null | awk -F/ 'NR>1{print $1}')
REQ="no"; [ -f /var/run/reboot-required ] && REQ="yes"
END="$(date -Iseconds)"; { echo "Pending after : $(wc -w<<<\"$AFTER\") -> $AFTER"; echo "Reboot required: ${REQ}"; echo "== ${END} : update finished =="; echo; } >> "$LOG"
SUMMARY=$(printf "%s\n\nPending before (%s): %s\n\nPending after (%s): %s\n\nReboot required: %s\nLog: %s\n" "Apt auto-upgrade summary for ${SERVER}" "$(wc -w<<<\"$BEFORE\")" "${BEFORE:-<none>}" "$(wc -w<<<\"$AFTER\")"  "${AFTER:-<none>}" "${REQ}" "$LOG")
printf "To: %s\nFrom: %s\nSubject: [%s] Apt auto-upgrade completed\n\n%s\n" "$TO" "$FROM" "$SERVER" "$SUMMARY" | msmtp -t
AUG
chmod +x /usr/local/sbin/apt-auto-upgrade-and-notify.sh

# Helper CLI
cat > /usr/local/bin/aiagent-mail <<'CLI'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/aiagent-mail/notify.conf"
usage(){ cat <<USAGE
aiagent-mail commands:
  test                 Send a test email
  reconfigure          Prompt and update SMTP + recipient
  upgrade-now          Run apt upgrade and email summary
  schedule-weekly      Cron: Wed 02:30 upgrade + email
  enable-reboot-mail   Enable reboot email service
  disable-reboot-mail  Disable reboot email service
  uninstall            Remove notifiers and config (keeps packages)
USAGE
}
cmd="${1:-}"; case "$cmd" in
test)
  . "$CONF" 2>/dev/null || true; TO="${TO:-root@localhost}"; FROM="${FROM:-root@localhost}"; SERVER="${SERVER:-$(hostname)}"
  printf "To: %s\nFrom: %s\nSubject: [%s] aiagent-mail test\n\nSent at %s\n" "$TO" "$FROM" "$SERVER" "$(date -Is)" | msmtp -t
  echo "Test sent to $TO"
;;
reconfigure)
  prompt(){ local var="$1" msg="$2" silent="${3:-0}"; if [ "$silent" = "1" ]; then read -r -s -p "$msg" "$var" < /dev/tty; echo; else read -r -p "$msg" "$var" < /dev/tty; fi; }
  DEF_SERVER=$(hostname -f 2>/dev/null || hostname)
  prompt SMTP_USER "From email: "; prompt SMTP_PASS "App Password for ${SMTP_USER}: " 1
  prompt NOTIFY_TO "Notification recipient (blank = same): "; [ -z "${NOTIFY_TO}" ] && NOTIFY_TO="$SMTP_USER"
  prompt SERVER "Server name [${DEF_SERVER}]: "; SERVER="${SERVER:-$DEF_SERVER}"
  cat > "$CONF" <<EOF
TO="${NOTIFY_TO}"
FROM="${SMTP_USER}"
SERVER="${SERVER}"
EOF
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
  chmod 600 /root/.msmtprc; touch /var/log/msmtp.log && chown root:adm /var/log/msmtp.log && chmod 640 /var/log/msmtp.log
  echo "Updated config."
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
  systemctl enable --now reboot-notify.service; echo "Enabled reboot-notify.service"
;;
disable-reboot-mail)
  systemctl disable --now reboot-notify.service; echo "Disabled reboot-notify.service"
;;
uninstall)
  systemctl disable --now reboot-notify.service 2>/dev/null || true
  rm -f /etc/systemd/system/reboot-notify.service; systemctl daemon-reload
  rm -f /usr/local/sbin/notify-reboot.sh /usr/local/sbin/apt-auto-upgrade-and-notify.sh
  rm -f /usr/local/bin/aiagent-mail /etc/aiagent-mail/notify.conf
  echo "Uninstalled (packages remain)."
;;
*) usage; exit 1;;
esac
CLI
chmod +x /usr/local/bin/aiagent-mail

# Smoke test
. /etc/aiagent-mail/notify.conf
printf "To: %s\nFrom: %s\nSubject: [%s] SMTP setup test\n\nInstaller test at %s\n" "$TO" "$FROM" "$SERVER" "$(date -Is)" | msmtp -t || true

echo "Done. Try:  sudo aiagent-mail test"
