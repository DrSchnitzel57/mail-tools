#!/usr/bin/env bash
# ======================================================================
#  thorska.sh  -  CCDC toolkit for THORSKA (Fedora 44, "Home Manager" web app)
#  WCComps Invitational 3 - Flokid - 192.168.220.231
#
#  bash thorska.sh            menu
#  bash thorska.sh first      START HERE: guided first run (8 steps, resumable)
#  bash thorska.sh check      is everything up?            (read-only)
#  bash thorska.sh hunt       what changed / looks evil?   (read-only)
#  bash thorska.sh watch      live dashboard               (read-only, run it in tmux)
#  bash thorska.sh tmux       open a 2-pane tmux layout: dashboard on top, shell below
#  bash thorska.sh web        find the web app, its files, its database (read-only)
#  bash thorska.sh protect    web app audit: webshells, fingerprints, permissions
#  bash thorska.sh fw [learn|lock|status|off]   host firewall (nftables)
#  bash thorska.sh backup     disguised backup of configs + app + database
#  bash thorska.sh restore [what]               restore one piece from backup
#  bash thorska.sh evict | docker | db | passwd | ssh | recon | report | rebase
#  bash thorska.sh seedshow <user...> [--csv]   show seed passwords (zulu-compatible)
#
#  Ctrl-C during a step = pause menu (skip / retry / quit). Nothing is ever deleted:
#  suspicious files are moved to /root/tk/quarantine/. Every change is logged.
# ======================================================================
VERSION="1.3"

# ---------------------- EDIT IF THE ENVIRONMENT CHANGED ----------------------
LAN="192.168.220.0/24"
ROUTER="192.168.220.2"          # vigra (OpenWRT)
DC="192.168.220.79"             # vattar (AD/DNS)
ALLOW_WEB_OUT="${ALLOW_WEB_OUT:-1}"   # firewall lock: 1 = still allow outbound 80/443 (dnf, downloads)
LEARN_LOG_RATE="20/second"
# -----------------------------------------------------------------------------

D=/root/tk; Q=$D/quarantine; BAK=$D/bak; W=$D/web; LOG=$D/changes.log
SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
UTF=0; case "${LANG:-}${LC_ALL:-}" in *UTF-8*|*utf8*) UTF=1;; esac
if [ -t 1 ]; then R=$'\e[1;31m'; G=$'\e[1;32m'; Y=$'\e[1;33m'; B=$'\e[1;36m'; M=$'\e[1;35m'; DIM=$'\e[2m'; BO=$'\e[1m'; N=$'\e[0m'
else R=; G=; Y=; B=; M=; DIM=; BO=; N=; fi
[ "$UTF" = 1 ] && { HL="━"; OKS="✔"; BADS="✘"; WRS="!"; AR="➜"; } || { HL="="; OKS="+"; BADS="X"; WRS="!"; AR="->"; }

# ------------------------------ output helpers ------------------------------
line()  { local i s=""; for ((i=0;i<${1:-64};i++)); do s+="$HL"; done; echo "$s"; }
hdr()   { echo; echo "${B}$(line 64)${N}"; echo "${B}  $*${N}"; echo "${B}$(line 64)${N}"; }
sub()   { echo; echo "${BO}${M}-- $* --${N}"; }
ok()    { echo "  ${G}${OKS}${N} $*"; }
warn()  { echo "  ${Y}${WRS}${N} $*"; }
bad()   { echo "  ${R}${BADS} $*${N}"; }
say()   { echo "  ${B}*${N} $*"; }
tip()   { echo "    ${DIM}${AR} $*${N}"; }
note()  { mkdir -p "$D"; echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }
have()  { command -v "$1" >/dev/null 2>&1; }
myip()  { { ip -4 -br a 2>/dev/null | awk '$1!="lo"{print $3}'; hostname -I 2>/dev/null | tr ' ' '\n'; } | grep -m1 . ; }
port_up(){ timeout 3 bash -c "</dev/tcp/$1/$2" 2>/dev/null; }
TS()    { date +%Y%m%d-%H%M%S; }
ask()   { local a; read -r -p "  ${Y}?${N} $* ${DIM}[y/N]${N} " a </dev/tty; [[ $a =~ ^[Yy] ]]; }
pause_enter(){ read -r -p "  ${DIM}Press Enter to continue...${N}" _ </dev/tty; }
is_lan(){ case "$1" in 192.168.220.*|127.*|::1|"[::1]"|::ffff:127.*|::ffff:192.168.220.*) return 0;; esac; return 1; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root:  sudo bash $0 $*"; exit 1; }
mkdir -p "$D" "$Q" "$BAK" "$W"; chmod 700 "$D"

# bk: copy a file into $BAK before changing it.   quar: move a file to quarantine (never delete)
bk()   { [ -e "$1" ] || return 0; local t="$BAK$(dirname "$1")"; mkdir -p "$t"; cp -a "$1" "$t/$(basename "$1").$(TS)"; }
quar() { [ -e "$1" ] || [ -L "$1" ] || return 0; local t="$Q/$(echo "$1" | tr / _).$(TS)"
         mv -f -- "$1" "$t" && chmod 000 "$t" 2>/dev/null; warn "quarantined $1 ${DIM}-> $t${N}"; note "QUARANTINE $1 -> $t"; }

# tmo SECONDS LABEL cmd...   run a slow command with a timeout + live timer. Ctrl-C stops it cleanly.
tmo() {
  local s=$1 label=$2; shift 2
  timeout -k 5 "$s" "$@" & local p=$! t=0 rc
  trap 'kill -TERM -- -'"$p"' 2>/dev/null; kill -TERM '"$p"' 2>/dev/null; trap - INT; kill -INT $BASHPID' INT
  while kill -0 "$p" 2>/dev/null; do
    [ -t 2 ] && printf '\r    %s %s... %ss ' "${DIM}" "$label" "$t" >&2; sleep 1; t=$((t+1))
  done
  wait "$p"; rc=$?; trap - INT
  [ -t 2 ] && printf '\r%-70s\r%s' "" "$N" >&2
  [ "$rc" = 124 ] && warn "$label timed out after ${s}s (skipped it, nothing else affected)"
  return $rc
}

# ------------------------------ step runner ------------------------------
# Runs one step in its own subshell. Ctrl-C (or a crash) -> pause menu: skip / retry / quit.
INTR=0
run_step() {
  local title=$1; shift
  while :; do
    INTR=0; trap 'INTR=1' INT
    ( "$@" ); local rc=$?
    trap - INT
    if [ "$INTR" = 1 ] || [ "$rc" = 130 ]; then
      echo; warn "${BO}Stopped:${N} $title"
      local c; read -r -p "  ${Y}?${N} [s]kip this step, [r]etry it, [q]uit the script: " c </dev/tty
      case "$c" in r|R) say "retrying..."; continue;; q|Q) note "QUIT during $title"; exit 130;;
                   *) note "SKIPPED $title"; return 1;; esac
    fi
    return "$rc"
  done
}

# ------------------------------ plan, then apply ------------------------------
# Steps collect proposed changes with plan_add "description" "command", then plan_apply asks ONCE.
PLAN_D=(); PLAN_C=(); PLAN_R=()
plan_reset(){ PLAN_D=(); PLAN_C=(); PLAN_R=(); }
plan_add()  { PLAN_D+=("$1"); PLAN_C+=("$2"); PLAN_R+=("${3:-}"); }   # 3rd arg "risky" = not included in [a]ll
plan_apply(){
  local n=${#PLAN_D[@]} i a sel=() nr=0
  if [ "$n" -eq 0 ]; then ok "Nothing to change here."; return 0; fi
  echo; echo "  ${BO}Planned changes:${N}"
  for ((i=0;i<n;i++)); do
    if [ "${PLAN_R[$i]}" = risky ]; then printf '   %s%2d)%s %s %s[pick by number only]%s\n' "$BO" $((i+1)) "$N" "${PLAN_D[$i]}" "$Y" "$N"; nr=$((nr+1))
    else printf '   %s%2d)%s %s\n' "$BO" $((i+1)) "$N" "${PLAN_D[$i]}"; fi
  done
  [ "$nr" -gt 0 ] && tip "[a]ll skips the $nr item(s) marked 'pick by number only' - type their numbers if you really want them"
  while :; do
    read -r -p "  ${Y}?${N} Apply ${BO}[a]ll${N} / pick numbers (e.g. ${BO}1 3 4${N}) / ${BO}[s]kip${N}: " a </dev/tty
    case "$a" in
      a|A|all) for ((i=0;i<n;i++)); do [ "${PLAN_R[$i]}" = risky ] || sel+=("$i"); done; break;;
      s|S|n|N|"") say "Skipped. Nothing changed."; return 0;;
      *) sel=(); local okp=1 x
         for x in ${a//,/ }; do [[ $x =~ ^[0-9]+$ ]] && [ "$x" -ge 1 ] && [ "$x" -le "$n" ] && sel+=($((x-1))) || okp=0; done
         [ "$okp" = 1 ] && [ ${#sel[@]} -gt 0 ] && break; warn "Type a, s, or numbers between 1 and $n.";;
    esac
  done
  for i in "${sel[@]}"; do
    if eval "${PLAN_C[$i]}"; then ok "done: ${PLAN_D[$i]}"; note "APPLIED ${PLAN_D[$i]}"
    else bad "failed: ${PLAN_D[$i]}"; note "FAILED ${PLAN_D[$i]}"; fi
  done
}
q() { printf '%q' "$1"; }   # quote a value for a plan command

# ------------------------------ package ownership (rpm) ------------------------------
OWNED=$D/.owned
build_owned() {
  [ -t 1 ] && printf '    %sindexing which files came from packages...%s\r' "$DIM" "$N"
  if have rpm; then timeout 180 rpm -qa --qf '[%{FILENAMES}\n]' 2>/dev/null | sort -u > "$OWNED"
  elif have dpkg; then cat /var/lib/dpkg/info/*.list 2>/dev/null | sort -u > "$OWNED"; fi
  [ -t 1 ] && printf '%-60s\r' ""
}
owned() { [ -s "$OWNED" ] || build_owned; local p; p=$(readlink -f -- "$1" 2>/dev/null || echo "$1")
          grep -qxF -- "$p" "$OWNED" || grep -qxF -- "$1" "$OWNED"; }
owner_pkg() { have rpm && rpm -qf -- "$1" 2>/dev/null | grep -v 'not owned' | head -1; }
SUDOGRP=wheel; getent group wheel >/dev/null || SUDOGRP=sudo
svc_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

# ======================================================================
#  PASSWORDS (zulu-compatible seed passwords)
# ======================================================================
WL=$D/wordlist.txt
get_wordlist() {   # the zulu wordlist is embedded at the bottom of this script (works offline)
  [ -s "$WL" ] && return 0
  sed -n '/^__WORDLIST__$/,$p' "$SELF" | tail -n +2 | base64 -d 2>/dev/null | gunzip -c > "$WL" 2>/dev/null
  [ "$(wc -l < "$WL" 2>/dev/null)" -gt 1000 ] && return 0
  bad "couldn't unpack the embedded wordlist"; rm -f "$WL"; return 1
}
zulu_pw() {  # zulu_pw <seed> <user>  -> same password zulu.sh would set
  local hash i hex dec idx pw="" b; hash=$(echo -n "$1$2" | md5sum); b=$(wc -l "$WL" | awk '{print $1-1}')
  for i in 0 4 8 12 16; do
    hex=${hash:$i:4}; dec=$((16#$hex))
    idx=$(awk -v x="$dec" -v b="$b" 'BEGIN{printf(int((0+((x-0)*(b-0))/(65535-0))))}')
    [ "$i" -ne 0 ] && pw+="-"; pw+=$(sed -n "$((idx+1))p" "$WL")
  done; echo "${pw}1"
}
read_seed() {
  local a b2
  while :; do
    read -r -s -p "  Team seed phrase (same one as zulu): " a </dev/tty; echo
    read -r -s -p "  Confirm seed phrase: " b2 </dev/tty; echo
    [ "$a" != "$b2" ] && { warn "didn't match, try again"; continue; }
    [ ${#a} -lt 8 ] && { warn "zulu needs at least 8 characters"; continue; }
    SEED=$a; break
  done
}
set_pw_manual() {
  local p1 p2
  while :; do
    read -r -s -p "  New password for ${BO}$1${N} (Enter = skip): " p1 </dev/tty; echo
    [ -z "$p1" ] && { say "skipped $1"; return; }
    read -r -s -p "  Again: " p2 </dev/tty; echo
    [ "$p1" = "$p2" ] && break; warn "didn't match, try again"
  done
  echo "$1:$p1" | chpasswd && ok "changed $1" && note "password changed: $1"
}
cmd_passwd() {
  hdr "PASSWORDS (zulu-compatible)"
  tip "Same as 'zulu.sh -i': you type passwords for root, ccdcuser1, ccdcuser2."
  tip "Every OTHER local login user (sysadmin etc.) gets the team seed-phrase password."
  tip "Nothing shows while you type. Enter on an empty prompt skips that account."
  local u
  for u in ccdcuser1 ccdcuser2; do id "$u" >/dev/null 2>&1 || { useradd -m -s /bin/bash "$u" && ok "created $u" && note "created $u"; }; done
  usermod -aG "$SUDOGRP" ccdcuser1 && ok "ccdcuser1 is in $SUDOGRP (admin). ccdcuser2 is a normal user, like zulu."
  for u in root ccdcuser1 ccdcuser2; do set_pw_manual "$u"; done
  local users; users=$(grep -v "false\|nologin" /etc/passwd | cut -d: -f1 | grep -vxE 'root|ccdcuser1|ccdcuser2|sync|shutdown|halt')
  echo; say "Other local login users: ${BO}$(echo $users)${N}"
  if [ -n "$users" ]; then
    tip "If Quotient scores SSH with one of these accounts, you can leave it out now and change it later with a PCR."
    local skip; read -r -p "  Names to leave alone (space-separated), or Enter for none: " skip </dev/tty
    for u in $skip; do users=$(echo "$users" | grep -vxF "$u"); note "passwd: left $u unchanged"; done
    [ -n "$skip" ] && say "Will change: ${BO}$(echo $users)${N}"
  fi
  if [ -n "$users" ] && ask "Give them the team seed-phrase passwords?" && get_wordlist; then
    read_seed
    for u in $users; do echo "$u:$(zulu_pw "$SEED" "$u")" | chpasswd && ok "seed password set: $u" && note "seed password set: $u"; done
    tip "sysadmin's password is now the SEED one. See it anytime:  bash $0 seedshow sysadmin"
    unset SEED
  elif [ -n "$users" ]; then
    for u in $users; do set_pw_manual "$u"; done
  fi
  sub "Admin group ($SUDOGRP)"
  say "members: ${BO}$(getent group "$SUDOGRP" | cut -d: -f4)${N}   (expected: ccdcuser1, maybe sysadmin)"
  tip "Remove extras in the 'evict' step, or: gpasswd -d <user> $SUDOGRP"
  tip "If a scored check logs in with a local account and goes red: submit a PCR in Quotient (bash $0 seedshow <user> --csv)."
}
cmd_seedshow() {
  shift; local csv=0 u us=()
  for u in "$@"; do [ "$u" = --csv ] && csv=1 || us+=("$u"); done
  [ ${#us[@]} -gt 0 ] || { echo "usage: bash $0 seedshow <user> [user...] [--csv]"; return 1; }
  get_wordlist || return 1; read_seed
  for u in "${us[@]}"; do [ $csv = 1 ] && echo "$u,$(zulu_pw "$SEED" "$u")" || echo "  $u : $(zulu_pw "$SEED" "$u")"; done
  unset SEED; tip "Run 'clear' after you've copied it."
}

# ======================================================================
#  EVICT: find planted backdoors, then plan -> apply
# ======================================================================
unit_bin() { grep -m1 -E '^\s*ExecStart\s*=' "$1" 2>/dev/null | cut -d= -f2- | sed -E 's/^[[:space:]]*[-@+!:]*//' | awk '{print $1}'; }
svc_tags() {   # warnings for a unit's plan line: is it the web app, the SSH server, running now?
  local u=$1 b=$2 t="" d
  systemctl is-active --quiet "$u" 2>/dev/null && t+=" ${Y}(running now)${N}"
  if grep -qxF "$u" "$W/units" 2>/dev/null; then t+=" ${R}(runs the web app)${N}"
  elif [ -n "$b" ]; then while read -r d; do [ -n "$d" ] && case "$b" in "$d"/*) t+=" ${R}(program is in the web app's folder)${N}"; break;; esac; done < "$W/dirs" 2>/dev/null; fi
  case "$u" in sshd.service|ssh.service|sshd.socket) t+=" ${R}(this is the SSH server)${N}";; esac
  echo "$t"
}
cmd_evict() {
  hdr "EVICT BACKDOORS"
  [ -s "$W/urls" ] || { say "finding the web app first (read-only), so evict can tell you which service is Home Manager..."; cmd_web >/dev/null 2>&1; }
  tip "Nothing changes until you approve the plan at the end. Files are moved to $Q, never deleted."
  plan_reset
  build_owned
  local f u b k found

  sub "SSH keys (logins without a password)"
  local akf; akf=$(sshd -T 2>/dev/null | awk '/^authorizedkeysfile/{for(i=2;i<=NF;i++)print $i}')
  [ -n "$akf" ] && ! echo "$akf" | grep -qx '.ssh/authorized_keys\|%h/.ssh/authorized_keys\|.ssh/authorized_keys2' && warn "sshd reads keys from a non-standard place: ${BO}$akf${N} (the 'ssh' step resets this)"
  found=0
  for k in /root/.ssh/authorized_keys* /home/*/.ssh/authorized_keys* /etc/ssh/.ssh/* $(echo "$akf" | grep '^/' ); do
    [ -s "$k" ] || continue; found=1
    bad "$k"; awk '{printf "      %s ...%s %s\n",$1,substr($2,length($2)-10),$3}' "$k"
    plan_add "quarantine $k (removes those keys)" "quar $(q "$k")"
  done
  [ $found = 0 ] && ok "no authorized_keys files"

  sub "Accounts"
  awk -F: '$3==0 && $1!="root"{print $1}' /etc/passwd | while read -r u; do bad "extra UID 0 (root-equivalent) account: $u"; done
  for u in $(awk -F: '$3==0 && $1!="root"{print $1}' /etc/passwd); do plan_add "lock root-equivalent account $u" "usermod -L -s /sbin/nologin $(q "$u")"; done
  for u in $(awk -F: '$3>0 && $3<1000 && $7~/(bash|sh|zsh)$/{print $1}' /etc/passwd); do
    warn "system account with a login shell: ${BO}$u${N} ($(getent passwd "$u" | cut -d: -f5,6))"; tip "last week red team planted 'svc-chrony' like this"
    plan_add "lock system account $u (nologin shell)" "usermod -L -s /sbin/nologin $(q "$u")"
  done
  local adm; adm=$(getent group "$SUDOGRP" | cut -d: -f4 | tr , ' ')
  say "$SUDOGRP (admin) members: ${BO}${adm:-none}${N}"
  for u in $adm; do case "$u" in ccdcuser1) ;; *)
    if [ "$u" = "${SUDO_USER:-}" ]; then plan_add "remove $u from $SUDOGRP ${Y}(you're logged in as $u: only AFTER 'sudo -i' works as ccdcuser1 in a new terminal)${N}" "gpasswd -d $(q "$u") $SUDOGRP" risky
    else plan_add "remove $u from $SUDOGRP (admin)" "gpasswd -d $(q "$u") $SUDOGRP"; fi;; esac; done
  for f in /etc/sudoers.d/*; do [ -f "$f" ] || continue; owned "$f" && continue
    bad "sudoers file not from a package: $f"; sed 's/^/      /' "$f" | grep -v '^\s*#' | head -5
    plan_add "quarantine sudoers file $f" "quar $(q "$f")"; done
  grep -nE 'NOPASSWD|^[^#].*ALL=\(ALL' /etc/sudoers 2>/dev/null | grep -vE '^\s*[0-9]+:\s*(root|%wheel)\s' | sed 's/^/      sudoers: /'

  sub "Services, timers, sockets not installed by any package"
  found=0
  for f in /etc/systemd/system/*.service /etc/systemd/system/*.timer /etc/systemd/system/*.socket /etc/systemd/system/*.path \
           /usr/lib/systemd/system/*.service /usr/lib/systemd/system/*.timer /usr/local/lib/systemd/system/* /etc/systemd/user/* \
           /root/.config/systemd/user/* /home/*/.config/systemd/user/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue; owned "$f" && continue
    u=$(basename "$f"); b=$(unit_bin "$f"); found=1
    warn "${BO}$u${N}  ${DIM}$f${N}"; echo "      $(grep -m1 '^Description' "$f")"; echo "      ExecStart: ${b:-?}"
    if [ -n "$b" ] && [ -e "$b" ] && ! owned "$b"; then echo "      ${R}program is not from a package${N}"; fi
    local cmd="systemctl disable --now $(q "$u") 2>/dev/null; quar $(q "$f")"
    [ -n "$b" ] && [ -e "$b" ] && ! owned "$b" && cmd+="; quar $(q "$b")"
    local tg; tg=$(svc_tags "$u" "$b"); local rk=""; case "$tg" in *"web app"*|*"SSH server"*) rk=risky;; esac
    plan_add "disable + quarantine $u$( [ -n "$b" ] && ! owned "$b" && echo " and $b")$tg" "$cmd; systemctl daemon-reload 2>/dev/null; true" "$rk"
  done
  [ $found = 0 ] && ok "every service/timer comes from a package"
  for f in /etc/systemd/system/*.d/*.conf; do [ -f "$f" ] || continue; grep -qE '^\s*Exec(Start|StartPre|StartPost|Stop)' "$f" || continue; owned "$f" && continue
    warn "drop-in changes what a service runs: ${BO}$f${N}"; grep -E '^\s*Exec' "$f" | sed 's/^/      /'
    plan_add "quarantine drop-in $f" "quar $(q "$f"); systemctl daemon-reload"; done

  sub "Scheduled jobs"
  for f in /var/spool/cron/* /etc/cron.d/* /var/spool/at/*; do [ -f "$f" ] || continue; owned "$f" && continue
    warn "cron/at job: ${BO}$f${N}"; grep -v '^\s*#' "$f" | grep . | head -4 | sed 's/^/      /'
    plan_add "quarantine scheduled job $f" "quar $(q "$f")"; done
  systemctl list-timers --all --no-legend 2>/dev/null | awk '{print $(NF-1)}' | while read -r u; do
    f=$(systemctl show -p FragmentPath --value "$u" 2>/dev/null); [ -n "$f" ] && ! owned "$f" && warn "timer not from a package: $u ($f)"; done

  sub "Login hooks (PAM, preload, shell startup)"
  if grep -q . /etc/ld.so.preload 2>/dev/null; then bad "/etc/ld.so.preload is not empty: $(cat /etc/ld.so.preload)"; plan_add "quarantine /etc/ld.so.preload (rootkit trick)" "quar /etc/ld.so.preload"; else ok "ld.so.preload clean"; fi
  for f in /usr/lib64/security/*.so /lib64/security/*.so /usr/lib/security/*.so; do [ -f "$f" ] || continue; owned "$f" && continue
    bad "PAM module not from a package: $f  (password stealer like last week's 'pamspam')"
    grep -rln "$(basename "$f")" /etc/pam.d/ 2>/dev/null | sed 's/^/      used in: /'
    tip "fix: remove its line from those /etc/pam.d files (bk first), THEN quarantine the .so - removing the .so first can break logins"
  done
  local hx; hx=$(grep -rnE 'pam_exec|pam_script' /etc/pam.d/ 2>/dev/null); [ -n "$hx" ] && { echo "$hx" | sed 's/^/      /'; warn "^ pam_exec runs a program at every login - check it"; }
  for f in /etc/profile.d/* /etc/bashrc /etc/profile /root/.bashrc /root/.bash_profile /home/*/.bashrc /home/*/.bash_profile; do
    [ -f "$f" ] || continue
    hx=$(grep -nE '(curl|wget) .*(\||sh)|\bnc |ncat|/dev/tcp|base64 -d|bash -i|python.*socket|LD_PRELOAD|alias (sudo|ps|ss|netstat|who|last|systemctl|passwd)=' "$f" 2>/dev/null)
    [ -n "$hx" ] && { echo "$hx" | sed "s|^|      $f:|"; warn "^ suspicious shell startup line in $f"; }
    case "$f" in /etc/profile.d/*) owned "$f" || { warn "profile.d script not from a package: $f"; plan_add "quarantine $f" "quar $(q "$f")"; };; esac
  done

  sub "Tampered system programs (rpm -V)"
  if have rpm; then
    local mod; mod=$(tmo 120 "verifying key packages" rpm -V openssh-server openssh-clients sudo shadow-utils util-linux coreutils procps-ng iproute bash pam systemd passwd findutils 2>/dev/null | awk '$1 ~ /5/ && $NF ~ /^\/usr\/(s?bin|lib64)/' )
    if [ -n "$mod" ]; then bad "system programs changed since install:"; echo "$mod" | sed 's/^/      /'
      local pk; for pk in $(echo "$mod" | awk '{print $NF}' | xargs -r rpm -qf --qf '%{NAME}\n' 2>/dev/null | sort -u); do
        plan_add "reinstall $pk from Fedora repos (needs internet)" "tmo 300 'dnf reinstall $pk' dnf -y -q reinstall $(q "$pk")"; done
    else ok "ssh, sudo, ps, ss, ls, login tools match their packages"; fi
  fi

  sub "Running programs"
  local p e
  for p in /proc/[0-9]*; do e=$(readlink "$p/exe" 2>/dev/null) || continue
    case "$e" in *" (deleted)"|/tmp/*|/var/tmp/*|/dev/shm/*) bad "PID ${p#/proc/} runs from ${BO}$e${N}: $(tr '\0' ' ' < "$p/cmdline" | cut -c1-100)"
      plan_add "kill PID ${p#/proc/} ($e)" "kill -9 ${p#/proc/}";; esac; done
  ss -Htlnp 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u | while read -r p; do
    e=$(readlink -f "/proc/$p/exe" 2>/dev/null); [ -n "$e" ] && ! owned "$e" && warn "listening program not from a package: ${BO}$e${N} (PID $p) ${DIM}- could be the web app itself; see 'web'${N}"; done
  if svc_active cockpit.socket || ss -Htln | grep -q ':9090 '; then warn "Cockpit admin console listens on 9090 (Fedora default). Not in the packet."
    plan_add "turn off Cockpit admin console (port 9090) - only if it isn't scored" "systemctl disable --now cockpit.socket cockpit.service"; fi

  sub "SUID programs not from a package"
  find / -xdev -perm -4000 -type f 2>/dev/null | while read -r f; do owned "$f" || bad "SUID: $f"; done
  find / -xdev -perm -4000 -type f 2>/dev/null | while read -r f; do owned "$f" || echo "$f"; done > "$D/.suid"
  while read -r f; do [ -n "$f" ] && plan_add "remove SUID bit from $f" "chmod u-s $(q "$f")"; done < "$D/.suid"

  docker_audit

  plan_apply
  tip "Write down what you quarantined + the time: your team needs it for an incident report."
  note "evict run"
}

# ======================================================================
#  DOCKER / PODMAN  (part of evict; alone: bash thorska.sh docker)
# ======================================================================
cmd_docker() { hdr "DOCKER / PODMAN"; plan_reset; docker_audit; plan_apply; }
docker_audit() {
  sub "Docker / Podman"
  tip "Read-only checks first. Stopping a container is always 'pick by number only' (it could be the web app or its database)."
  local cr g u pm n ports st img priv net pid rp mnt cmd cap why any=0 home
  if have docker || [ -S /var/run/docker.sock ] || [ -d /etc/docker ]; then any=1
    g=$(getent group docker | cut -d: -f4)
    if [ -n "$g" ]; then bad "group docker = root without a password. Members: ${BO}${g//,/ }${N}"
      for u in ${g//,/ }; do
        if [ "$u" = "${SUDO_USER:-}" ] || who 2>/dev/null | awk '{print $1}' | grep -qx "$u"; then plan_add "remove $u from group docker (root-equivalent) ${R}(logged in now)${N}" "gpasswd -d $(q "$u") docker" risky
        else plan_add "remove $u from group docker (root-equivalent)" "gpasswd -d $(q "$u") docker"; fi; done
    else ok "group docker has no members"; fi
    if [ -S /var/run/docker.sock ]; then pm=$(stat -c '%a %U:%G' /var/run/docker.sock 2>/dev/null)
      case "$pm" in [0-7][0-7]0\ *) ok "docker.sock is root/docker only ($pm)";; *) bad "docker.sock is open to every user ($pm) = anyone can get root"; plan_add "make docker.sock root/docker only (chmod 660)" "chmod 660 /var/run/docker.sock";; esac; fi
    if ss -Htln 2>/dev/null | awk '{print $4}' | grep -qE ':(2375|2376)$' || pgrep -af dockerd 2>/dev/null | grep -q 'tcp://' || grep -qs 'tcp://' /etc/docker/daemon.json /etc/systemd/system/docker.service.d/*.conf /etc/sysconfig/docker; then
      bad "Docker API is open on the network (tcp 2375/2376) = anyone who reaches it gets root"
      tip "the firewall step blocks 2375/2376 inbound. Full fix (restarts Docker, so containers restart): remove the tcp:// host from /etc/docker/daemon.json or the docker.service drop-in, then systemctl restart docker"
    else ok "Docker API is not open on the network"; fi
  fi
  for cr in docker podman; do have $cr || continue; any=1
    if ! timeout 15 $cr ps -a --format '{{.Names}}|{{.Ports}}' > "$D/.ctr" 2>/dev/null; then warn "$cr didn't answer (service stopped?)  check: systemctl status $cr"; continue; fi
    [ -s "$D/.ctr" ] || { ok "$cr: no containers"; continue; }
    say "$cr containers (all, running or not):"
    while IFS='|' read -r n ports; do [ -n "$n" ] || continue
      IFS='|' read -r st img priv net pid rp mnt cmd cap < <(timeout 10 $cr inspect -f '{{.State.Status}}|{{.Config.Image}}|{{.HostConfig.Privileged}}|{{.HostConfig.NetworkMode}}|{{.HostConfig.PidMode}}|{{.HostConfig.RestartPolicy.Name}}|{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}|{{.Config.Cmd}}|{{.HostConfig.CapAdd}}' "$n" 2>/dev/null | tr '\n' ' ')
      why=""
      [ "$priv" = true ] && why+=" privileged(full host root)"
      case " $mnt" in *docker.sock*|*podman.sock*) why+=" has-the-Docker-socket(controls the host)";; esac
      case " $mnt" in *" /:"*|*" /etc:"*|*" /root:"*|*" /home:"*|*" /boot:"*) why+=" mounts-host-system-folders";; esac
      [ "$pid" = host ] && why+=" sees-host-processes"
      case "$cap" in *SYS_ADMIN*|*ALL*|*SYS_PTRACE*|*SYS_MODULE*) why+=" extra-powers($cap)";; esac
      echo "$cmd" | grep -qE '\bnc\b|ncat|socat|/dev/tcp|bash -i|sh -i|(curl|wget).*\|' && why+=" runs-a-shell/downloader($cmd)"
      echo "      ${BO}$n${N}  $img  [$st]  ports: ${ports:-none}  net: $net  restart: ${rp:-no}"
      [ -n "$mnt" ] && echo "         folders: $mnt"
      if [ -n "$why" ]; then bad "container $n looks dangerous:$why"
        if [ "$cr" = docker ]; then plan_add "stop container $n and keep it from restarting ($img)" "docker update --restart=no $(q "$n") >/dev/null 2>&1; docker stop -t 5 $(q "$n")" risky
        else plan_add "stop container $n ($img)" "podman stop -t 5 $(q "$n")" risky; fi
      elif [ -n "$ports" ]; then say "   ^ publishes ports: probably the app (or its database). Leave it running."; fi
    done < "$D/.ctr"
    grep -q . "$D/.ctr" && tip "ports a container publishes go through $cr's own firewall rules, not this script's: they stay open, and 'fw lock' doesn't limit what containers connect to"
  done
  for home in /root /home/*; do [ -d "$home/.local/share/containers/storage" ] || continue; any=1
    u=$(stat -c %U "$home" 2>/dev/null); [ "$u" = root ] && [ "$home" != /root ] && continue
    [ "$home" = /root ] && continue
    warn "user ${BO}$u${N} has their own Podman containers (not in the list above). Look:  sudo -u $u podman ps -a"; done
  [ "$any" = 0 ] && ok "no Docker or Podman on this box"
  return 0
}

# ======================================================================
#  DATABASE AUDIT  (part of protect; alone: bash thorska.sh db)
# ======================================================================
cmd_db() { hdr "DATABASE AUDIT"; plan_reset; db_audit; plan_apply; }
dbx() { timeout 15 mysql -N -B -e "$1"; }          # used by plan commands
dbq() { timeout 15 mysql -N -B -e "$1" 2>/dev/null; }
sqs() { printf "%s" "$1" | sed "s/'/''/g"; }        # escape for '...' in SQL
db_rootpw() {   # set a new password for the database root, keeping root's no-password socket login on MariaDB
  local p1 p2
  read -r -s -p "  New database root password: " p1 </dev/tty; echo; read -r -s -p "  Again: " p2 </dev/tty; echo
  [ -n "$p1" ] && [ "$p1" = "$p2" ] || { warn "empty or didn't match - not changed"; return 1; }
  if dbq "select version()" | grep -qi mariadb; then dbx "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('$(sqs "$p1")'); FLUSH PRIVILEGES;"
  else dbx "ALTER USER 'root'@'localhost' IDENTIFIED BY '$(sqs "$p1")'; FLUSH PRIVILEGES;" && printf '[client]\nuser=root\npassword="%s"\n' "$p1" > /root/.my.cnf && chmod 600 /root/.my.cnf; fi
  tip "write it down for the team. Scored checks don't normally log in as the database root."
}
db_audit() {
  sub "Database (MySQL / MariaDB)"
  if ! pgrep -x mariadbd >/dev/null && ! pgrep -x mysqld >/dev/null; then
    if [ -s "$W/dbtargets" ]; then say "no database server on this box. The app's database is on ${BO}$(tr '\n' ' ' < "$W/dbtargets")${N}: tell whoever owns that box to check users, UDFs, FILE privilege and secure_file_priv."
    else ok "no MySQL/MariaDB server on this box"; fi
    pgrep -x postgres >/dev/null && warn "PostgreSQL is running here (not audited by this script): sudo -u postgres psql -c '\\du' -c '\\l'"
    return 0
  fi
  if ! dbq "select 1" | grep -q 1; then
    warn "can't log in to the database as root without a password"
    local pw; read -r -s -p "  Database root password (Enter = skip the database checks): " pw </dev/tty; echo
    [ -n "$pw" ] || return 0; export MYSQL_PWD="$pw"
    dbq "select 1" | grep -q 1 || { bad "that password didn't work - skipping the database checks"; unset MYSQL_PWD; return 0; }
    plan_add "keep the database root password in /root/.my.cnf (root-only) so backups and checks work" "printf '[client]\\nuser=root\\npassword=\"%s\"\\n' $(q "$pw") > /root/.my.cnf && chmod 600 /root/.my.cnf"
  fi
  local ver appu u h plugin nopw su fi gr name dl f x n=0 isapp
  ver=$(dbq "select version()"); say "server version: ${BO}$ver${N}"
  case "$ver" in 5.1.*|5.5.[0-9]|5.5.[0-9]-*|5.5.1[0-9]*|5.5.2[0-3]*|5.2.*|5.3.*) bad "version $ver may have CVE-2012-2122 (log in as root by retrying a wrong password). Lock root to localhost, update the package if you can.";; esac
  # the app's own database user(s): never touched by [a]ll
  appu=$(sed -nE 's#.*://([^:@/]+)[:@].*#\1#p; s#.*(DB_USER(NAME)?|MYSQL_USER|DATABASE_USER(NAME)?)["'"'"' ]*[=:][ "'"'"']*([^"'"'"' ;]+).*#\4#Ip' "$W/dburls" 2>/dev/null | sort -u | tr '\n' ' ')
  [ -n "$appu" ] && say "the web app logs in as: ${BO}$appu${N}(changing these breaks the app unless you update its config too)"
  say "database accounts:"
  while IFS=$'\t' read -r u h plugin nopw su fi gr; do
    [ -n "$h" ] || continue; n=$((n+1)); isapp=""; [ "$u" = "(anon)" ] && u=""; case " $appu " in *" $u "*) isapp=risky;; esac; local locked=""
    printf '      %-18s %-16s %-22s %s\n' "${u:-(anonymous)}" "$h" "$plugin" "$([ "$su$fi$gr" != NNN ] && echo "SUPER=$su FILE=$fi GRANT=$gr")"
    case "$u" in mariadb.sys|mysql.sys|mysql.session|mysql.infoschema|mysql) continue;; esac
    local acct="'$(sqs "$u")'@'$(sqs "$h")'"
    if [ -z "$u" ]; then bad "anonymous database login allowed from $h"; plan_add "remove anonymous database login @$h" "dbx $(q "DROP USER $acct")"; continue; fi
    if [ "$nopw" = 1 ] && [ "$plugin" != unix_socket ] && [ "$plugin" != auth_socket ] && [ "$plugin" != invalid ]; then bad "database account $u@$h has NO password"
      plan_add "lock database account $u@$h (no password)" "dbx $(q "ALTER USER $acct ACCOUNT LOCK")" "$isapp"; locked=1; fi
    if [ "$u" = root ]; then case "$h" in localhost|127.0.0.1|::1) ;; *) bad "database root can log in from the network ($h)"
      plan_add "lock database root@$h (network root login)" "dbx $(q "ALTER USER $acct ACCOUNT LOCK")" "$isapp";; esac; continue; fi
    [ "$fi" = Y ] && { bad "$u@$h has FILE privilege (read/write files on the server, e.g. drop a PHP webshell)"; plan_add "revoke FILE from $u@$h" "dbx $(q "REVOKE FILE ON *.* FROM $acct")" "$isapp"; }
    [ "$su" = Y ] && { bad "$u@$h has SUPER (database admin)"; plan_add "revoke SUPER from $u@$h" "dbx $(q "REVOKE SUPER ON *.* FROM $acct")" "$isapp"; }
    [ "$gr" = Y ] && { warn "$u@$h can GRANT privileges to others"; plan_add "revoke GRANT OPTION from $u@$h" "dbx $(q "REVOKE GRANT OPTION ON *.* FROM $acct")" "$isapp"; }
    if [ -z "$isapp" ] && [ "$u" != root ] && [ -z "$locked" ]; then warn "extra database account: $u@$h (not the app's) - could be red team, could be scored"
      plan_add "lock database account $u@$h (extra account) ${R}(check it isn't scored)${N}" "dbx $(q "ALTER USER $acct ACCOUNT LOCK")" risky; fi
  done < <(dbq "select if(user='','(anon)',user),host,plugin,authentication_string='',Super_priv,File_priv,Grant_priv from mysql.user")
  [ "$n" = 0 ] && warn "couldn't read mysql.user (not enough privilege?)"
  # user-defined functions = run system commands from SQL
  while IFS=$'\t' read -r name dl; do [ -n "$name" ] || continue
    bad "user-defined function ${BO}$name${N} from $dl (runs code inside the database server)"
    plan_add "drop database function $name (UDF from $dl)" "dbx $(q "DROP FUNCTION IF EXISTS \`$name\`")"
  done < <(dbq "select name,dl from mysql.func")
  x=$(dbq "select @@plugin_dir")
  [ -d "$x" ] && for f in "$x"/*.so; do [ -f "$f" ] || continue; owned "$f" && continue
    bad "database plugin file not from a package: $f"; plan_add "quarantine database plugin $f" "quar $(q "$f")"; done
  # settings
  x=$(dbq "select @@secure_file_priv"); case "$x" in
    "") bad "secure_file_priv is EMPTY: SQL can read/write files anywhere mysqld can (INTO OUTFILE -> webshell)"
        tip "fix (needs a database restart = brief outage): add 'secure_file_priv=/var/lib/mysql-files' under [mysqld] in /etc/my.cnf.d/, mkdir that folder (owner mysql), restart mariadb";;
    NULL) ok "secure_file_priv = NULL (file import/export disabled)";; *) ok "secure_file_priv limited to $x";; esac
  if [ "$(dbq "select @@local_infile")" = 1 ]; then warn "local_infile is ON (clients can make the server read their files)"
    plan_add "turn off local_infile (now + after restart)" "dbx 'SET GLOBAL local_infile=0' && mkdir -p /etc/my.cnf.d && printf '[mysqld]\nlocal_infile=0\n' > /etc/my.cnf.d/zz-tk.cnf"; fi
  x=$(dbq "select @@bind_address"); say "listens on: ${BO}${x:-all addresses}${N} $(case "$x" in 127.*|localhost|::1) echo "(local only)";; *) echo "(other boxes can connect - fine if they need to; the firewall keeps it open)";; esac)"
  # databases + columns that look like credentials / personal data
  x=$(dbq "show databases" | grep -vxE 'information_schema|performance_schema|mysql|sys' | tr '\n' ' ')
  say "databases: ${BO}${x:-none}${N}"
  x=$(dbq "select concat(table_schema,'.',table_name,'.',column_name) from information_schema.columns where table_schema not in ('information_schema','performance_schema','mysql','sys') and column_name regexp 'pass|pwd|hash|secret|token|card|ccn|cvv|ssn|social|email|phone|address|dob|birth' limit 40")
  [ -n "$x" ] && { warn "columns that look like passwords or personal data (protect these; mention in reports):"; echo "$x" | sed 's/^/      /'; }
  plan_add "set a NEW password for the database root (you type it; root still logs in locally without one on MariaDB)" "db_rootpw" risky
  tip "dumps of every database are in the backup step (README.gz). Nothing here deletes data."
  return 0
}

# ======================================================================
#  SSH
# ======================================================================
cmd_ssh() {
  hdr "SSH HARDENING"
  local f=/etc/ssh/sshd_config.d/00-ccdc.conf
  tip "Password login stays ON (SSH may be scored). Root login, tunnels and stray key files get turned off."
  say "current: $(sshd -T 2>/dev/null | grep -iE '^(permitrootlogin|passwordauthentication|authorizedkeysfile|maxauthtries) ' | tr '\n' ' ')"
  plan_reset
  plan_add "write $f: no root login, 3 tries, no forwarding/tunnels, standard key file, keep passwords" "ssh_apply"
  plan_apply
}
ssh_apply() {
  local f=/etc/ssh/sshd_config.d/00-ccdc.conf
  grep -qE '^\s*Include\s+/etc/ssh/sshd_config.d' /etc/ssh/sshd_config || { bad "sshd_config has no Include line for sshd_config.d - not touching it"; return 1; }
  bk /etc/ssh/sshd_config; bk "$f"
  cat > "$f" <<'CONF'
# CCDC hardening - first match wins, so this file must sort first
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
CONF
  chmod 600 "$f"; have restorecon && restorecon "$f" 2>/dev/null
  if sshd -t; then systemctl reload sshd 2>/dev/null || systemctl restart sshd; ok "sshd reloaded (your current SSH session stays open)"
  else bad "sshd -t failed - removing the change"; rm -f "$f"; return 1; fi
  sshd -T | grep -iE '^(permitrootlogin|passwordauthentication|authorizedkeysfile|maxauthtries) ' | sed 's/^/      /'
  tip "Test from a NEW terminal before closing this one:  ssh ccdcuser1@192.168.220.231"
}

# ======================================================================
#  WEB APP DISCOVERY (read-only) - writes facts to /root/tk/web/ for every other step
# ======================================================================
NOT_HTTP=" 22 25 53 88 110 111 135 139 143 389 445 465 587 636 993 995 1433 2049 3306 5432 6379 9090 11211 27017 "
cmd_web() {
  hdr "FIND THE WEB APP"
  tip "Read-only. Figures out what 'Home Manager' is, where its files live, and where its database is."
  : > "$W/urls"; : > "$W/pids"; : > "$W/units"; : > "$W/dirs"; : > "$W/configs"; : > "$W/dbtargets"; : > "$W/sqlite"; : > "$W/localdb"; : > "$W/dburls"; : > "$W/containers"
  local tmpb="$D/.body" tmph="$D/.hdr" l addr port proc pids scheme code title srv t

  sub "Listening ports"
  ss -Htlnp 2>/dev/null | awk '{print $4, $6}' | sort -u | while read -r addr proc; do
    port=${addr##*:}; local name; name=$(echo "$proc" | grep -o '(("[^"]*"' | head -1 | tr -d '(")')
    case "$addr" in 127.*|"[::1]"*|*%lo*) printf '      %-6s %-14s %s\n' "$port" "local-only" "$name";; *) printf '      %-6s %-14s %s\n' "$port" "open" "$name";; esac
  done
  ss -Htlnp 2>/dev/null | awk '{print $4"|"$6}' > "$D/.listen"
  ss -Hulnp 2>/dev/null | awk '{print $4, $6}' | grep -v '127.0.0.5[34]' | sed 's/^/      udp /' | head -10

  sub "Which ports answer like a website"
  while IFS='|' read -r addr proc; do
    port=${addr##*:}; case "$NOT_HTTP" in *" $port "*) continue;; esac
    pids=$(echo "$proc" | grep -o 'pid=[0-9]*' | cut -d= -f2 | tr '\n' ' ')
    for scheme in https http; do
      code=$(curl -sk -m 4 -o "$tmpb" -D "$tmph" -w '%{http_code}' "$scheme://127.0.0.1:$port/" 2>/dev/null)
      [ -n "$code" ] && [ "$code" != 000 ] || continue
      title=$(tr -d '\r\n' < "$tmpb" | grep -oiE '<title[^>]*>[^<]*' | head -1 | sed -E 's/<title[^>]*>//I' | cut -c1-60)
      srv=$(grep -i '^server:' "$tmph" | head -1 | cut -d' ' -f2- | tr -d '\r'); t=$(grep -ci 'x-powered-by' "$tmph")
      printf '      %s%-28s%s %s  %-24s %s\n' "$G" "$scheme://127.0.0.1:$port/" "$N" "$code" "${srv:-?}" "${title:-(no title)}"
      local sc=0; case "$addr" in 127.*|"[::1]"*|*%lo*) ;; *) sc=$((sc+3));; esac
      case "$code" in 2*|3*) sc=$((sc+2));; 401|403) sc=$((sc+1));; *) sc=$((sc-5));; esac
      [ -n "$title" ] && sc=$((sc+1)); case "$port" in 80|443) sc=$((sc+1));; esac
      echo "$sc|$scheme://127.0.0.1:$port/|$code|${srv}|${title}|${addr}" >> "$W/urls.tmp"
      case "$code" in 2*|3*|401|403) for l in $pids; do echo "$l" >> "$W/pids"; done;; esac
      break
    done
  done < "$D/.listen"
  [ -f "$W/urls.tmp" ] && { sort -t'|' -k1 -nr "$W/urls.tmp" | awk -F'|' '$1>=0' | cut -d'|' -f2- > "$W/urls"; rm -f "$W/urls.tmp"; }
  [ -s "$W/urls" ] || warn "nothing answered over HTTP(S) locally. Is the app stopped? Check: systemctl --failed ; podman ps -a ; docker ps -a"

  # containers
  local cr; for cr in podman docker; do have $cr || continue
    $cr ps --format '{{.Names}}|{{.Image}}|{{.Ports}}' 2>/dev/null | while IFS='|' read -r n i p; do echo "$cr|$n|$i|$p" >> "$W/containers"; done
  done
  if [ -s "$W/containers" ]; then sub "Containers"; sed 's/|/  /g; s/^/      /' "$W/containers"
    while IFS='|' read -r cr n i p; do
      $cr inspect -f '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$n" 2>/dev/null | grep '^/' >> "$W/dirs"
      $cr inspect -f '{{range .Config.Env}}{{.}}{{"\n"}}{{end}}' "$n" 2>/dev/null | grep -iE 'DB|DATABASE|SQL|PG|MYSQL|REDIS|MONGO|HBOX|DSN' | sed "s|^|$n env: |" >> "$W/dburls"
    done < "$W/containers"; fi

  sub "Who serves it (process, service, files)"
  sort -u "$W/pids" -o "$W/pids"
  local p par exe cwd unit wd envf usr
  for p in $(cat "$W/pids"); do
    [ -d "/proc/$p" ] || continue
    # walk up to the main process (skip worker children)
    par=$(awk '/^PPid/{print $2}' "/proc/$p/status" 2>/dev/null)
    [ -n "$par" ] && [ "$par" -gt 1 ] && [ "$(readlink /proc/$par/exe 2>/dev/null)" = "$(readlink /proc/$p/exe 2>/dev/null)" ] && p=$par
    exe=$(readlink -f "/proc/$p/exe" 2>/dev/null); cwd=$(readlink -f "/proc/$p/cwd" 2>/dev/null)
    usr=$(stat -c %U "/proc/$p" 2>/dev/null)
    unit=$(systemctl status "$p" --no-pager 2>/dev/null | head -1 | grep -oE '[A-Za-z0-9@_.:-]+\.service' | head -1)
    echo "      ${BO}PID $p${N}  $exe  ${DIM}(user $usr, pkg: $(owner_pkg "$exe" || echo none))${N}"
    echo "        cmd : $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-110)"
    echo "        cwd : $cwd"
    [ -n "$unit" ] && { echo "        unit: $unit"; echo "$unit" >> "$W/units"
      wd=$(systemctl show -p WorkingDirectory --value "$unit" 2>/dev/null); [ -n "$wd" ] && [ "$wd" != "/" ] && echo "$wd" >> "$W/dirs"
      envf=$(systemctl show -p EnvironmentFiles --value "$unit" 2>/dev/null | awk '{print $1}'); [ -n "$envf" ] && { echo "        env file: $envf"; echo "$envf" >> "$W/configs"; }; }
    case "$cwd" in /|/root|"") ;; *) echo "$cwd" >> "$W/dirs";; esac
    case "$exe" in /usr/*) ;; *) dirname "$exe" >> "$W/dirs";; esac
    tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -E '^(HBOX_|[A-Z0-9_]*(DB_|DATABASE|_DSN|SQLITE|POSTGRES|PGHOST|PGDATABASE|MYSQL|MARIADB|REDIS_URL|MONGO))[A-Z0-9_]*=' >> "$W/dburls"
    ls -l "/proc/$p/fd" 2>/dev/null | grep -oE '/[^ ]+\.(db|sqlite3?|db3)$' >> "$W/sqlite"
  done

  # reverse proxies and their roots/backends
  if have nginx && pgrep -x nginx >/dev/null; then
    nginx -T 2>/dev/null > "$D/.nginx"
    grep -E '^\s*root\s' "$D/.nginx" | awk '{print $2}' | tr -d ';' >> "$W/dirs"
    grep -E 'proxy_pass|fastcgi_pass|uwsgi_pass' "$D/.nginx" | sed 's/^\s*/        nginx: /' | sort -u
    echo nginx.service >> "$W/units"
  fi
  if have httpd && pgrep -x httpd >/dev/null; then
    grep -rhE '^\s*DocumentRoot' /etc/httpd/ 2>/dev/null | awk '{print $2}' | tr -d '"' >> "$W/dirs"
    grep -rhE 'ProxyPass\s' /etc/httpd/ 2>/dev/null | sed 's/^\s*/        httpd: /' | sort -u
    echo httpd.service >> "$W/units"
  fi
  [ -f /etc/caddy/Caddyfile ] && { grep -E 'root|reverse_proxy' /etc/caddy/Caddyfile | sed 's/^\s*/        caddy: /'; echo caddy.service >> "$W/units"; }
  pgrep -f php-fpm >/dev/null && echo php-fpm.service >> "$W/units"

  # clean dir list: existing, not system dirs, unique
  sort -u "$W/dirs" | while read -r l; do [ -d "$l" ] || continue; case "$l" in /|/usr|/usr/*bin|/usr/local|/usr/local/*bin|/usr/lib*|/usr/libexec|/bin|/sbin|/etc|/root|/home|/var|/var/lib|/tmp|/proc|/opt|/srv) continue;; esac; echo "$l"; done > "$W/dirs.tmp"; mv "$W/dirs.tmp" "$W/dirs"
  sort -u "$W/units" -o "$W/units"

  sub "App files"
  if [ -s "$W/dirs" ]; then while read -r l; do echo "      $l  ${DIM}($(timeout 20 du -sh "$l" 2>/dev/null | cut -f1))${N}"; done < "$W/dirs"
  else warn "couldn't tell where the app's files are"; fi
  [ -s "$W/dirs" ] && find $(cat "$W/dirs") -maxdepth 3 -type f -size -2M \( -name '.env*' -o -name '*.env' -o -name 'config.*' -o -name 'settings*.py' -o -name 'appsettings*.json' \
       -o -name 'application*.properties' -o -name 'application*.y*ml' -o -name 'database.y*ml' -o -name 'wp-config.php' -o -name '*.ini' -o -name '*.toml' \
       -o -name 'docker-compose*.y*ml' -o -name 'compose*.y*ml' -o -name 'local_settings.py' -o -name 'parameters.yml' \) 2>/dev/null | grep -v node_modules >> "$W/configs"
  sort -u "$W/configs" -o "$W/configs"
  [ -s "$W/configs" ] && { say "config files:"; sed 's/^/      /' "$W/configs"; }

  sub "Database (where the app keeps its data)"
  local cf
  while read -r cf; do [ -f "$cf" ] || continue
    grep -IhoE '(mysql|mariadb|postgres(ql)?|pgsql|sqlserver|mssql|mongodb(\+srv)?|redis)://[^ "'"'"'<>]+' "$cf" 2>/dev/null | sed "s|^|$cf: |" >> "$W/dburls"
    grep -IhE '^\s*[A-Za-z_]*(DB_HOST|DB_PORT|DB_NAME|DB_USER|DATABASE_URL|DB_TYPE|DB_DRIVER|DB_CONNECTION|DB_DATABASE|DB_PATH|SQLITE)[A-Za-z_]*\s*[=:]' "$cf" 2>/dev/null | sed "s|^|$cf: |" >> "$W/dburls"
    grep -IhoE '(Server|Data Source|Host)=[^;"]+;[^"]*' "$cf" 2>/dev/null | sed "s|^|$cf: |" >> "$W/dburls"
    grep -IhoE "define\(\s*'DB_(HOST|NAME|USER)'[^)]*\)" "$cf" 2>/dev/null | sed "s|^|$cf: |" >> "$W/dburls"
  done < "$W/configs"
  sort -u "$W/dburls" -o "$W/dburls"
  timeout 60 find $(cat "$W/dirs") /var/lib /opt /srv /data -maxdepth 5 -type f -size +0 \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db3' \) 2>/dev/null \
    | grep -vE '/var/lib/(rpm|dnf|sss|PackageKit|systemd|selinux|alternatives|flatpak|fwupd|NetworkManager|cockpit|polkit|colord|libvirt)|/usr/share|\.cache/' >> "$W/sqlite"
  sort -u "$W/sqlite" -o "$W/sqlite"
  # live connections from the app to a database
  local apids; apids=$(cat "$W/pids" | tr '\n' '|' | sed 's/|$//')
  if [ -n "$apids" ]; then
    ss -Htnp state established 2>/dev/null | grep -E "pid=($apids)," | awk '{print $4}' | while read -r l; do
      port=${l##*:}; case " 3306 5432 1433 27017 6379 1521 9042 " in *" $port "*) echo "${l%:*}:$port" >> "$W/dbtargets";; esac; done
  fi
  # host:port written in configs/env
  grep -oE '@[A-Za-z0-9._-]+:[0-9]{2,5}' "$W/dburls" 2>/dev/null | tr -d @ >> "$W/dbtargets"
  grep -iE 'DB_HOST' "$W/dburls" 2>/dev/null | sed -E 's/.*[=:]\s*["'"'"']?([A-Za-z0-9._-]+).*/\1/' | while read -r h; do
    local dp; dp=$(grep -iE 'DB_PORT' "$W/dburls" | head -1 | grep -oE '[0-9]{2,5}' | tail -1); echo "$h:${dp:-3306}" >> "$W/dbtargets"; done
  sed -i -E 's/^\[([^]]*)\]/\1/; /^(localhost|127\.0\.0\.1|::1):/d' "$W/dbtargets"; sort -u "$W/dbtargets" -o "$W/dbtargets"
  for l in mysqld mariadbd postgres mongod redis-server sqlservr; do pgrep -x "$l" >/dev/null && echo "$l" >> "$W/localdb"; done
  sort -u "$W/localdb" -o "$W/localdb"

  [ -s "$W/localdb" ] && ok "database running ON this box: ${BO}$(tr '\n' ' ' < "$W/localdb")${N}"
  [ -s "$W/sqlite" ]  && { ok "SQLite database file(s) (data lives in a file):"; sed 's/^/      /' "$W/sqlite"; }
  [ -s "$W/dbtargets" ] && { ok "database on ANOTHER box (the firewall will allow exactly these):"; sed "s/^/      ${BO}/; s/$/${N}/" "$W/dbtargets"; }
  [ -s "$W/dburls" ] && { say "database settings found (passwords hidden):"; sed -E 's/(:\/\/[^:@\/]+:)[^@]*@/\1****@/; s/((PASS|PASSWORD|PWD)[A-Z_]*\s*[=:]\s*).*/\1****/I; s/(Password|Pwd)=[^;]*/\1=****/I' "$W/dburls" | head -15 | sed 's/^/      /'; }
  [ -s "$W/localdb" ] || [ -s "$W/sqlite" ] || [ -s "$W/dbtargets" ] || warn "no database found yet. Jesse's fallback: the firewall will also allow outbound 3306/5432/1433 to the LAN."
  chmod 600 "$W"/* 2>/dev/null

  sub "Summary"
  local first; first=$(head -1 "$W/urls" 2>/dev/null)
  if [ -n "$first" ]; then
    IFS='|' read -r u c s ti a <<<"$first"
    say "Home Manager is most likely: ${BO}${ti:-untitled app}${N} at ${BO}$u${N} (${s:-unknown server})"
    say "Services to keep alive: ${BO}$(tr '\n' ' ' < "$W/units")${N}"
    [ -f "$W/title" ] || echo "$ti" > "$W/title"
  fi
  note "web discovery: $(wc -l < "$W/urls") url(s), $(wc -l < "$W/dbtargets") remote db, $(wc -l < "$W/sqlite") sqlite, $(tr '\n' ' ' < "$W/localdb")"
}

# ======================================================================
#  BACKUP (disguised, backdated, optional encryption) + database dump
# ======================================================================
BK_DECOYS="libsss_certmap-extra python3-pyasn1-doc libnfsidmap-plugins perl-Text-Tabs-doc libverto-libev-doc xorg-x11-fonts-misc-doc libgpg-error-extra libtevent-doc"
BK_CONF="/etc/ssh /etc/pam.d /etc/passwd /etc/shadow /etc/group /etc/gshadow /etc/sudoers /etc/sudoers.d /etc/nginx /etc/httpd /etc/caddy /etc/php.ini /etc/php.d /etc/php-fpm.d /etc/php-fpm.conf /etc/firewalld /etc/sysconfig /etc/systemd/system /etc/crontab /etc/cron.d /etc/selinux/config /etc/hosts /etc/resolv.conf /etc/my.cnf /etc/my.cnf.d /etc/sssd /etc/krb5.conf /etc/tk /var/spool/cron"
TAROPT=(); tar --help 2>/dev/null | grep -q -- '--selinux' && TAROPT=(--selinux --xattrs --acls)
bk_enc() { if [ -n "$BKPASS" ]; then openssl enc -aes-256-cbc -pbkdf2 -salt -pass env:BKPASS; else cat; fi; }
bk_dec() { if [ "$1" = 1 ]; then openssl enc -d -aes-256-cbc -pbkdf2 -pass env:BKPASS; else cat; fi; }
bk_hide(){ local ref=/usr/share/doc/bash/README; [ -e "$ref" ] || ref=/etc/hostname; local f; for f in "$@"; do [ -e "$f" ] && touch -h -r "$ref" "$f"; done; }
tarz() { tar -czf - "${TAROPT[@]}" "$@" 2>/dev/null | bk_enc; }   # tar to stdout, encrypted if a passphrase is set

cmd_backup() {
  hdr "BACKUP (disguised) + DATABASE DUMP"
  tip "Saved as fake package docs with old timestamps. Optional passphrase encrypts them (configs hold DB passwords)."
  tip "Every part has a timeout and a live timer. Ctrl-C stops it and asks: skip / retry / quit."
  [ -s "$W/urls" ] || { warn "web app not discovered yet - running discovery first"; cmd_web >/dev/null 2>&1; }
  local a b2; BKPASS=""
  read -r -s -p "  Backup passphrase (Enter = none): " a </dev/tty; echo
  if [ -n "$a" ]; then read -r -s -p "  Confirm: " b2 </dev/tty; echo; [ "$a" = "$b2" ] && export BKPASS="$a" || warn "didn't match - saving UNencrypted"; fi
  local enc=0; [ -n "$BKPASS" ] && enc=1
  local pkgs=($BK_DECOYS) pkg d1 d2=/usr/share/locale/en_GB/LC_MESSAGES
  for pkg in $(printf '%s\n' "${pkgs[@]}" | shuf); do [ -e "/usr/share/doc/$pkg" ] || break; done
  d1=/usr/share/doc/$pkg; mkdir -p "$d2"
  local t_doc t_d2; t_doc=$(stat -c %Y /usr/share/doc); t_d2=$(stat -c %Y "$d2")
  mkdir -p "$d1"; chmod 755 "$d1"
  local p conf=(); for p in $BK_CONF; do [ -e "$p" ] && conf+=("$p"); done

  sub "1/3 configs"
  tmo 120 "saving configs" bash -c "$(declare -f bk_enc tarz); TAROPT=(${TAROPT[*]}); tarz $(printf '%q ' "${conf[@]}") > $(q "$d1/changelog.gz")" \
    && ok "configs saved ($(du -h "$d1/changelog.gz" | cut -f1))"

  sub "2/3 web app files"
  local dirs=() l sz
  while read -r l; do [ -d "$l" ] || continue; sz=$(timeout 30 du -sm "$l" 2>/dev/null | cut -f1)
    if [ "${sz:-0}" -gt 1500 ]; then warn "skipping $l (${sz} MB is too big for a quick backup)"; else dirs+=("$l"); fi; done < "$W/dirs"
  if [ ${#dirs[@]} -gt 0 ]; then
    say "app folders: ${dirs[*]}"
    tmo 300 "saving app files" bash -c "$(declare -f bk_enc tarz); TAROPT=(${TAROPT[*]}); tarz --exclude='*/node_modules' --exclude='*/.cache' --exclude='*.log' $(printf '%q ' "${dirs[@]}") > $(q "$d1/NEWS.gz")" \
      && ok "app files saved ($(du -h "$d1/NEWS.gz" | cut -f1))"
  else warn "no app folders known (run 'web' first). Skipped."; fi

  sub "3/3 database"
  local db="$D/.dbdump"; rm -rf "$db"; mkdir -p "$db"; chmod 700 "$db"
  local f i=0
  while read -r f; do [ -f "$f" ] || continue; i=$((i+1))
    if have sqlite3; then tmo 120 "copying $f safely" sqlite3 "$f" ".backup '$db/sqlite$i.db'"; else cp --sparse=always "$f" "$db/sqlite$i.db"; fi
    echo "sqlite$i.db|$f" >> "$db/paths.txt" && ok "SQLite copied: $f"
  done < "$W/sqlite"
  if grep -qE 'mysqld|mariadbd' "$W/localdb" 2>/dev/null; then
    if tmo 300 "dumping local MySQL/MariaDB" bash -c "mysqldump --all-databases --single-transaction --routines --events 2>$db/mysql.err > $db/mysql-all.sql"; then ok "local MySQL dumped ($(du -h "$db/mysql-all.sql" | cut -f1))"
    else warn "local mysqldump failed: $(head -1 "$db/mysql.err"). Try with the app's DB user: see guide."; fi; fi
  if grep -q postgres "$W/localdb" 2>/dev/null; then
    tmo 300 "dumping local PostgreSQL" bash -c "runuser -u postgres -- pg_dumpall > $db/postgres-all.sql 2>$db/pg.err" && ok "local PostgreSQL dumped" || warn "pg_dumpall failed: $(head -1 "$db/pg.err")"; fi
  local url
  grep -oE '(mysql|mariadb|postgres(ql)?)://[^ "'"'"']+' "$W/dburls" 2>/dev/null | sort -u | while read -r url; do
    local proto=${url%%://*} rest=${url#*://} cred hostp dbn usr pw host port
    cred=${rest%@*}; hostp=${rest##*@}; dbn=${hostp#*/}; dbn=${dbn%%\?*}; hostp=${hostp%%/*}
    usr=${cred%%:*}; pw=${cred#*:}; host=${hostp%:*}; port=${hostp##*:}; [ "$port" = "$hostp" ] && port=""
    case "$proto" in
      mysql|mariadb) have mysqldump || { warn "remote MySQL found ($host) but mysqldump isn't installed: dnf -y install mariadb"; continue; }
        export MYSQL_PWD="$pw"; tmo 300 "dumping $dbn from $host" bash -c "mysqldump -h $(q "$host") -P ${port:-3306} -u $(q "$usr") --single-transaction $(q "$dbn") > $(q "$db/remote-$host-$dbn.sql")" && ok "dumped $dbn from $host"; unset MYSQL_PWD;;
      postgres*) have pg_dump || { warn "remote PostgreSQL found ($host) but pg_dump isn't installed: dnf -y install postgresql"; continue; }
        tmo 300 "dumping $dbn from $host" bash -c "pg_dump $(q "$url") > $(q "$db/remote-$host-$dbn.sql")" && ok "dumped $dbn from $host";;
    esac
  done
  if [ -n "$(ls -A "$db" 2>/dev/null | grep -v '\.err$')" ]; then
    tmo 120 "packing database dump" bash -c "$(declare -f bk_enc); cd $(q "$db") && tar -czf - --exclude='*.err' . | bk_enc > $(q "$d1/README.gz")" && ok "database saved ($(du -h "$d1/README.gz" | cut -f1))"
  else warn "no database dump made (nothing found, or the dumps failed)"; fi
  rm -rf "$db"

  printf 'Extra documentation for this package.\n' | gzip > "$d1/copyright.gz"
  [ -f "$d1/changelog.gz" ] && cp "$d1/changelog.gz" "$d2/$pkg.mo"
  chmod 644 "$d1"/* "$d2/$pkg.mo" 2>/dev/null
  bk_hide "$d1"/* "$d1" "$d2/$pkg.mo"; touch -d "@$t_doc" /usr/share/doc; touch -d "@$t_d2" "$d2"
  echo "$(date '+%H:%M')|$enc|$d1|$d2/$pkg.mo" >> "$D/backup.list"; chmod 600 "$D/backup.list"
  unset BKPASS
  ok "saved to ${BO}$d1/${N}  (+ copy of configs: $d2/$pkg.mo)  encrypted: $([ $enc = 1 ] && echo yes || echo no)"
  tip "Write the folder name (${BO}$pkg${N}) on the team sheet. Restore: bash $0 restore"
  note "backup -> $d1 (enc=$enc)"
}

cmd_restore() {   # restore [ssh|pam|web|app|db|etc|list]
  hdr "RESTORE"
  [ -s "$D/backup.list" ] || { bad "no backups recorded yet"; return 1; }
  local i=0 tm en d1 d2 n=1 line what=$2
  echo "  Backups (1 = first = cleanest):"
  while IFS='|' read -r tm en d1 d2; do i=$((i+1)); echo "   $i) $tm  $d1  encrypted=$([ "$en" = 1 ] && echo yes || echo no)"; done < "$D/backup.list"
  [ "$i" -gt 1 ] && { read -r -p "  Which backup? [1]: " n </dev/tty; n=${n:-1}; }
  line=$(sed -n "${n}p" "$D/backup.list"); [ -n "$line" ] || { bad "no backup #$n"; return 1; }
  IFS='|' read -r tm en d1 d2 <<<"$line"
  if [ -z "$what" ]; then
    echo "  What to restore:"
    echo "    ssh   - /etc/ssh             pam  - /etc/pam.d           web - nginx/httpd/php config"
    echo "    app   - the web app's files   db   - the app's database   etc - ALL saved configs"
    echo "    list  - just show what's inside"
    read -r -p "  Type one: " what </dev/tty
  fi
  [ "$en" = 1 ] && { read -r -s -p "  Backup passphrase: " BKPASS </dev/tty; echo; export BKPASS; }
  local arch members=() svc=()
  case "$what" in
    ssh) arch=$d1/changelog.gz; members=(etc/ssh); svc=(sshd);;
    pam) arch=$d1/changelog.gz; members=(etc/pam.d);;
    web) arch=$d1/changelog.gz; for l in etc/nginx etc/httpd etc/caddy etc/php.ini etc/php.d etc/php-fpm.d; do members+=("$l"); done; svc=($(cat "$W/units" 2>/dev/null));;
    etc) arch=$d1/changelog.gz;;
    app) arch=$d1/NEWS.gz; svc=($(cat "$W/units" 2>/dev/null));;
    db)  arch=$d1/README.gz;;
    list) arch=$d1/changelog.gz;;
    *) bad "unknown choice: $what"; return 1;;
  esac
  [ -s "$arch" ] || { [ "$arch" = "$d1/changelog.gz" ] && [ -s "$d2" ] && arch=$d2 && warn "main copy missing - using the second copy"; }
  [ -s "$arch" ] || { bad "backup file missing: $arch (deleted?)"; return 1; }
  bk_dec "$en" < "$arch" | tar -tzf - >/dev/null 2>&1 || { bad "can't open the backup (wrong passphrase?)"; return 1; }
  if [ "$what" = list ]; then for arch in "$d1"/*.gz; do echo "  ${BO}$(basename "$arch")${N}"; bk_dec "$en" < "$arch" | tar -tzf - 2>/dev/null | awk -F/ 'NF>1{print "    "$1"/"$2}' | sort -u | head -30; done; return; fi
  if [ "$what" = db ]; then
    local tmp="$D/.dbrestore"; rm -rf "$tmp"; mkdir -p "$tmp"; bk_dec "$en" < "$arch" | tar -xzf - -C "$tmp"
    ls -la "$tmp" | sed 's/^/    /'
    if [ -f "$tmp/paths.txt" ]; then while IFS='|' read -r f orig; do
      if ask "Put SQLite file back at $orig? (the app's services are stopped, the current file is kept as a copy)"; then
        local u; for u in $(cat "$W/units" 2>/dev/null); do systemctl stop "$u" 2>/dev/null; done
        local own; own=$(stat -c %u:%g "$orig" 2>/dev/null)
        cp -a "$orig" "$BAK/$(echo "$orig" | tr / _).$(TS)" 2>/dev/null; cp "$tmp/$f" "$orig"
        [ -n "$own" ] && chown "$own" "$orig"; have restorecon && restorecon "$orig"
        for u in $(cat "$W/units" 2>/dev/null); do systemctl start "$u" 2>/dev/null; done; ok "restored $orig and restarted the app"; note "RESTORED sqlite $orig"
      fi; done < "$tmp/paths.txt"; fi
    [ -f "$tmp/mysql-all.sql" ] && { say "MySQL dump: $tmp/mysql-all.sql"; tip "restore ALL databases:  mysql < $tmp/mysql-all.sql   (only if the data is really damaged)"; }
    ls "$tmp"/remote-*.sql 2>/dev/null | while read -r f; do tip "remote dump: $f  ->  mysql -h HOST -u USER -p DBNAME < $f  (coordinate with the DB box owner)"; done
    tip "Dumps stay in $tmp until you delete them."
    return
  fi
  local cur="$BAK/pre-restore-$what-$(TS).tgz"
  if [ ${#members[@]} -gt 0 ]; then tar -czf "$cur" $(printf '/%s ' "${members[@]}") 2>/dev/null
  elif [ "$what" = app ]; then tar -czf "$cur" $(cat "$W/dirs") 2>/dev/null; fi
  [ -s "$cur" ] && ok "current state saved first (undo): $cur"
  local avail=(); for l in "${members[@]}"; do bk_dec "$en" < "$arch" | tar -tzf - 2>/dev/null | grep -q "^$l" && avail+=("$l"); done
  if [ ${#members[@]} -gt 0 ] && [ ${#avail[@]} -eq 0 ]; then bad "that part isn't in this backup"; return 1; fi
  bk_dec "$en" < "$arch" | tar -xzf - "${TAROPT[@]}" -C / "${avail[@]}" && ok "restored ${avail[*]:-all of $(basename "$arch")} from backup $n ($tm)" && note "RESTORED $what"
  have restorecon && { for l in "${avail[@]}"; do restorecon -R "/$l" 2>/dev/null; done; [ "$what" = app ] && restorecon -R $(cat "$W/dirs") 2>/dev/null; }
  local u; for u in "${svc[@]}"; do
    case "$u" in nginx.service) nginx -t 2>/dev/null || { bad "nginx config test failed - not restarting"; continue; };; httpd.service) httpd -t 2>/dev/null || { bad "httpd config test failed"; continue; };; esac
    systemctl restart "$u" && ok "restarted $u" || bad "$u failed to restart: journalctl -u $u -n 30"; done
  unset BKPASS; tip "Next: bash $0 check"
}

# ======================================================================
#  FIREWALL (nftables table "tk_fw", layered in front of firewalld; firewalld is left alone)
#  learn = inbound locked, outbound allowed + logged      lock = outbound allowlist only
# ======================================================================
FW=$D/fw; mkdir -p "$FW"
lan_name() { case "$1" in 192.168.220.2) echo "vigra (router)";; 192.168.220.79) echo "vattar (AD/DNS)";; 192.168.220.10) echo "borgar (food ordering)";;
  192.168.220.30) echo "kolla (fileshare)";; 192.168.220.100) echo "gufu (Gitea)";; 192.168.220.67) echo "haf (Wabbit)";; 192.168.220.44) echo "kvigindis (help site)";;
  192.168.220.97) echo "skerja (tickets)";; 192.168.220.222) echo "djupi (POS)";; 192.168.220.231) echo "thorska (this box)";; 192.168.220.*) echo "LAN host (not in packet!)";; *) echo "internet";; esac; }
fw_in_ports() {  # $1 = tcp|udp : every port listening on a non-loopback address, plus 22 for tcp
  local fl=-Htln; [ "$1" = udp ] && fl=-Huln
  { [ "$1" = tcp ] && echo 22; ss $fl 2>/dev/null | awk '{print $4}' | grep -vE '^(127\.|\[::1\]|.*%lo)' | sed 's/.*://'; } | grep -E '^[0-9]+$' | grep -vxE '2375|2376' | sort -nu | tr '\n' ',' | sed 's/,$//'   # never open the Docker API
}
fw_joined() { realm list 2>/dev/null | grep -q domain-name || svc_active sssd; }
fw_render() {  # fw_render learn|lock  -> $FW/rules.nft
  local mode=$1 tcp udp l
  tcp=$(fw_in_ports tcp); udp=$(fw_in_ports udp)
  {
    echo "table inet tk_fw"; echo "delete table inet tk_fw"
    echo "table inet tk_fw {"
    if [ -n "$tcp" ]; then echo "  set in_tcp { type inet_service; elements = { $tcp }; }"; else echo "  set in_tcp { type inet_service; }"; fi
    if [ -n "$udp" ]; then echo "  set in_udp { type inet_service; elements = { $udp }; }"; else echo "  set in_udp { type inet_service; }"; fi
    echo "  set sshrate { type ipv4_addr; size 65535; flags dynamic,timeout; timeout 1m; }"
    echo "  chain input {"
    echo "    type filter hook input priority -5; policy drop;"
    echo "    iif \"lo\" accept"
    for l in docker0 'br-*' 'podman*' 'cni-podman*'; do echo "    iifname \"$l\" tcp dport != { 2375, 2376 } accept"; done   # containers <-> host
    echo "    ct state established,related accept"
    echo "    ct state invalid drop"
    echo "    meta l4proto { icmp, ipv6-icmp } accept"
    echo "    tcp dport 22 ct state new add @sshrate { ip saddr limit rate over 30/minute burst 30 packets } drop"
    echo "    tcp dport @in_tcp accept"
    echo "    udp dport @in_udp accept"
    echo "    udp sport 67 udp dport 68 accept"
    echo "    udp dport 546 accept"
    echo "    limit rate 6/minute log prefix \"TK-IN-DROP \" level info"
    echo "    counter"
    echo "  }"
    echo "  chain output {"
    echo "    type filter hook output priority -5; policy $([ "$mode" = lock ] && echo drop || echo accept);"
    echo "    oif \"lo\" accept"
    for l in docker0 'br-*' 'podman*' 'cni-podman*'; do echo "    oifname \"$l\" accept"; done   # host -> its own containers (web server proxying to a container)
    echo "    ct state established,related accept"
    echo "    meta l4proto { icmp, ipv6-icmp } accept"
    echo "    udp dport { 53, 67, 123, 547 } accept"
    echo "    tcp dport 53 accept"
    if fw_joined; then echo "    ip daddr $DC tcp dport { 88, 135, 389, 445, 464, 636, 3268, 3269, 49152-65535 } accept"; echo "    ip daddr $DC udp dport { 88, 389, 464 } accept"; fi
    while IFS=: read -r h p; do [ -n "$h" ] && [ -n "$p" ] && [[ $h =~ ^[0-9.]+$ ]] && echo "    ip daddr $h tcp dport $p accept"; done < "$W/dbtargets" 2>/dev/null
    if [ ! -s "$W/dbtargets" ]; then echo "    ip daddr $LAN tcp dport { 1433, 3306, 5432 } accept"; fi   # Jesse's fallback when no DB was discovered
    [ -f "$FW/allowed" ] && while IFS='|' read -r pr h p; do [ -n "$h" ] && echo "    ip daddr $h $pr dport $p accept"; done < "$FW/allowed"
    [ "$mode" = lock ] && [ "$ALLOW_WEB_OUT" = 1 ] && echo "    tcp dport { 80, 443 } accept"
    if [ "$mode" = learn ]; then echo "    ct state new limit rate $LEARN_LOG_RATE log prefix \"TK-LEARN \" level info"
    else echo "    limit rate 6/minute log prefix \"TK-OUT-DROP \" level info"; echo "    counter"; fi
    echo "  }"
    echo "}"
  } > "$FW/rules.nft"
}
fw_load() {  # fw_load learn|lock : check, load with a 90s auto-undo, ask, persist
  local mode=$1
  have nft || { bad "nft not installed: dnf -y install nftables"; return 1; }
  fw_render "$mode"
  nft -c -f "$FW/rules.nft" 2>"$FW/err" || { bad "rules failed the syntax check (nothing changed):"; sed 's/^/      /' "$FW/err" | head; return 1; }
  { echo "table inet tk_fw"; echo "delete table inet tk_fw"; nft list table inet tk_fw 2>/dev/null; } > "$FW/rollback.nft"
  local pre_db="" post_db="" h p
  while IFS=: read -r h p; do [ -n "$p" ] && port_up "$h" "$p" && pre_db+="$h:$p "; done < "$W/dbtargets" 2>/dev/null
  setsid bash -c "sleep 90; nft -f $(q "$FW/rollback.nft") 2>/dev/null; echo 'thorska.sh: firewall change UNDONE (not confirmed)' | wall 2>/dev/null" >/dev/null 2>&1 &
  local rb=$!
  nft -f "$FW/rules.nft" || { bad "load failed"; kill "$rb"; return 1; }
  ok "rules loaded (${BO}$mode${N} mode). Auto-undo in 90 seconds unless you confirm."
  say "inbound open (tcp): ${BO}$(fw_in_ports tcp)${N}   udp: ${BO}$(fw_in_ports udp)${N}"
  while IFS=: read -r h p; do [ -n "$p" ] && port_up "$h" "$p" && post_db+="$h:$p "; done < "$W/dbtargets" 2>/dev/null
  if [ -s "$W/dbtargets" ]; then
    [ "$pre_db" = "$post_db" ] && ok "database still reachable: ${post_db:-none were reachable before either}" || bad "database reachability CHANGED: before [$pre_db] after [$post_db] - type no"
  fi
  [ -s "$W/urls" ] && { local u; u=$(head -1 "$W/urls" | cut -d'|' -f1); curl -sk -m 5 -o /dev/null "$u" && ok "web app still answers locally ($u)" || warn "web app didn't answer locally ($u)"; }
  tip "Best test: open a NEW terminal and SSH in again. Your current session stays up either way."
  trap 'kill "$rb" 2>/dev/null; nft -f "$FW/rollback.nft" 2>/dev/null; echo; warn "interrupted - firewall change undone"; trap - INT; kill -INT $BASHPID' INT
  local a=""; read -r -t 80 -p "  ${Y}?${N} Type ${BO}yes${N} to keep it (80s, anything else = undo): " a </dev/tty
  trap - INT
  if [ "$a" = yes ]; then
    kill "$rb" 2>/dev/null; pkill -f "sleep 90; nft -f $FW/rollback.nft" 2>/dev/null
    echo "$mode" > "$FW/mode"; [ "$mode" = learn ] && date +%s > "$FW/learn.start"
    mkdir -p /etc/tk; cp "$FW/rules.nft" /etc/tk/fw.nft
    cat > /etc/systemd/system/tk-fw.service <<UNIT
[Unit]
Description=Host firewall rules (tk_fw)
After=firewalld.service network-pre.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/tk/fw.nft
ExecStop=/usr/sbin/nft delete table inet tk_fw
[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload; systemctl enable tk-fw.service >/dev/null 2>&1
    ok "kept + saved (reloads at boot via tk-fw.service)"; note "firewall $mode applied"
  else warn "not confirmed - undoing now"; kill "$rb" 2>/dev/null; nft -f "$FW/rollback.nft" 2>/dev/null; return 1; fi
}
fw_learned() {  # prints proto|ip|port|count for outbound connections seen since learn started (+ ones already open)
  local since; since=$(cat "$FW/learn.start" 2>/dev/null || echo $(( $(date +%s) - 3600 )))
  { journalctl -k --since "@$since" --no-pager 2>/dev/null | grep 'TK-LEARN' | sed -nE 's/.*DST=([0-9.]+).*PROTO=([A-Z]+).*DPT=([0-9]+).*/\L\2\E|\1|\3/p'
    local lp; lp=" $(ss -Htln 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -u | tr '\n' ' ') "
    ss -Htn state established 2>/dev/null | awk '{print $3, $4}' | while read -r loc peer; do
      case "$peer" in 127.*|\[*) continue;; esac
      case "$lp" in *" ${loc##*:} "*) continue;; esac          # inbound connection to one of our services
      echo "tcp|${peer%:*}|${peer##*:}"; done
  } | sort | uniq -c | awk '{print $2"|"$1}' | sort -t'|' -k4 -nr
}
cmd_fw() {
  local sub=${2:-}
  [ -z "$sub" ] && { [ -f "$FW/mode" ] && sub=status || sub=learn; }
  case "$sub" in
    learn)
      hdr "FIREWALL: inbound lock + outbound learn"
      tip "Inbound: only ports that are listening right now stay open (unknown ones stay open + flagged), SSH is rate-limited."
      tip "Outbound: allowed but logged, so you can see what the app needs. Lock it whenever you like:  bash $0 fw lock"
      [ -s "$W/urls" ] || { say "discovering the web app first..."; cmd_web >/dev/null 2>&1; }
      [ -s "$W/dbtargets" ] && say "database host(s) that will stay allowed: ${BO}$(tr '\n' ' ' < "$W/dbtargets")${N}" || say "no remote database found: Jesse's fallback allows outbound 1433/3306/5432 to the LAN"
      fw_load learn;;
    lock)
      hdr "FIREWALL: lock outbound"
      [ -f "$FW/learn.start" ] && say "learning since $(date -d @"$(cat "$FW/learn.start")" '+%H:%M') ($(( ($(date +%s)-$(cat "$FW/learn.start"))/60 )) min)" || warn "learn mode never ran - only already-open connections are known"
      plan_reset
      local pr h p c name flag
      while IFS='|' read -r pr h p c; do
        [ -n "$h" ] || continue
        grep -qxF "$pr|$h|$p" "$FW/allowed" 2>/dev/null && continue
        case "$p" in 53|67|123|547) continue;; esac
        name=$(lan_name "$h"); flag=""
        local rk=""; if ! is_lan "$h"; then case "$p" in 80|443) flag=" ${DIM}(web: covered by ALLOW_WEB_OUT=$ALLOW_WEB_OUT)${N}";; *) flag=" ${R}<- internet + odd port: could be red team${N}"; rk=risky;; esac; fi
        plan_add "allow out: $pr $h:$p  ${DIM}$name, seen $c time(s)${N}$flag" "echo $(q "$pr|$h|$p") >> $(q "$FW/allowed")" "$rk"
      done < <(fw_learned)
      say "Pick what the box is allowed to keep talking to (everything else outbound gets blocked):"
      plan_apply
      fw_load lock;;
    status)
      hdr "FIREWALL STATUS"
      if nft list table inet tk_fw >/dev/null 2>&1; then ok "tk_fw loaded, mode: ${BO}$(cat "$FW/mode" 2>/dev/null || echo ?)${N}"; else bad "tk_fw table is NOT loaded (deleted? reboot?)  ->  bash $0 fw learn"; fi
      svc_active firewalld && say "firewalld is also running (zone: $(firewall-cmd --get-default-zone 2>/dev/null)) - both must allow traffic"
      say "inbound open now: tcp ${BO}$(fw_in_ports tcp)${N} udp ${BO}$(fw_in_ports udp)${N}"
      [ "$(cat "$FW/mode" 2>/dev/null)" = learn ] && say "learned so far: ${BO}$(fw_learned | wc -l)${N} destinations  ->  bash $0 fw lock"
      say "recent drops:"; journalctl -k --since -15min --no-pager 2>/dev/null | grep -E 'TK-(IN|OUT)-DROP' | tail -6 | sed -E 's/.*(TK-[A-Z-]+).*SRC=([0-9.]+).*DST=([0-9.]+).*PROTO=([A-Z]+).*DPT=([0-9]+).*/      \1 \2 -> \3 \4\/\5/';;
    off)
      hdr "FIREWALL OFF (emergency)"
      nft list table inet tk_fw > "$FW/before-off.nft" 2>/dev/null
      nft delete table inet tk_fw 2>/dev/null; systemctl disable tk-fw.service >/dev/null 2>&1; rm -f "$FW/mode"
      warn "tk_fw removed (firewalld untouched). Turn it back on: bash $0 fw learn"; note "firewall OFF";;
    *) echo "usage: bash $0 fw [learn|lock|status|off]";;
  esac
}

# ======================================================================
#  PROTECT THE WEB APP (audit -> plan -> apply)
# ======================================================================
app_find() { [ -s "$W/dirs" ] || return 0; timeout 60 find $(cat "$W/dirs") -xdev "$@" 2>/dev/null; }
SKIPDIRS='/(node_modules|\.git|cache|tmp|logs?|sessions?)/'
cmd_protect() {
  hdr "PROTECT THE WEB APP"
  [ -s "$W/urls" ] || { say "running discovery first..."; cmd_web >/dev/null 2>&1; }
  [ -s "$W/dirs" ] || warn "no app folders known - file checks will be limited"
  plan_reset
  local f u code a

  sub "Webshells and planted code"
  local hits; hits=$(app_find -type f -size -3M \( -name '*.php*' -o -name '*.phtml' -o -name '*.jsp' -o -name '*.aspx' -o -name '*.py' -o -name '*.sh' -o -name '*.pl' -o -name '*.cgi' -o -name '*.js' \) \
     -exec grep -lIE 'eval\(\s*(base64_decode|gzinflate|str_rot13)|(system|passthru|shell_exec|popen|proc_open|exec)\(\s*\$_(GET|POST|REQUEST|COOKIE)|assert\(\s*\$_|\$_(GET|POST|REQUEST)\[.(cmd|exec|c)\.\]|child_process.*req\.(query|body)|os\.system\(.*request|Runtime\.getRuntime\(\)\.exec\(.*request|/dev/tcp/|nc -e|bash -i' {} + | grep -vE "$SKIPDIRS|vendor/|/dist/" | grep -vxF "$SELF")
  if [ -n "$hits" ]; then while read -r f; do bad "suspicious code: $f"; grep -nIE 'eval\(|system\(|passthru|shell_exec|/dev/tcp|bash -i|exec\(' "$f" | head -2 | cut -c1-140 | sed 's/^/        /'
      plan_add "quarantine suspected webshell $f" "quar $(q "$f")"; done <<<"$hits"
  else ok "no obvious webshell patterns in the app's code"; fi
  app_find -type f \( -name '*.php*' -o -name '*.phtml' -o -name '*.jsp' -o -name '*.sh' \) | grep -iE '/(uploads?|media|files|attachments|images?|static)/' | while read -r f; do bad "script inside an upload/static folder: $f"; done
  app_find -type f \( -name 'phpinfo.php' -o -name 'info.php' -o -name 'test.php' -o -name 'shell*.php' -o -name 'cmd*.php' \) | while read -r f; do warn "risky file: $f"; done
  for f in $(app_find -type f \( -name 'phpinfo.php' -o -name 'info.php' -o -name 'shell*.php' -o -name 'cmd*.php' \)); do plan_add "quarantine $f" "quar $(q "$f")"; done
  say "app files changed in the last 2 days (not counting uploads/cache/logs):"
  app_find -type f -mtime -2 | grep -vE "$SKIPDIRS|\.(db|sqlite3?|db-wal|db-shm|log)$" | head -15 | sed 's/^/      /'

  sub "Things the app shouldn't show the world"
  local base; base=$(head -1 "$W/urls" 2>/dev/null | cut -d'|' -f1)
  if [ -n "$base" ]; then
    # many apps answer 200 with the same page for ANY path (single-page apps) - learn that page first
    curl -sk -m 4 -o "$D/.body" "${base}tk-nope-$RANDOM-x" 2>/dev/null; local nope; nope=$(md5sum < "$D/.body" | cut -c1-32)
    for u in .env .git/config phpinfo.php info.php server-status install install.php setup setup.php installer admin/install config.php.bak backup.zip .DS_Store; do
      code=$(curl -sk -m 4 -o "$D/.body" -w '%{http_code}' "${base}${u}" 2>/dev/null)
      [ "$code" = 200 ] || continue
      [ "$(md5sum < "$D/.body" | cut -c1-32)" = "$nope" ] && continue
      [ "$(wc -c < "$D/.body")" -gt 20 ] && ! grep -qiE '<title>[^<]*(404|not found|login|sign in)' "$D/.body" && bad "${base}${u} is readable (HTTP 200)"
    done; ok "checked common leaks (.env, .git, phpinfo, installers, backups)"
    tip "If something above is readable: block it in the web server config, or move the file out of the web folder."
  fi

  sub "Web server info leaks"
  if have nginx && pgrep -x nginx >/dev/null && ! nginx -T 2>/dev/null | grep -qE '^\s*server_tokens\s+off'; then
    plan_add "nginx: hide version (server_tokens off) - tested with nginx -t before reload" "tk_nginx_tokens"; fi
  if have httpd && pgrep -x httpd >/dev/null && ! grep -rqiE '^\s*ServerTokens\s+Prod' /etc/httpd/ 2>/dev/null; then
    plan_add "httpd: hide version, turn off TRACE - tested with httpd -t before reload" "tk_httpd_tokens"; fi

  sub "Secrets readable by every user"
  local appusers; appusers=" $(for a in $(cat "$W/pids" 2>/dev/null); do stat -c %U "/proc/$a" 2>/dev/null; done | sort -u | tr '\n' ' ') "
  while read -r f; do [ -f "$f" ] || continue
    if [ "$(( $(stat -c %a "$f") % 10 ))" -ge 4 ] && grep -qiE 'pass|secret|key|token' "$f" 2>/dev/null; then
      local fo fg; fo=$(stat -c %U "$f"); fg=$(stat -c %G "$f")
      local okc=0 au; for au in $appusers; do { [ "$au" = "$fo" ] || [ "$au" = root ] || id -nG "$au" 2>/dev/null | grep -qw "$fg"; } && okc=1; done
      if [ "$okc" = 1 ]; then
        warn "world-readable secrets file: $f ($(stat -c '%A %U:%G' "$f"))"; plan_add "make $f unreadable to other users (chmod o-rwx)" "bk $(q "$f"); chmod o-rwx $(q "$f")"
      else warn "world-readable secrets file: $f - the app may read it as 'other', so NOT changing it"; fi
    fi; done < "$W/configs"

  sub "SELinux"
  local se; se=$(getenforce 2>/dev/null || echo unknown)
  case "$se" in
    Enforcing) ok "SELinux is Enforcing (good - leave it on)"
      if have ausearch; then local avc; avc=$(ausearch -m avc -ts recent 2>/dev/null | grep -E 'denied' | tail -5)
        if [ -n "$avc" ]; then warn "recent SELinux denials (these can break the app):"; echo "$avc" | sed -E 's/.*denied *\{ ([^}]*)\}.*comm="([^"]*)".*tcontext=[^:]*:[^:]*:([^:]*).*/        \2 denied \1 on \3/' | sort -u
          echo "$avc" | grep -q 'name_connect' && echo "$avc" | grep -q 'httpd_t' && plan_add "SELinux: let the web server connect to databases (setsebool -P httpd_can_network_connect_db 1)" "setsebool -P httpd_can_network_connect_db 1"
          echo "$avc" | grep -q 'name_connect' && echo "$avc" | grep -q 'httpd_t' && plan_add "SELinux: let the web server open outbound connections (setsebool -P httpd_can_network_connect 1)" "setsebool -P httpd_can_network_connect 1"
        else ok "no recent SELinux denials"; fi; fi;;
    Permissive) warn "SELinux is Permissive (logging only). Don't switch it to Enforcing mid-competition - it can break the app.";;
    *) warn "SELinux is $se";;
  esac

  db_audit

  plan_apply
  sub "Fingerprint the app (so hunt/watch catch defacement)"
  web_fingerprint && ok "fingerprinted $(wc -l < "$W/sha256") app files -> $W/sha256"
  note "protect run"
}
web_fingerprint() { [ -s "$W/dirs" ] || return 1
  app_find -type f -size -20M | grep -vE "$SKIPDIRS|\.(db|sqlite3?|db-wal|db-shm|db-journal|log|pid|sock)$|/(uploads?|media)/" | head -20000 | xargs -r -d '\n' sha256sum 2>/dev/null > "$W/sha256"; }
tk_nginx_tokens() { local f=/etc/nginx/conf.d/00-tk-hardening.conf; echo "server_tokens off;" > "$f"; have restorecon && restorecon "$f"
  if nginx -t 2>/dev/null; then systemctl reload nginx; else bad "nginx -t failed - removing"; rm -f "$f"; return 1; fi; }
tk_httpd_tokens() { local f=/etc/httpd/conf.d/00-tk-hardening.conf; printf 'ServerTokens Prod\nServerSignature Off\nTraceEnable Off\n' > "$f"; have restorecon && restorecon "$f"
  if httpd -t 2>/dev/null; then systemctl reload httpd; else bad "httpd -t failed - removing"; rm -f "$f"; return 1; fi; }

# ======================================================================
#  RECON / REPORT / BASELINE
# ======================================================================
cmd_recon() {
  hdr "RECON (saved for injects + incident reports)"
  local f="$D/recon-$(TS).txt"
  {
    echo "### HOST"; hostnamectl 2>/dev/null; uptime; date
    echo "### OS"; cat /etc/fedora-release 2>/dev/null || head -3 /etc/os-release; uname -r
    echo "### NETWORK"; ip -br a 2>/dev/null || hostname -I; ip r 2>/dev/null; resolvectl status 2>/dev/null | grep -E 'DNS Servers|Current DNS' ; cat /etc/resolv.conf
    echo "### LISTENING TCP"; ss -tlnp; echo "### LISTENING UDP"; ss -ulnp
    echo "### ESTABLISHED"; ss -tnp state established
    echo "### LOGIN USERS"; awk -F: '$7!~/(nologin|false|sync|shutdown|halt)$/' /etc/passwd
    echo "### ADMINS ($SUDOGRP)"; getent group "$SUDOGRP"; grep -rhv '^\s*#' /etc/sudoers /etc/sudoers.d/ 2>/dev/null | grep .
    echo "### SSH KEYS"; for k in /root/.ssh/authorized_keys* /home/*/.ssh/authorized_keys*; do [ -f "$k" ] && { echo "--- $k"; cat "$k"; }; done
    echo "### ENABLED SERVICES"; systemctl list-unit-files --state=enabled --no-pager
    echo "### RUNNING SERVICES"; systemctl list-units --type=service --state=running --no-pager
    echo "### TIMERS"; systemctl list-timers --all --no-pager
    echo "### CRON"; ls -la /etc/cron* /var/spool/cron 2>/dev/null; cat /etc/crontab /var/spool/cron/* 2>/dev/null
    echo "### FIREWALLD"; firewall-cmd --state 2>&1; firewall-cmd --list-all 2>/dev/null
    echo "### NFTABLES TABLES"; nft list tables 2>/dev/null
    echo "### SELINUX"; sestatus 2>/dev/null
    echo "### CONTAINERS"; podman ps -a 2>/dev/null; docker ps -a 2>/dev/null
    echo "### WEB APP"; for x in urls units dirs configs sqlite dbtargets localdb; do echo "-- $x"; cat "$W/$x" 2>/dev/null; done
    echo "### DISK / MEMORY"; df -h; free -h
    echo "### LAST LOGINS"; last -n 25 2>/dev/null
  } > "$f" 2>&1
  chmod 600 "$f"; ok "saved $f"
  say "OS: $(cat /etc/fedora-release 2>/dev/null)   kernel $(uname -r)   IP $(myip)"
  say "login users: ${BO}$(awk -F: '$7!~/(nologin|false|sync|shutdown|halt)$/{printf $1" "}' /etc/passwd)${N}"
  say "listening: ${BO}$(ss -Htln | awk '{print $4}' | sed 's/.*://' | sort -nu | tr '\n' ' ')${N}"
  note "recon -> $f"
}
cmd_report() {
  hdr "INVENTORY (copy into injects)"
  local ip; ip=$(myip)
  echo "  Hostname : $(hostname)"; echo "  IP       : $ip   (public 10.100.1XX.${ip##*.} via router 1:1 NAT)"
  echo "  OS       : $(cat /etc/fedora-release 2>/dev/null || grep PRETTY /etc/os-release | cut -d= -f2), kernel $(uname -r)"
  echo "  SELinux  : $(getenforce 2>/dev/null)     Firewall: firewalld $(systemctl is-active firewalld 2>/dev/null), tk_fw $(cat "$FW/mode" 2>/dev/null || echo off)"
  echo; printf '  %-7s %-6s %-22s %s\n' PROTO PORT PROCESS PACKAGE
  ss -Htlnp 2>/dev/null | while read -r st rq sq loc peer proc; do local pid exe name; pid=$(echo "$proc" | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2); exe=$(readlink -f /proc/$pid/exe 2>/dev/null); name=$(echo "$proc" | grep -o '(("[^"]*"' | head -1 | tr -d '(")')
    printf '  %-7s %-6s %-22s %s\n' tcp "${loc##*:}" "$name" "$(owner_pkg "$exe" || echo '-')"; done | sort -u -k2n
  echo; [ -s "$W/urls" ] && { echo "  Web app  : $(head -1 "$W/urls" | cut -d'|' -f4) ($(head -1 "$W/urls" | cut -d'|' -f3))"; echo "  Services : $(tr '\n' ' ' < "$W/units")"; echo "  Data     : $(cat "$W/sqlite" "$W/dbtargets" "$W/localdb" 2>/dev/null | tr '\n' ' ')"; }
  echo "  Users    : $(awk -F: '$7!~/(nologin|false|sync|shutdown|halt)$/{printf $1" "}' /etc/passwd)"
}
units_list() { find /etc/systemd/system /usr/lib/systemd/system /usr/local/lib/systemd/system /etc/systemd/user /root/.config/systemd /home/*/.config/systemd -maxdepth 2 -type f 2>/dev/null | sort; }
cmd_rebase() {
  ss -Htln | awk '{print $4}' | sort -u > "$D/base.ports"
  awk -F: '{print $1":"$3":"$7}' /etc/passwd | sort > "$D/base.users"
  getent group "$SUDOGRP" > "$D/base.admins"
  units_list > "$D/base.units"
  find / -xdev -perm -4000 -type f 2>/dev/null | sort > "$D/base.suid"
  getenforce > "$D/base.selinux" 2>/dev/null
  web_fingerprint
  touch "$D/base.ts"
  ok "baseline saved: hunt/watch now report only changes after $(date '+%H:%M')"; note "baseline refreshed"
}

# ======================================================================
#  CHECK (is everything up?)  -  read-only
# ======================================================================
cmd_check() {
  hdr "HEALTH CHECK  $(date '+%H:%M:%S')"
  tip "${G}${OKS}${N}${DIM} good   ${Y}${WRS}${N}${DIM} look at it   ${R}${BADS}${N}${DIM} broken -> guide: Something's broken${N}"
  local u c s ti a code tm t2 ip; ip=$(myip); ip=${ip%/*}
  sub "Web app"
  if [ -s "$W/urls" ]; then
    while IFS='|' read -r u c s ti a; do
      read -r code tm <<<"$(curl -sk -m 8 -o "$D/.body" -w '%{http_code} %{time_total}' "$u" 2>/dev/null)"
      t2=$(tr -d '\r\n' < "$D/.body" 2>/dev/null | grep -oiE '<title[^>]*>[^<]*' | head -1 | sed -E 's/<title[^>]*>//I' | cut -c1-60)
      if [ -z "$code" ] || [ "$code" = 000 ]; then bad "$u not answering  ->  systemctl status $(head -1 "$W/units" 2>/dev/null)"
      elif [ "${code:0:1}" = 5 ]; then bad "$u answers $code (server error)  ->  app/DB problem, see logs"
      else ok "$u  $code  ${tm}s  ${DIM}\"${t2}\"${N}"; fi
      [ -n "$ti" ] && [ -n "$t2" ] && [ "$t2" != "$ti" ] && warn "page title changed: was \"$ti\", now \"$t2\" (defaced? or just a different page)"
      case "$a" in 127.*|"[::1]"*) ;; *) [ -z "$ip" ] && continue; local port=${u##*:}; port=${port%/}; curl -sk -m 5 -o /dev/null "${u%%://*}://$ip:$port/" && ok "also answers on the LAN address $ip:$port" || bad "doesn't answer on $ip:$port (firewall?)";; esac
    done < "$W/urls"
  else warn "web app not discovered yet: bash $0 web"; fi
  sub "Services"
  for u in $(cat "$W/units" 2>/dev/null) sshd.service; do svc_active "$u" && ok "$u running" || bad "$u NOT running  ->  systemctl restart $u ; journalctl -u $u -n 30"; done
  sub "Database"
  for u in $(cat "$W/localdb" 2>/dev/null); do pgrep -x "$u" >/dev/null && ok "$u running here" || bad "$u not running"; done
  while IFS=: read -r u c; do [ -n "$c" ] && { port_up "$u" "$c" && ok "DB $u:$c reachable ($(lan_name "$u"))" || bad "DB $u:$c UNREACHABLE  ->  DB box down, or a firewall (yours, router, theirs)"; }; done < "$W/dbtargets" 2>/dev/null
  while read -r u; do [ -f "$u" ] && ok "SQLite $u ($(du -h "$u" | cut -f1), changed $(( ($(date +%s)-$(stat -c %Y "$u"))/60 )) min ago)" || bad "SQLite file missing: $u"; done < "$W/sqlite" 2>/dev/null
  sub "Box"
  ss -Htln | grep -q ':22 ' && ok "SSH listening" || bad "SSH not listening"
  nft list table inet tk_fw >/dev/null 2>&1 && ok "firewall tk_fw loaded ($(cat "$FW/mode" 2>/dev/null))" || warn "firewall tk_fw not loaded"
  say "SELinux: $(getenforce 2>/dev/null || echo unknown)$(have ausearch && echo ", denials last 10 min: $(ausearch -m avc -ts recent 2>/dev/null | grep -c denied)")"
  local df; df=$(df --output=pcent / | tail -1 | tr -d ' %'); [ "$df" -lt 90 ] && ok "disk / ${df}% used" || bad "disk / ${df}% full"
  timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes && ok "clock synced" || warn "clock not synced (matters if the app uses AD/Kerberos)"
  tip "Quotient (scoring.wccomps.org) is the source of truth."
}

# ======================================================================
#  HUNT (what changed since the baseline?) - read-only
# ======================================================================
cmd_hunt() {
  hdr "HUNT  $(date '+%H:%M:%S')"
  [ -f "$D/base.ts" ] || { warn "no baseline yet - making one now (run 'first' or 'rebase')"; cmd_rebase; return; }
  tip "Only RED lines matter. If YOU caused a change:  bash $0 rebase"
  local x
  sub "Who's on"; who | sed 's/^/      /'
  sub "Connections to outside the LAN"
  x=$(ss -Htnp state established 2>/dev/null | awk '{print $3, $4, $5}' | while read -r l p pr; do is_lan "${p%:*}" || echo "      ${R}$l <-> $p $pr${N}"; done)
  [ -n "$x" ] && echo "$x" || ok "none"
  sub "New since baseline"
  x=$(comm -13 "$D/base.ports" <(ss -Htln | awk '{print $4}' | sort -u)); [ -n "$x" ] && bad "new listening ports: $(echo $x)" || ok "no new listening ports"
  x=$(comm -13 "$D/base.users" <(awk -F: '{print $1":"$3":"$7}' /etc/passwd | sort)); [ -n "$x" ] && bad "new/changed accounts: $(echo $x)" || ok "no new accounts"
  [ "$(getent group "$SUDOGRP")" != "$(cat "$D/base.admins")" ] && bad "admin group changed: $(getent group "$SUDOGRP")"
  x=$(comm -13 "$D/base.units" <(units_list)); [ -n "$x" ] && { bad "new service files:"; echo "$x" | sed 's/^/        /'; } || ok "no new services"
  x=$(find /etc/systemd /usr/lib/systemd/system /etc/cron* /var/spool/cron /etc/profile.d /etc/pam.d /etc/sudoers.d /etc/ssh -newer "$D/base.ts" -type f 2>/dev/null | grep -v '/etc/ssh/ssh_host'); [ -n "$x" ] && { warn "system config changed since baseline:"; echo "$x" | head -15 | sed 's/^/        /'; }
  x=$(comm -13 "$D/base.suid" <(find / -xdev -perm -4000 -type f 2>/dev/null | sort)); [ -n "$x" ] && bad "new SUID programs: $(echo $x)"
  for x in /root/.ssh/authorized_keys* /home/*/.ssh/authorized_keys*; do [ -s "$x" ] && bad "SSH key file: $x"; done
  grep -q . /etc/ld.so.preload 2>/dev/null && bad "/etc/ld.so.preload is populated"
  [ "$(getenforce 2>/dev/null)" != "$(cat "$D/base.selinux" 2>/dev/null)" ] && bad "SELinux mode changed to $(getenforce)"
  nft list table inet tk_fw >/dev/null 2>&1 || { [ -f "$FW/mode" ] && bad "firewall table tk_fw is GONE  ->  bash $0 fw $(cat "$FW/mode")"; }
  sub "Web app files"
  if [ -s "$W/sha256" ]; then x=$(sha256sum --quiet -c "$W/sha256" 2>/dev/null | head -20); [ -n "$x" ] && { bad "app files changed (defacement/webshell?):"; echo "$x" | sed 's/^/        /'; } || ok "app files match fingerprint"; fi
  x=$(app_find -type f -newer "$D/base.ts" | grep -vE "$SKIPDIRS|\.(db|sqlite3?|db-wal|db-shm|db-journal|log)$" | head -15); [ -n "$x" ] && { warn "new/changed files in app folders:"; echo "$x" | sed 's/^/        /'; }
  sub "Processes"
  for x in /proc/[0-9]*; do local e; e=$(readlink "$x/exe" 2>/dev/null) || continue; case "$e" in *" (deleted)"|/tmp/*|/var/tmp/*|/dev/shm/*) bad "PID ${x#/proc/} runs from $e";; esac; done
  ps -eo pid,user,%cpu,etime,cmd --sort=-%cpu | head -6 | cut -c1-130 | sed 's/^/      /'
  sub "Recent logins"
  journalctl -u sshd --since -30min --no-pager 2>/dev/null | grep -E 'Accepted|Failed|Invalid' | tail -8 | cut -c1-150 | sed 's/^/      /'
  note "hunt run"
}

# ======================================================================
#  WATCH (live dashboard) - read-only. q = quit, r = refresh now
# ======================================================================
cmd_watch() {
  local int=${WATCH_INT:-30} key alerts="$D/alerts.log" start; start=$(date +%s)
  local b_ports b_users b_exe b_units; b_ports=$(ss -Htln | awk '{print $4}' | sort -u); b_users=$(cut -d: -f1 /etc/passwd | sort)
  b_exe=$(for p in /proc/[0-9]*; do readlink "$p/exe" 2>/dev/null; done | sort -u); b_units=$(units_list); touch "$D/.watchmark"
  trap 'tput cnorm 2>/dev/null; echo; exit 0' INT TERM; tput civis 2>/dev/null
  alert() { local m="$(date '+%H:%M:%S') $*"; grep -qF "$*" "$alerts" 2>/dev/null || { echo "$m" >> "$alerts"; printf '\a'; }; }
  while :; do
    local out="" u c s ti a code tm x n
    out+="${B}${BO} THORSKA WATCH ${N}  $(date '+%H:%M:%S')  up $(uptime -p 2>/dev/null | sed 's/up //')  load $(cut -d' ' -f1-3 /proc/loadavg)\n"
    out+="  fw: ${BO}$(nft list table inet tk_fw >/dev/null 2>&1 && cat "$FW/mode" 2>/dev/null || echo "${R}OFF${N}")${N}"
    [ "$(cat "$FW/mode" 2>/dev/null)" = learn ] && out+=" ($(fw_learned 2>/dev/null | wc -l) destinations learned -> 'fw lock' when ready)"
    out+="   SELinux: $(getenforce 2>/dev/null)   disk: $(df --output=pcent / | tail -1 | tr -d ' ')\n\n"
    out+="${BO}WEB${N}\n"
    while IFS='|' read -r u c s ti a; do read -r code tm <<<"$(curl -sk -m 6 -o /dev/null -w '%{http_code} %{time_total}' "$u" 2>/dev/null)"
      if [ -z "$code" ] || [ "$code" = 000 ] || [ "${code:0:1}" = 5 ]; then out+="  ${R}${BADS} $u ${code:-down}${N}\n"; alert "WEB DOWN $u ($code)"
      else out+="  ${G}${OKS}${N} $u $code ${tm}s\n"; fi; done < "$W/urls" 2>/dev/null
    [ -s "$W/urls" ] || out+="  ${Y}run 'web' first${N}\n"
    out+="${BO}SERVICES / DB${N}\n  "
    for u in $(cat "$W/units" 2>/dev/null) sshd.service; do svc_active "$u" && out+="${G}${OKS}${N}${u%.service} " || { out+="${R}${BADS}${u%.service}${N} "; alert "SERVICE DOWN $u"; }; done
    while IFS=: read -r u c; do [ -n "$c" ] && { port_up "$u" "$c" && out+=" ${G}${OKS}${N}db $u:$c" || { out+=" ${R}${BADS}db $u:$c${N}"; alert "DB UNREACHABLE $u:$c"; }; }; done < "$W/dbtargets" 2>/dev/null
    out+="\n${BO}WHO${N}\n$(who | sed 's/^/  /')\n"
    x=$(ss -Htnp state established 2>/dev/null | awk '{print $3, $4, $5}' | while read -r l p pr; do is_lan "${p%:*}" || echo "  $p $(echo "$pr" | grep -o '"[^"]*"' | head -1)"; done)
    n=$(echo -n "$x" | grep -c .); out+="${BO}OUTSIDE CONNECTIONS${N} ($n)\n"; [ -n "$x" ] && { out+="${R}$(echo "$x" | head -5)${N}\n"; }
    out+="${BO}NEW SINCE WATCH STARTED${N}\n"
    x=$(comm -13 <(echo "$b_ports") <(ss -Htln | awk '{print $4}' | sort -u)); [ -n "$x" ] && { out+="  ${R}ports: $(echo $x)${N}\n"; alert "NEW PORT $(echo $x)"; }
    x=$(comm -13 <(echo "$b_users") <(cut -d: -f1 /etc/passwd | sort)); [ -n "$x" ] && { out+="  ${R}users: $(echo $x)${N}\n"; alert "NEW USER $(echo $x)"; }
    x=$(comm -13 <(echo "$b_units") <(units_list)); [ -n "$x" ] && { out+="  ${R}services: $(echo $x | tr ' ' '\n' | xargs -r -n1 basename | tr '\n' ' ')${N}\n"; alert "NEW SERVICE FILE $(echo $x)"; }
    x=$(comm -13 <(echo "$b_exe") <(for p in /proc/[0-9]*; do readlink "$p/exe" 2>/dev/null; done | sort -u) | grep -vE '^/usr/(bin|sbin|lib|libexec)/(sleep|curl|ss|ps|awk|sed|grep|tput|comm|sort|cut|tr|cat|head|tail|bash|systemctl|journalctl|nft|readlink|date|uptime|who|df|find|sshd|sshd-session|sudo|timeout|less|tmux)' | head -5)
    [ -n "$x" ] && out+="  ${Y}programs: $(echo $x)${N}\n"
    x=$(app_find -type f -newer "$D/.watchmark" 2>/dev/null | grep -vE "$SKIPDIRS|\.(db|sqlite3?|db-wal|db-shm|db-journal|log)$" | head -3); [ -n "$x" ] && { out+="  ${R}app files changed: $(echo $x)${N}\n"; alert "APP FILE CHANGED $(echo $x | cut -c1-120)"; }
    out+="${BO}LOGINS${N}\n$(journalctl -u sshd --since -15min --no-pager 2>/dev/null | grep -E 'Accepted|Failed' | tail -3 | awk '{$1=$2=""; print "  "$0}' | cut -c1-110)\n"
    out+="${BO}ALERTS${N} ${DIM}($alerts)${N}\n$(tail -5 "$alerts" 2>/dev/null | sed "s/^/  ${R}/; s/$/${N}/")\n"
    out+="\n${DIM}refresh every ${int}s   r = refresh now   q = quit   (read-only: changes nothing)${N}"
    printf '\033[H\033[2J%b\n' "$out"
    read -rsn1 -t "$int" key </dev/tty; [ "$key" = q ] && { tput cnorm 2>/dev/null; echo; break; }
  done
}
cmd_tmux() {
  have tmux || { say "installing tmux..."; tmo 180 "dnf install tmux" dnf -y -q install tmux || { bad "couldn't install tmux"; return 1; }; }
  if [ -n "$TMUX" ]; then tmux split-window -v -b -l 45% "bash $(q "$SELF") watch"; ok "dashboard opened above. Ctrl-b then arrow keys moves between panes."; return; fi
  if tmux has-session -t tk 2>/dev/null; then exec tmux attach -t tk; fi
  tmux new-session -d -s tk -x "$(tput cols 2>/dev/null || echo 200)" -y "$(tput lines 2>/dev/null || echo 50)" "bash $(q "$SELF") watch"
  tmux split-window -v -t tk -l 60%; tmux select-pane -t tk:0.1
  tmux set -t tk mouse on >/dev/null 2>&1
  echo "  Opening tmux: dashboard on top, your shell below.  Ctrl-b d = leave it running   tmux a -t tk = come back"; sleep 2
  exec tmux attach -t tk
}

# ======================================================================
#  FIRST RUN (8 steps, resumable)
# ======================================================================
STEPS=("Passwords (zulu-compatible)|cmd_passwd|creates ccdcuser1+2, you set root/ccdcuser1/ccdcuser2, everyone else gets the seed password|3 passwords, then y + seed phrase twice"
       "Evict backdoors|cmd_evict|finds planted SSH keys, fake services, cron jobs, PAM stealers, tampered programs|one plan: apply all / pick numbers / skip"
       "Find the web app|cmd_web|read-only: what Home Manager is, its service, its files, its database|nothing"
       "Backups + database dump|cmd_backup|disguised, backdated copies of configs, app files and the database|optional passphrase (Enter = none)"
       "Harden SSH|cmd_ssh|no root login, 3 tries, no tunnels - passwords stay on|apply / skip"
       "Firewall: inbound lock + outbound learn|cmd_fw fw learn|keeps every listening port open, logs where the box connects out, 90s auto-undo|type yes to keep it"
       "Protect the web app + database|cmd_protect|webshell scan, leak check, version hiding, secret file permissions, SELinux, fingerprint, database accounts/UDFs/FILE|one plan: apply all / pick / skip"
       "Recon + baseline + health check|cmd_finish|saves the inventory, sets the baseline for hunt/watch, checks every service|nothing")
cmd_finish() { cmd_recon; cmd_rebase; cmd_check; }
cmd_first() {
  hdr "FIRST RUN: ${#STEPS[@]} steps"
  echo "  Each step shows what it does, then asks before changing anything."
  echo "  ${BO}Ctrl-C${N} pauses a step (skip / retry / quit). Re-running 'first' offers to resume."
  local done_f="$D/first.done" startat=1 i last=0
  if [ -s "$done_f" ]; then last=$(sort -n "$done_f" | tail -1)
    if [ "$last" -lt ${#STEPS[@]} ]; then local a; read -r -p "  ${Y}?${N} Steps 1-$last already done. Resume at step $((last+1))? [Y/n] " a </dev/tty; [[ $a =~ ^[Nn] ]] || startat=$((last+1)); fi
  fi
  for ((i=startat;i<=${#STEPS[@]};i++)); do
    local title fn what ans; IFS='|' read -r title fn what ans <<<"${STEPS[$((i-1))]}"
    echo; echo "${G}$(line 64)${N}"; echo "${G}${BO}  STEP $i/${#STEPS[@]}: $title${N}"; echo "${G}$(line 64)${N}"
    echo "  What it does : $what"; echo "  You'll answer: $ans"
    local c; read -r -p "  ${DIM}Enter = start, s = skip this step:${N} " c </dev/tty
    [[ $c =~ ^[Ss] ]] && { note "first: skipped step $i"; continue; }
    # shellcheck disable=SC2086
    run_step "$title" $fn && echo "$i" >> "$done_f"
  done
  hdr "FIRST RUN DONE"
  echo "  What changed:"; tail -20 "$LOG" | sed 's/^/    /'
  echo "  Quarantined files: $(ls "$Q" 2>/dev/null | wc -l)  (tell your Injects/IR person)"
  echo; ok "Next:  ${BO}bash $0 tmux${N}   (dashboard on top, shell below)"
  ok "Later: ${BO}bash $0 fw lock${N}   (lock outbound once the app has run a while)"
  ok "Every 15 min: ${BO}bash $0 hunt${N}  and  ${BO}bash $0 check${N}"
}

# ======================================================================
#  MENU
# ======================================================================
menu_status() {
  local u code; u=$(head -1 "$W/urls" 2>/dev/null | cut -d'|' -f1)
  [ -n "$u" ] && code=$(curl -sk -m 3 -o /dev/null -w '%{http_code}' "$u" 2>/dev/null)
  printf '  web: %s   firewall: %s   first run: %s/%s   backups: %s   quarantined: %s\n' \
    "$( [ -z "$u" ] && echo "${Y}unknown${N}" || { [ "${code:-000}" != 000 ] && [ "${code:0:1}" != 5 ] && echo "${G}up ($code)${N}" || echo "${R}DOWN ($code)${N}"; } )" \
    "$(nft list table inet tk_fw >/dev/null 2>&1 && echo "${G}$(cat "$FW/mode" 2>/dev/null)${N}" || echo "${Y}off${N}")" \
    "$(sort -u "$D/first.done" 2>/dev/null | wc -l)" "${#STEPS[@]}" "$(wc -l < "$D/backup.list" 2>/dev/null || echo 0)" "$(ls "$Q" 2>/dev/null | wc -l)"
}
cmd_menu() {
  while :; do
    printf '\033[H\033[2J'
    echo "${B}$(line 64)${N}"; echo "${B}${BO}  THORSKA toolkit v$VERSION${N}  ${DIM}$(hostname) $(myip)  $(date '+%H:%M')${N}"; echo "${B}$(line 64)${N}"
    menu_status; echo
    echo "   ${BO}1${N}  First run (start here)        ${BO}6${N}  Firewall: status / learn / lock / off"
    echo "   ${BO}2${N}  Check: is everything up?      ${BO}7${N}  Backup now"
    echo "   ${BO}3${N}  Hunt: what changed?           ${BO}8${N}  Restore something"
    echo "   ${BO}4${N}  Live dashboard (tmux)         ${BO}9${N}  Passwords / show a seed password"
    echo "   ${BO}5${N}  Web app: find / protect       ${BO}e${N}  Evict backdoors again"
    echo "   ${BO}r${N}  Inventory report (injects)    ${BO}b${N}  Rebase (accept current state)"
    echo "   ${BO}s${N}  SSH hardening                 ${BO}q${N}  Quit"
    echo; local c; read -r -n1 -p "  Choose (single key): " c </dev/tty; echo
    [ -z "$c" ] && continue
    case "$c" in
      1) cmd_first;; 2) run_step Check cmd_check;; 3) run_step Hunt cmd_hunt;;
      4) cmd_tmux;; 5) local w; read -r -p "  [f]ind (read-only) or [p]rotect? " w </dev/tty; [[ $w =~ ^[Pp] ]] && run_step Protect cmd_protect || run_step "Find web app" cmd_web;;
      6) local w; read -r -p "  [s]tatus / [l]earn / loc[k] / [o]ff? " w </dev/tty
         case "$w" in l|L) run_step Firewall cmd_fw fw learn;; k|K) run_step Firewall cmd_fw fw lock;; o|O) ask "Really remove the host firewall?" && run_step Firewall cmd_fw fw off;; *) run_step Firewall cmd_fw fw status;; esac;;
      7) run_step Backup cmd_backup;; 8) run_step Restore cmd_restore restore;;
      9) local w; read -r -p "  [c]hange passwords or [s]how a seed password? " w </dev/tty
         if [[ $w =~ ^[Ss] ]]; then local us; read -r -p "  user(s): " us </dev/tty; run_step Seedshow cmd_seedshow seedshow $us; else run_step Passwords cmd_passwd; fi;;
      e|E) run_step Evict cmd_evict;; r|R) cmd_report;; b|B) cmd_rebase;; s|S) run_step SSH cmd_ssh;;
      q|Q) exit 0;;
      *) continue;;
    esac
    echo; pause_enter
  done
}

# ======================================================================
#  DISPATCH
# ======================================================================
case "${1:-}" in
  "") cmd_menu;;
  first) cmd_first;;
  check) run_step Check cmd_check;;  hunt) run_step Hunt cmd_hunt;;
  watch) cmd_watch;;  tmux) cmd_tmux;;
  web) run_step "Find web app" cmd_web;;  protect) run_step Protect cmd_protect;;
  fw) run_step Firewall cmd_fw "$@";;
  backup) run_step Backup cmd_backup;;  restore) run_step Restore cmd_restore "$@";;
  evict) run_step Evict cmd_evict;;  docker) run_step Docker cmd_docker;;  db) run_step Database cmd_db;;  passwd) run_step Passwords cmd_passwd;;  ssh) run_step SSH cmd_ssh;;
  recon) cmd_recon;;  report) cmd_report;;  rebase) cmd_rebase;;
  seedshow) cmd_seedshow "$@";;
  -h|--help|help) sed -n '2,22p' "$SELF";;
  *) echo "unknown command: $1"; sed -n '2,22p' "$SELF"; exit 1;;
esac
exit $?

__WORDLIST__
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
