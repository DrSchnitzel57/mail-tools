#!/usr/bin/env bash
# =====================================================================
#  ccmail.sh  -  CCDC Ubuntu Email box toolkit (webmail / mail.underpressure.local)
#  Postfix + Dovecot + Apache/Roundcube + SSSD(AD) + Roundcube DB on MSSQL
#
#  Usage:  sudo bash ccmail.sh <command>
#    first    START HERE at drop flag: passwd -> evict -> sshd -> disk -> backup -> recon -> fw -> check
#    recon    snapshot of the box to /root/ccdc/ (read-only)
#    backup   disguised, backdated, optionally encrypted backup of configs + Roundcube (+ mail if it fits)
#    evict    remove known planted backdoors (SSH keys, fake mod_coraza, rogue units) - asks first
#    passwd   zulu-compatible: root/ccdcuser1/ccdcuser2 by hand, everyone else from the team seed phrase
#    seedshow show the seed password for a user:  bash ccmail.sh seedshow sysadmin
#    sshd     harden sshd with a drop-in (keeps password auth for the scorer)
#    fw       iptables firewall with automatic 90s rollback if you lose access
#    fwoff    flush the firewall (emergency: scoring is down and you suspect the fw)
#    mail     audit + safe hardening of Postfix/Dovecot/Apache/Roundcube - asks first
#    hunt     re-runnable threat hunt (run every 15-20 min)
#    check    scoring health check of every dependency
#    disk     free disk space (root fs starts ~96% full)
#    restore  restore one piece:  bash ccmail.sh restore postfix|dovecot|apache2|roundcube|sssd|ssh|pam.d|list
#    rebase   accept current configs as the new baseline (after your own changes)
#    sqlpass  after Ben changes the roundcube SQL password: test it, update Roundcube, verify, undo if broken
#
#  Every change backs the file up to /root/ccdc/bak/ first. Nothing is deleted:
#  suspicious files are moved to /root/ccdc/quarantine/ for incident reports.
# =====================================================================

# ---------------------- EDIT THESE IF THE ENVIRONMENT CHANGED ----------------------
TEAM="${TEAM:-2}"
LAN="172.20.240.0/24"
DC_IP="172.20.240.100"          # AD + DNS
SQL_IP="172.20.240.120"         # MSSQL (Roundcube DB lives here)
SPLUNK_IP="172.20.240.20"       # Splunk indexer (9997) / syslog
MY_IP="172.20.240.15"
PUBLIC_IP="172.25.$((20+TEAM)).15"
ADMIN_USERS="root sysadmin ccdcuser1 ccdcuser2"     # local accounts we keep
IN_TCP="22,25,80,110,143,443,465,587,993,995"   # inbound scored/mail ports
ALLOW_WEB_OUT="${ALLOW_WEB_OUT:-1}"   # 1 = allow outbound 80/443 anywhere (apt, github). Set 0 after updates.
ALLOW_SMTP_OUT="${ALLOW_SMTP_OUT:-1}" # 1 = allow outbound 25 (mail relay to other hosts)
# -----------------------------------------------------------------------------------

D=/root/ccdc; BAK=$D/bak; Q=$D/quarantine; LOG=$D/changes.log
TS() { date +%Y%m%d-%H%M%S; }
R=$'\e[1;31m'; G=$'\e[1;32m'; Y=$'\e[1;33m'; B=$'\e[1;36m'; N=$'\e[0m'
say()  { echo "${B}[*]${N} $*"; }
ok()   { echo "${G}[+]${N} $*"; }
warn() { echo "${Y}[!]${N} $*"; }
bad()  { echo "${R}[X] $*${N}"; }
hdr()  { echo; echo "${B}==================== $* ====================${N}"; }
note() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }          # change log for injects/IR
ask()  { local a; read -r -p "${Y}[?]${N} $* ${Y}[y = yes, Enter = no]${N} " a; [[ $a =~ ^[Yy] ]]; }
tip()  { echo "    ${B}->${N} $*"; }                                # plain-English hint
stage() { # stage <n> <title> <what it does> <what you will be asked>
  echo; echo "${G}################################################################${N}"
  echo "${G}  STEP $1/8: $2${N}"; echo "${G}################################################################${N}"
  echo "  What it does : $3"; echo "  You'll answer: $4"
  read -r -p "  Press Enter to start this step (Ctrl-C quits safely) " _ 2>/dev/null </dev/tty || true; }
bk()   { [ -e "$1" ] || return 0; local t; t="$BAK$(dirname "$1")"; mkdir -p "$t"; cp -a "$1" "$t/$(basename "$1").$(TS)"; }
quar() { [ -e "$1" ] || return 0; mkdir -p "$Q"; local t; t="$Q/$(echo "$1" | tr / _).$(TS)"; mv "$1" "$t"; chmod 000 "$t"; warn "quarantined $1 -> $t"; note "QUARANTINE $1 -> $t"; }
have() { command -v "$1" >/dev/null 2>&1; }
port_up() { timeout 3 bash -c "</dev/tcp/$1/$2" 2>/dev/null; }
# package ownership: one index of every dpkg-owned file, with /usr merged away (works on 22.04 and 24.04)
OWNED=/root/ccdc/.owned
build_owned() { mkdir -p /root/ccdc; cat /var/lib/dpkg/info/*.list 2>/dev/null | sed -E 's#^/usr/#/#' | sort -u > "$OWNED"; }
owned() { [ -s "$OWNED" ] || build_owned; local p; p=$(readlink -f "$1" 2>/dev/null || echo "$1"); p=${p#/usr}; grep -qxF "$p" "$OWNED" || grep -qxF "${1#/usr}" "$OWNED"; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash $0 $*"; exit 1; }
mkdir -p "$D" "$BAK" "$Q"; chmod 700 "$D"; build_owned

# =============================== recon ===============================
cmd_recon() {
  local f="$D/recon-$(TS).txt"
  hdr "RECON -> $f"
  {
    echo "### host";      hostnamectl 2>/dev/null; uptime; date
    echo "### ip";        ip -br a; ip r; cat /etc/resolv.conf
    echo "### listening"; ss -tulpn
    echo "### established"; ss -tnp state established
    echo "### shell users"; awk -F: '$7!~/(nologin|false|sync)$/{print}' /etc/passwd
    echo "### uid0";      awk -F: '$3==0{print $1}' /etc/passwd
    echo "### sudo/admin groups"; getent group sudo admin wheel
    echo "### sudoers";   grep -rhv '^\s*#' /etc/sudoers /etc/sudoers.d/ 2>/dev/null | grep -v '^\s*$'
    echo "### authorized_keys"; for k in /root/.ssh/authorized_keys* /home/*/.ssh/authorized_keys* /etc/ssh/.ssh/* ; do [ -f "$k" ] && { echo "--- $k"; cat "$k"; }; done
    echo "### sshd effective"; sshd -T 2>/dev/null | grep -Ei 'permitroot|passwordauth|pubkey|authorizedkeys|allowusers|allowgroups|port '
    echo "### crontabs";  ls -la /etc/cron* /var/spool/cron/crontabs 2>/dev/null; cat /etc/crontab; for c in /var/spool/cron/crontabs/*; do [ -f "$c" ] && { echo "--- $c"; cat "$c"; }; done
    echo "### timers";    systemctl list-timers --all --no-pager
    echo "### running services"; systemctl list-units --type=service --state=running --no-pager
    echo "### unit files in /etc/systemd/system (not from packages)"; for u in /etc/systemd/system/*.service /lib/systemd/system/*.service; do owned "$u" || { echo "--- $u"; grep -E '^(Description|ExecStart)' "$u"; }; done
    echo "### ld.so.preload"; cat /etc/ld.so.preload 2>/dev/null
    echo "### apache modules"; apache2ctl -M 2>/dev/null; ls -la /etc/apache2/mods-enabled/
    echo "### apache sites"; ls -la /etc/apache2/sites-enabled/; cat /etc/apache2/sites-enabled/*.conf
    echo "### postfix -n"; postconf -n 2>/dev/null
    echo "### postfix master.cf (non-comment)"; grep -v '^\s*#' /etc/postfix/master.cf 2>/dev/null | grep -v '^\s*$'
    echo "### dovecot -n"; doveconf -n 2>/dev/null
    echo "### sssd"; cat /etc/sssd/sssd.conf 2>/dev/null; realm list 2>/dev/null
    echo "### pam modules in use"; grep -rhoE 'pam_[A-Za-z0-9_]+\.so' /etc/pam.d/ | sort | uniq -c
    echo "### pam_exec / pam_script lines"; grep -rnE 'pam_exec|pam_script' /etc/pam.d/
    echo "### unpackaged PAM modules"; for m in /lib/x86_64-linux-gnu/security/*.so; do owned "$m" || echo "UNPACKAGED $m"; done
    echo "### roundcube"; ls -la /opt/roundcube /opt/roundcube/plugins 2>/dev/null; grep -E "db_dsnw|des_key|plugins|enable_installer" /opt/roundcube/config/config.inc.php 2>/dev/null
    echo "### disk";      df -h; du -xsh /var/log /var/mail /var/spool/postfix /snap /var/lib/snapd /home 2>/dev/null
    echo "### procs";     ps auxf
    echo "### deleted-binary processes"; ls -l /proc/*/exe 2>/dev/null | grep deleted
    echo "### files changed in last 30 days (key dirs)"; find /etc /opt/roundcube /usr/lib/apache2 /usr/bin /usr/sbin /bin /sbin /usr/local /var/www /tmp /dev/shm -xdev -type f -mtime -30 2>/dev/null | grep -vE '^/etc/(ld.so.cache|machine-id)$' | head -300
    echo "### SUID outside usual"; find / -xdev -perm -4000 -type f 2>/dev/null | grep -vE '^/(usr/(bin|lib|libexec|sbin)|bin|sbin|snap)/'
  } > "$f" 2>&1
  ok "saved. Highlights:"
  echo "  shell users: $(awk -F: '$7!~/(nologin|false|sync)$/{printf $1" "}' /etc/passwd)"
  echo "  uid 0     : $(awk -F: '$3==0{printf $1" "}' /etc/passwd)"
  echo "  sudo grp  : $(getent group sudo | cut -d: -f4)"
  echo "  listening : $(ss -tlnH | awk '{print $4}' | sed 's/.*://' | sort -un | tr '\n' ' ')"
  echo "  disk /    : $(df -h / | awk 'NR==2{print $5" used, "$4" free"}')"
  grep -q . /etc/ld.so.preload 2>/dev/null && bad "/etc/ld.so.preload is NOT empty (rootkit indicator)"
  for k in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys /etc/ssh/.ssh/authorized_keys; do [ -s "$k" ] && bad "authorized_keys present: $k ($(wc -l <"$k") keys)"; done
  apache2ctl -M 2>/dev/null | grep -qi coraza && bad "Apache has a 'coraza' module loaded (planted backdoor last time)"
  note "recon saved to $f"
}

# =============================== disk ===============================
cmd_disk() {
  hdr "DISK"
  df -h /
  say "vacuuming journal to 50M"; journalctl --vacuum-size=50M 2>/dev/null | tail -1
  say "apt clean"; apt-get clean
  say "removing old compressed logs (*.gz)"; find /var/log -type f -name '*.gz' -delete 2>/dev/null
  if have snap; then
    say "removing disabled snap revisions"
    snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read -r s r; do snap remove "$s" --revision="$r" >/dev/null 2>&1 && echo "   removed $s rev $r"; done
    snap set system refresh.retain=2 2>/dev/null
    if snap list 2>/dev/null | grep -q '^powershell'; then
      ask "Remove the powershell snap (not needed for any scored service, frees ~200-300MB)?" && { snap remove --purge powershell && note "removed powershell snap"; }
    fi
  fi
  df -h /
  say "biggest dirs on / (top 10):"; du -xh / --max-depth=3 2>/dev/null | sort -rh | head -10
  local free; free=$(df --output=avail -m / | tail -1)
  [ "$free" -lt 1000 ] && warn "Less than 1GB free. Postfix rejects mail ('452 Insufficient system storage') when space is low. Keep digging."
  note "disk cleanup, free now ${free}MB"
}

# =============================== backup ===============================
# Backups are disguised as package docs in a RANDOM package folder each run, backdated to match
# nearby system files, optionally encrypted. Locations are only recorded in /root/ccdc/backup.list.
BK_DECOYS="libnss-sss-extra libpam-cracklib-data libgssapi-krb5-3 libsasl2-modules-gssapi liblmdb-utils libkrb5-doc-extra python3-ldap3-doc libverto-glib1"
BK_CONF="/etc/postfix /etc/dovecot /etc/apache2 /etc/ssl /etc/sssd /etc/pam.d /etc/ssh /etc/passwd /etc/shadow /etc/group /etc/sudoers /etc/sudoers.d /etc/aliases /etc/mailname /etc/krb5.conf /etc/hosts /etc/resolv.conf /etc/php /etc/systemd/system /etc/crontab /etc/cron.d /etc/chrony /etc/iptables"
bk_enc() { if [ -n "$BKPASS" ]; then openssl enc -aes-256-cbc -pbkdf2 -salt -pass env:BKPASS; else cat; fi; }
bk_dec() { if [ "$1" = 1 ]; then openssl enc -d -aes-256-cbc -pbkdf2 -pass env:BKPASS; else cat; fi; }
bk_hide() {  # backdate files + folders so nothing looks freshly made
  local ref=/usr/share/doc/bash/copyright; [ -e "$ref" ] || ref=/etc/hostname
  local f; for f in "$@"; do [ -e "$f" ] && touch -h -r "$ref" "$f"; done
}
cmd_backup() {
  hdr "BACKUP (disguised)"
  tip "Backups are saved as fake package docs with old timestamps. Optional passphrase encrypts them (configs contain the DB password)."
  tip "If you set a passphrase you MUST remember it to restore. Enter = no encryption."
  local a b2; BKPASS=""
  read -r -s -p "  Backup passphrase (Enter = none): " a </dev/tty 2>/dev/null; echo
  if [ -n "$a" ]; then read -r -s -p "  Confirm: " b2 </dev/tty 2>/dev/null; echo; [ "$a" = "$b2" ] && export BKPASS="$a" || { warn "didn't match - saving UNencrypted"; }; fi
  local enc=0; [ -n "$BKPASS" ] && enc=1
  local pkgs=($BK_DECOYS) pkg; pkg=${pkgs[$((RANDOM % ${#pkgs[@]}))]}
  local d1=/usr/share/doc/$pkg d2=/usr/share/locale/en_GB/LC_MESSAGES
  local t_doc t_d2; t_doc=$(stat -c %Y /usr/share/doc); mkdir -p "$d2"; t_d2=$(stat -c %Y "$d2")
  mkdir -p "$d1"; chmod 755 "$d1"
  # shellcheck disable=SC2086
  tar -czf - $BK_CONF 2>/dev/null | bk_enc > "$d1/changelog.Debian.gz" && ok "configs saved ($(du -h "$d1/changelog.Debian.gz" | cut -f1))"
  [ -d /opt/roundcube ] && tar -czf - --exclude='/opt/roundcube/temp/*' --exclude='/opt/roundcube/logs/*' /opt/roundcube 2>/dev/null | bk_enc > "$d1/NEWS.Debian.gz" && ok "roundcube saved ($(du -h "$d1/NEWS.Debian.gz" | cut -f1))"
  local mailpaths="" p
  for p in /var/mail /var/spool/mail /var/vmail /home/*/Maildir /home/*/mail; do [ -e "$p" ] && mailpaths="$mailpaths $p"; done
  if [ -n "$mailpaths" ]; then
    # shellcheck disable=SC2086
    local need; need=$(du -scm $mailpaths 2>/dev/null | tail -1 | cut -f1); local free; free=$(df --output=avail -m / | tail -1)
    if [ "$need" -lt $((free/2)) ]; then
      # shellcheck disable=SC2086
      tar -czf - $mailpaths 2>/dev/null | bk_enc > "$d1/README.Debian.gz" && ok "mail saved (${need}MB raw)"
    else warn "mail is ${need}MB, only ${free}MB free: skipped. Run 'disk' then 'backup' again."; fi
  fi
  printf 'This package provides extra documentation.\n' | gzip > "$d1/copyright.gz" 2>/dev/null
  cp "$d1/changelog.Debian.gz" "$d2/$pkg.mo"                     # second copy of configs
  chmod 644 "$d1"/* "$d2/$pkg.mo"
  bk_hide "$d1"/* "$d1" "$d2/$pkg.mo"
  touch -d "@$t_doc" /usr/share/doc; touch -d "@$t_d2" "$d2"       # parent folders keep their old times
  echo "$(date '+%H:%M')|$enc|$d1|$d2/$pkg.mo" >> "$D/backup.list"; chmod 600 "$D/backup.list"
  unset BKPASS
  # hash baseline for integrity checks in hunt
  find /opt/roundcube /etc/postfix /etc/dovecot /etc/apache2 /etc/pam.d /etc/ssh /usr/lib/apache2/modules -type f -not -path '*/temp/*' -not -path '*/logs/*' -exec sha256sum {} + 2>/dev/null > "$D/baseline.sha256"
  ss -tlnH | awk '{print $4}' | sort -u > "$D/baseline.ports"
  awk -F: '{print $1":"$3":"$7}' /etc/passwd | sort > "$D/baseline.passwd"
  ok "saved to: $d1/   (+ copy: $d2/$pkg.mo)   encrypted: $([ $enc = 1 ] && echo yes || echo no)"
  tip "Write the folder name ($pkg) on your team sheet. Restore with:  bash $0 restore"
  note "backup -> $d1 (enc=$enc)"
}

cmd_restore() {  # restore [postfix|dovecot|apache2|roundcube|sssd|ssh|pam.d|ssl|php|mail|list]
  hdr "RESTORE"
  [ -s "$D/backup.list" ] || { bad "no backups recorded in $D/backup.list"; return 1; }
  local i=0 line; echo "  Backups (1 = first = cleanest):"
  while IFS='|' read -r tm en d1 d2; do i=$((i+1)); echo "   $i) $tm  $d1  encrypted=$([ "$en" = 1 ] && echo yes || echo no)"; done < "$D/backup.list"
  local n=1; [ "$i" -gt 1 ] && { read -r -p "  Which backup? [1]: " n; n=${n:-1}; }
  line=$(sed -n "${n}p" "$D/backup.list"); [ -n "$line" ] || { bad "no backup #$n"; return 1; }
  local tm en d1 d2; IFS='|' read -r tm en d1 d2 <<<"$line"
  local what=$2
  if [ -z "$what" ]; then
    echo "  What to restore: postfix dovecot apache2 roundcube sssd ssh pam.d ssl php mail list"
    read -r -p "  Type one: " what
  fi
  local arch="$d1/changelog.Debian.gz" path svc
  case "$what" in
    postfix) path=etc/postfix; svc=postfix;;  dovecot) path=etc/dovecot; svc=dovecot;;
    apache2) path=etc/apache2; svc=apache2;;  sssd) path=etc/sssd; svc=sssd;;
    ssh) path=etc/ssh; svc=ssh;;  pam.d) path=etc/pam.d;;  ssl) path=etc/ssl; svc=apache2;;  php) path=etc/php; svc=apache2;;
    roundcube) arch="$d1/NEWS.Debian.gz"; path=opt/roundcube; svc=apache2;;
    mail) arch="$d1/README.Debian.gz"; path="";;
    list) ;;
    *) bad "unknown: $what"; return 1;;
  esac
  [ -s "$arch" ] || { [ "$arch" = "$d1/changelog.Debian.gz" ] && [ -s "$d2" ] && arch=$d2 && warn "main copy missing, using second copy $d2"; }
  [ -s "$arch" ] || { bad "backup file missing: $arch (red team may have deleted it)"; return 1; }
  if [ "$en" = 1 ]; then read -r -s -p "  Backup passphrase: " BKPASS; echo; export BKPASS; fi
  bk_dec "$en" < "$arch" | tar -tzf - >/dev/null 2>&1 || { bad "can't open the backup (wrong passphrase?)"; unset BKPASS; return 1; }
  if [ "$what" = list ]; then bk_dec "$en" < "$arch" | tar -tzf - | awk -F/ '{print $1"/"$2}' | sort -u; unset BKPASS; return; fi
  # save current state first so this restore can be undone
  [ -n "$path" ] && [ -e "/$path" ] && tar -czf "$BAK/pre-restore-${what}-$(TS).tgz" "/$path" 2>/dev/null && ok "current /$path saved to $BAK/pre-restore-${what}-*.tgz (undo)"
  if [ -n "$path" ]; then bk_dec "$en" < "$arch" | tar -xzf - -C / "$path"; else bk_dec "$en" < "$arch" | tar -xzf - -C /; fi \
    && ok "restored ${path:-mail} from backup $n ($tm)" && note "RESTORED $what from $d1"
  unset BKPASS
  case "$svc" in
    apache2) apache2ctl configtest && systemctl restart apache2 && ok "apache2 restarted";;
    ssh) sshd -t && systemctl restart ssh && ok "ssh restarted";;
    "") ;;
    *) systemctl restart "$svc" && ok "$svc restarted" || bad "$svc failed to restart: journalctl -u $svc -n 30";;
  esac
  tip "Run: bash $0 check"
}

# =============================== evict ===============================
cmd_evict() {
  hdr "EVICT KNOWN BACKDOORS"
  # 1. SSH keys (last time: kali@transistor in root + sysadmin)
  local k
  for k in /root/.ssh/authorized_keys* /home/*/.ssh/authorized_keys* /etc/ssh/.ssh/authorized_keys*; do
    [ -s "$k" ] || continue
    bad "$k:"; awk '{print "     "$1" ..."substr($2,length($2)-12)" "$3}' "$k"
    tip "These keys let someone log in with no password. Say y unless YOU put this key there (last time: kali@transistor = red team)."
    if ask "Quarantine $k (removes all keys in it)?"; then quar "$k"; fi
  done
  # 2. sshd AuthorizedKeysFile redirection
  sshd -T 2>/dev/null | grep -i '^authorizedkeysfile' | grep -vq '\.ssh/authorized_keys' && bad "sshd AuthorizedKeysFile is non-standard: $(sshd -T | grep -i authorizedkeysfile). Run: ccmail.sh sshd"
  # 3. fake Apache modules
  local m found=0
  for m in /etc/apache2/mods-enabled/*.load; do
    local so; so=$(awk '/LoadModule/{print $3}' "$m" 2>/dev/null)
    [ -n "$so" ] || continue
    [[ $so != /* ]] && so="/usr/lib/apache2/$so"
    if [ -f "$so" ] && ! owned "$so"; then
      found=1; bad "Apache module NOT from any package: $m -> $so"
      tip "Real Apache modules always come from packages. Last time a fake one (coraza) was a backdoor. Say y."
      if ask "Disable and quarantine it?"; then
        local name; name=$(basename "$m" .load)
        a2dismod -f "$name" >/dev/null 2>&1; quar "$so"; quar "/etc/apache2/mods-available/$name.load"; quar "/etc/apache2/mods-available/$name.conf"
        apache2ctl configtest && systemctl restart apache2 && ok "apache restarted" || bad "apache configtest failed - check: apache2ctl configtest"
      fi
    fi
  done
  [ $found = 0 ] && ok "all enabled Apache modules belong to packages (good)"
  # 4. systemd units not owned by packages
  local u
  for u in /etc/systemd/system/*.service /lib/systemd/system/*.service; do
    [ -f "$u" ] || continue; [ -L "$u" ] && continue
    owned "$u" && continue
    local ex; ex=$(grep -m1 '^ExecStart' "$u" | cut -d= -f2-)
    warn "unpackaged unit: $u"; echo "     $(grep -m1 '^Description' "$u")"; echo "     ExecStart=$ex"
    case "$(basename "$u")" in snap*|cloud*|sssd*|splunk*|Splunk*) tip "known-good ($(basename "$u")), skipping"; continue;; esac
    tip "A service that no package installed. Say y if it isn't something your team added (Splunk/SSSD are skipped automatically). Red team names look like OS daemons: net-pathd, rt-tagd, irqbalance-daemon."
    if ask "Stop, disable and quarantine $(basename "$u") and its binary?"; then
      local svc; svc=$(basename "$u"); systemctl disable --now "$svc" 2>/dev/null; note "disabled $svc"
      local bin; bin=$(echo "$ex" | awk '{print $1}' | sed 's/^[-@+!]*//')
      [ -f "$bin" ] && ! owned "$bin" && quar "$bin"
      quar "$u"; systemctl daemon-reload
    fi
  done
  # 4b. PAM backdoors (credential stealers like 'pamspam' on Splunk last time)
  local m2; for m2 in /lib/x86_64-linux-gnu/security/*.so; do owned "$m2" || { bad "UNPACKAGED PAM module: $m2"; grep -rln "$(basename "$m2")" /etc/pam.d/ | sed 's/^/     used in: /'; warn "     fix: remove its line from those /etc/pam.d files (bk first), then quarantine the .so"; }; done
  grep -rnE 'pam_exec|pam_script' /etc/pam.d/ && bad "^ pam_exec lines above run a program on every login - inspect"
  # 5. ld.so.preload
  grep -q . /etc/ld.so.preload 2>/dev/null && { bad "/etc/ld.so.preload: $(cat /etc/ld.so.preload)"; ask "Quarantine /etc/ld.so.preload?" && quar /etc/ld.so.preload; }
  # 6. extra uid-0 users / unexpected sudo members
  awk -F: '$3==0 && $1!="root"{print $1}' /etc/passwd | while read -r x; do bad "extra UID 0 user: $x  -> fix: usermod -L -s /usr/sbin/nologin $x"; done
  say "sudo group members: $(getent group sudo | cut -d: -f4)  (expected: sysadmin,ccdcuser1)"
  # 7. suspicious tmp binaries
  find /tmp /var/tmp /dev/shm -xdev -type f \( -perm -100 -o -name '*.bak' -o -name '.*' \) 2>/dev/null | head -20 | while read -r x; do warn "exec/hidden file in tmp: $x ($(file -b "$x" | cut -c1-50))"; done
  # 8. root history reminder
  say "Check: cat /root/.bash_history /home/*/.bash_history  (last time it showed the attacker's exact commands)"
  note "evict run"
}

# =============================== passwd ===============================
# Seed-phrase passwords: byte-for-byte the same algorithm as BYU zulu.sh, so the team can
# re-derive any password with zulu.sh -g (or: bash ccmail.sh seedshow <user>).
WORDLIST_URLS="https://raw.githubusercontent.com/BYU-CCDC/public-ccdc-resources/main/windows/hardening/wordlist.txt https://raw.githubusercontent.com/DrSchnitzel57/mail-tools/main/wordlist.txt"
WL=$D/wordlist.txt
get_wordlist() {
  [ -s "$WL" ] && return 0
  local u; for u in /root/wordlist.txt ./wordlist.txt; do [ -s "$u" ] && { tr -d '\r' < "$u" > "$WL"; return 0; }; done
  for u in $WORDLIST_URLS; do
    { wget -qO- "$u" 2>/dev/null || curl -fsSL "$u" 2>/dev/null; } | tr -d '\r' > "$WL.tmp"
    [ "$(wc -l < "$WL.tmp")" -gt 1000 ] && { mv "$WL.tmp" "$WL"; ok "wordlist downloaded ($(wc -l < "$WL") words)"; return 0; }
  done
  rm -f "$WL.tmp"; bad "couldn't get the zulu wordlist (no internet?). Put wordlist.txt in /root/ and re-run: bash $0 passwd"; return 1
}
zulu_pw() {  # zulu_pw <seed> <user>  -> prints password (5 words-1)
  local hash i hex dec idx pw="" b; hash=$(echo -n "$1$2" | md5sum); b=$(wc -l "$WL" | awk '{print $1-1}')
  for i in 0 4 8 12 16; do
    hex=${hash:$i:4}; dec=$((16#$hex))
    idx=$(awk -v x="$dec" -v b="$b" 'BEGIN{printf(int((0+((x-0)*(b-0))/(65535-0))))}')
    [ $i -ne 0 ] && pw+="-"; pw+=$(sed -n "$((idx+1))p" "$WL")
  done; echo "${pw}1"
}
read_seed() {  # sets SEED
  local a b2
  while true; do
    read -r -s -p "  Team seed phrase (same one you use with zulu): " a; echo
    read -r -s -p "  Confirm seed phrase: " b2; echo
    [ "$a" != "$b2" ] && { warn "didn't match, try again"; continue; }
    [ ${#a} -lt 8 ] && { warn "zulu requires at least 8 characters, try again"; continue; }
    SEED=$a; break
  done
}
set_pw_manual() {  # set_pw_manual <user>
  local p1 p2
  while true; do
    read -r -s -p "  New password for $1 (Enter = skip): " p1; echo
    [ -z "$p1" ] && { say "skipped $1"; return; }
    read -r -s -p "  Again: " p2; echo
    [ "$p1" = "$p2" ] && break; warn "didn't match, try again"
  done
  echo "$1:$p1" | chpasswd && ok "changed $1" && note "password changed: $1"
}
cmd_passwd() {
  hdr "PASSWORDS (zulu-compatible)"
  tip "Same as zulu -i: you type passwords for root, ccdcuser1, ccdcuser2. Every OTHER local login user (like sysadmin) gets a seed-phrase password."
  tip "Nothing shows while you type. Enter on an empty prompt skips that account."
  local u
  for u in ccdcuser1 ccdcuser2; do id "$u" >/dev/null 2>&1 || { useradd -m -s /bin/bash "$u" && ok "created $u" && note "created $u"; }; done
  usermod -aG sudo ccdcuser1 && ok "ccdcuser1 is in sudo (ccdcuser2 is a normal user, like zulu)"
  for u in root ccdcuser1 ccdcuser2; do set_pw_manual "$u"; done
  # everyone else with a login shell, exactly like zulu's user list (excludes root, ccdcuser1, ccdcuser2)
  local users; users=$(grep -v "false\|nologin" /etc/passwd | cut -d: -f1 | grep -vxE 'root|ccdcuser1|ccdcuser2')
  echo; say "Other local login users: $(echo $users)"
  if [ -n "$users" ] && ask "Give them seed-phrase passwords (team zulu scheme)?" < /dev/tty && get_wordlist; then
    read_seed < /dev/tty
    for u in $users; do
      echo "$u:$(zulu_pw "$SEED" "$u")" | chpasswd && ok "seed password set: $u" && note "seed password set: $u"
    done
    tip "sysadmin's password is now the SEED one, not what you typed by hand at minute 1."
    tip "To see any of them later:  bash $0 seedshow sysadmin     (or zulu.sh -g -u sysadmin on your laptop)"
    unset SEED
  elif [ -n "$users" ]; then
    say "No seed: set passwords by hand instead."
    for u in $users; do set_pw_manual "$u"; done
  fi
  say "Check sudo members: $(getent group sudo | cut -d: -f4)   (remove extras: gpasswd -d <user> sudo)"
  say "Scored mail users are AD accounts -> changed on the DC + PCR in Quotient (Savannah)."
  say "If SSH is scored with sysadmin and goes red after this: submit a PCR in Quotient with sysadmin's new password."
}
cmd_seedshow() {  # print the seed password for one or more users (doesn't change anything)
  [ -n "$2" ] || { echo "usage: bash $0 seedshow <user> [user...]"; return 1; }
  get_wordlist || return 1; read_seed; shift
  local u; for u in "$@"; do echo "  $u : $(zulu_pw "$SEED" "$u")"; done; unset SEED
}

# =============================== sshd ===============================
cmd_sshd() {
  hdr "SSHD"
  local f=/etc/ssh/sshd_config.d/00-ccdc.conf
  grep -q '^Include /etc/ssh/sshd_config.d' /etc/ssh/sshd_config || warn "sshd_config has no Include line; settings will be appended to sshd_config instead"
  bk /etc/ssh/sshd_config; bk "$f"
  cat > /tmp/ccdc-sshd.conf <<'EOF'
# CCDC hardening (first match wins, so this file must sort first)
PermitRootLogin no
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no
GatewayPorts no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
  if grep -q '^Include /etc/ssh/sshd_config.d' /etc/ssh/sshd_config; then cp /tmp/ccdc-sshd.conf "$f"
  else sed -i '1r /tmp/ccdc-sshd.conf' /etc/ssh/sshd_config; fi
  grep -rl 'AuthorizedKeysFile' /etc/ssh/sshd_config.d/ 2>/dev/null | grep -v 00-ccdc | while read -r x; do warn "other drop-in sets AuthorizedKeysFile: $x"; done
  if sshd -t; then systemctl restart ssh 2>/dev/null || systemctl restart sshd; ok "sshd hardened + restarted"; note "sshd hardened ($f)"
  else bad "sshd -t failed, reverting"; rm -f "$f"; fi
  sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|authorizedkeysfile|maxauthtries)'
  say "SSH stays open with passwords because a scored SSH check may use it. Optional lockdown: add 'AllowUsers sysadmin ccdcuser1' to $f ONLY if the team confirms SSH isn't scored on this box."
}

# =============================== firewall ===============================
cmd_fw() {
  hdr "FIREWALL (iptables)"
  have iptables || apt-get install -y iptables
  have ufw && ufw status 2>/dev/null | grep -q active && { ufw disable; note "ufw disabled"; }
  local pre_sql=0 pre_ad=0; port_up "$SQL_IP" 1433 && pre_sql=1; port_up "$DC_IP" 389 && pre_ad=1
  say "before firewall: MSSQL 1433 $([ $pre_sql = 1 ] && echo reachable || echo NOT reachable), AD 389 $([ $pre_ad = 1 ] && echo reachable || echo NOT reachable)"
  local save="$BAK/iptables.$(TS)"; iptables-save > "$save"; ok "old rules saved: $save"
  tip "Applying rules now. Your console session won't drop. A 90-second safety timer will UNDO everything unless you confirm below."
  # dead-man switch: auto-rollback in 90s unless confirmed
  setsid bash -c "sleep 90; iptables-restore < '$save'; iptables -P INPUT ACCEPT; iptables -P OUTPUT ACCEPT; echo 'ccmail: firewall ROLLED BACK' | wall" >/dev/null 2>&1 &
  local rb=$!
  local I="iptables"
  $I -P INPUT ACCEPT; $I -P OUTPUT ACCEPT; $I -P FORWARD ACCEPT; $I -F; $I -X
  # loopback (Roundcube -> local IMAP/SMTP), established, ICMP (ping is scored)
  $I -A INPUT  -i lo -j ACCEPT;  $I -A OUTPUT -o lo -j ACCEPT
  $I -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  $I -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  $I -A INPUT  -m conntrack --ctstate INVALID -j DROP
  $I -A INPUT  -p icmp -j ACCEPT; $I -A OUTPUT -p icmp -j ACCEPT
  # inbound: SSH with brute-force slowdown, then mail/web
  $I -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --set --name ssh
  $I -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 10 --name ssh -j DROP
  $I -A INPUT -p tcp -m multiport --dports "$IN_TCP" -j ACCEPT
  # outbound: DNS, NTP, AD (Kerberos/LDAP/GC/kpasswd/SMB for SSSD), MSSQL, Splunk
  $I -A OUTPUT -p udp --dport 53 -j ACCEPT; $I -A OUTPUT -p tcp --dport 53 -j ACCEPT
  $I -A OUTPUT -p udp --dport 123 -j ACCEPT
  $I -A OUTPUT -d "$DC_IP" -p tcp -m multiport --dports 88,135,389,445,464,636,3268,3269 -j ACCEPT
  $I -A OUTPUT -d "$DC_IP" -p udp -m multiport --dports 88,389,464 -j ACCEPT
  $I -A OUTPUT -d "$DC_IP" -p tcp --dport 49152:65535 -j ACCEPT
  $I -A OUTPUT -d "$SQL_IP" -p tcp --dport 1433 -j ACCEPT
  $I -A OUTPUT -d "$SPLUNK_IP" -p tcp -m multiport --dports 8089,9997 -j ACCEPT
  $I -A OUTPUT -d "$SPLUNK_IP" -p udp -m multiport --dports 514,5514 -j ACCEPT
  [ "$ALLOW_SMTP_OUT" = 1 ] && $I -A OUTPUT -p tcp -m multiport --dports 25,587 -j ACCEPT
  [ "$ALLOW_WEB_OUT" = 1 ]  && $I -A OUTPUT -p tcp -m multiport --dports 80,443 -j ACCEPT
  # log + drop the rest (rate-limited logs: journalctl -k | grep FW-)
  $I -A INPUT  -m limit --limit 6/min -j LOG --log-prefix "FW-IN-DROP " --log-level 4
  $I -A OUTPUT -m limit --limit 6/min -j LOG --log-prefix "FW-OUT-DROP " --log-level 4
  $I -P INPUT DROP; $I -P OUTPUT DROP; $I -P FORWARD DROP
  # IPv6: nothing scored uses it
  if have ip6tables; then
    ip6tables -F; ip6tables -A INPUT -i lo -j ACCEPT; ip6tables -A OUTPUT -o lo -j ACCEPT
    ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A INPUT -p ipv6-icmp -j ACCEPT; ip6tables -A OUTPUT -p ipv6-icmp -j ACCEPT
    ip6tables -P INPUT DROP; ip6tables -P FORWARD DROP; ip6tables -P OUTPUT DROP
  fi
  ok "rules applied. Self-test (after firewall):"
  local post_sql=0 post_ad=0; port_up "$SQL_IP" 1433 && post_sql=1; port_up "$DC_IP" 389 && post_ad=1
  [ $post_sql = 1 ] && ok "  MSSQL 1433 reachable" || bad "  MSSQL 1433 NOT reachable"
  [ $post_ad = 1 ]  && ok "  AD LDAP 389 reachable" || bad "  AD LDAP 389 NOT reachable"
  getent hosts dc.underpressure.local >/dev/null && ok "  DNS works" || warn "  DNS lookup of dc.underpressure.local failed"
  if [ $pre_sql -gt $post_sql ] || [ $pre_ad -gt $post_ad ]; then
    bad "  The firewall BROKE something that worked before. Type no (it undoes). Then check IPs at the top of the script."
  elif [ $post_sql = 1 ] && [ $post_ad = 1 ]; then
    ok "  Everything that worked before still works. ${G}Type yes.${N}"
  else
    warn "  Something was ALREADY unreachable before your firewall, so it's not your rules. ${Y}Type yes${N}, then tell Ben (MSSQL) / Savannah (AD) / Ava (Palo)."
  fi
  local a=""; read -r -t 80 -p "${Y}Type yes to keep the firewall (80s, anything else = undo): ${N}" a
  if [ "$a" = yes ]; then
    kill "$rb" 2>/dev/null; pkill -f "sleep 90; iptables-restore" 2>/dev/null
    mkdir -p /etc/iptables; iptables-save > /etc/iptables/rules.v4; have ip6tables && ip6tables-save > /etc/iptables/rules.v6
    if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
      echo iptables-persistent iptables-persistent/autosave_v4 boolean false | debconf-set-selections
      echo iptables-persistent iptables-persistent/autosave_v6 boolean false | debconf-set-selections
      DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null 2>&1 && ok "iptables-persistent installed (rules survive reboot)" || warn "couldn't install iptables-persistent; rules saved to /etc/iptables/rules.v4 - after reboot: iptables-restore < /etc/iptables/rules.v4"
    fi
    ok "firewall kept + saved"; note "firewall applied (in: $IN_TCP; web_out=$ALLOW_WEB_OUT smtp_out=$ALLOW_SMTP_OUT)"
  else
    warn "no confirmation - rolling back now"; kill "$rb" 2>/dev/null; iptables-restore < "$save"; iptables -P INPUT ACCEPT; iptables -P OUTPUT ACCEPT
  fi
}
cmd_fwoff() {
  iptables-save > "$BAK/iptables.beforeflush.$(TS)"
  iptables -P INPUT ACCEPT; iptables -P OUTPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -F
  have ip6tables && { ip6tables -P INPUT ACCEPT; ip6tables -P OUTPUT ACCEPT; ip6tables -F; }
  warn "firewall FLUSHED (allow all). Re-apply with: ccmail.sh fw"; note "firewall flushed"
}

# =============================== mail hardening ===============================
cmd_mail() {
  tip "Each fix asks first and validates the config before reloading. Red lines = something an attacker may have added."
  hdr "POSTFIX"
  if have postconf; then
    bk /etc/postfix/main.cf; bk /etc/postfix/master.cf
    echo "  mynetworks = $(postconf -h mynetworks)"
    postconf -h mynetworks | grep -qE '0\.0\.0\.0/0|::/0|172\.(16|25|31)\.' && bad "mynetworks is too wide (open relay)"
    postconf -h smtpd_relay_restrictions smtpd_recipient_restrictions | grep -q reject_unauth_destination || bad "no reject_unauth_destination -> possible open relay"
    local bccs; bccs=$(postconf -n | grep -E '^(always_bcc|sender_bcc_maps|recipient_bcc_maps|content_filter|smtpd_proxy_filter|header_checks|body_checks|smtpd_milters|non_smtpd_milters)')
    [ -n "$bccs" ] && { bad "mail copy/filter settings present (classic exfil/backdoor):"; echo "$bccs" | sed 's/^/     /'; }
    grep -vE '^\s*#|^\s*$' /etc/postfix/master.cf | grep -E 'pipe|argv=' | grep -vE 'argv=/usr/(lib/dovecot/deliver|bin/procmail|lib/dovecot/dovecot-lda|lib/postfix)' && bad "^ master.cf pipe transports above - check they're legit"
    if ask "Apply safe Postfix hardening (disable VRFY, hide version banner, require HELO, reject unauth destination)?"; then
      postconf -e 'disable_vrfy_command = yes' 'smtpd_banner = $myhostname ESMTP' 'smtpd_helo_required = yes'
      postconf -h smtpd_relay_restrictions | grep -q reject_unauth_destination || postconf -e 'smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination'
      postfix check && systemctl reload postfix && ok "postfix reloaded" && note "postfix: vrfy off, banner, helo required"
    fi
    [ -n "$bccs" ] && ask "Remove always_bcc / sender_bcc_maps / recipient_bcc_maps? (content_filter/milters: check manually)" && { postconf -X always_bcc sender_bcc_maps recipient_bcc_maps 2>/dev/null; systemctl reload postfix; note "removed bcc maps"; }
    echo "  queue: $(mailq 2>/dev/null | tail -1)"
  fi
  hdr "DOVECOT"
  if have doveconf; then
    doveconf -n | grep -E 'auth_debug|auth_verbose_passwords|auth_debug_passwords|auth_anonymous|mail_plugins|executable|post-login|^passdb|^userdb|driver|args' | sed 's/^/  /'
    local dbg; dbg=$(doveconf -n | grep -E '^(auth_debug_passwords|auth_verbose_passwords|auth_debug) = (yes|plain|sha1)')
    [ -n "$dbg" ] && bad "Dovecot is LOGGING PASSWORDS: $dbg"
    doveconf -n | grep -qiE 'executable *= *script-login|post-login' && bad "Dovecot post-login script configured - inspect it"
    if [ -n "$dbg" ] && ask "Turn off password logging in Dovecot?"; then
      bk /etc/dovecot/conf.d/10-logging.conf
      printf 'auth_debug = no\nauth_debug_passwords = no\nauth_verbose_passwords = no\n' > /etc/dovecot/conf.d/99-ccdc.conf
      doveconf -n >/dev/null && systemctl restart dovecot && ok "dovecot restarted" && note "dovecot password logging off"
    fi
    warn "Do NOT set disable_plaintext_auth=yes / ssl=required unless you know the scorer uses TLS - it may log in plaintext on 110/143."
  fi
  hdr "APACHE / ROUNDCUBE"
  if ask "Apply Apache info-leak hardening (ServerTokens Prod, ServerSignature Off, TraceEnable Off)?"; then
    bk /etc/apache2/conf-available/security.conf
    printf 'ServerTokens Prod\nServerSignature Off\nTraceEnable Off\n' > /etc/apache2/conf-available/zz-ccdc.conf
    a2enconf zz-ccdc >/dev/null; apache2ctl configtest && systemctl reload apache2 && ok "apache reloaded" && note "apache tokens/signature/trace off"
  fi
  local RC=/opt/roundcube CF=/opt/roundcube/config/config.inc.php
  if [ -f "$CF" ]; then
    [ -d $RC/installer ] && { bad "Roundcube installer dir exists (should never be live)"; ask "Quarantine $RC/installer?" && quar $RC/installer; }
    grep -q "enable_installer.*true" "$CF" && bad "enable_installer = true"
    if grep -q "CHANGE-ME-24-CHAR-DES-KEY" "$CF" && ask "Replace placeholder des_key with a random one (logs out active webmail sessions)?"; then
      bk "$CF"; local k; k=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
      sed -i "s|\$config\['des_key'\] = '[^']*';|\$config['des_key'] = '$k';|" "$CF" && ok "des_key changed" && note "roundcube des_key rotated"
    fi
    say "Roundcube plugins dir (expected only stock plugins; config enables: archive, zipdownload):"
    ls $RC/plugins | tr '\n' ' '; echo
    say "PHP files in writable/odd places:"; find $RC/temp $RC/logs $RC/public_html $RC/skins $RC/plugins -name '*.php*' -newer $RC/index.php 2>/dev/null | head -20
    grep -rlE 'eval\(\$_|base64_decode\(\$_|system\(\$_|passthru\(\$_|shell_exec\(\$_|assert\(\$_|eval\(base64' $RC --include='*.php' 2>/dev/null | head && bad "^ possible webshells above"
    chmod 640 "$CF"; chown root:www-data "$CF" 2>/dev/null
    say "config.inc.php DB line: $(grep db_dsnw "$CF" | sed -E 's/:[^:@]*@/:****@/')"
  fi
}

# =============================== sqlpass ===============================
cmd_sqlpass() {  # update Roundcube after Ben changes the 'roundcube' SQL login password on MSSQL
  hdr "ROUNDCUBE DATABASE PASSWORD"
  local CF=/opt/roundcube/config/config.inc.php
  [ -f "$CF" ] || { bad "$CF not found"; return 1; }
  local info; info=$(CF="$CF" python3 - <<'PY'
import os,re
s=open(os.environ['CF']).read()
m=re.search(r"\$config\['db_dsnw'\]\s*=\s*'([^']*)'",s)
if not m: print("NONE"); raise SystemExit
v=m.group(1); scheme,rest=v.split('://',1); cred,hp=rest.rsplit('@',1)
user=cred.split(':',1)[0]; host,_,db=hp.partition('/'); h,_,port=host.partition(':')
print(scheme,user,h,port or '1433',db)
PY
)
  [ "$info" = NONE ] || [ -z "$info" ] && { bad "couldn't find the db_dsnw line in $CF - edit it by hand (see guide)"; return 1; }
  local scheme user host port db; read -r scheme user host port db <<<"$info"
  say "Roundcube connects as SQL login '${user}' to ${host}:${port}, database '${db}'"
  tip "Do this right AFTER Ben runs ALTER LOGIN on MSSQL. Webmail is down between his change and yours, so be quick."
  tip "Ben should send the new password privately. Letters, numbers and dashes are easiest; other characters are encoded for you."
  local p1 p2
  while true; do
    read -r -s -p "  New password for SQL login '$user': " p1; echo
    [ -z "$p1" ] && { say "cancelled"; return 1; }
    read -r -s -p "  Again: " p2; echo
    [ "$p1" = "$p2" ] && break; warn "didn't match, try again"
  done
  # 1. test the password before touching anything
  if have php && php -m 2>/dev/null | grep -qi pdo_sqlsrv; then
    local r; r=$(S="$host,$port" D="$db" U="$user" P="$p1" php -r 'try{new PDO("sqlsrv:Server=".getenv("S").";Database=".getenv("D"),getenv("U"),getenv("P"));echo "OK";}catch(Exception $e){echo "FAIL: ".$e->getMessage();}' 2>&1)
    if [[ $r == OK* ]]; then ok "test login to MSSQL with the new password WORKED"
    else bad "test login FAILED: $r"
      tip "Login failed = wrong password, or Ben hasn't changed it yet, or login locked. Firewall/encryption errors = not the password."
      ask "Apply the new password anyway?" || return 1
    fi
  else warn "can't pre-test (php pdo_sqlsrv CLI missing) - will check the webmail page right after"; fi
  # 2. back up + edit just the password inside db_dsnw (URL-encoded, like Roundcube expects)
  bk "$CF"; local saved; saved=$(ls -t "$BAK/opt/roundcube/config/"config.inc.php.* | head -1)
  CF="$CF" P="$p1" python3 - <<'PY' || { bad "edit failed - config untouched"; return 1; }
import os,re,urllib.parse
p=os.environ['CF']; enc=urllib.parse.quote(os.environ['P'],safe='')
s=open(p).read()
def fix(m):
    scheme,rest=m.group(2).split('://',1); cred,hp=rest.rsplit('@',1); user=cred.split(':',1)[0]
    return m.group(1)+scheme+'://'+user+':'+enc+'@'+hp+m.group(3)
s2,n=re.subn(r"(\$config\['db_dsnw'\]\s*=\s*')([^']*)(';)",fix,s,count=1)
assert n==1
open(p,'w').write(s2)
PY
  unset p1 p2
  if have php && ! php -l "$CF" >/dev/null 2>&1; then bad "config has a PHP syntax error - restoring"; cp -a "$saved" "$CF"; return 1; fi
  ok "config updated (backup: $saved)"; note "roundcube db_dsnw password updated (backup $saved)"
  # 3. reload so PHP picks it up
  systemctl reload apache2 2>/dev/null; systemctl reload 'php*-fpm.service' 2>/dev/null; sleep 2
  # 4. verify the web page
  local page; page=$(curl -sk -m 8 https://127.0.0.1/ 2>/dev/null)
  if echo "$page" | grep -qiE 'DATABASE ERROR|DB Error|connection failed'; then
    bad "webmail shows a DATABASE ERROR with the new password"
    if ask "Put the OLD config back?"; then cp -a "$saved" "$CF"; systemctl reload apache2; warn "restored old config"; note "roundcube db password change ROLLED BACK"; fi
  elif echo "$page" | grep -qi roundcube; then ok "webmail login page loads with no database error"
    tip "Best final test: log in to webmail in a browser from the Ubuntu workstation (https://172.20.240.15)."
  else warn "page didn't look like Roundcube - check: curl -vk https://127.0.0.1/ and the 'Webmail' fix steps"; fi
  cmd_rebase >/dev/null; ok "baseline refreshed so hunt won't flag this change"
}

# =============================== hunt ===============================
cmd_hunt() {
  hdr "HUNT $(date '+%H:%M:%S')"
  tip "Read only the RED lines. Each one is something new since your baseline. If YOU caused it, run: bash $0 rebase"
  say "who is logged in:"; who; w -h | awk '{print "   "$1, $2, $3, $NF}' | head
  say "established connections (non-LAN peers flagged):"
  ss -tnpH state established | while read -r _ _ l r p; do
    case "$r" in 172.20.240.*|127.*|\[::1\]*|\[::ffff:127*) echo "   $l <- $r $p";; *) echo "${R}   $l <-> $r $p${N}";; esac
  done
  if [ -f "$D/baseline.ports" ]; then
    local newp; newp=$(comm -13 "$D/baseline.ports" <(ss -tlnH | awk '{print $4}' | sort -u))
    [ -n "$newp" ] && bad "NEW listening ports since baseline: $newp" && ss -tlnp | grep -F "$(echo "$newp" | head -1 | sed 's/.*://')"
  fi
  if [ -f "$D/baseline.passwd" ]; then
    local newu; newu=$(comm -13 "$D/baseline.passwd" <(awk -F: '{print $1":"$3":"$7}' /etc/passwd | sort))
    [ -n "$newu" ] && bad "NEW/CHANGED users: $newu"
  fi
  awk -F: '$3==0 && $1!="root"' /etc/passwd | grep . && bad "extra UID 0 account!"
  local pm; for pm in /lib/x86_64-linux-gnu/security/*.so; do owned "$pm" || bad "unpackaged PAM module: $pm"; done
  ls /root/.config/systemd/user /home/*/.config/systemd/user 2>/dev/null | grep -q . && bad "user-level systemd units exist: ls /root/.config/systemd/user /home/*/.config/systemd/user"
  local k; for k in /root/.ssh/authorized_keys* /home/*/.ssh/authorized_keys* /etc/ssh/.ssh/*; do [ -s "$k" ] && bad "authorized_keys exists: $k"; done
  grep -q . /etc/ld.so.preload 2>/dev/null && bad "/etc/ld.so.preload populated"
  local f; for f in /etc/systemd/system/*.service /etc/systemd/system/*.timer; do [ -f "$f" ] && ! owned "$f" && [ "$f" -nt "$D/baseline.ports" ] 2>/dev/null && bad "unit created after baseline: $f"; done
  say "crontabs modified in last 60 min:"; find /etc/cron* /var/spool/cron -type f -mmin -60 2>/dev/null | sed 's/^/   /'
  say "files changed in last 20 min (etc, roundcube, bins, tmp):"
  find /etc /opt/roundcube /usr/bin /usr/sbin /usr/lib/apache2 /tmp /var/tmp /dev/shm /root /home -xdev -type f -mmin -20 2>/dev/null | grep -vE '/opt/roundcube/(temp|logs)/|/root/ccdc/|\.bash_history$|/\.cache/' | head -30 | sed 's/^/   /'
  ls -l /proc/*/exe 2>/dev/null | grep -q deleted && { bad "process running from a DELETED binary:"; ls -l /proc/*/exe 2>/dev/null | grep deleted; }
  apache2ctl -M 2>/dev/null | grep -qi coraza && bad "coraza module is back in Apache"
  postconf -n 2>/dev/null | grep -qE '^(always_bcc|sender_bcc_maps|recipient_bcc_maps)' && bad "postfix bcc exfil setting present"
  if [ -f "$D/baseline.sha256" ]; then
    local chg; chg=$(sha256sum --quiet -c "$D/baseline.sha256" 2>/dev/null | head -20)
    [ -n "$chg" ] && { bad "files changed vs baseline (if you didn't change them, investigate):"; echo "$chg" | sed 's/^/   /'; } || ok "config/Roundcube hashes match baseline"
  fi
  say "top CPU:"; ps -eo pid,user,%cpu,etime,cmd --sort=-%cpu | head -6 | cut -c1-150
  say "recent auth failures/sudo:"; grep -E 'Failed password|Accepted|sudo:.*COMMAND|useradd|usermod' /var/log/auth.log 2>/dev/null | tail -8 | cut -c1-160
  say "mail auth failures (last 5):"; grep -iE 'auth failed|authentication failure|SASL.*failed' /var/log/mail.log 2>/dev/null | tail -5 | cut -c1-160
  say "firewall drops (last 5):"; journalctl -k --since '-15 min' 2>/dev/null | grep 'FW-' | tail -5 | cut -c1-200
  note "hunt run"
}

# =============================== check ===============================
cmd_check() {
  hdr "SCORING HEALTH $(date '+%H:%M:%S')"
  tip "Green [+] = good. Red [X] = fix it (see 'Something's broken' in the guide). Yellow [!] = check, may be fine."
  local s
  for s in postfix dovecot apache2 sssd ssh; do
    systemctl is-active --quiet "$s" && ok "$s active" || bad "$s NOT active -> systemctl restart $s ; journalctl -u $s -n 30"
  done
  local p
  for p in 25 110 143 443 80 993 995 587 22; do port_up 127.0.0.1 $p && ok "port $p listening" || warn "port $p not listening"; done
  local b
  b=$(timeout 4 bash -c 'exec 3<>/dev/tcp/127.0.0.1/25; head -1 <&3; echo QUIT >&3' 2>/dev/null); [[ $b == 220* ]] && ok "SMTP banner: $b" || bad "SMTP banner bad: '$b'"
  b=$(timeout 4 bash -c 'exec 3<>/dev/tcp/127.0.0.1/143; head -1 <&3' 2>/dev/null); [[ $b == *OK* ]] && ok "IMAP banner OK" || bad "IMAP banner bad: '$b'"
  b=$(timeout 4 bash -c 'exec 3<>/dev/tcp/127.0.0.1/110; head -1 <&3' 2>/dev/null); [[ $b == +OK* ]] && ok "POP3 banner OK" || bad "POP3 banner bad: '$b'"
  b=$(curl -sk -m 6 https://127.0.0.1/ 2>/dev/null)
  echo "$b" | grep -qi roundcube && ok "HTTPS serves Roundcube login page" || bad "HTTPS page doesn't look like Roundcube (curl -vk https://127.0.0.1/)"
  echo "$b" | grep -qiE 'DB Error|database error|Service Unavailable' && bad "Roundcube shows a DB error -> MSSQL ($SQL_IP:1433) / roundcube SQL login"
  port_up "$SQL_IP" 1433 && ok "MSSQL $SQL_IP:1433 reachable" || bad "MSSQL $SQL_IP:1433 UNREACHABLE (webmail logins will fail)"
  port_up "$DC_IP" 389   && ok "DC LDAP reachable"  || bad "DC $DC_IP:389 UNREACHABLE (AD logins fail)"
  port_up "$DC_IP" 88    && ok "DC Kerberos reachable" || bad "DC $DC_IP:88 UNREACHABLE"
  getent hosts mail.underpressure.local >/dev/null && ok "DNS resolves mail.underpressure.local" || warn "DNS can't resolve mail.underpressure.local"
  systemctl is-active --quiet sssd && { realm list 2>/dev/null | grep -q underpressure && ok "realm joined: underpressure.local" || warn "realm list doesn't show underpressure.local"; }
  local skew; skew=$(chronyc tracking 2>/dev/null | awk '/System time/{print $4}'); [ -n "$skew" ] && echo "   clock offset: ${skew}s (Kerberos breaks > 300s)"
  echo "   disk /: $(df -h / | awk 'NR==2{print $5" used, "$4" free"}')   mail queue: $(mailq 2>/dev/null | tail -1)"
  if [ -n "$TESTUSER" ]; then
    getent passwd "$TESTUSER" >/dev/null && ok "AD user $TESTUSER resolves via SSSD" || bad "AD user $TESTUSER does NOT resolve (sss_cache -E; systemctl restart sssd)"
    [ -n "$TESTPASS" ] && { doveadm auth test "$TESTUSER" "$TESTPASS" 2>&1 | grep -q succeeded && ok "doveadm auth test $TESTUSER succeeded" || bad "doveadm auth test $TESTUSER FAILED"; }
  else say "deeper test: TESTUSER=adam.brown TESTPASS='...' bash ccmail.sh check"; fi
  say "Also compare with Quotient service status - it's the source of truth."
}

cmd_rebase() {   # accept current state as the new known-good baseline (after YOU changed configs)
  find /opt/roundcube /etc/postfix /etc/dovecot /etc/apache2 /etc/pam.d /etc/ssh /usr/lib/apache2/modules -type f -not -path '*/temp/*' -not -path '*/logs/*' -exec sha256sum {} + 2>/dev/null > "$D/baseline.sha256"
  ss -tlnH | awk '{print $4}' | sort -u > "$D/baseline.ports"
  awk -F: '{print $1":"$3":"$7}' /etc/passwd | sort > "$D/baseline.passwd"
  ok "baseline refreshed"; note "baseline refreshed"
}

# =============================== first ===============================
cmd_first() {
  hdr "DROP-FLAG SEQUENCE: 8 steps, about 5-8 minutes"
  echo "  Every change is backed up first. Nothing is deleted (suspicious files go to $Q)."
  echo "  Ctrl-C at any prompt stops safely. You can re-run any single step later, e.g.  bash $0 fw"
  stage 1 "Passwords (zulu-compatible)" "creates ccdcuser1+2; you set root/ccdcuser1/ccdcuser2; everyone else gets the team seed-phrase password" "3 passwords, then y + the seed phrase twice"
  cmd_passwd
  stage 2 "Evict backdoors" "find planted SSH keys, fake services/modules, PAM stealers" "y to quarantine anything flagged that your team didn't add"
  cmd_evict
  stage 3 "Harden SSH" "no root login, 3 tries, no tunnels; passwords stay on for the scorer" "nothing (automatic)"
  cmd_sshd
  stage 4 "Free disk space" "logs, apt cache, old snaps (disk starts ~96% full)" "y to remove the PowerShell snap"
  cmd_disk
  stage 5 "Backups" "disguised + backdated copies of configs and Roundcube, plus a fingerprint of every config file" "optional passphrase (Enter = none)"
  cmd_backup
  stage 6 "Recon" "snapshot of users, ports, services into a file for injects/IR" "nothing (automatic)"
  cmd_recon
  stage 7 "Firewall" "allow mail/web/ssh in; only DNS/AD/MSSQL/Splunk/web out; auto-undo in 90s" "type yes if MSSQL + AD say reachable"
  cmd_fw
  stage 8 "Health check" "tests every scored service and dependency" "nothing - read the red lines"
  cmd_check
  hdr "DONE - SUMMARY"
  echo "  What changed (from $LOG):"; sed 's/^/    /' "$LOG" | tail -25
  echo "  Quarantined files: $(ls "$Q" 2>/dev/null | wc -l)  (in $Q - tell your Injects lead for an incident report)"
  echo
  ok "Next:  bash $0 mail     (mail-service hardening, ~2 min)"
  ok "Then:  bash $0 hunt; bash $0 check     every 15 minutes"
  ok "Broken?  bash $0 fwoff  (if you suspect the firewall)   |   bash $0 restore postfix  (or dovecot, apache2, roundcube...)"
}

case "$1" in
  first|recon|disk|backup|evict|passwd|sshd|fw|fwoff|mail|hunt|check|rebase|sqlpass) "cmd_$1" ;;
  restore) cmd_restore "$@" ;;
  seedshow) cmd_seedshow "$@" ;;
  *) sed -n '2,28p' "$0"; echo; echo "  ${G}Start here:  bash $0 first${N}" ;;
esac
