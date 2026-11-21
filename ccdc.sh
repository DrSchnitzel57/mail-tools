#!/bin/sh
# ---- plain-sh launcher: keep this block POSIX. It re-runs the script under bash, installing bash first if needed (Alpine). ----
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then exec bash "$0" "$@"; fi
  echo "ccdc.sh needs bash, and bash isn't installed on this box."
  if [ "$(id -u)" != 0 ]; then echo "Become root first (su -, doas -s or sudo -i), then run:  sh $0"; exit 1; fi
  for pm in "apk add bash" "apt-get install -y bash" "dnf -y install bash" "yum -y install bash" "zypper -n install bash" "pacman -S --noconfirm bash"; do
    command -v "${pm%% *}" >/dev/null 2>&1 || continue
    echo "Installing it now:  $pm"
    if $pm; then exec bash "$0" "$@"; fi
    break
  done
  echo "Couldn't install bash (no internet?). Install it another way, then run:  bash $0"; exit 1
fi
# ======================================================================
#: ccdc.sh  -  universal CCDC Linux toolkit
#:   Debian / Ubuntu / Mint / Kali    Fedora / RHEL / Rocky / Alma / CentOS    Alpine
#:
#:   bash ccdc.sh            menu
#:   bash ccdc.sh first      START HERE: guided first run (8 steps, resumable)
#:   bash ccdc.sh info       what this box is (distro, services, firewall, roles)
#:   bash ccdc.sh check      is everything up?                    (read-only)
#:   bash ccdc.sh hunt       what changed / looks evil?           (read-only)
#:   bash ccdc.sh watch      live dashboard                       (read-only)
#:   bash ccdc.sh tmux       dashboard on top, shell below
#:   bash ccdc.sh discover   find web apps, databases, mail, file shares, DNS (read-only)
#:   bash ccdc.sh harden     audit every service role found, then plan -> apply
#:   bash ccdc.sh protect    web app audit only
#:   bash ccdc.sh fw [learn|lock|status|off]       host firewall (nftables or iptables)
#:   bash ccdc.sh backup     disguised backup of /etc + apps + databases
#:   bash ccdc.sh restore [what]                   restore one piece (ssh pam web app db etc list /some/path)
#:   bash ccdc.sh evict | passwd | ssh | recon | report | rebase
#:   bash ccdc.sh seedshow <user...> [--csv]       show seed passwords (zulu-compatible)
#:   bash ccdc.sh selftest   run every read-only check and report script errors (for testing a new distro)
#:
#:   Ctrl-C during a step = pause menu (skip / retry / quit). Nothing is ever deleted:
#:   suspicious files go to /root/cct/quarantine/. Every change is logged in /root/cct/changes.log.
# ======================================================================
VERSION="1.0"

# ------------- optional settings (leave empty = auto-detect) -------------
LAN="${LAN:-}"                          # e.g. 192.168.220.0/24  (default: this box's own subnet)
ALLOW_WEB_OUT="${ALLOW_WEB_OUT:-1}"     # firewall lock: 1 = still allow outbound 80/443 (package installs)
FW_BACKEND="${FW_BACKEND:-}"            # nft | iptables  (default: nft when it works)
DRYRUN="${DRYRUN:-0}"                   # 1 = show every plan but change nothing
LEARN_LOG_RATE="20/second"
# --------------------------------------------------------------------------

D=${CCDC_DIR:-/root/cct}; Q=$D/quarantine; BAK=$D/bak; W=$D/web; LOG=$D/changes.log; FW=$D/fw
SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
ME="bash $0"
TABLE=ccdc_fw
UTF=0; case "${LANG:-}${LC_ALL:-}" in *UTF-8*|*utf8*|*UTF8*) UTF=1;; esac
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
TS()    { date +%Y%m%d-%H%M%S; }
ask()   { local a; read -r -p "  ${Y}?${N} $* ${DIM}[y/N]${N} " a </dev/tty; [[ $a =~ ^[Yy] ]]; }
pause_enter(){ read -r -p "  ${DIM}Press Enter to continue...${N}" _ </dev/tty; }
port_up(){ timeout 3 bash -c "</dev/tcp/$1/$2" 2>/dev/null; }
q()     { printf '%q' "$1"; }   # quote a value for a plan command
indent(){ sed "s/^/${1:-      }/"; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root:  sudo bash $0 $*   (or: su -  /  doas -s)"; exit 1; }
umask 077
mkdir -p "$D" "$Q" "$BAK" "$W" "$FW"; chmod 700 "$D"

# bk: copy a file into $BAK before changing it.   quar: move a file to quarantine (never delete)
bk()   { [ -e "$1" ] || return 0; local t="$BAK$(dirname "$1")"; mkdir -p "$t"; cp -a "$1" "$t/$(basename "$1").$(TS)"; }
quar() { [ -e "$1" ] || [ -L "$1" ] || return 0; local t; t="$Q/$(echo "$1" | tr / _).$(TS)"
         mv -f -- "$1" "$t" && chmod 000 "$t" 2>/dev/null; warn "quarantined $1 ${DIM}-> $t${N}"; note "QUARANTINE $1 -> $t"; }

# tmo SECONDS LABEL cmd...   run a slow command with a time limit + live timer. Ctrl-C stops it cleanly.
timeout 2 true >/dev/null 2>&1 || { timeout -t 2 true >/dev/null 2>&1 && timeout() { command timeout -t "$@"; }; }   # very old busybox syntax
TMO_K=(); timeout -k 1 2 true >/dev/null 2>&1 && TMO_K=(-k 5)
tmo() {
  local s=$1 label=$2; shift 2
  timeout "${TMO_K[@]}" "$s" "$@" & local p=$! t=0 rc
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
  if [ "$DRYRUN" = 1 ]; then say "dry run: nothing applied"; return 0; fi
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

# ======================================================================
#  PLATFORM DETECTION  -  everything distro-specific is decided here once
# ======================================================================
osr() { sed -n "s/^$1=//p" /etc/os-release 2>/dev/null | head -1 | tr -d '"'; }
grp_exists() { grep -q "^$1:" /etc/group 2>/dev/null || getent group "$1" >/dev/null 2>&1; }
detect() {
  OS_ID=$(osr ID); OS_LIKE=$(osr ID_LIKE); OS_VER=$(osr VERSION_ID); OS_PRETTY=$(osr PRETTY_NAME)
  [ -z "$OS_PRETTY" ] && [ -f /etc/redhat-release ] && OS_PRETTY=$(head -1 /etc/redhat-release)
  [ -z "$OS_PRETTY" ] && [ -f /etc/alpine-release ] && OS_PRETTY="Alpine $(cat /etc/alpine-release)"
  [ -z "$OS_PRETTY" ] && OS_PRETTY="$(uname -s) (unknown distro)"
  case " $OS_ID $OS_LIKE " in
    *" alpine "*) FAMILY=alpine;;
    *" debian "*|*" ubuntu "*) FAMILY=debian;;
    *" rhel "*|*" fedora "*|*" centos "*|*" rocky "*|*" almalinux "*|*" ol "*|*" amzn "*) FAMILY=rhel;;
    *" suse "*|*" opensuse "*|*" sles "*) FAMILY=suse;;
    *" arch "*|*" manjaro "*) FAMILY=arch;;
    *) FAMILY=unknown
       [ -f /etc/redhat-release ] && FAMILY=rhel; [ -f /etc/debian_version ] && FAMILY=debian; [ -f /etc/alpine-release ] && FAMILY=alpine;;
  esac
  # package database
  case "$FAMILY" in
    debian) PKG=dpkg;; rhel|suse) PKG=rpm;; alpine) PKG=apk;; arch) PKG=pacman;;
    *) PKG=none; have dpkg && [ -d /var/lib/dpkg/info ] && PKG=dpkg; have rpm && [ "$PKG" = none ] && PKG=rpm
       [ -f "${APK_DB:-/lib/apk/db/installed}" ] && PKG=apk; have pacman && [ "$PKG" = none ] && PKG=pacman;;
  esac
  PM=none; for x in apt-get dnf yum apk zypper pacman; do have "$x" && { PM=$x; break; }; done
  [ "$FAMILY" = rhel ] && have dnf && PM=dnf
  # init system
  if [ -d /run/systemd/system ]; then INIT=systemd
  elif have rc-service || [ -x /sbin/openrc-run ] || [ -x /sbin/openrc ]; then INIT=openrc
  else INIT=sysv; fi
  # network listing tool
  if have ss && ss -tln >/dev/null 2>&1; then NETT=ss; elif have netstat && netstat -tln >/dev/null 2>&1; then NETT=netstat; else NETT=proc; fi
  # firewall backend we will use for our own rules
  FWB=none
  [ -z "$FW_BACKEND" ] && [ -s "$FW/backend" ] && FW_BACKEND=$(cat "$FW/backend")
  if [ "$FW_BACKEND" != iptables ] && have nft && nft list tables >/dev/null 2>&1; then FWB=nft
  elif have iptables && iptables -S >/dev/null 2>&1; then FWB=iptables
  elif [ "$FW_BACKEND" = iptables ] && have nft && nft list tables >/dev/null 2>&1; then FWB=nft; fi
  # firewall manager already on the box (we never fight it)
  FWMGR=none
  if have firewall-cmd && timeout 5 firewall-cmd --state 2>/dev/null | grep -q running; then FWMGR=firewalld
  elif have ufw && timeout 5 ufw status 2>/dev/null | grep -qi 'status: active'; then FWMGR=ufw; fi
  # admin group, doas
  ADMIN_GRPS=""; for x in wheel sudo admin; do grp_exists "$x" && ADMIN_GRPS+="$x "; done
  case "$FAMILY" in debian) SUDOGRP=sudo;; *) SUDOGRP=wheel;; esac
  grp_exists "$SUDOGRP" || SUDOGRP=$(echo "$ADMIN_GRPS" | awk '{print $1}')
  [ -z "$SUDOGRP" ] && SUDOGRP=wheel
  DOAS=0; { have doas || [ -f /etc/doas.conf ] || [ -d /etc/doas.d ]; } && DOAS=1
  # SELinux / AppArmor
  MAC=none
  if have getenforce && [ "$(getenforce 2>/dev/null)" != Disabled ] && [ -n "$(getenforce 2>/dev/null)" ]; then MAC=selinux
  elif [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" = Y ]; then MAC=apparmor; fi
  # ssh daemon + its service name
  SSHD=$(command -v sshd 2>/dev/null); [ -z "$SSHD" ] && [ -x /usr/sbin/sshd ] && SSHD=/usr/sbin/sshd
  SSH_SVC=sshd; DROPBEAR=0
  if [ -f /lib/systemd/system/ssh.service ] || [ -f /usr/lib/systemd/system/ssh.service ] || { [ -x /etc/init.d/ssh ] && [ ! -x /etc/init.d/sshd ]; }; then SSH_SVC=ssh; fi
  if [ -z "$SSHD" ] && have dropbear; then DROPBEAR=1; SSH_SVC=dropbear; fi
  [ -n "$SSHD" ] && [ ! -d /run/sshd ] && [ "$FAMILY" = debian ] && mkdir -p /run/sshd 2>/dev/null   # sshd -t needs it; socket-activated ssh may not have made it yet
  # logs
  JOURNAL=0; [ "$INIT" = systemd ] && have journalctl && JOURNAL=1
  AUTHLOG=""; for x in /var/log/auth.log /var/log/secure /var/log/messages; do [ -s "$x" ] && { AUTHLOG=$x; break; }; done
  NOLOGIN=/sbin/nologin; [ -x /usr/sbin/nologin ] && NOLOGIN=/usr/sbin/nologin; [ -x "$NOLOGIN" ] || NOLOGIN=/bin/false
  UID_MIN=$(awk '/^UID_MIN/{print $2}' /etc/login.defs 2>/dev/null); UID_MIN=${UID_MIN:-1000}
  BUSYBOX=0; case "$(readlink -f "$(command -v ls)" 2>/dev/null)" in *busybox*) BUSYBOX=1;; esac
  [ -z "$LAN" ] && LAN=$(lan_detect)
  MYIP=$(myip)
}
myip() {
  local x
  x=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)
  [ -z "$x" ] && x=$(ip -4 addr 2>/dev/null | awk '/inet /&&$2!~/^127\./{sub(/\/.*/,"",$2);print $2;exit}')
  [ -z "$x" ] && x=$(awk '/32 host/ && prev !~ /^127\./ {print prev; exit} {prev=$2}' /proc/net/fib_trie 2>/dev/null)
  [ -z "$x" ] && [ "$BUSYBOX" != 1 ] && x=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^127\.' | grep -m1 '\.')
  [ -z "$x" ] && x=$(hostname -i 2>/dev/null | tr ' ' '\n' | grep -v '^127\.' | grep -m1 '\.')
  echo "$x"
}
lan_detect() {   # this box's own subnet, e.g. 192.168.220.0/24
  local dev x
  dev=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
  if [ -n "$dev" ]; then x=$(ip -4 route show dev "$dev" 2>/dev/null | awk '$1 ~ /\// && $1 !~ /^(0\.0\.0\.0|default)/ {print $1; exit}'); fi
  [ -z "$x" ] && x=$(ip -4 route 2>/dev/null | awk '$1 ~ /\// && /scope link/ && $0 !~ /docker|podman|br-|virbr|cni|veth|lxc/ {print $1; exit}')
  if [ -z "$x" ] && [ -r /proc/net/route ]; then   # Iface Destination Gateway Flags RefCnt Use Metric Mask (hex, little-endian)
    x=$(awk 'function h(s,  i,c,v){v=0; s=toupper(s); for(i=1;i<=length(s);i++){c=index("0123456789ABCDEF",substr(s,i,1))-1; v=v*16+c}; return v}
      function bits(m,  i,v,b){b=0; for(i=1;i<=7;i+=2){v=h(substr(m,i,2)); while(v>0){b+=v%2; v=int(v/2)}}; return b}
      NR>1 {n++; I[n]=$1; Dd[n]=$2; Mm[n]=$8; if ($2=="00000000") dev=$1}
      END {for(i=1;i<=n;i++) if (Dd[i]!="00000000" && (I[i]==dev || (dev=="" && I[i] !~ /^(lo|docker|podman|br-|virbr|veth)/))) {d=Dd[i]
             printf "%d.%d.%d.%d/%s\n", h(substr(d,7,2)),h(substr(d,5,2)),h(substr(d,3,2)),h(substr(d,1,2)), bits(Mm[i]); exit}}' /proc/net/route)
  fi
  echo "${x:-0.0.0.0/0}"
}
ip2int() { local IFS=.; set -- $1; echo $(( ($1<<24) + ($2<<16) + ($3<<8) + $4 )); }
in_cidr() {   # in_cidr IP CIDR
  local ip=$1 net=${2%/*} bits=${2#*/} m
  [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [ "$bits" = "$2" ] && bits=32; [ "$bits" -eq 0 ] && return 0
  m=$(( (0xFFFFFFFF << (32-bits)) & 0xFFFFFFFF ))
  [ $(( $(ip2int "$ip") & m )) -eq $(( $(ip2int "$net") & m )) ]
}
is_loop() { case "$1" in 127.*|::1|::ffff:127.*|localhost) return 0;; esac; return 1; }
is_lan()  { local a=${1#::ffff:}; is_loop "$a" && return 0; in_cidr "$a" "$LAN"; }

# ======================================================================
#  NETWORK LISTING (ss -> netstat -> /proc)  normalized output
#   net_listen tcp|udp  -> addr|port|pid|name
#   net_estab           -> laddr|lport|raddr|rport|pid|name   (TCP established)
# ======================================================================
proc_sockmap() {  # inode|pid|name for every socket fd
  ls -l /proc/[0-9]*/fd 2>/dev/null | awk '
    /^\/proc\/[0-9]+\/fd:$/ {split($0,a,"/"); pid=a[3]; next}
    /socket:\[/ {s=$NF; gsub(/[^0-9]/,"",s); print s"|"pid}' | while IFS='|' read -r ino pid; do
      echo "$ino|$pid|$(cat /proc/$pid/comm 2>/dev/null)"; done
}
proc_net() {  # proc_net LISTEN|ESTAB tcp|udp
  local want=$1 pr=$2
  proc_sockmap > "$D/.sockmap"
  { [ -r /proc/net/$pr ] && awk -v v=4 'NR>1{print v, $2, $3, $4, $10}' /proc/net/$pr
    [ -r /proc/net/${pr}6 ] && awk -v v=6 'NR>1{print v, $2, $3, $4, $10}' /proc/net/${pr}6; } |
  awk -v want="$want" -v pr="$pr" -v mapf="$D/.sockmap" '
    function h(s,  i,c,v){v=0; s=toupper(s); for(i=1;i<=length(s);i++){c=index("0123456789ABCDEF",substr(s,i,1))-1; v=v*16+c}; return v}
    function ad(x, v,  ip,p,a){split(x,p,":"); a=p[1];
      if (v==4) ip=h(substr(a,7,2))"."h(substr(a,5,2))"."h(substr(a,3,2))"."h(substr(a,1,2));
      else if (a=="00000000000000000000000000000000") ip="::";
      else if (a=="00000000000000000000000001000000") ip="::1";
      else if (substr(a,1,24)=="0000000000000000FFFF0000") ip="::ffff:" h(substr(a,31,2))"."h(substr(a,29,2))"."h(substr(a,27,2))"."h(substr(a,25,2));
      else ip="v6:" a;
      return ip "|" h(p[2]) }
    BEGIN{while ((getline l < mapf) > 0) {split(l,f,"|"); P[f[1]]=f[2]; C[f[1]]=f[3]}}
    { st=$4; ok=0
      if (want=="LISTEN" && pr=="tcp" && st=="0A") ok=1
      if (want=="LISTEN" && pr=="udp" && st=="07") ok=1
      if (want=="ESTAB" && st=="01") ok=1
      if (!ok) next
      if (want=="LISTEN") print ad($2,$1) "|" P[$5] "|" C[$5]
      else print ad($2,$1) "|" ad($3,$1) "|" P[$5] "|" C[$5] }'
}
net_listen() {
  local pr=${1:-tcp}
  case "$NETT" in
    ss) ss -${pr:0:1}lnp 2>/dev/null | awk -v OFS='|' '$1=="State"||$1=="Netid"||$1=="Recv-Q"{next}
          {l=$4; n=split(l,a,":"); port=a[n]; addr=substr(l,1,length(l)-length(port)-1); gsub(/[][]/,"",addr); sub(/%.*/,"",addr)
           pid=""; name=""; if (match($0,/pid=[0-9]+/)) pid=substr($0,RSTART+4,RLENGTH-4)
           if (match($0,/\(\("[^"]*"/)) name=substr($0,RSTART+3,RLENGTH-4); print addr,port,pid,name}';;
    netstat) netstat -${pr:0:1}lnp 2>/dev/null | awk -v OFS='|' -v pr="$pr" '$1 ~ "^"pr {l=$4; n=split(l,a,":"); port=a[n]; addr=substr(l,1,length(l)-length(port)-1); if(addr=="") addr="::"
           pp=$NF; pid=""; name=""; if (pp ~ /^[0-9]+\//) {pid=pp; sub(/\/.*/,"",pid); name=pp; sub(/^[0-9]+\//,"",name)}; print addr,port,pid,name}';;
    *) proc_net LISTEN "$pr";;
  esac | awk -F'|' '$2 ~ /^[0-9]+$/' | sort -u
}
net_estab() {
  case "$NETT" in
    ss) ss -tnp state established 2>/dev/null | awk -v OFS='|' '$1=="Recv-Q"||$1=="State"{next}
          {l=$3; r=$4; n=split(l,a,":"); lp=a[n]; la=substr(l,1,length(l)-length(lp)-1); m=split(r,b,":"); rp=b[m]; ra=substr(r,1,length(r)-length(rp)-1)
           gsub(/[][]/,"",la); gsub(/[][]/,"",ra); sub(/%.*/,"",la); pid=""; name=""
           if (match($0,/pid=[0-9]+/)) pid=substr($0,RSTART+4,RLENGTH-4); if (match($0,/\(\("[^"]*"/)) name=substr($0,RSTART+3,RLENGTH-4); print la,lp,ra,rp,pid,name}';;
    netstat) netstat -tnp 2>/dev/null | awk -v OFS='|' '$1 ~ /^tcp/ && $6=="ESTABLISHED" {l=$4; r=$5; n=split(l,a,":"); lp=a[n]; la=substr(l,1,length(l)-length(lp)-1)
           m=split(r,b,":"); rp=b[m]; ra=substr(r,1,length(r)-length(rp)-1); pp=$7; pid=""; name=""; if (pp ~ /^[0-9]+\//) {pid=pp; sub(/\/.*/,"",pid); name=pp; sub(/^[0-9]+\//,"",name)}; print la,lp,ra,rp,pid,name}';;
    *) proc_net ESTAB tcp;;
  esac
}
listen_ports() {  # listen_ports tcp|udp [all]  -> comma list of ports on non-loopback addresses (+22 for tcp)
  { [ "$1" = tcp ] && echo 22
    net_listen "$1" | awk -F'|' -v all="$2" 'all=="all" || ($1 !~ /^(127\.|::1$|::ffff:127\.)/) {print $2}'; } | grep -E '^[0-9]+$' | sort -nu | tr '\n' ',' | sed 's/,$//'
}
listen_lines() { net_listen tcp | awk -F'|' '{print $1":"$2}' | sort -u; }   # for baselines

# ======================================================================
#  HTTP probe (curl -> wget -> bash /dev/tcp)   http_probe URL BODY HDR -> "code seconds"
# ======================================================================
http_probe() {
  local url=$1 body=${2:-/dev/null} hdr=${3:-/dev/null}
  if have curl; then curl -sk -m 5 -o "$body" -D "$hdr" -w '%{http_code} %{time_total}' "$url" 2>/dev/null; return; fi
  if have wget; then
    wget -q -S -T 5 -t 1 --no-check-certificate -O "$body" "$url" 2>"$hdr.tmp"
    local c; c=$(grep -oE 'HTTP/[0-9.]+ [0-9]{3}' "$hdr.tmp" | tail -1 | awk '{print $2}'); sed 's/^ *//' "$hdr.tmp" > "$hdr" 2>/dev/null; rm -f "$hdr.tmp"
    echo "${c:-000} ?"; return
  fi
  case "$url" in https://*) echo "000 ?"; return;; esac
  local hp=${url#http://}; hp=${hp%%/*}; local h=${hp%:*} p=${hp##*:}; [ "$p" = "$hp" ] && p=80
  local path="/${url#http://*/}"; [ "$path" = "/$url" ] && path=/
  timeout 5 bash -c "exec 3<>/dev/tcp/$h/$p; printf 'GET %s HTTP/1.0\r\nHost: %s\r\n\r\n' '$path' '$h' >&3; cat <&3" > "$body.raw" 2>/dev/null
  sed -n '1,/^\r*$/p' "$body.raw" > "$hdr"; sed '1,/^\r*$/d' "$body.raw" > "$body" 2>/dev/null; rm -f "$body.raw"
  echo "$(head -1 "$hdr" | awk '{print $2}' | grep -E '^[0-9]{3}$' || echo 000) ?"
}

# ======================================================================
#  PACKAGES (dpkg / rpm / apk / pacman)
# ======================================================================
OWNED=$D/.owned
build_owned() {   # build_owned [force]  -> index of every file a package installed
  if [ "$1" != force ] && [ -s "$OWNED" ] && [ $(( $(date +%s) - $(stat -c %Y "$OWNED") )) -lt 900 ]; then return 0; fi
  [ -t 1 ] && printf '    %sindexing which files came from packages...%s\r' "$DIM" "$N"
  case "$PKG" in
    rpm)    timeout 180 rpm -qa --qf '[%{FILENAMES}\n]';;
    dpkg)   cat /var/lib/dpkg/info/*.list;;
    apk)    awk '/^F:/{d=substr($0,3)} /^R:/{f=substr($0,3); print (d=="" ? "/" f : "/" d "/" f)}' "${APK_DB:-/lib/apk/db/installed}";;
    pacman) for x in /var/lib/pacman/local/*/files; do awk '/^%FILES%/{f=1;next} /^%/{f=0} f&&NF{print "/"$0}' "$x"; done;;
  esac 2>/dev/null | sed 's:/$::' | awk '{print} /^\/(bin|sbin|lib|lib32|lib64|libx32)\//{print "/usr"$0} /^\/usr\/(bin|sbin|lib|lib32|lib64|libx32)\//{print substr($0,5)}' | sort -u > "$OWNED.tmp"
  mv -f "$OWNED.tmp" "$OWNED"
  [ -t 1 ] && printf '%-60s\r' ""
}
owned() { [ -s "$OWNED" ] || build_owned; [ "$PKG" = none ] && return 0
          local r; r=$(readlink -f -- "$1" 2>/dev/null); grep -qxF -e "$1" -e "${r:-$1}" "$OWNED"; }
unowned_filter() { [ -s "$OWNED" ] || build_owned; [ "$PKG" = none ] && return 0; awk 'NR==FNR{o[$0]=1;next} !($0 in o)' "$OWNED" -; }
owner_pkg() {
  local x r
  case "$PKG" in
    rpm)  rpm -qf --qf '%{NAME}\n' -- "$1" 2>/dev/null | grep -v 'not owned' | head -1;;
    dpkg) for r in "$1" "$(readlink -f -- "$1" 2>/dev/null)" "${1#/usr}"; do [ -n "$r" ] || continue; x=$(dpkg -S -- "$r" 2>/dev/null | head -1 | cut -d: -f1); [ -n "$x" ] && { echo "$x"; return; }; done;;
    apk)  apk info -W -- "$1" 2>/dev/null | sed -n 's/.* is owned by //p' | head -1 | sed -E 's/-[0-9][^-]*-r[0-9]+$//';;
    pacman) pacman -Qqo -- "$1" 2>/dev/null | head -1;;
  esac
}
pkg_installed() {
  case "$PKG" in
    rpm) rpm -q "$1" >/dev/null 2>&1;;
    dpkg) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed';;
    apk) apk info -e "$1" >/dev/null 2>&1;;
    pacman) pacman -Q "$1" >/dev/null 2>&1;;
    *) return 1;;
  esac
}
KEY_PKGS() {
  case "$PKG" in
    rpm)  echo openssh-server openssh-clients sudo shadow-utils util-linux coreutils procps-ng iproute bash pam passwd findutils net-tools systemd glibc;;
    dpkg) echo openssh-server openssh-client sudo passwd login util-linux coreutils procps iproute2 bash libpam-modules libpam-modules-bin libpam-runtime findutils net-tools systemd libc-bin;;
    apk)  echo busybox openssh-server openssh-client-default sudo doas shadow util-linux coreutils procps-ng iproute2 bash linux-pam musl-utils;;
    pacman) echo openssh sudo shadow util-linux coreutils procps-ng iproute2 bash pam systemd glibc;;
  esac
}
pkg_verify() {   # print system programs/libraries whose contents differ from the package
  local p=() x; for x in $(KEY_PKGS); do pkg_installed "$x" && p+=("$x"); done
  case "$PKG" in
    rpm)  [ ${#p[@]} -gt 0 ] && rpm -V "${p[@]}" 2>/dev/null | awk '$1 ~ /5/ {print $NF}';;
    dpkg) [ ${#p[@]} -gt 0 ] && dpkg --verify "${p[@]}" 2>/dev/null | awk '$1 ~ /5/ {print $NF}';;
    apk)  apk audit --system 2>/dev/null | awk '$1 ~ /^[UXM]$/ {x=$2; if (x !~ /^\//) x="/" x; print x}';;
    pacman) [ ${#p[@]} -gt 0 ] && pacman -Qkk "${p[@]}" 2>/dev/null | grep -i 'checksum mismatch' | sed -E 's/^[^:]*: [^:]*: ([^ ]+).*/\1/';;
  esac | grep -E '^/(usr/)?(s?bin|lib|lib64|libexec)/' | sort -u
}
pkg_install_cmd() {   # the command that installs packages "$@" on this box
  case "$PM" in
    apt-get) echo "DEBIAN_FRONTEND=noninteractive apt-get install -y -q $*";;
    dnf) echo "dnf -y -q install $*";; yum) echo "yum -y -q install $*";;
    apk) echo "apk add -q $*";; zypper) echo "zypper -n -q install $*";; pacman) echo "pacman -S --noconfirm $*";;
    *) echo "false";;
  esac
}
db_client_pkg() { case "$FAMILY" in rhel|suse) echo mariadb;; arch) echo mariadb-clients;; *) echo mariadb-client;; esac; }
pkg_install() { local c; c=$(pkg_install_cmd "$@"); tmo 240 "installing $*" bash -c "$c" >/dev/null 2>&1; }
pkg_reinstall() {   # quiet reinstall with a verdict
  local log="$D/.reinstall.log"; tmo 300 "reinstalling $1" bash -c "$(pkg_reinstall_cmd "$1")" >"$log" 2>&1; local rc=$?
  if [ $rc -ne 0 ] || grep -qiE 'not possible|unable to|error|no match|not found|failed' "$log"; then warn "reinstall of $1 didn't work: $(grep -iE 'not possible|unable|error|no match|not found|failed' "$log" | head -1)"; return 1; fi
}
pkg_reinstall_cmd() {
  case "$PM" in
    apt-get) echo "DEBIAN_FRONTEND=noninteractive apt-get install -y -q --reinstall $1";;
    dnf) echo "dnf -y -q reinstall $1";; yum) echo "yum -y -q reinstall $1";;
    apk) echo "apk fix -q --reinstall $1";; zypper) echo "zypper -n install -f $1";; pacman) echo "pacman -S --noconfirm $1";;
    *) echo "false";;
  esac
}

# ======================================================================
#  SERVICES (systemd / OpenRC / SysV)  - names are given without .service
# ======================================================================
svc_bare() { echo "${1%.service}"; }
svc_active() { local s; s=$(svc_bare "$1")
  case "$INIT" in
    systemd) systemctl is-active --quiet "$s" 2>/dev/null;;
    openrc)  rc-service "$s" status >/dev/null 2>&1;;
    *) if have service; then service "$s" status >/dev/null 2>&1; elif [ -x "/etc/init.d/$s" ]; then "/etc/init.d/$s" status >/dev/null 2>&1; else pgrep -x "$s" >/dev/null; fi;;
  esac; }
svc_do() {   # svc_do start|stop|restart|reload|enable|disable NAME
  local a=$1 s; s=$(svc_bare "$2")
  case "$INIT" in
    systemd) systemctl "$a" "$s" 2>/dev/null;;
    openrc) case "$a" in enable) rc-update add "$s" default >/dev/null;; disable) rc-update del "$s" default >/dev/null 2>&1; rc-update del "$s" boot >/dev/null 2>&1; true;;
                        *) rc-service "$s" "$a" >/dev/null 2>&1;; esac;;
    *) case "$a" in enable) if have update-rc.d; then update-rc.d "$s" defaults >/dev/null 2>&1; elif have chkconfig; then chkconfig "$s" on; fi;;
                    disable) if have update-rc.d; then update-rc.d "$s" disable >/dev/null 2>&1; elif have chkconfig; then chkconfig "$s" off 2>/dev/null; fi; true;;
                    *) if have service; then service "$s" "$a" >/dev/null 2>&1; elif [ -x "/etc/init.d/$s" ]; then "/etc/init.d/$s" "$a" >/dev/null 2>&1; else false; fi;; esac;;
  esac; }
svc_restart() { svc_do restart "$1"; }
svc_reload()  { svc_do reload "$1" || svc_do restart "$1"; }
svc_off()     { svc_do stop "$1"; svc_do disable "$1"; [ "$INIT" = systemd ] && systemctl daemon-reload 2>/dev/null; true; }
svc_running() {
  case "$INIT" in
    systemd) systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | awk '{print $1}' | sed 's/\.service$//';;
    openrc)  rc-status -a 2>/dev/null | awk '/\[ *started/{print $1}' | sort -u;;
    *) if have service; then service --status-all 2>/dev/null | awk '/\[ \+ \]/{print $NF}'; fi;;
  esac
}
svc_enabled() {
  case "$INIT" in
    systemd) systemctl list-unit-files --state=enabled --no-legend --no-pager 2>/dev/null | awk '{print $1}';;
    openrc)  rc-update show -v 2>/dev/null | awk -F'|' '$2 ~ /[a-z]/ {gsub(/ /,"",$1); print $1}';;
    *) ls /etc/rc[2-5].d/ 2>/dev/null | grep '^S' | sed 's/^S[0-9]*//' | sort -u;;
  esac
}
svc_of_pid() {   # which service runs this PID (best effort)
  local c x; c=$(cat "/proc/$1/cgroup" 2>/dev/null)
  x=$(echo "$c" | grep -oE '[A-Za-z0-9@_.:-]+\.service' | tail -1); [ -n "$x" ] && { echo "${x%.service}"; return; }
  x=$(echo "$c" | grep -oE 'openrc\.[A-Za-z0-9@_.-]+' | head -1); [ -n "$x" ] && { echo "${x#openrc.}"; return; }
  [ "$INIT" = systemd ] && { x=$(systemctl status "$1" --no-pager 2>/dev/null | head -1 | grep -oE '[A-Za-z0-9@_.:-]+\.service' | head -1); [ -n "$x" ] && { echo "${x%.service}"; return; }; }
  local comm; comm=$(cat "/proc/$1/comm" 2>/dev/null)
  for x in "$comm" "${comm%d}" "$comm"d; do [ -x "/etc/init.d/$x" ] && { echo "$x"; return; }; done
}
svc_logs() {   # svc_logs NAME LINES
  local s; s=$(svc_bare "$1")
  if [ "$JOURNAL" = 1 ]; then journalctl -u "$s" -n "${2:-30}" --no-pager 2>/dev/null
  else for x in /var/log/messages /var/log/syslog /var/log/daemon.log "/var/log/$s.log" "/var/log/$s/error.log"; do [ -f "$x" ] && grep -i "$s" "$x" 2>/dev/null | tail -n "${2:-30}"; done; fi
}
svc_hint() { case "$INIT" in systemd) echo "systemctl restart $1 ; journalctl -u $1 -n 30";; openrc) echo "rc-service $1 restart ; tail /var/log/messages";; *) echo "service $1 restart";; esac; }
service_files() {   # every place a service/startup entry can live (for baselines and hunts)
  find /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system /usr/local/lib/systemd/system /run/systemd/system /etc/systemd/user \
       /root/.config/systemd /home/*/.config/systemd /etc/init.d /etc/local.d /etc/runlevels /etc/rc.local /etc/xdg/autostart \
       -maxdepth 2 \( -type f -o -type l \) 2>/dev/null | sort -u
}

# ======================================================================
#  USERS AND GROUPS (shadow-utils or busybox)
# ======================================================================
grp_members() { { awk -F: -v g="$1" '$1==g{print $4}' /etc/group; getent group "$1" 2>/dev/null | cut -d: -f4; } | tr ',' '\n' | grep . | sort -u | tr '\n' ' '; }
user_add() {   # user_add NAME
  local sh=/bin/bash; [ -x $sh ] || sh=/bin/sh
  if have useradd; then useradd -m -s "$sh" "$1"; else adduser -D -s "$sh" "$1"; fi; }
grp_add_user() { if have usermod; then usermod -aG "$2" "$1"; elif have gpasswd; then gpasswd -a "$1" "$2" >/dev/null; else addgroup "$1" "$2"; fi; }
grp_del_user() { if have gpasswd; then gpasswd -d "$1" "$2" >/dev/null; elif [ "$FAMILY" = alpine ] || [ "$BUSYBOX" = 1 ]; then delgroup "$1" "$2"; else deluser "$1" "$2"; fi; }
grp_del_cmd()  { echo "grp_del_user $(q "$1") $(q "$2")"; }
user_lock() {   # lock password + nologin shell
  if have usermod; then usermod -L -s "$NOLOGIN" "$1"
  else passwd -l "$1" >/dev/null 2>&1; bk /etc/passwd; awk -F: -v OFS=: -v u="$1" -v s="$NOLOGIN" '$1==u{$7=s}1' /etc/passwd > /etc/passwd.ccdc && cat /etc/passwd.ccdc > /etc/passwd && rm -f /etc/passwd.ccdc; fi; }
set_pw() {   # set_pw USER PASSWORD
  if [ "$BUSYBOX" = 1 ] && chpasswd --help 2>&1 | grep -q -- '-c'; then echo "$1:$2" | chpasswd -c sha512; else echo "$1:$2" | chpasswd; fi; }
login_users() { awk -F: '$7!~/(nologin|false|sync|shutdown|halt)$/ && $7!=""{print $1}' /etc/passwd; }
admin_grants() {   # does group $1 actually give root? (sudoers or doas)
  grep -qsE "^[[:space:]]*%$1[[:space:]]" /etc/sudoers /etc/sudoers.d/* && return 0
  grep -qsE "^[[:space:]]*permit[^#]*:$1([[:space:]]|$)" /etc/doas.conf /etc/doas.d/*.conf && return 0
  return 1; }

# ======================================================================
#  LOGS
# ======================================================================
ssh_log() {   # recent sshd login lines
  if [ "$JOURNAL" = 1 ]; then journalctl -u "$SSH_SVC" -u sshd -u ssh --since "-${1:-30}min" --no-pager 2>/dev/null
  elif [ -n "$AUTHLOG" ]; then tail -n 3000 "$AUTHLOG" 2>/dev/null | grep -E 'sshd|dropbear'; fi | grep -E 'Accepted|Failed|Invalid|authentication failure|Bad password|Password auth succeeded'
}
klog() {   # kernel log (firewall LOG lines)
  if [ "$JOURNAL" = 1 ]; then journalctl -k --since "${1:--30min}" --no-pager 2>/dev/null
  else { dmesg 2>/dev/null; tail -n 5000 /var/log/kern.log /var/log/messages 2>/dev/null; }; fi
}

# ======================================================================
#  HOST NAMES for nicer firewall plans:  /root/cct/hosts.txt ("IP name" per line), /etc/hosts, reverse DNS
# ======================================================================
host_name() {
  local n; n=$(awk -v ip="$1" '$1==ip{print $2; exit}' "$D/hosts.txt" /etc/hosts 2>/dev/null)
  [ -z "$n" ] && n=$(timeout 2 getent hosts "$1" 2>/dev/null | awk '{print $2; exit}')
  if is_lan "$1"; then echo "${n:-LAN host}"; else echo "${n:+$n, }internet"; fi
}

detect

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
  local hash i hex dec idx pw="" b; hash=$(printf '%s' "$1$2" | md5sum); b=$(wc -l < "$WL" | awk '{print $1-1}')
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
  set_pw "$1" "$p1" && ok "changed $1" && note "password changed: $1"
}
cmd_passwd() {
  hdr "PASSWORDS (zulu-compatible)"
  tip "Same as 'zulu.sh -i': you type passwords for root, ccdcuser1, ccdcuser2."
  tip "Every OTHER local login user gets the team seed-phrase password."
  tip "Nothing shows while you type. Enter on an empty prompt skips that account."
  local u
  for u in ccdcuser1 ccdcuser2; do id "$u" >/dev/null 2>&1 || { user_add "$u" && ok "created $u" && note "created $u"; }; done
  grp_exists "$SUDOGRP" || { have groupadd && groupadd "$SUDOGRP" || addgroup "$SUDOGRP" 2>/dev/null; }
  grp_add_user ccdcuser1 "$SUDOGRP" && ok "ccdcuser1 is in $SUDOGRP (admin). ccdcuser2 is a normal user, like zulu."
  if ! admin_grants "$SUDOGRP"; then
    warn "the $SUDOGRP group doesn't actually grant root on this box yet"
    if have sudo; then tip "fix:  echo '%$SUDOGRP ALL=(ALL:ALL) ALL' > /etc/sudoers.d/ccdc-admins; chmod 440 /etc/sudoers.d/ccdc-admins"
      ask "Add that sudoers rule now?" && { echo "%$SUDOGRP ALL=(ALL:ALL) ALL" > /etc/sudoers.d/ccdc-admins; chmod 440 /etc/sudoers.d/ccdc-admins
        if visudo -c >/dev/null 2>&1 || ! have visudo; then ok "added /etc/sudoers.d/ccdc-admins"; note "added sudoers rule for $SUDOGRP"; else bad "visudo check failed - removing"; rm -f /etc/sudoers.d/ccdc-admins; fi; }
    elif [ "$DOAS" = 1 ]; then tip "fix:  echo 'permit persist :$SUDOGRP' >> /etc/doas.d/ccdc.conf"
      ask "Add that doas rule now?" && { mkdir -p /etc/doas.d; echo "permit persist :$SUDOGRP" > /etc/doas.d/ccdc.conf; chmod 600 /etc/doas.d/ccdc.conf; ok "added /etc/doas.d/ccdc.conf"; note "added doas rule for $SUDOGRP"; }
    else tip "neither sudo nor doas is installed: ccdcuser1 logs in, then 'su -' with the root password"; fi
  fi
  for u in root ccdcuser1 ccdcuser2; do set_pw_manual "$u"; done
  local users; users=$(grep -v "false\|nologin" /etc/passwd | cut -d: -f1 | grep -vxE 'root|ccdcuser1|ccdcuser2|sync|shutdown|halt')
  echo; say "Other local login users: ${BO}$(echo $users)${N}"
  if [ -n "$users" ]; then
    tip "If a scored check logs in with one of these accounts, leave it out now and change it later with a password change request."
    local skip; read -r -p "  Names to leave alone (space-separated), or Enter for none: " skip </dev/tty
    for u in $skip; do users=$(echo "$users" | grep -vxF "$u"); note "passwd: left $u unchanged"; done
    [ -n "$skip" ] && say "Will change: ${BO}$(echo $users)${N}"
  fi
  if [ -n "$users" ] && ask "Give them the team seed-phrase passwords?" && get_wordlist; then
    read_seed
    for u in $users; do set_pw "$u" "$(zulu_pw "$SEED" "$u")" && ok "seed password set: $u" && note "seed password set: $u"; done
    tip "See any seed password later:  $ME seedshow <user>"
    unset SEED
  elif [ -n "$users" ]; then
    for u in $users; do set_pw_manual "$u"; done
  fi
  sub "Admin groups"
  for u in $ADMIN_GRPS; do say "$u: ${BO}$(grp_members "$u")${N}"; done
  tip "Remove extras in the 'evict' step."
  tip "If a scored check logs in with a local account and goes red: file the password change with the scoring team ($ME seedshow <user> --csv)."
}
cmd_seedshow() {
  shift; local csv=0 u us=()
  for u in "$@"; do [ "$u" = --csv ] && csv=1 || us+=("$u"); done
  [ ${#us[@]} -gt 0 ] || { echo "usage: $ME seedshow <user> [user...] [--csv]"; return 1; }
  get_wordlist || return 1; read_seed
  for u in "${us[@]}"; do [ $csv = 1 ] && echo "$u,$(zulu_pw "$SEED" "$u")" || echo "  $u : $(zulu_pw "$SEED" "$u")"; done
  unset SEED; tip "Run 'clear' after you've copied it."
}

# ======================================================================
#  EVICT: find planted backdoors, then plan -> apply
# ======================================================================
del_line() {   # del_line FILE "exact line" -> comment it out (keeps a record, easy to undo)
  local f=$1 l=$2; awk -v l="$l" '$0==l{print "# ccdc disabled: " $0; next} {print}' "$f" > "$f.ccdc" && cat "$f.ccdc" > "$f" && rm -f "$f.ccdc"; }
unit_bin() { grep -m1 -E '^[[:space:]]*ExecStart[[:space:]]*=' "$1" 2>/dev/null | cut -d= -f2- | sed -E 's/^[[:space:]]*[-@+!:]*//' | awk '{print $1}'; }
initd_bin() { grep -m1 -E '^[[:space:]]*(command|DAEMON|daemon|exec)=' "$1" 2>/dev/null | cut -d= -f2- | tr -d '"'"'" | awk '{print $1}'; }
SUSP_RE='(curl|wget)[^|]*[|][[:space:]]*(ba)?sh|[[:space:]]nc[[:space:]]|ncat|socat|/dev/tcp/|/dev/udp/|base64[[:space:]]+-d|bash[[:space:]]+-i|python[0-9.]*[[:space:]]+-c|perl[[:space:]]+-e|LD_PRELOAD|mkfifo|alias[[:space:]]+(sudo|ps|ss|netstat|who|w|last|systemctl|passwd|cat|top|kill|lsof|crontab)='
svc_tags() {   # svc_tags NAME PROGRAM -> warnings appended to a plan line
  local t="" n d; n=$(svc_bare "$1"); n=${n%.timer}; n=${n%.socket}
  svc_active "$n" && t+=" ${Y}(running now)${N}"
  if grep -qx "$n" "$W/units" 2>/dev/null; then t+=" ${R}(runs the web app)${N}"
  elif [ -n "$2" ]; then while read -r d; do [ -n "$d" ] && case "$2" in "$d"/*) t+=" ${R}(program is in the web app's folder)${N}"; break;; esac; done < "$W/dirs" 2>/dev/null; fi
  case "$n" in ssh|sshd|dropbear) t+=" ${R}(this is the SSH server)${N}";; esac
  echo "$t"
}
risky_if() { case "$1" in *"web app"*|*"SSH server"*|*"logged in as"*) echo risky;; esac; }
cmd_evict() {
  hdr "EVICT BACKDOORS"
  tip "Nothing changes until you approve the plan at the end. Files are moved to $Q, never deleted."
  plan_reset
  build_owned force
  local f u b k found x

  sub "SSH keys (logins without a password)"
  local akf=""; [ -n "$SSHD" ] && akf=$("$SSHD" -T 2>/dev/null | awk '/^authorizedkeysfile /{for(i=2;i<=NF;i++)print $i}')
  if [ -n "$akf" ] && echo "$akf" | grep -qvxE '\.ssh/authorized_keys2?|%h/\.ssh/authorized_keys2?'; then warn "sshd reads keys from a non-standard place: ${BO}$(echo $akf)${N} (the 'ssh' step resets this)"; fi
  [ -n "$SSHD" ] && "$SSHD" -T 2>/dev/null | grep -qiE '^authorizedkeyscommand [^n]' && bad "sshd runs an AuthorizedKeysCommand: $("$SSHD" -T 2>/dev/null | grep -i '^authorizedkeyscommand ')"
  found=0; local seen_k=""
  for k in /root/.ssh/authorized_keys* /home/*/.ssh/authorized_keys* /etc/ssh/.ssh/* /etc/dropbear/authorized_keys $(awk -F: '$6!="" && $6!="/" {print $6"/.ssh/authorized_keys"}' /etc/passwd | sort -u) $(echo "$akf" | grep '^/'); do
    [ -s "$k" ] || continue; case " $seen_k " in *" $k "*) continue;; esac; seen_k="$seen_k $k"; found=1
    bad "$k"; awk '!/^[[:space:]]*#/ && NF {printf "      %s ...%s %s\n",$1,substr($2,length($2)-10),$3}' "$k"
    plan_add "quarantine $k (removes those keys)" "quar $(q "$k")"
  done
  [ $found = 0 ] && ok "no authorized_keys files"

  sub "Accounts"
  for u in $(awk -F: '$3==0 && $1!="root"{print $1}' /etc/passwd); do bad "extra UID 0 (root-equivalent) account: $u"; plan_add "lock root-equivalent account $u" "user_lock $(q "$u")"; done
  for u in $(awk -F: -v m="$UID_MIN" '$3>0 && $3<m && $7~/(bash|sh|zsh|ash|dash|ksh|fish)$/ && $1!="sync"{print $1}' /etc/passwd); do
    warn "system account with a login shell: ${BO}$u${N} ($(awk -F: -v u="$u" '$1==u{print $5", home "$6}' /etc/passwd))"
    plan_add "lock system account $u (nologin shell) - skip it if a service logs in as $u" "user_lock $(q "$u")"
  done
  for u in $(awk -F: '($2=="" ){print $1}' /etc/shadow 2>/dev/null); do bad "account with NO password (anyone can log in): $u"; plan_add "lock passwordless account $u" "passwd -l $(q "$u") >/dev/null"; done
  local g adm
  for g in $ADMIN_GRPS; do adm=$(grp_members "$g"); say "$g (admin) members: ${BO}${adm:-none}${N}"
    for u in $adm; do case "$u" in ccdcuser1|root) ;; *)
      if [ "$u" = "${SUDO_USER:-}${DOAS_USER:-}" ]; then plan_add "remove $u from $g ${Y}(you're logged in as $u: only AFTER 'sudo -i' works as ccdcuser1 in a new terminal)${N}" "$(grp_del_cmd "$u" "$g")" risky
      else plan_add "remove $u from $g (admin)" "$(grp_del_cmd "$u" "$g")"; fi;; esac; done; done
  for g in root docker lxd disk; do adm=$(grp_members "$g"); [ -n "$adm" ] && grp_exists "$g" && warn "group ${BO}$g${N} has members ($adm): that's root-equivalent"
    for u in $adm; do [ "$u" = root ] || plan_add "remove $u from group $g (root-equivalent)" "$(grp_del_cmd "$u" "$g")"; done; done
  for f in /etc/sudoers.d/*; do [ -f "$f" ] || continue; owned "$f" && continue; case "$f" in */ccdc-admins) continue;; esac
    bad "sudoers file not from a package: $f"; grep -v '^[[:space:]]*#' "$f" | grep . | head -5 | indent
    plan_add "quarantine sudoers file $f" "quar $(q "$f")"; done
  grep -nE 'NOPASSWD|!authenticate' /etc/sudoers 2>/dev/null | grep -v ':[[:space:]]*#' | indent "      sudoers: "
  if [ "$DOAS" = 1 ]; then
    grep -nE '^[[:space:]]*permit' /etc/doas.conf /etc/doas.d/*.conf 2>/dev/null | grep -vE "permit (persist )?:($SUDOGRP|wheel)([[:space:]]|$)" | awk -F: '!s[$1 FS $3]++' > "$D/.doas"
    while IFS= read -r x; do warn "doas rule: $x"; local df=${x%%:*} dl=${x#*:}; dl=${dl#*:}
      plan_add "doas: comment out '$dl' in $df" "bk $(q "$df"); del_line $(q "$df") $(q "$dl")"; done < "$D/.doas"
    for f in /etc/doas.d/*.conf; do [ -f "$f" ] || continue; owned "$f" && continue; case "$f" in */ccdc.conf) continue;; esac; plan_add "quarantine doas rule file $f" "quar $(q "$f")"; done
  fi

  sub "Services and startup entries not installed by any package"
  found=0
  if [ -d /etc/systemd ] || [ "$INIT" = systemd ]; then
    for f in /etc/systemd/system/*.service /etc/systemd/system/*.timer /etc/systemd/system/*.socket /etc/systemd/system/*.path \
             /usr/lib/systemd/system/*.service /usr/lib/systemd/system/*.timer /lib/systemd/system/*.service /lib/systemd/system/*.timer \
             /usr/local/lib/systemd/system/* /run/systemd/system/*.service /etc/systemd/user/* /root/.config/systemd/user/* /home/*/.config/systemd/user/* \
             /etc/systemd/system-generators/* /usr/lib/systemd/system-generators/* /lib/systemd/system-generators/*; do
      [ -f "$f" ] || continue; owned "$f" && continue
      [ -L "$f" ] && owned "$(readlink -f "$f")" && continue
      u=$(basename "$f"); case "$u" in ccdc-*) continue;; esac; b=$(unit_bin "$f"); found=1
      warn "${BO}$u${N}  ${DIM}$f${N}"; echo "      $(grep -m1 '^Description' "$f")"; echo "      ExecStart: ${b:-?}"
      local cmd="svc_off $(q "$u"); quar $(q "$f")" also=""
      if [ -n "$b" ] && [ -e "$b" ] && ! owned "$b" && [ "$b" != "$SSHD" ]; then echo "      ${R}program is not from a package${N}"; cmd+="; quar $(q "$b")"; also=" and $b"; fi
      local tg; tg=$(svc_tags "$u" "$b"); plan_add "disable + quarantine $u$also$tg" "$cmd; true" "$(risky_if "$tg")"
    done
    for f in /etc/systemd/system/*.d/*.conf /run/systemd/system/*.d/*.conf; do [ -f "$f" ] || continue; grep -qE '^[[:space:]]*Exec(Start|StartPre|StartPost|Stop|Reload)' "$f" || continue; owned "$f" && continue
      warn "drop-in changes what a service runs: ${BO}$f${N}"; grep -E '^[[:space:]]*Exec' "$f" | indent
      plan_add "quarantine drop-in $f" "quar $(q "$f"); systemctl daemon-reload 2>/dev/null; true"; done
  fi
  for f in /etc/init.d/*; do [ -f "$f" ] || continue; owned "$f" && continue
    case "$(basename "$f")" in README|skeleton|functions|rc|rcS|halt|reboot) continue;; esac
    u=$(basename "$f"); b=$(initd_bin "$f"); found=1
    warn "init script not from a package: ${BO}$f${N}  ${DIM}runs: ${b:-?}${N}"
    local cmd="svc_off $(q "$u"); quar $(q "$f")" also=""
    if [ -n "$b" ] && [ -e "$b" ] && ! owned "$b" && [ "$b" != "$SSHD" ]; then cmd+="; quar $(q "$b")"; also=" and $b"; fi
    local tg; tg=$(svc_tags "$u" "$b"); plan_add "disable + quarantine init script $u$also$tg" "$cmd; true" "$(risky_if "$tg")"
  done
  for f in /etc/local.d/*.start /etc/local.d/*.stop /etc/rc.local /etc/rc.d/rc.local; do [ -f "$f" ] || continue; owned "$f" && continue; case "$f" in */ccdc-fw.start) continue;; esac
    x=$(grep -vE '^[[:space:]]*(#|exit 0|$)' "$f"); [ -n "$x" ] || continue; found=1
    warn "runs at boot: ${BO}$f${N}"; echo "$x" | head -4 | indent
    plan_add "quarantine boot script $f" "quar $(q "$f")"; done
  [ -f /etc/inittab ] && grep -vE '^[[:space:]]*(#|$)' /etc/inittab | grep -vE 'getty|openrc|rc |sysinit|shutdown|ctrlaltdel|reboot|initdefault|si::|rc::|l[0-6]:|::wait:|::once:/sbin/openrc' | while read -r x; do warn "unusual /etc/inittab line: $x"; done
  for f in /etc/xdg/autostart/*.desktop /root/.config/autostart/*.desktop /home/*/.config/autostart/*.desktop; do [ -f "$f" ] || continue; owned "$f" && continue
    warn "desktop autostart entry: $f ($(grep -m1 '^Exec=' "$f"))"; plan_add "quarantine autostart entry $f" "quar $(q "$f")"; found=1; done
  [ $found = 0 ] && ok "every service and startup entry comes from a package"

  sub "Scheduled jobs"
  for f in /var/spool/cron/* /var/spool/cron/crontabs/* /etc/cron.d/* /etc/cron.hourly/* /etc/cron.daily/* /etc/cron.weekly/* /etc/cron.monthly/* \
           /etc/periodic/*/* /var/spool/at/* /var/spool/cron/atjobs/* /etc/crontabs/*; do
    [ -f "$f" ] || continue
    case "$f" in /etc/cron.hourly/*|/etc/cron.daily/*|/etc/cron.weekly/*|/etc/cron.monthly/*|/etc/periodic/*) owned "$f" && continue;; esac
    if owned "$f"; then   # packaged crontabs: only show lines that look added
      x=$(grep -vE '^[[:space:]]*(#|$)' "$f" | grep -vE 'run-parts|anacron|/etc/periodic|debian-sa1|sa1|e2scrub|popularity-contest|logrotate|man-db|apt-compat|dpkg|0anacron|certbot|sysstat|php|MAILTO|SHELL=|PATH=|HOME=' )
      if [ -n "$x" ]; then warn "added lines in packaged crontab $f:"; echo "$x" | head -4 | indent
        while IFS= read -r l; do plan_add "remove this line from $f: ${DIM}$l${N}" "bk $(q "$f"); del_line $(q "$f") $(q "$l")"; done < <(echo "$x" | awk '!s[$0]++'); fi
      continue
    fi
    case "$(basename "$f")" in .placeholder|README|*.dpkg-dist) continue;; esac
    warn "scheduled job: ${BO}$f${N}"; grep -vE '^[[:space:]]*(#|$)' "$f" | head -4 | indent
    plan_add "quarantine scheduled job $f" "quar $(q "$f")"; done
  x=$(grep -vE '^[[:space:]]*(#|$)' /etc/crontab 2>/dev/null | grep -vE 'run-parts|anacron|SHELL=|PATH=|MAILTO=|HOME=|cron\.(hourly|daily|weekly|monthly)')
  if [ -n "$x" ]; then warn "extra lines in /etc/crontab:"; echo "$x" | indent
    while IFS= read -r l; do plan_add "remove this line from /etc/crontab: ${DIM}$l${N}" "bk /etc/crontab; del_line /etc/crontab $(q "$l")"; done <<<"$x"; fi
  if [ "$INIT" = systemd ]; then systemctl list-timers --all --no-legend 2>/dev/null | grep -oE '[A-Za-z0-9@_.:-]+\.timer' | sort -u | while read -r u; do
    f=$(systemctl show -p FragmentPath --value "$u" 2>/dev/null); [ -n "$f" ] && ! owned "$f" && warn "timer not from a package: $u ($f)"; done; fi

  sub "Login hooks (PAM, preload, shell startup)"
  local seen_pam=""
  if grep -q . /etc/ld.so.preload 2>/dev/null; then bad "/etc/ld.so.preload is not empty: $(cat /etc/ld.so.preload)"; plan_add "quarantine /etc/ld.so.preload (rootkit trick)" "quar /etc/ld.so.preload"; else ok "ld.so.preload clean"; fi
  grep -qs 'LD_PRELOAD' /etc/environment && { bad "/etc/environment sets LD_PRELOAD"; plan_add "remove LD_PRELOAD from /etc/environment" "bk /etc/environment; sed -i '/LD_PRELOAD/d' /etc/environment"; }
  for f in /etc/ld.so.conf.d/*; do [ -f "$f" ] && ! owned "$f" && warn "library path file not from a package: $f ($(head -2 "$f" | tr '\n' ' '))"; done
  for f in /lib/x86_64-linux-gnu/security/*.so /usr/lib/x86_64-linux-gnu/security/*.so /lib/aarch64-linux-gnu/security/*.so /usr/lib64/security/*.so /lib64/security/*.so /lib/security/*.so /usr/lib/security/*.so; do
    [ -f "$f" ] || continue; owned "$f" && continue
    local rp; rp=$(readlink -f "$f"); case " $seen_pam " in *" $rp "*) continue;; esac; seen_pam+=" $rp "
    bad "PAM module not from a package: $f  (password stealer?)"
    grep -rln "$(basename "$f")" /etc/pam.d/ 2>/dev/null | indent "      used in: "
    tip "fix: remove its line from those /etc/pam.d files (bk first), THEN quarantine the .so - removing the .so first can break logins"
  done
  x=$(grep -rnE 'pam_exec|pam_script' /etc/pam.d/ 2>/dev/null); [ -n "$x" ] && { echo "$x" | indent; warn "^ pam_exec runs a program at every login - check it"; }
  x=$(grep -rnE '^[[:space:]]*auth[[:space:]]+(sufficient|\[[^]]*success=[^]]*\])[[:space:]]+pam_permit\.so' /etc/pam.d/ 2>/dev/null)
  [ -n "$x" ] && { echo "$x" | indent; bad "^ 'auth sufficient pam_permit.so' lets ANY password log in"; tip "restore PAM from a clean backup, or edit that line out (bk first)"; }
  for f in /etc/profile.d/* /etc/profile /etc/bash.bashrc /etc/bashrc /etc/environment /etc/zsh/zshrc /etc/zshrc \
           /root/.bashrc /root/.bash_profile /root/.profile /root/.zshrc /home/*/.bashrc /home/*/.bash_profile /home/*/.profile /home/*/.zshrc; do
    [ -f "$f" ] || continue
    x=$(grep -nE "$SUSP_RE" "$f" 2>/dev/null)
    [ -n "$x" ] && { echo "$x" | sed "s|^|      $f:|"; warn "^ suspicious shell startup line in $f"; }
    case "$f" in /etc/profile.d/*) if ! owned "$f"; then
      if [ -n "$x" ]; then plan_add "quarantine $f (suspicious login script)" "quar $(q "$f")"; else say "login script not from a package (looks harmless): ${DIM}$f${N}"; fi; fi;; esac
  done
  for f in /etc/aliases /root/.forward /home/*/.forward; do [ -f "$f" ] || continue; x=$(grep -nE '[|]' "$f" | grep -v '^[0-9]*:[[:space:]]*#'); [ -n "$x" ] && { warn "mail alias pipes to a program in $f:"; echo "$x" | indent; }; done

  sub "Tampered system programs (package verify)"
  if [ "$PKG" != none ]; then
    local mod; mod=$(tmo 180 "verifying key packages" bash -c "$(declare -f pkg_verify pkg_installed KEY_PKGS); PKG=$PKG; pkg_verify")
    if [ -n "$mod" ]; then bad "system programs changed since install:"; echo "$mod" | indent
      local pk; for pk in $(for x in $mod; do owner_pkg "$x"; done | sort -u); do
        plan_add "reinstall $pk from the distro repos (needs internet)" "pkg_reinstall $(q "$pk")"; done
    else ok "ssh, sudo, ps, ls, login tools match their packages"; fi
  fi

  sub "Running programs"
  local p e cl why
  for p in /proc/[0-9]*; do e=$(readlink "$p/exe" 2>/dev/null) || continue; why=""
    case "$e" in *" (deleted)"|/tmp/*|/var/tmp/*|/dev/shm/*|/run/user/*) why="runs from $e";; esac
    cl=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null | cut -c1-60)
    case "$cl" in "["*"]"*) why="${why:+$why, }pretends to be kernel thread ${cl% }";; esac
    [ -n "$why" ] && { bad "PID ${p#/proc/} $why: $(tr '\0' ' ' < "$p/cmdline" | cut -c1-80)"; plan_add "kill PID ${p#/proc/} ($why)" "kill -9 ${p#/proc/}"; }
  done
  net_listen tcp | awk -F'|' '$3!=""{print $3}' | sort -u | while read -r p; do e=$(readlink -f "/proc/$p/exe" 2>/dev/null) && echo "$e|$p"; done | awk -F'|' '{a[$1]=a[$1]" "$2} END{for(e in a) print e"|"a[e]}' | while IFS='|' read -r e p; do
    [ -n "$e" ] && ! owned "$e" && warn "listening program not from a package: ${BO}$e${N} (PID$p) ${DIM}- could be the web app itself; see 'discover'${N}"; done
  if svc_active cockpit.socket || net_listen tcp | grep -q '|9090|'; then warn "Cockpit admin console listens on 9090. Turn it off unless it's scored."
    plan_add "turn off Cockpit admin console (port 9090) - only if it isn't scored" "svc_off cockpit.socket; svc_off cockpit"; fi

  sub "SUID programs and capabilities not from a package"
  find / -xdev -perm -4000 -type f 2>/dev/null | unowned_filter > "$D/.suid"
  if [ -s "$D/.suid" ]; then while read -r f; do bad "SUID: $f"; plan_add "remove SUID bit from $f" "chmod u-s $(q "$f")"; done < "$D/.suid"; else ok "no unexpected SUID programs"; fi
  if have getcap; then getcap -r /usr /bin /sbin /opt /home /root /tmp 2>/dev/null | grep -E 'cap_(setuid|setgid|sys_admin|dac_override|dac_read_search|sys_ptrace)' | while read -r f x; do
    owned "$f" && continue; bad "dangerous capability on $f: $x"; done
    for f in $(getcap -r /usr /bin /sbin /opt /home /root /tmp 2>/dev/null | grep -E 'cap_(setuid|setgid|sys_admin|dac_override|dac_read_search|sys_ptrace)' | awk '{print $1}'); do
      owned "$f" || plan_add "remove capabilities from $f" "setcap -r $(q "$f")"; done; fi

  plan_apply
  tip "Write down what you quarantined + the time: your team needs it for an incident report."
  note "evict run"
}

# ======================================================================
#  SSH HARDENING (OpenSSH drop-in or main config; dropbear options)
# ======================================================================
SSH_FULL='PermitRootLogin no
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
ClientAliveCountMax 2'
SSH_MIN='PermitRootLogin no
PermitEmptyPasswords no
MaxAuthTries 3
X11Forwarding no
AllowTcpForwarding no'
ssh_eff() { "$SSHD" -T 2>/dev/null | grep -iE '^(permitrootlogin|passwordauthentication|authorizedkeysfile|maxauthtries|permitemptypasswords|allowtcpforwarding) ' | tr '\n' ' '; }
cmd_ssh() {
  hdr "SSH HARDENING"
  tip "Password login stays ON (SSH may be scored). Root login, tunnels and stray key files get turned off."
  plan_reset
  if [ "$DROPBEAR" = 1 ]; then
    say "this box runs dropbear, not OpenSSH"
    plan_add "dropbear: no root login, no port forwarding (-w -g -j -k)" "ssh_dropbear"
  elif [ -z "$SSHD" ]; then warn "no SSH server installed - nothing to harden"; return 0
  else
    say "current: $(ssh_eff)"
    if grep -qsE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d' /etc/ssh/sshd_config /usr/etc/ssh/sshd_config; then
      plan_add "write /etc/ssh/sshd_config.d/00-ccdc.conf: no root login, 3 tries, no forwarding/tunnels, standard key file, keep passwords" "ssh_apply dropin"
    elif [ -f /etc/ssh/sshd_config ]; then
      plan_add "add a hardening block to the top of /etc/ssh/sshd_config (this OpenSSH has no .d folder): no root login, 3 tries, no tunnels, keep passwords" "ssh_apply main"
    else warn "no /etc/ssh/sshd_config and no sshd_config.d support - harden SSH by hand"; fi
  fi
  plan_apply
}
ssh_write() {   # ssh_write dropin|main "settings"
  local f=/etc/ssh/sshd_config.d/00-ccdc.conf
  if [ "$1" = dropin ]; then mkdir -p /etc/ssh/sshd_config.d; printf '# CCDC hardening - first match wins, so this file must sort first\n%s\n' "$2" > "$f"; chmod 600 "$f"; have restorecon && restorecon "$f" 2>/dev/null
  else
    sed -i '/^# >>> ccdc hardening/,/^# <<< ccdc hardening/d' /etc/ssh/sshd_config
    { echo "# >>> ccdc hardening (first match wins, so it sits at the top)"; echo "$2"; echo "# <<< ccdc hardening"; cat /etc/ssh/sshd_config; } > /etc/ssh/sshd_config.ccdc && cat /etc/ssh/sshd_config.ccdc > /etc/ssh/sshd_config && rm -f /etc/ssh/sshd_config.ccdc
  fi
}
ssh_undo() { rm -f /etc/ssh/sshd_config.d/00-ccdc.conf; sed -i '/^# >>> ccdc hardening/,/^# <<< ccdc hardening/d' /etc/ssh/sshd_config; }
ssh_apply() {
  local mode=$1
  bk /etc/ssh/sshd_config; bk /etc/ssh/sshd_config.d/00-ccdc.conf
  ssh_write "$mode" "$SSH_FULL"
  if ! "$SSHD" -t 2>"$D/.sshd.err"; then
    warn "this OpenSSH rejected an option ($(head -1 "$D/.sshd.err")) - trying the minimal set"
    ssh_write "$mode" "$SSH_MIN"
    "$SSHD" -t 2>"$D/.sshd.err" || { bad "sshd -t failed: $(head -1 "$D/.sshd.err") - removing the change"; ssh_undo; return 1; }
  fi
  if [ "$INIT" = systemd ] && systemctl is-active --quiet ssh.socket 2>/dev/null && ! systemctl is-active --quiet "$SSH_SVC" 2>/dev/null; then
    ok "ssh is socket-activated: new logins pick up the change automatically"
  elif svc_reload "$SSH_SVC"; then ok "sshd reloaded (your current SSH session stays open)"
  else warn "couldn't reload $SSH_SVC - $(svc_hint "$SSH_SVC")"; fi
  local eff; eff=$("$SSHD" -T 2>/dev/null)
  echo "$eff" | grep -qi '^permitrootlogin no' && ok "effective: PermitRootLogin no" || {
    bad "PermitRootLogin is still '$(echo "$eff" | awk 'tolower($1)=="permitrootlogin"{print $2}')' - another file wins:"
    grep -lisE '^[[:space:]]*PermitRootLogin[[:space:]]+(yes|without-password|prohibit-password)' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | indent; }
  echo "$eff" | grep -iE '^(permitrootlogin|passwordauthentication|authorizedkeysfile|maxauthtries) ' | indent
  note "ssh hardened ($mode)"
  tip "Test from a NEW terminal before closing this one:  ssh ccdcuser1@${MYIP:-this-box}"
}
ssh_dropbear() {
  local f; for f in /etc/conf.d/dropbear /etc/default/dropbear; do [ -f "$f" ] && break; done
  [ -f "$f" ] || { bad "no dropbear options file found"; return 1; }
  bk "$f"
  local var=DROPBEAR_OPTS; grep -q 'DROPBEAR_EXTRA_ARGS' "$f" && var=DROPBEAR_EXTRA_ARGS
  if grep -qE "^[[:space:]]*$var=.*-w.*-g" "$f"; then ok "dropbear already has -w -g"; return 0
  elif grep -qE "^[[:space:]]*$var=" "$f"; then sed -i -E "s/^[[:space:]]*$var=\"?([^\"]*)\"?/$var=\"\1 -w -g -j -k\"/" "$f"; else echo "$var=\"-w -g -j -k\"" >> "$f"; fi
  svc_restart dropbear && ok "dropbear restarted with -w -g -j -k" || warn "restart dropbear by hand: $(svc_hint dropbear)"
  note "dropbear hardened"
}

# ======================================================================
#  DISCOVER (read-only): web apps, their files and databases, plus every service role on the box.
#  Writes facts to /root/cct/web/ and /root/cct/roles for every other step.
# ======================================================================
NOT_HTTP=" 21 22 23 25 53 88 110 111 135 139 143 389 445 465 514 587 631 636 993 995 1433 2049 3306 3389 5432 5900 5901 6379 9090 11211 27017 "
DB_PORTS=" 3306 5432 1433 27017 6379 1521 9042 5984 "
cmd_discover() { cmd_web; roles_detect; roles_show; }
cmd_web() {
  hdr "DISCOVER: WEB APPS + DATABASES"
  tip "Read-only. Figures out what web apps run here, where their files live, and where their database is."
  local x; for x in urls pids units dirs configs dbtargets sqlite localdb dburls containers; do : > "$W/$x"; done
  local tmpb="$D/.body" tmph="$D/.hdr" l addr port pid name scheme code tm title srv
  net_listen tcp > "$D/.listen"

  sub "Listening ports"
  while IFS='|' read -r addr port pid name; do
    if is_loop "$addr"; then printf '      %-6s %-12s %s\n' "$port" "local-only" "${name:--}"; else printf '      %-6s %-12s %s\n' "$port" "open" "${name:--}"; fi
  done < "$D/.listen" | sort -n -u
  net_listen udp | awk -F'|' '$1 !~ /^127\.0\.0\.5[34]$/ {printf "      udp %-6s %s\n", $2, $4}' | sort -u | head -10

  sub "Which ports answer like a website"
  awk -F'|' '{print $2}' "$D/.listen" | sort -nu | while read -r port; do
    case "$NOT_HTTP" in *" $port "*) continue;; esac
    addr=$(awk -F'|' -v p="$port" '$2==p && $1 !~ /^(127\.|::1$)/ {print $1; exit}' "$D/.listen"); [ -z "$addr" ] && addr=$(awk -F'|' -v p="$port" '$2==p{print $1; exit}' "$D/.listen")
    local pids; pids=$(awk -F'|' -v p="$port" '$2==p && $3!="" {print $3}' "$D/.listen" | sort -u | tr '\n' ' ')
    local host=127.0.0.1; case "$addr" in 127.*|0.0.0.0|::|"*"|::ffff:0.0.0.0) ;; ::1) host="[::1]";; *:*) host="[$addr]";; *) host=$addr;; esac
    for scheme in https http; do
      read -r code tm <<<"$(http_probe "$scheme://$host:$port/" "$tmpb" "$tmph")"
      [ -n "$code" ] && [ "$code" != 000 ] || continue
      title=$(tr -d '\r\n' < "$tmpb" 2>/dev/null | grep -oiE '<title[^>]*>[^<]*' | head -1 | sed -E 's/<[tT][iI][tT][lL][eE][^>]*>//' | cut -c1-60)
      srv=$(grep -i '^server:' "$tmph" 2>/dev/null | head -1 | cut -d' ' -f2- | tr -d '\r')
      printf '      %s%-30s%s %s  %-22s %s\n' "$G" "$scheme://$host:$port/" "$N" "$code" "${srv:-?}" "${title:-(no title)}"
      local sc=0; is_loop "$addr" || sc=$((sc+3))
      case "$code" in 2*|3*) sc=$((sc+2));; 401|403) sc=$((sc+1));; *) sc=$((sc-5));; esac
      [ -n "$title" ] && sc=$((sc+1)); case "$port" in 80|443) sc=$((sc+1));; esac
      echo "$sc|$scheme://$host:$port/|$code|${srv}|${title}|${addr}" >> "$W/urls.tmp"
      case "$code" in 2*|3*|401|403) for l in $pids; do echo "$l" >> "$W/pids"; done;; esac
      break
    done
  done
  [ -f "$W/urls.tmp" ] && { sort -t'|' -k1 -nr "$W/urls.tmp" | awk -F'|' '$1>=0' | cut -d'|' -f2- > "$W/urls"; rm -f "$W/urls.tmp"; }
  [ -s "$W/urls" ] || warn "nothing answered over HTTP(S) locally (no web app, or it's stopped: check failed services and containers)"

  local cr n i p; for cr in podman docker; do have $cr || continue
    timeout 10 $cr ps --format '{{.Names}}|{{.Image}}|{{.Ports}}' 2>/dev/null | while IFS='|' read -r n i p; do echo "$cr|$n|$i|$p" >> "$W/containers"; done
  done
  if [ -s "$W/containers" ]; then sub "Containers"; sed 's/|/  /g' "$W/containers" | indent
    while IFS='|' read -r cr n i p; do
      $cr inspect -f '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$n" 2>/dev/null | grep '^/' >> "$W/dirs"
      $cr inspect -f '{{range .Config.Env}}{{.}}{{"\n"}}{{end}}' "$n" 2>/dev/null | grep -iE 'DB|DATABASE|SQL|PG|MYSQL|REDIS|MONGO|DSN' | sed "s|^|$n env: |" >> "$W/dburls"
    done < "$W/containers"; fi

  sub "Who serves it (process, service, files)"
  sort -u "$W/pids" -o "$W/pids"
  local par exe cwd unit usr
  for p in $(cat "$W/pids"); do
    [ -d "/proc/$p" ] || continue
    par=$(awk '/^PPid/{print $2}' "/proc/$p/status" 2>/dev/null)
    [ -n "$par" ] && [ "$par" -gt 1 ] && [ "$(readlink /proc/$par/exe 2>/dev/null)" = "$(readlink /proc/$p/exe 2>/dev/null)" ] && p=$par
    exe=$(readlink -f "/proc/$p/exe" 2>/dev/null); cwd=$(readlink -f "/proc/$p/cwd" 2>/dev/null)
    usr=$(stat -c %U "/proc/$p" 2>/dev/null); unit=$(svc_of_pid "$p")
    x=$(owner_pkg "$exe"); echo "      ${BO}PID $p${N}  $exe  ${DIM}(user $usr, package: ${x:-none})${N}"
    echo "        cmd : $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-110)"
    echo "        cwd : $cwd"
    if [ -n "$unit" ]; then echo "        service: $unit"; echo "$unit" >> "$W/units"
      if [ "$INIT" = systemd ]; then
        x=$(systemctl show -p WorkingDirectory --value "$unit" 2>/dev/null); [ -n "$x" ] && [ "$x" != "/" ] && echo "$x" >> "$W/dirs"
        x=$(systemctl show -p EnvironmentFiles --value "$unit" 2>/dev/null | awk '{print $1}'); [ -n "$x" ] && { echo "        env file: $x"; echo "$x" >> "$W/configs"; }
      fi
      [ -f "/etc/conf.d/$unit" ] && echo "/etc/conf.d/$unit" >> "$W/configs"
      [ -f "/etc/default/$unit" ] && echo "/etc/default/$unit" >> "$W/configs"
    fi
    case "$cwd" in /|/root|"") ;; *) echo "$cwd" >> "$W/dirs";; esac
    case "$exe" in /usr/*|/bin/*|/sbin/*) ;; *) dirname "$exe" >> "$W/dirs";; esac
    tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -E '^[A-Z0-9_]*(DB_|DATABASE|_DSN|SQLITE|POSTGRES|PGHOST|PGDATABASE|MYSQL|MARIADB|REDIS_URL|MONGO)[A-Z0-9_]*=' >> "$W/dburls"
    ls -l "/proc/$p/fd" 2>/dev/null | grep -oE '/[^ ]+\.(db|sqlite3?|db3)$' >> "$W/sqlite"
  done

  # web servers: document roots, proxies, service names
  if have nginx && pgrep -x nginx >/dev/null; then
    nginx -T 2>/dev/null > "$D/.nginx"
    grep -E '^[[:space:]]*root[[:space:]]' "$D/.nginx" | awk '{print $2}' | tr -d ';"' >> "$W/dirs"
    grep -E 'proxy_pass|fastcgi_pass|uwsgi_pass' "$D/.nginx" | sed -E 's/^[[:space:]]*/        nginx: /' | sort -u
    echo nginx >> "$W/units"
  fi
  local ap=""; for x in httpd apache2; do pgrep -x "$x" >/dev/null && ap=$x; done
  if [ -n "$ap" ]; then
    local cdir=/etc/httpd; [ -d /etc/apache2 ] && cdir=/etc/apache2
    grep -rhiE '^[[:space:]]*DocumentRoot' "$cdir" 2>/dev/null | awk '{print $2}' | tr -d '"' >> "$W/dirs"
    grep -rhiE 'ProxyPass[[:space:]]' "$cdir" 2>/dev/null | sed -E 's/^[[:space:]]*/        apache: /' | sort -u
    echo "$ap" >> "$W/units"
  fi
  if pgrep -x lighttpd >/dev/null; then grep -rhE 'server\.document-root' /etc/lighttpd 2>/dev/null | sed -E 's/.*=[[:space:]]*"?([^"]+)"?.*/\1/' >> "$W/dirs"; echo lighttpd >> "$W/units"; fi
  [ -f /etc/caddy/Caddyfile ] && { grep -E 'root|reverse_proxy' /etc/caddy/Caddyfile | sed -E 's/^[[:space:]]*/        caddy: /'; echo caddy >> "$W/units"; }
  for p in $(pgrep -f 'php-fpm: master' 2>/dev/null; pgrep -x 'php-fpm[0-9.]*' 2>/dev/null); do x=$(svc_of_pid "$p"); [ -n "$x" ] && echo "$x" >> "$W/units"; done

  sort -u "$W/dirs" | while read -r l; do [ -d "$l" ] || continue; case "$l" in /|/usr|/usr/*bin|/usr/local|/usr/local/*bin|/usr/lib*|/usr/libexec|/bin|/sbin|/etc|/root|/home|/var|/var/lib|/tmp|/proc|/opt|/srv|/usr/share|/usr/share/nginx|/run|/dev) continue;; esac; echo "$l"; done > "$W/dirs.tmp"; mv "$W/dirs.tmp" "$W/dirs"
  sort -u "$W/units" | grep . > "$W/units.tmp"; mv "$W/units.tmp" "$W/units"

  sub "App files"
  if [ -s "$W/dirs" ]; then while read -r l; do echo "      $l  ${DIM}($(timeout 20 du -sh "$l" 2>/dev/null | cut -f1))${N}"; done < "$W/dirs"
  else warn "couldn't tell where the app's files are"; fi
  [ -s "$W/dirs" ] && find $(cat "$W/dirs") -maxdepth 3 -type f -size -2048k \( -name '.env*' -o -name '*.env' -o -name 'config.*' -o -name 'settings*.py' -o -name 'appsettings*.json' \
       -o -name 'application*.properties' -o -name 'application*.y*ml' -o -name 'database.y*ml' -o -name 'wp-config.php' -o -name '*.ini' -o -name '*.toml' -o -name 'app.ini' \
       -o -name 'docker-compose*.y*ml' -o -name 'compose*.y*ml' -o -name 'local_settings.py' -o -name 'parameters.yml' -o -name 'configuration.php' -o -name 'config.inc.php' \) 2>/dev/null | grep -v node_modules >> "$W/configs"
  for x in /etc/gitea/app.ini /etc/roundcube/config.inc.php /etc/wordpress/config-*.php; do [ -f "$x" ] && echo "$x" >> "$W/configs"; done
  sort -u "$W/configs" -o "$W/configs"
  [ -s "$W/configs" ] && { say "config files:"; indent < "$W/configs"; }

  sub "Database (where the app keeps its data)"
  local cf
  while read -r cf; do [ -f "$cf" ] || continue
    grep -hoE '(mysql|mariadb|postgres(ql)?|pgsql|sqlserver|mssql|mongodb(\+srv)?|redis)://[^ "'"'"'<>]+' "$cf" 2>/dev/null | sed "s|^|$cf: |" >> "$W/dburls"
    grep -hE '^[[:space:]]*[A-Za-z_]*(DB_HOST|DB_PORT|DB_NAME|DB_USER|DATABASE_URL|DB_TYPE|DB_DRIVER|DB_CONNECTION|DB_DATABASE|DB_PATH|SQLITE)[A-Za-z_]*[[:space:]]*[=:]' "$cf" 2>/dev/null | sed "s|^|$cf: |" >> "$W/dburls"
    grep -hoE '(Server|Data Source|Host)=[^;"]+;[^"]*' "$cf" 2>/dev/null | sed "s|^|$cf: |" >> "$W/dburls"
    grep -hoE "define\([[:space:]]*'DB_(HOST|NAME|USER)'[^)]*\)" "$cf" 2>/dev/null | sed "s|^|$cf: |" >> "$W/dburls"
    awk '/^\[database\]/{f=1;next} /^\[/{f=0} f && /^[[:space:]]*(DB_TYPE|HOST|NAME|USER|PATH)[[:space:]]*=/' "$cf" 2>/dev/null | sed "s|^|$cf [database]: |" >> "$W/dburls"
  done < "$W/configs"
  sort -u "$W/dburls" -o "$W/dburls"
  timeout 60 find $(cat "$W/dirs") /var/lib /opt /srv /data -maxdepth 5 -type f -size +0 \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db3' \) 2>/dev/null \
    | grep -vE '/var/lib/(rpm|dnf|yum|apt|dpkg|apk|sss|PackageKit|systemd|selinux|alternatives|flatpak|fwupd|NetworkManager|cockpit|polkit|colord|libvirt|docker|containers|snapd|ucf|update-notifier|command-not-found|plocate|mlocate|logrotate|man-db|private)|/usr/share|\.cache/|/proc/' >> "$W/sqlite"
  sort -u "$W/sqlite" -o "$W/sqlite"
  local apids; apids=" $(tr '\n' ' ' < "$W/pids") "
  net_estab | while IFS='|' read -r la lp ra rp pid name; do
    case "$apids" in *" $pid "*) ;; *) continue;; esac
    case "$DB_PORTS" in *" $rp "*) echo "$ra:$rp" >> "$W/dbtargets";; esac; done
  grep -oE '@[A-Za-z0-9._-]+:[0-9]{2,5}' "$W/dburls" 2>/dev/null | tr -d @ >> "$W/dbtargets"
  grep -iE 'DB_HOST|[[:space:]]HOST[[:space:]]*=' "$W/dburls" 2>/dev/null | sed -E 's/.*(DB_HOST|HOST)[^=:]*[=:][[:space:]]*["'"'"']?([A-Za-z0-9._-]+).*/\2/' | while read -r x; do
    local dp; dp=$(grep -iE 'DB_PORT' "$W/dburls" | head -1 | grep -oE '[0-9]{2,5}' | tail -1); echo "$x" | grep -q ':' && echo "$x" >> "$W/dbtargets" || echo "$x:${dp:-3306}" >> "$W/dbtargets"; done
  sed -i -E 's/^\[([^]]*)\]/\1/; /^(localhost|127\.0\.0\.1|::1|ipv4|0\.0\.0\.0):/d; /^::ffff:127\./d' "$W/dbtargets"; sort -u "$W/dbtargets" -o "$W/dbtargets"
  for l in mysqld mariadbd postgres mongod redis-server sqlservr; do pgrep -x "$l" >/dev/null && echo "$l" >> "$W/localdb"; done
  sort -u "$W/localdb" -o "$W/localdb"

  [ -s "$W/localdb" ] && ok "database running ON this box: ${BO}$(tr '\n' ' ' < "$W/localdb")${N}"
  [ -s "$W/sqlite" ]  && { ok "SQLite database file(s) (data lives in a file):"; indent < "$W/sqlite"; }
  [ -s "$W/dbtargets" ] && { ok "database on ANOTHER box (the firewall will allow exactly these):"; sed "s/^/      ${BO}/; s/$/${N}/" "$W/dbtargets"; }
  [ -s "$W/dburls" ] && { say "database settings found (passwords hidden):"; sed -E 's/(:\/\/[^:@\/]+:)[^@]*@/\1****@/; s/((PASS|PASSWORD|PWD)[A-Za-z_]*[[:space:]]*[=:][[:space:]]*).*/\1****/; s/([Pp]ass(word)?|[Pp]wd)=[^;]*/\1=****/' "$W/dburls" | head -15 | indent; }
  [ -s "$W/localdb" ] || [ -s "$W/sqlite" ] || [ -s "$W/dbtargets" ] || warn "no database found for the web app. The firewall then also allows outbound 3306/5432/1433 to the LAN."
  chmod 600 "$W"/* 2>/dev/null

  local first; first=$(head -1 "$W/urls" 2>/dev/null)
  if [ -n "$first" ]; then
    local u c s ti a; IFS='|' read -r u c s ti a <<<"$first"
    sub "Summary"
    say "main web app: ${BO}${ti:-untitled app}${N} at ${BO}$u${N} (${s:-unknown server})"
    say "services to keep alive: ${BO}$(tr '\n' ' ' < "$W/units")${N}"
    [ -f "$W/title" ] || echo "$ti" > "$W/title"
  fi
  note "discover: $(wc -l < "$W/urls") url(s), $(wc -l < "$W/dbtargets") remote db, $(wc -l < "$W/sqlite") sqlite, $(tr '\n' ' ' < "$W/localdb")"
}

# ---------------------- service roles ----------------------
roles_detect() {   # -> $D/roles : role|detail
  local ports procs r=""; ports=" $(net_listen tcp | awk -F'|' '{print $2}' | sort -nu | tr '\n' ' ') $(net_listen udp | awk -F'|' '{print "u"$2}' | sort -u | tr '\n' ' ') "
  procs=" $(cat /proc/[0-9]*/comm 2>/dev/null | sort -u | tr '\n' ' ') "
  has_p() { case "$ports" in *" $1 "*) return 0;; esac; return 1; }
  has_c() { local c; for c in "$@"; do case "$procs" in *" $c "*) return 0;; esac; done; return 1; }
  {
    if [ -s "$W/urls" ]; then echo "web|$(head -1 "$W/urls" | cut -d'|' -f1) ($(head -1 "$W/urls" | cut -d'|' -f4))"
    elif [ ! -f "$W/pids" ] && { has_p 80 || has_p 443 || has_p 8080 || has_p 8443 || has_c nginx httpd apache2 lighttpd caddy php-fpm; }; then echo "web|probably (run 'discover' to confirm)"; fi
    { has_c mysqld mariadbd postgres mongod redis-server sqlservr || has_p 3306 || has_p 5432 || has_p 27017 || has_p 6379; } && echo "db|$(for x in mysqld mariadbd postgres mongod redis-server; do has_c $x && printf '%s ' $x; done)"
    { has_c master postfix dovecot exim exim4 sendmail || has_p 25 || has_p 143 || has_p 110 || has_p 993 || has_p 587; } && echo "mail|$(for x in master dovecot exim exim4 sendmail; do has_c $x && printf '%s ' ${x/master/postfix}; done)"
    { has_p 2049 || has_c nfsd rpc.mountd || [ -s /etc/exports ]; } && echo "nfs|$(grep -cvE '^[[:space:]]*(#|$)' /etc/exports 2>/dev/null) export line(s)"
    { has_p 21 || has_c vsftpd proftpd pure-ftpd; } && echo "ftp|$(for x in vsftpd proftpd pure-ftpd; do has_c $x && printf '%s ' $x; done)"
    { has_p 445 || has_c smbd; } && echo "smb|samba"
    { has_c named dnsmasq unbound pdns_server || { has_p 53 && ! has_c systemd-resolve systemd-resolved; }; } && echo "dns|$(for x in named dnsmasq unbound pdns_server; do has_c $x && printf '%s ' $x; done)"
    { has_p 389 || has_p 636 || has_c slapd; } && echo "ldap|slapd"
    { has_p 3389 || has_c xrdp Xvnc x11vnc vncserver || has_p 5900 || has_p 5901; } && echo "remote-desktop|$(for x in xrdp Xvnc x11vnc; do has_c $x && printf '%s ' $x; done)"
    { has_p 23 || has_c telnetd in.telnetd; } && echo "telnet|telnet server"
  } > "$D/roles"
}
roles_show() {
  sub "Service roles on this box"
  [ -s "$D/roles" ] || roles_detect
  if [ -s "$D/roles" ]; then while IFS='|' read -r r x; do say "${BO}$(printf '%-14s' "$r")${N} $x"; done < "$D/roles"
  else say "no server roles found besides SSH"; fi
  tip "'harden' audits every role listed here."
}
has_role() { grep -q "^$1|" "$D/roles" 2>/dev/null; }

# ======================================================================
#  HARDEN: audit every service role found -> one plan per role
#  Rule of thumb: never change anything a scorer might rely on without saying so in the plan line.
# ======================================================================
cmd_harden() {
  hdr "HARDEN SERVICES"
  [ -s "$W/urls" ] || { say "running discovery first..."; cmd_web >/dev/null 2>&1; }
  roles_detect; roles_show
  has_role web && cmd_protect
  has_role mail && audit_mail
  has_role db   && audit_db
  { has_role nfs || has_role ftp || has_role smb; } && audit_files
  has_role dns  && audit_dns
  { has_role remote-desktop || has_role telnet || has_role ldap; } && audit_misc
  note "harden run"
}

# ---------------------- mail (postfix, dovecot) ----------------------
audit_mail() {
  hdr "MAIL"
  plan_reset
  local x
  if have postconf; then
    sub "Postfix"
    x=$(postconf -h mynetworks 2>/dev/null)
    case " $x " in *" 0.0.0.0/0 "*|*" 0/0 "*|*"::/0"*) bad "mynetworks = $x  -> OPEN RELAY (anyone can send mail through this box)"
      plan_add "postfix: mynetworks = 127.0.0.0/8 [::1]/128 plus the LAN ($LAN)" "postconf -e 'mynetworks = 127.0.0.0/8 [::1]/128 $LAN' && postfix reload";; *) ok "mynetworks = $x";; esac
    x=$(postconf -h smtpd_relay_restrictions 2>/dev/null)
    if [ -n "$x" ] && ! echo "$x" | grep -q reject_unauth_destination; then bad "smtpd_relay_restrictions has no reject_unauth_destination: $x"
      plan_add "postfix: relay only for the LAN and logged-in users (reject_unauth_destination)" "postconf -e 'smtpd_relay_restrictions = permit_mynetworks permit_sasl_authenticated reject_unauth_destination' && postfix reload"; fi
    for x in always_bcc sender_bcc_maps recipient_bcc_maps; do local v; v=$(postconf -h "$x" 2>/dev/null)
      [ -n "$v" ] && { bad "$x = $v  -> every message is secretly copied"; plan_add "postfix: remove $x (mail theft)" "postconf -X $x && postfix reload"; }; done
    for x in content_filter smtpd_milters non_smtpd_milters; do local v; v=$(postconf -h "$x" 2>/dev/null); [ -n "$v" ] && warn "$x = $v  (fine if it's a known spam/virus filter)"; done
    x=$(grep -nE 'pipe' /etc/postfix/master.cf 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE 'argv=/usr/(lib|libexec)/(dovecot|postfix|cyrus|mailman)|flags=[A-Za-z]* user=(dovecot|vmail|cyrus|list)')
    if [ -n "$x" ]; then warn "master.cf pipes mail to a program:"; echo "$x" | indent
      while IFS= read -r l; do l=${l#*:}; plan_add "postfix: comment out this master.cf transport: ${DIM}$l${N}" "bk /etc/postfix/master.cf; del_line /etc/postfix/master.cf $(q "$l"); postfix reload" risky; done <<<"$x"; fi
    [ "$(postconf -h disable_vrfy_command 2>/dev/null)" = yes ] || plan_add "postfix: turn off VRFY (stops username guessing)" "postconf -e 'disable_vrfy_command = yes' && postfix reload"
    postconf -h smtpd_banner 2>/dev/null | grep -qiE 'postfix|ubuntu|debian|\$mail_version' && plan_add "postfix: hide the software name in the SMTP banner" "postconf -e 'smtpd_banner = \$myhostname ESMTP' && postfix reload"
  fi
  if have doveconf; then
    sub "Dovecot"
    x=$(doveconf -n 2>/dev/null)
    echo "$x" | grep -qE '^auth_(debug_passwords|verbose_passwords) *= *(yes|plain|sha1)' && { bad "Dovecot logs passwords (auth_debug_passwords / auth_verbose_passwords)"
      plan_add "dovecot: stop logging passwords" "dovecot_nopw"; }
    echo "$x" | grep -nE 'executable *=|mail_plugins.*(script|exec)' | indent | grep . && warn "^ dovecot runs extra programs - check them"
    echo "$x" | grep -qE '^(disable_plaintext_auth = yes|ssl = required)' && warn "plaintext logins are disabled - a scorer using plain POP3/IMAP would fail"
    ok "Dovecot reviewed (plain logins left as they are for the scorer)"
  fi
  for x in /var/www/roundcube /var/www/html/roundcube /usr/share/roundcube /opt/roundcube /var/lib/roundcube /usr/share/webapps/roundcube; do
    [ -d "$x/installer" ] && { bad "Roundcube installer is still there: $x/installer"; plan_add "quarantine the Roundcube installer" "quar $(q "$x/installer")"; }; done
  plan_apply
}

dovecot_nopw() {
  local f=/etc/dovecot/conf.d/99-ccdc.conf
  if [ -d /etc/dovecot/conf.d ] && grep -qE '^[[:space:]]*!include[[:space:]]+conf\.d/' /etc/dovecot/dovecot.conf 2>/dev/null; then printf 'auth_debug_passwords = no\nauth_verbose_passwords = no\n' > "$f"
  else bk /etc/dovecot/dovecot.conf; sed -i -E '/^[[:space:]]*auth_(debug|verbose)_passwords/d' /etc/dovecot/dovecot.conf; printf 'auth_debug_passwords = no\nauth_verbose_passwords = no\n' >> /etc/dovecot/dovecot.conf; fi
  doveconf -n >/dev/null 2>&1 || { bad "doveconf reports an error - check /etc/dovecot"; return 1; }
  doveadm reload 2>/dev/null || svc_reload dovecot || warn "reload dovecot by hand: $(svc_hint dovecot)"; true
}

# ---------------------- databases ----------------------
audit_db() {
  hdr "DATABASES"
  plan_reset
  local x
  if pgrep -x mysqld >/dev/null || pgrep -x mariadbd >/dev/null; then
    sub "MySQL / MariaDB"
    local my=mysql; have mariadb && my=mariadb; local MYX=()
    [ -f /etc/mysql/debian.cnf ] && MYX=(--defaults-file=/etc/mysql/debian.cnf)
    if $my "${MYX[@]}" -N -e 'select 1' >/dev/null 2>&1; then
      ok "root can query the database from this box (socket login)"
      x=$($my "${MYX[@]}" -N -e "select concat(user,'@',host) from mysql.user where user=''" 2>/dev/null); [ -n "$x" ] && { bad "anonymous MySQL accounts: $x"
        for u in $x; do plan_add "mysql: drop anonymous account $u" "$my ${MYX[*]} -e \"DROP USER '${u%@*}'@'${u#*@}'\""; done; }
      x=$($my "${MYX[@]}" -N -e "select concat(user,'@',host) from mysql.user where (authentication_string='' or authentication_string is null) and plugin not in ('unix_socket','auth_socket') and user<>''" 2>/dev/null)
      [ -n "$x" ] && bad "MySQL accounts with NO password: $x  ${DIM}(set one, then update the app config and tell the scorer)${N}"
      x=$($my "${MYX[@]}" -N -e "select concat(user,'@',host) from mysql.user where host='%' and Super_priv='Y'" 2>/dev/null); [ -n "$x" ] && warn "admin accounts that can log in from anywhere: $x"
      $my "${MYX[@]}" -N -e "select concat(user,'@',host,' ',plugin) from mysql.user" 2>/dev/null | indent "      account: "
    else warn "can't log in as root without a password - use the app's DB login from its config (see 'discover')"; fi
    x=$(net_listen tcp | awk -F'|' '$2==3306 {print $1}' | head -1)
    case "$x" in 127.*|::1|"") ok "MySQL only listens locally";; *) say "MySQL listens on $x:3306 - other boxes can reach it (needed if other web servers use it; the firewall keeps it open)";; esac
  fi
  if pgrep -x postgres >/dev/null; then
    sub "PostgreSQL"
    local hba; hba=$(find /etc/postgresql /var/lib/pgsql /var/lib/postgresql /var/lib/postgres -name pg_hba.conf 2>/dev/null | head -1)
    if [ -n "$hba" ]; then
      x=$(grep -nE '^[[:space:]]*host.*[[:space:]]trust([[:space:]]|$)' "$hba"); [ -n "$x" ] && { bad "pg_hba.conf lets network logins in with NO password (trust):"; echo "$x" | indent; tip "change trust to scram-sha-256 (or md5) on those lines, then reload - check the app has a password first"; }
      x=$(grep -nE '^[[:space:]]*host.*(0\.0\.0\.0/0|::/0|all[[:space:]]+all[[:space:]]+all)' "$hba"); [ -n "$x" ] && warn "pg_hba.conf allows any address:" && echo "$x" | indent
      ok "reviewed $hba"
    fi
  fi
  if pgrep -x redis-server >/dev/null && have redis-cli; then
    sub "Redis"
    x=$(timeout 3 redis-cli CONFIG GET requirepass 2>/dev/null | tail -1)
    local bindr; bindr=$(net_listen tcp | awk -F'|' '$2==6379 {print $1}' | head -1)
    if [ -z "$x" ] && ! is_loop "$bindr"; then bad "Redis has NO password and listens on $bindr - anyone can take over the box through it"; tip "if only this box uses it: set 'bind 127.0.0.1' in redis.conf and restart"
    else ok "Redis: password set or local-only"; fi
  fi
  if pgrep -x mongod >/dev/null; then
    sub "MongoDB"
    grep -qE '^[[:space:]]*authorization:[[:space:]]*enabled' /etc/mongod.conf 2>/dev/null && ok "MongoDB requires logins" || bad "MongoDB authorization isn't enabled (/etc/mongod.conf security.authorization)"
  fi
  plan_apply
}

# ---------------------- file sharing (NFS, FTP, SMB) ----------------------
audit_files() {
  hdr "FILE SHARING"
  plan_reset
  local x f
  if [ -s /etc/exports ]; then
    sub "NFS (/etc/exports)"
    grep -vE '^[[:space:]]*(#|$)' /etc/exports | indent
    grep -qE 'no_root_squash' /etc/exports && { bad "no_root_squash: root on any client is root on these files"
      plan_add "NFS: change no_root_squash to root_squash, then exportfs -ra" "bk /etc/exports; sed -i 's/no_root_squash/root_squash/g' /etc/exports; { have exportfs && exportfs -ra; } || true"; }
    grep -qE '(^|[[:space:]])\*\(|[[:space:]]\*[[:space:]]*$' /etc/exports && warn "exported to every host (*) - fine only if scoring needs it"
    grep -qE '[(,]insecure[,)]' /etc/exports && warn "'insecure' lets unprivileged client ports mount"
  fi
  for f in /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf; do [ -f "$f" ] || continue
    sub "vsftpd ($f)"
    grep -qiE '^[[:space:]]*anonymous_enable[[:space:]]*=[[:space:]]*YES' "$f" && { warn "anonymous FTP is ON"
      plan_add "vsftpd: turn off anonymous login - ONLY if anonymous FTP isn't a scored service" "bk $(q "$f"); sed -i 's/^[[:space:]]*anonymous_enable[[:space:]]*=.*/anonymous_enable=NO/' $(q "$f"); svc_restart vsftpd || warn 'config changed - restart vsftpd by hand: $(svc_hint vsftpd)'"; }
    grep -qiE '^[[:space:]]*anon_(upload|mkdir_write|other_write)_enable[[:space:]]*=[[:space:]]*YES' "$f" && { bad "anonymous users can upload/write"
      plan_add "vsftpd: no anonymous uploads or writes" "bk $(q "$f"); sed -i -E 's/^[[:space:]]*(anon_(upload|mkdir_write|other_write)_enable)[[:space:]]*=.*/\1=NO/' $(q "$f"); svc_restart vsftpd || warn 'config changed - restart vsftpd by hand: $(svc_hint vsftpd)'"; }
    ok "reviewed $f"
  done
  for f in /etc/proftpd/proftpd.conf /etc/proftpd.conf; do [ -f "$f" ] && grep -qiE '^[[:space:]]*<Anonymous' "$f" && warn "proftpd has an <Anonymous> block in $f"; done
  if [ -f /etc/samba/smb.conf ]; then
    sub "Samba"
    x=$( (have testparm && testparm -s 2>/dev/null) || cat /etc/samba/smb.conf)
    echo "$x" | grep -qiE 'guest ok *= *yes|public *= *yes' && warn "some shares allow guests (check they aren't writable)"
    echo "$x" | grep -qiE 'map to guest *= *bad user' && warn "'map to guest = bad user': wrong usernames become guest"
    echo "$x" | grep -iE '^\[|path *=|writ|guest|valid users' | indent
    have pdbedit && { say "samba users:"; pdbedit -L 2>/dev/null | indent; }
  fi
  [ -f /etc/rsyncd.conf ] && ! grep -qiE 'auth users' /etc/rsyncd.conf && warn "rsyncd has modules without 'auth users'"
  plan_apply
}

# ---------------------- DNS ----------------------
audit_dns() {
  hdr "DNS"
  local f
  for f in /etc/named.conf /etc/bind/named.conf.options /etc/bind/named.conf /etc/named/named.conf; do [ -f "$f" ] || continue
    sub "BIND ($f)"
    grep -qE 'allow-transfer[[:space:]]*\{[[:space:]]*any' "$f" && bad "zone transfers allowed to anyone (allow-transfer { any; })"
    grep -q 'allow-transfer' "$f" || warn "no allow-transfer limit in $f (BIND default allows transfers)"
    grep -qE 'recursion[[:space:]]+yes' "$f" && ! grep -q 'allow-recursion' "$f" && warn "recursion on with no allow-recursion limit (open resolver?)"
    have named-checkconf && { named-checkconf 2>&1 | head -3 | indent; named-checkconf >/dev/null 2>&1 && ok "named-checkconf passes"; }
  done
  [ -f /etc/dnsmasq.conf ] && { sub "dnsmasq"; grep -vE '^[[:space:]]*(#|$)' /etc/dnsmasq.conf | indent; }
  tip "DNS is easy to break: change it only with the DNS owner, and run named-checkconf before every reload."
}

# ---------------------- remote desktop, telnet, LDAP ----------------------
audit_misc() {
  hdr "OTHER SERVICES"
  has_role telnet && { bad "a telnet server is running (plaintext logins)"; tip "turn it off unless it's scored: $(svc_hint telnet)"; }
  has_role remote-desktop && { say "remote desktop (VNC/RDP) is running - keep it up if scored"
    for f in /root/.vnc/passwd /home/*/.vnc/passwd; do [ -f "$f" ] && say "VNC password file: $f"; done
    [ -f /etc/xrdp/xrdp.ini ] && grep -iE '^(security_layer|crypt_level)' /etc/xrdp/xrdp.ini | indent; }
  has_role ldap && { say "LDAP server running"; tip "check for anonymous binds:  ldapsearch -x -H ldap://127.0.0.1 -b '' -s base"; }
}

# ======================================================================
#  BACKUP (disguised, backdated, optional encryption): all of /etc, app files, service data, databases
# ======================================================================
bk_decoys() {
  case "$FAMILY" in
    debian) echo "libxkbcommon-data libtext-iconv-perl-doc libsemanage-data libnss-myhostname-doc libgpg-error-l10n libpam-cap-doc libxau-doc libverto-common";;
    rhel)   echo "libsss_certmap-extra python3-pyasn1-doc libnfsidmap-plugins perl-Text-Tabs-doc libverto-libev-doc xorg-x11-fonts-misc-doc libgpg-error-extra libtevent-doc";;
    alpine) echo "libverto-doc libcap-ng-doc musl-locales-doc libedit-extra libmnl-doc libnftnl-doc pcre2-tools-doc libuv-doc";;
    *)      echo "libverto-doc libxau-extra libgpg-error-l10n libnftnl-doc libmnl-extra";;
  esac
}
TAROPT=(); tar --selinux --xattrs --acls -cf /dev/null /etc/hostname >/dev/null 2>&1 && TAROPT=(--selinux --xattrs --acls)
bk_enc() { if [ -n "$BKPASS" ]; then openssl enc -aes-256-cbc -pbkdf2 -salt -pass env:BKPASS; else cat; fi; }
bk_dec() { if [ "$1" = 1 ]; then openssl enc -d -aes-256-cbc -pbkdf2 -pass env:BKPASS; else cat; fi; }
bk_ref() { local f best="" bt=9999999999 t; for f in /etc/os-release /usr/lib/os-release /bin/sh /usr/bin/env /etc/hostname; do
             [ -e "$f" ] || continue; t=$(stat -L -c %Y "$f" 2>/dev/null) || continue; [ "$t" -lt "$bt" ] && { bt=$t; best=$f; }; done; echo "${best:-/etc/hostname}"; }
bk_hide(){ local ref; ref=$(bk_ref); local f; for f in "$@"; do [ -e "$f" ] && { touch -h -r "$ref" "$f" 2>/dev/null || touch -r "$ref" "$f" 2>/dev/null; }; done; }
touch_at(){ touch -d "@$1" "$2" 2>/dev/null || touch -t "$(date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null)" "$2" 2>/dev/null; }
data_dirs() {   # service data worth saving (size-limited later)
  awk '!/^[[:space:]]*(#|$)/{print $1}' /etc/exports 2>/dev/null
  grep -hE '^[[:space:]]*(anon_root|local_root)[[:space:]]*=' /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf 2>/dev/null | cut -d= -f2
  grep -hE '^[[:space:]]*path[[:space:]]*=' /etc/samba/smb.conf 2>/dev/null | cut -d= -f2 | sed 's/^[[:space:]]*//'
  for x in /var/mail /var/spool/mail /var/lib/gitea /var/lib/roundcube /srv/ftp /var/ftp /var/www; do [ -d "$x" ] && echo "$x"; done
}
cmd_backup() {
  hdr "BACKUP (disguised) + DATABASE DUMP"
  tip "Saved as fake package docs with old timestamps. Optional passphrase encrypts them (configs hold DB passwords)."
  tip "Every part has a time limit and a live timer. Ctrl-C stops it and asks: skip / retry / quit."
  [ -s "$W/urls" ] || [ -f "$W/pids" ] || { warn "apps not discovered yet - running discovery first"; cmd_web >/dev/null 2>&1; }
  local a b2; BKPASS=""
  if have openssl; then
    read -r -s -p "  Backup passphrase (Enter = none): " a </dev/tty; echo
    if [ -n "$a" ]; then read -r -s -p "  Confirm: " b2 </dev/tty; echo; [ "$a" = "$b2" ] && export BKPASS="$a" || warn "didn't match - saving UNencrypted"; fi
  else tip "openssl isn't installed, so backups are not encrypted"; fi
  local enc=0; [ -n "$BKPASS" ] && enc=1
  local pkg d1 d2=/usr/share/locale/en_GB/LC_MESSAGES
  for pkg in $(bk_decoys | tr ' ' '\n' | awk 'BEGIN{srand()} {print rand()" "$0}' | sort | cut -d' ' -f2); do [ -e "/usr/share/doc/$pkg" ] || break; done
  mkdir -p /usr/share/doc "$d2"; d1=/usr/share/doc/$pkg
  local t_doc t_d2; t_doc=$(stat -c %Y /usr/share/doc); t_d2=$(stat -c %Y "$d2")
  mkdir -p "$d1"; chmod 755 "$d1"
  local conf=(/etc); local p; for p in /var/spool/cron /var/spool/cron/crontabs /root/.ssh /var/lib/pgsql/data/pg_hba.conf /var/lib/pgsql/data/postgresql.conf; do [ -e "$p" ] && conf+=("$p"); done

  sub "1/4 all of /etc + crontabs"
  tmo 180 "saving /etc" bash -c "$(declare -f bk_enc); TAROPT=(${TAROPT[*]}); tar -czf - \"\${TAROPT[@]}\" $(printf '%q ' "${conf[@]}") 2>/dev/null | bk_enc > $(q "$d1/changelog.gz")" \
    && ok "configs saved ($(du -h "$d1/changelog.gz" | cut -f1))"

  sub "2/4 web app files"
  local dirs=() l sz
  while read -r l; do [ -d "$l" ] || continue; sz=$(timeout 30 du -sm "$l" 2>/dev/null | cut -f1)
    if [ "${sz:-0}" -gt 1500 ]; then warn "skipping $l (${sz} MB is too big for a quick backup)"; else dirs+=("$l"); fi; done < "$W/dirs"
  if [ ${#dirs[@]} -gt 0 ]; then
    say "app folders: ${dirs[*]}"
    tmo 300 "saving app files" bash -c "$(declare -f bk_enc); tar -czf - --exclude='*/node_modules' --exclude='*/.cache' --exclude='*.log' $(printf '%q ' "${dirs[@]}") 2>/dev/null | bk_enc > $(q "$d1/NEWS.gz")" \
      && ok "app files saved ($(du -h "$d1/NEWS.gz" | cut -f1))"
  else say "no web app folders known - skipped"; fi

  sub "3/4 service data (mail, shares, Gitea...)"
  local sd=() seen=" ${dirs[*]} "
  while read -r l; do [ -d "$l" ] || continue; case "$seen" in *" $l "*) continue;; esac; seen+=" $l "
    sz=$(timeout 30 du -sm "$l" 2>/dev/null | cut -f1); [ "${sz:-0}" -gt 1500 ] && { warn "skipping $l (${sz} MB)"; continue; }; sd+=("$l"); done < <(data_dirs | sort -u)
  if [ ${#sd[@]} -gt 0 ]; then say "data folders: ${sd[*]}"
    tmo 300 "saving service data" bash -c "$(declare -f bk_enc); tar -czf - --exclude='*.log' $(printf '%q ' "${sd[@]}") 2>/dev/null | bk_enc > $(q "$d1/TODO.gz")" && ok "service data saved ($(du -h "$d1/TODO.gz" | cut -f1))"
  else say "no service data folders found - skipped"; fi

  sub "4/4 databases"
  local db="$D/.dbdump"; rm -rf "$db"; mkdir -p "$db"; chmod 700 "$db"
  local f i=0
  while read -r f; do [ -f "$f" ] || continue; i=$((i+1))
    if have sqlite3; then tmo 120 "copying $f safely" sqlite3 "$f" ".backup '$db/sqlite$i.db'"; else cp "$f" "$db/sqlite$i.db"; fi
    echo "sqlite$i.db|$f" >> "$db/paths.txt" && ok "SQLite copied: $f"
  done < "$W/sqlite"
  if grep -qE 'mysqld|mariadbd' "$W/localdb" 2>/dev/null || pgrep -x mysqld >/dev/null || pgrep -x mariadbd >/dev/null; then
    local dump=mysqldump; have mariadb-dump && dump=mariadb-dump; local MYX=""; [ -f /etc/mysql/debian.cnf ] && MYX="--defaults-file=/etc/mysql/debian.cnf"
    if ! have $dump; then warn "a local MySQL/MariaDB runs, but mysqldump isn't installed: $(pkg_install_cmd "$(db_client_pkg)")"
    elif tmo 300 "dumping local MySQL/MariaDB" bash -c "$dump $MYX --all-databases --single-transaction --routines --events 2>$db/mysql.err > $db/mysql-all.sql"; then ok "local MySQL dumped ($(du -h "$db/mysql-all.sql" | cut -f1))"
    else warn "local mysqldump failed: $(head -1 "$db/mysql.err" 2>/dev/null). Dump it with the app's DB login instead."; rm -f "$db/mysql-all.sql"; fi; fi
  if grep -q postgres "$W/localdb" 2>/dev/null || pgrep -x postgres >/dev/null; then
    local asp="su postgres -s /bin/sh -c pg_dumpall"; have runuser && asp="runuser -u postgres -- pg_dumpall"
    tmo 300 "dumping local PostgreSQL" bash -c "cd /tmp && $asp > $db/postgres-all.sql 2>$db/pg.err" && ok "local PostgreSQL dumped" || warn "pg_dumpall failed: $(head -1 "$db/pg.err" 2>/dev/null)"; fi
  local url
  grep -oE '(mysql|mariadb|postgres(ql)?)://[^ "'"'"']+' "$W/dburls" 2>/dev/null | sort -u | while read -r url; do
    local proto=${url%%://*} rest=${url#*://} cred hostp dbn usr pw host port
    cred=${rest%@*}; hostp=${rest##*@}; dbn=${hostp#*/}; dbn=${dbn%%\?*}; hostp=${hostp%%/*}
    usr=${cred%%:*}; pw=${cred#*:}; host=${hostp%:*}; port=${hostp##*:}; [ "$port" = "$hostp" ] && port=""
    case "$proto" in
      mysql|mariadb) have mysqldump || have mariadb-dump || { warn "remote MySQL found ($host) but mysqldump isn't installed: $(pkg_install_cmd "$(db_client_pkg)")"; continue; }
        local dump=mysqldump; have mariadb-dump && dump=mariadb-dump
        export MYSQL_PWD="$pw"; tmo 300 "dumping $dbn from $host" bash -c "$dump -h $(q "$host") -P ${port:-3306} -u $(q "$usr") --single-transaction $(q "$dbn") > $(q "$db/remote-$host-$dbn.sql")" && ok "dumped $dbn from $host"; unset MYSQL_PWD;;
      postgres*) have pg_dump || { warn "remote PostgreSQL found ($host) but pg_dump isn't installed"; continue; }
        tmo 300 "dumping $dbn from $host" bash -c "pg_dump $(q "$url") > $(q "$db/remote-$host-$dbn.sql")" && ok "dumped $dbn from $host";;
    esac
  done
  if [ -n "$(ls -A "$db" 2>/dev/null | grep -v '\.err$')" ]; then
    tmo 120 "packing database dump" bash -c "$(declare -f bk_enc); cd $(q "$db") && tar -czf - --exclude='*.err' . | bk_enc > $(q "$d1/README.gz")" && ok "database saved ($(du -h "$d1/README.gz" | cut -f1))"
  else say "no database found to dump"; fi
  rm -rf "$db"

  printf 'Extra documentation for this package.\n' | gzip > "$d1/copyright.gz"
  [ -f "$d1/changelog.gz" ] && cp "$d1/changelog.gz" "$d2/$pkg.mo"
  chmod 644 "$d1"/* "$d2/$pkg.mo" 2>/dev/null
  bk_hide "$d1"/* "$d1" "$d2/$pkg.mo"; touch_at "$t_doc" /usr/share/doc; touch_at "$t_d2" "$d2"
  echo "$(date '+%H:%M')|$enc|$d1|$d2/$pkg.mo" >> "$D/backup.list"; chmod 600 "$D/backup.list"
  unset BKPASS
  ok "saved to ${BO}$d1/${N}  (+ copy of configs: $d2/$pkg.mo)  encrypted: $([ $enc = 1 ] && echo yes || echo no)"
  tip "Write the folder name (${BO}$pkg${N}) on the team sheet. Restore: $ME restore"
  note "backup -> $d1 (enc=$enc)"
}

# ---------------------- restore ----------------------
RESTORE_HELP="    ssh   - /etc/ssh             pam   - /etc/pam.d           web  - web server + php config
    mail  - postfix + dovecot    app   - web app files        data - shares, mail, Gitea data
    db    - databases            etc   - ALL of /etc          list - show what's inside
    /some/path - just that file or folder (e.g. /etc/nginx/nginx.conf)"
cmd_restore() {   # restore [ssh|pam|web|mail|app|data|db|etc|list|/path]
  hdr "RESTORE"
  [ -s "$D/backup.list" ] || { bad "no backups recorded yet"; return 1; }
  local i=0 tm en d1 d2 n=1 line what=${2:-}
  echo "  Backups (1 = first = cleanest):"
  while IFS='|' read -r tm en d1 d2; do i=$((i+1)); echo "   $i) $tm  $d1  encrypted=$([ "$en" = 1 ] && echo yes || echo no)"; done < "$D/backup.list"
  [ "$i" -gt 1 ] && { read -r -p "  Which backup? [1]: " n </dev/tty; n=${n:-1}; }
  line=$(sed -n "${n}p" "$D/backup.list"); [ -n "$line" ] || { bad "no backup #$n"; return 1; }
  IFS='|' read -r tm en d1 d2 <<<"$line"
  [ -z "$what" ] && { echo "  What to restore:"; echo "$RESTORE_HELP"; read -r -p "  Type one: " what </dev/tty; }
  [ "$en" = 1 ] && { read -r -s -p "  Backup passphrase: " BKPASS </dev/tty; echo; export BKPASS; }
  local arch pre="" svc=() l
  case "$what" in
    ssh)  arch=$d1/changelog.gz; pre='etc/ssh'; svc=("$SSH_SVC");;
    pam)  arch=$d1/changelog.gz; pre='etc/pam\.d';;
    web)  arch=$d1/changelog.gz; pre='etc/(nginx|httpd|apache2|lighttpd|caddy|php[^/]*)'; svc=($(cat "$W/units" 2>/dev/null));;
    mail) arch=$d1/changelog.gz; pre='etc/(postfix|dovecot|aliases)'; svc=(postfix dovecot);;
    etc)  arch=$d1/changelog.gz; pre='etc';;
    app)  arch=$d1/NEWS.gz; svc=($(cat "$W/units" 2>/dev/null));;
    data) arch=$d1/TODO.gz;;
    db)   arch=$d1/README.gz;;
    list) arch=$d1/changelog.gz;;
    /*)   l=${what#/}; pre=$(printf '%s' "$l" | sed 's/[.[\*^$()+?{}|]/\\&/g'); arch=$d1/changelog.gz; case "$l" in etc/*|var/spool/*|root/.ssh*) ;; *) arch=$d1/NEWS.gz;; esac;;
    *) bad "unknown choice: $what"; echo "$RESTORE_HELP"; return 1;;
  esac
  [ -s "$arch" ] || { [ "$arch" = "$d1/changelog.gz" ] && [ -s "$d2" ] && arch=$d2 && warn "main copy missing - using the second copy"; }
  [ -s "$arch" ] || { bad "backup file missing: $arch (deleted? or that part was never saved)"; return 1; }
  bk_dec "$en" < "$arch" | tar -tzf - > "$D/.members" 2>/dev/null || { bad "can't open the backup (wrong passphrase?)"; return 1; }
  if [ "$what" = list ]; then for arch in "$d1"/*.gz; do [ "$(basename "$arch")" = copyright.gz ] && continue; echo "  ${BO}$(basename "$arch")${N}"
      bk_dec "$en" < "$arch" | tar -tzf - 2>/dev/null | awk -F/ 'NF>1{print "    "$1"/"$2}' | sort -u | head -40; done; return; fi
  if [ "$what" = db ]; then
    local tmp="$D/.dbrestore"; rm -rf "$tmp"; mkdir -p "$tmp"; bk_dec "$en" < "$arch" | tar -xzf - -C "$tmp"
    ls -la "$tmp" | indent "    "
    if [ -f "$tmp/paths.txt" ]; then while IFS='|' read -r f orig; do
      if ask "Put SQLite file back at $orig? (the app's services are stopped, the current file is kept as a copy)"; then
        local u; for u in $(cat "$W/units" 2>/dev/null); do svc_do stop "$u"; done
        local own; own=$(stat -c %u:%g "$orig" 2>/dev/null)
        cp -a "$orig" "$BAK/$(echo "$orig" | tr / _).$(TS)" 2>/dev/null; cp "$tmp/$f" "$orig"
        [ -n "$own" ] && chown "$own" "$orig"; [ "$MAC" = selinux ] && restorecon "$orig" 2>/dev/null
        for u in $(cat "$W/units" 2>/dev/null); do svc_do start "$u"; done; ok "restored $orig and restarted the app"; note "RESTORED sqlite $orig"
      fi; done < "$tmp/paths.txt"; fi
    [ -f "$tmp/mysql-all.sql" ] && { say "MySQL dump: $tmp/mysql-all.sql"; tip "restore ALL databases:  mysql < $tmp/mysql-all.sql   (only if the data is really damaged)"; }
    [ -f "$tmp/postgres-all.sql" ] && tip "PostgreSQL dump: $tmp/postgres-all.sql  ->  su postgres -s /bin/sh -c 'psql -f $tmp/postgres-all.sql postgres'"
    ls "$tmp"/remote-*.sql 2>/dev/null | while read -r f; do tip "remote dump: $f  ->  mysql -h HOST -u USER -p DBNAME < $f  (coordinate with the DB box owner)"; done
    tip "Dumps stay in $tmp until you delete them."
    return
  fi
  local sel="$D/.sel"; : > "$sel"
  if [ -n "$pre" ]; then   # keep only top-level matches (a directory entry covers everything below it)
    grep -E "^/?($pre)(/|$)" "$D/.members" | awk '{k=1; for (t in T) if (index($0,t)==1) {k=0; break}; if (k) {print; if ($0 ~ /\/$/) T[$0]=1}}' > "$sel"
    [ -s "$sel" ] || { bad "that part isn't in this backup"; return 1; }; fi
  local cur; cur="$BAK/pre-restore-$(echo "$what" | tr / _)-$(TS).tgz"
  if [ -s "$sel" ]; then (cd / && tar -czf "$cur" -T "$sel" 2>/dev/null)
  elif [ "$what" = app ]; then tar -czf "$cur" $(cat "$W/dirs") 2>/dev/null; fi
  [ -s "$cur" ] && ok "current state saved first (undo): $cur"
  local xargs_t=(); [ -s "$sel" ] && xargs_t=(-T "$sel")
  if bk_dec "$en" < "$arch" | tar -xzf - "${TAROPT[@]}" -C / "${xargs_t[@]}"; then ok "restored $([ -s "$sel" ] && sed 's|^/*|/|' "$sel" | head -5 | tr '\n' ' ' || echo "all of $(basename "$arch")") from backup $n ($tm)"; note "RESTORED $what"
  else bad "extract reported errors (some files may not have been restored)"; fi
  if [ "$MAC" = selinux ]; then [ -s "$sel" ] && awk -F/ '{print "/"$1"/"$2}' "$sel" | sort -u | while read -r l; do restorecon -R "$l" 2>/dev/null; done
    [ "$what" = app ] && restorecon -R $(cat "$W/dirs") 2>/dev/null; fi
  local u; for u in "${svc[@]}"; do svc_test_restart "$u"; done
  unset BKPASS; tip "Next: $ME check"
}
svc_test_restart() {   # config test first, then restart
  local u; u=$(svc_bare "$1")
  case "$u" in
    nginx) nginx -t 2>/dev/null || { bad "nginx config test failed - not restarting"; return 1; };;
    httpd|apache2) { have apachectl && apachectl -t 2>/dev/null; } || { have apache2ctl && apache2ctl -t 2>/dev/null; } || { have httpd && httpd -t 2>/dev/null; } || { bad "apache config test failed - not restarting"; return 1; };;
    ssh|sshd) [ -n "$SSHD" ] && { "$SSHD" -t 2>/dev/null || { bad "sshd -t failed - not restarting"; return 1; }; };;
    postfix) have postfix && { postfix check 2>/dev/null || { bad "postfix check failed"; return 1; }; };;
  esac
  svc_active "$u" || svc_exists_any "$u" || return 0
  svc_restart "$u" && ok "restarted $u" || bad "$u failed to restart: $(svc_hint "$u")"
}
svc_exists_any() { case "$INIT" in systemd) systemctl cat "$1" >/dev/null 2>&1;; *) [ -x "/etc/init.d/$1" ];; esac; }

# ======================================================================
#  FIREWALL: our own rules in FRONT of whatever the box already has (firewalld / ufw / plain).
#  nftables: table "inet ccdc_fw"        iptables: chains CCDC_IN / CCDC_OUT jumped to first
#  Both layers must allow a packet, so we never open anything the existing firewall blocks.
#  learn = inbound locked to listening ports, outbound allowed + logged      lock = outbound allowlist only
# ======================================================================
fw_joined() { realm list 2>/dev/null | grep -q domain-name || svc_active sssd || svc_active winbind || pgrep -x sssd >/dev/null; }
fw_out_allows() {   # proto|dest|ports   (dest = any | IP | CIDR ; ports = "53,123" or "49152-65535")
  local mode=$1 h p pr
  echo "udp|any|53,67,123,547"; echo "tcp|any|53"
  if fw_joined; then echo "tcp|$LAN|88,135,389,445,464,636,3268,3269,49152-65535"; echo "udp|$LAN|88,389,464"; fi
  has_role mail && echo "tcp|any|25,465,587"
  while IFS=: read -r h p; do [ -n "$h" ] && [ -n "$p" ] && [[ $h =~ ^[0-9.]+$ ]] && echo "tcp|$h|$p"; done < "$W/dbtargets" 2>/dev/null
  [ -s "$W/dbtargets" ] || echo "tcp|$LAN|1433,3306,5432"       # no database found: allow the common DB ports inside the LAN
  [ -f "$FW/allowed" ] && while IFS='|' read -r pr h p; do [ -n "$h" ] && echo "$pr|$h|$p"; done < "$FW/allowed"
  [ "$mode" = lock ] && [ "$ALLOW_WEB_OUT" = 1 ] && echo "tcp|any|80,443"
  true
}
fw_render_nft() {  # -> $FW/rules.nft
  local mode=$1 tcp udp pr dst pt
  tcp=$(listen_ports tcp); udp=$(listen_ports udp)
  {
    echo "table inet $TABLE"; echo "delete table inet $TABLE"
    echo "table inet $TABLE {"
    if [ -n "$tcp" ]; then echo "  set in_tcp { type inet_service; elements = { $tcp }; }"; else echo "  set in_tcp { type inet_service; }"; fi
    if [ -n "$udp" ]; then echo "  set in_udp { type inet_service; elements = { $udp }; }"; else echo "  set in_udp { type inet_service; }"; fi
    echo "  set sshrate { type ipv4_addr; size 65535; flags dynamic,timeout; timeout 1m; }"
    echo "  chain input {"
    echo "    type filter hook input priority -5; policy drop;"
    echo "    iif \"lo\" accept"
    echo "    ct state established,related accept"
    echo "    ct state invalid drop"
    echo "    meta l4proto { icmp, ipv6-icmp } accept"
    echo "    tcp dport 22 ct state new add @sshrate { ip saddr limit rate over 30/minute burst 30 packets } drop"
    echo "    tcp dport @in_tcp accept"
    echo "    udp dport @in_udp accept"
    echo "    udp sport 67 udp dport 68 accept"
    echo "    udp dport 546 accept"
    echo "    limit rate 6/minute log prefix \"CCDC-IN-DROP \" level info"
    echo "    counter"
    echo "  }"
    echo "  chain output {"
    echo "    type filter hook output priority -5; policy $([ "$mode" = lock ] && echo drop || echo accept);"
    echo "    oif \"lo\" accept"
    echo "    ct state established,related accept"
    echo "    meta l4proto { icmp, ipv6-icmp } accept"
    fw_out_allows "$mode" | sort -u | while IFS='|' read -r pr dst pt; do
      local ps="$pt"; [[ $pt == *,* ]] && ps="{ ${pt//,/, } }"
      if [ "$dst" = any ]; then echo "    $pr dport $ps accept"; else echo "    ip daddr $dst $pr dport $ps accept"; fi
    done
    if [ "$mode" = learn ]; then echo "    ct state new limit rate $LEARN_LOG_RATE log prefix \"CCDC-LEARN \" level info"
    else echo "    limit rate 6/minute log prefix \"CCDC-OUT-DROP \" level info"; echo "    counter"; fi
    echo "  }"
    echo "}"
  } > "$FW/rules.nft"
}
fw_render_ipt() {  # -> $FW/rules.sh  (plain sh, works with iptables-legacy and iptables-nft)
  local mode=$1 tcp udp CT="-m conntrack --ctstate"
  iptables -m conntrack --help 2>/dev/null | grep -q ctstate || CT="-m state --state"
  tcp=$(listen_ports tcp); udp=$(listen_ports udp)
  mp() {  # mp T CHAIN PROTO PORTS extra... -> multiport rules, 15 ports per rule
    local t=$1 c=$2 pr=$3 ps=$4; shift 4; local extra="$*" x list chunk=()
    for x in ${ps//,/ }; do chunk+=("${x/-/:}"); if [ ${#chunk[@]} -eq 15 ]; then list=$(IFS=,; echo "${chunk[*]}"); echo "r $t -A $c -p $pr -m multiport --dports $list $extra"; chunk=(); fi; done
    if [ ${#chunk[@]} -gt 0 ]; then list=$(IFS=,; echo "${chunk[*]}"); echo "r $t -A $c -p $pr -m multiport --dports $list $extra"; fi
  }
  {
    echo "#!/bin/sh"; echo "# generated by ccdc.sh ($mode mode) - reload with: sh $FW/rules.sh"
    echo 'fail=0; r() { "$@" || { echo "rule failed: $*" >&2; fail=1; }; }; o() { "$@" 2>/dev/null || echo "optional rule skipped: $*" >&2; }'
    echo 'V6=0; ip6tables -S >/dev/null 2>&1 && V6=1'
    echo 'for T in iptables ip6tables; do [ $T = ip6tables ] && [ $V6 = 0 ] && continue; $T -N CCDC_IN 2>/dev/null; $T -F CCDC_IN; $T -N CCDC_OUT 2>/dev/null; $T -F CCDC_OUT; done'
    local T ICMP
    for T in iptables ip6tables; do
      ICMP=icmp; [ $T = ip6tables ] && { ICMP=ipv6-icmp; echo 'if [ $V6 = 1 ]; then'; }
      echo "r $T -A CCDC_IN -i lo -j RETURN"
      echo "r $T -A CCDC_IN $CT ESTABLISHED,RELATED -j RETURN"
      echo "r $T -A CCDC_IN $CT INVALID -j DROP"
      echo "r $T -A CCDC_IN -p $ICMP -j RETURN"
      [ $T = iptables ] && echo "o $T -A CCDC_IN -p tcp --dport 22 $CT NEW -m hashlimit --hashlimit-above 30/min --hashlimit-burst 30 --hashlimit-mode srcip --hashlimit-name ccdcssh -j DROP"
      [ -n "$tcp" ] && mp $T CCDC_IN tcp "$tcp" -j RETURN
      [ -n "$udp" ] && mp $T CCDC_IN udp "$udp" -j RETURN
      if [ $T = iptables ]; then echo "r $T -A CCDC_IN -p udp --sport 67 --dport 68 -j RETURN"; else echo "r $T -A CCDC_IN -p udp --dport 546 -j RETURN"; fi
      echo "o $T -A CCDC_IN -m limit --limit 6/min -j LOG --log-prefix 'CCDC-IN-DROP '"
      echo "r $T -A CCDC_IN -j DROP"
      echo "r $T -A CCDC_OUT -o lo -j RETURN"
      echo "r $T -A CCDC_OUT $CT ESTABLISHED,RELATED -j RETURN"
      echo "r $T -A CCDC_OUT -p $ICMP -j RETURN"
      local pr dst pt
      while IFS='|' read -r pr dst pt; do
        if [ "$dst" = any ]; then mp $T CCDC_OUT "$pr" "$pt" -j RETURN
        elif [ $T = iptables ]; then mp $T CCDC_OUT "$pr" "$pt" -d "$dst" -j RETURN; fi
      done < <(fw_out_allows "$mode" | sort -u)
      if [ "$mode" = learn ]; then echo "o $T -A CCDC_OUT $CT NEW -m limit --limit 20/sec -j LOG --log-prefix 'CCDC-LEARN '"
      else echo "o $T -A CCDC_OUT -m limit --limit 6/min -j LOG --log-prefix 'CCDC-OUT-DROP '"; echo "r $T -A CCDC_OUT -j DROP"; fi
      [ $T = ip6tables ] && echo 'fi'
    done
    echo 'for T in iptables ip6tables; do [ $T = ip6tables ] && [ $V6 = 0 ] && continue'
    echo '  while $T -D INPUT -j CCDC_IN 2>/dev/null; do :; done; $T -I INPUT 1 -j CCDC_IN'
    echo '  while $T -D OUTPUT -j CCDC_OUT 2>/dev/null; do :; done; $T -I OUTPUT 1 -j CCDC_OUT; done'
    echo 'exit $fail'
  } > "$FW/rules.sh"
}
FW_OFF_IPT='for T in iptables ip6tables; do command -v $T >/dev/null 2>&1 || continue; while $T -D INPUT -j CCDC_IN 2>/dev/null; do :; done; while $T -D OUTPUT -j CCDC_OUT 2>/dev/null; do :; done; $T -F CCDC_IN 2>/dev/null; $T -X CCDC_IN 2>/dev/null; $T -F CCDC_OUT 2>/dev/null; $T -X CCDC_OUT 2>/dev/null; done; true'
fw_active() { case "$FWB" in nft) nft list table inet $TABLE >/dev/null 2>&1;; iptables) iptables -S INPUT 2>/dev/null | grep -q -- '-j CCDC_IN';; *) return 1;; esac; }
fw_mode() { fw_active && cat "$FW/mode" 2>/dev/null || echo off; }
fw_persist() {
  mkdir -p /etc/ccdc; local cmd
  if [ "$FWB" = nft ]; then cp "$FW/rules.nft" /etc/ccdc/fw.nft; cmd="$(command -v nft) -f /etc/ccdc/fw.nft"
  else cp "$FW/rules.sh" /etc/ccdc/fw.sh; cmd="/bin/sh /etc/ccdc/fw.sh"; fi
  case "$INIT" in
    systemd) cat > /etc/systemd/system/ccdc-fw.service <<UNIT
[Unit]
Description=Host firewall rules (ccdc)
After=firewalld.service ufw.service network-pre.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$cmd
[Install]
WantedBy=multi-user.target
UNIT
      systemctl daemon-reload 2>/dev/null; systemctl enable ccdc-fw.service >/dev/null 2>&1 && echo "reloads at boot via ccdc-fw.service";;
    openrc) mkdir -p /etc/local.d; printf '#!/bin/sh\n%s\n' "$cmd" > /etc/local.d/ccdc-fw.start; chmod 755 /etc/local.d/ccdc-fw.start
      rc-update add local default >/dev/null 2>&1; echo "reloads at boot via /etc/local.d/ccdc-fw.start";;
    *) echo "won't survive a reboot (no systemd/OpenRC): re-run '$ME fw $(cat "$FW/mode" 2>/dev/null)' after one";;
  esac
}
fw_unpersist() { rm -f /etc/local.d/ccdc-fw.start; [ "$INIT" = systemd ] && systemctl disable ccdc-fw.service >/dev/null 2>&1; true; }
fw_load() {  # fw_load learn|lock : render, check, load with a 90s auto-undo, ask, persist
  local mode=$1
  if [ "$FWB" = none ]; then
    bad "neither nftables nor iptables works on this box"
    tip "install one:  $(pkg_install_cmd nftables)   then run this again"; return 1
  fi
  local pre_db="" post_db="" h p
  while IFS=: read -r h p; do [ -n "$p" ] && port_up "$h" "$p" && pre_db+="$h:$p "; done < "$W/dbtargets" 2>/dev/null
  if [ "$FWB" = nft ]; then
    fw_render_nft "$mode"
    nft -c -f "$FW/rules.nft" 2>"$FW/err" || { bad "rules failed the syntax check (nothing changed):"; indent < "$FW/err" | head; return 1; }
    { echo "table inet $TABLE"; echo "delete table inet $TABLE"; nft list table inet $TABLE 2>/dev/null; } > "$FW/rollback.nft"
    echo "nft -f $FW/rollback.nft" > "$FW/rollback.cmd"
  else
    fw_render_ipt "$mode"
    if fw_active && [ -f /etc/ccdc/fw.sh ]; then cp /etc/ccdc/fw.sh "$FW/rollback.sh"; else echo "$FW_OFF_IPT" > "$FW/rollback.sh"; fi
    echo "sh $FW/rollback.sh" > "$FW/rollback.cmd"
  fi
  setsid bash -c "sleep 90; sh -c \"\$(cat $(q "$FW/rollback.cmd"))\" >/dev/null 2>&1; echo 'ccdc.sh: firewall change UNDONE (not confirmed)' | wall 2>/dev/null" >/dev/null 2>&1 &
  local rb=$!
  if [ "$FWB" = nft ]; then nft -f "$FW/rules.nft" || { bad "load failed"; kill "$rb" 2>/dev/null; return 1; }
  else sh "$FW/rules.sh" 2>"$FW/err"; local rc=$?; [ -s "$FW/err" ] && indent < "$FW/err" | head -8
       [ "$rc" = 0 ] || warn "some rules failed (above) - the rest are loaded; type no if anything looks wrong"; fi
  ok "rules loaded (${BO}$mode${N} mode, $FWB). Auto-undo in 90 seconds unless you confirm."
  [ "$FWMGR" != none ] && say "$FWMGR is also running and still applies: both must allow traffic"
  say "inbound open (tcp): ${BO}$(listen_ports tcp)${N}   udp: ${BO}$(listen_ports udp)${N}"
  while IFS=: read -r h p; do [ -n "$p" ] && port_up "$h" "$p" && post_db+="$h:$p "; done < "$W/dbtargets" 2>/dev/null
  if [ -s "$W/dbtargets" ]; then
    [ "$pre_db" = "$post_db" ] && ok "database still reachable: ${post_db:-none were reachable before either}" || bad "database reachability CHANGED: before [$pre_db] after [$post_db] - type no"
  fi
  [ -s "$W/urls" ] && { local u; u=$(head -1 "$W/urls" | cut -d'|' -f1); read -r code _ <<<"$(http_probe "$u")"; [ "${code:-000}" != 000 ] && ok "web app still answers locally ($u)" || warn "web app didn't answer locally ($u)"; }
  tip "Best test: open a NEW terminal and SSH in again. Your current session stays up either way."
  trap 'kill "$rb" 2>/dev/null; sh -c "$(cat "$FW/rollback.cmd")" >/dev/null 2>&1; echo; warn "interrupted - firewall change undone"; trap - INT; kill -INT $BASHPID' INT
  local a=""; read -r -t 80 -p "  ${Y}?${N} Type ${BO}yes${N} to keep it (80s, anything else = undo): " a </dev/tty
  trap - INT
  if [ "$a" = yes ]; then
    kill "$rb" 2>/dev/null; pkill -f "sleep 90; sh -c" 2>/dev/null
    echo "$mode" > "$FW/mode"; echo "$FWB" > "$FW/backend"; [ "$mode" = learn ] && date +%s > "$FW/learn.start"
    local how; how=$(fw_persist); ok "kept + saved ($how)"; note "firewall $mode applied ($FWB)"
  else warn "not confirmed - undoing now"; kill "$rb" 2>/dev/null; sh -c "$(cat "$FW/rollback.cmd")" >/dev/null 2>&1; return 1; fi
}
fw_learned() {  # proto|ip|port|count for outbound connections seen since learn started (+ ones open now)
  local since lp; since=$(cat "$FW/learn.start" 2>/dev/null || echo $(( $(date +%s) - 3600 )))
  lp=" $(net_listen tcp | awk -F'|' '{print $2}' | sort -u | tr '\n' ' ') "
  { klog "@$since" | grep 'CCDC-LEARN' | awk '{d="";p="";t=""; for(i=1;i<=NF;i++){ if($i ~ /^DST=/) d=substr($i,5); if($i ~ /^PROTO=/) p=tolower(substr($i,7)); if($i ~ /^DPT=/) t=substr($i,5)} if(d!="" && t!="") print p"|"d"|"t}'
    net_estab | while IFS='|' read -r la lport ra rport pid name; do
      is_loop "$ra" && continue; case "$lp" in *" $lport "*) continue;; esac
      echo "tcp|${ra#::ffff:}|$rport"; done
  } | grep -vE '\|(53|67|123|547)$' | sort | uniq -c | awk '{print $2"|"$1}' | sort -t'|' -k4 -nr
}
cmd_fw() {
  local sub=${2:-}
  [ -z "$sub" ] && { [ -f "$FW/mode" ] && sub=status || sub=learn; }
  [ -s "$D/roles" ] || roles_detect
  case "$sub" in
    learn)
      hdr "FIREWALL: inbound lock + outbound learn ($FWB)"
      tip "Inbound: only ports listening right now stay open (unknown ones stay open + flagged), SSH is rate-limited, ping allowed."
      tip "Outbound: allowed but logged, so you can see what the box needs. Lock it whenever you like:  $ME fw lock"
      [ -f "$W/pids" ] || { say "discovering apps first..."; cmd_web >/dev/null 2>&1; }
      [ -s "$W/dbtargets" ] && say "database host(s) that will stay allowed: ${BO}$(tr '\n' ' ' < "$W/dbtargets")${N}" || say "no remote database found: outbound 1433/3306/5432 inside the LAN ($LAN) stays allowed"
      fw_load learn;;
    lock)
      hdr "FIREWALL: lock outbound ($FWB)"
      [ -f "$FW/learn.start" ] && say "learning since $(date -d @"$(cat "$FW/learn.start")" '+%H:%M' 2>/dev/null) ($(( ($(date +%s)-$(cat "$FW/learn.start"))/60 )) min)" || warn "learn mode never ran - only connections open right now are known"
      plan_reset
      local pr h p c name flag
      while IFS='|' read -r pr h p c; do
        [ -n "$h" ] || continue
        grep -qxF "$pr|$h|$p" "$FW/allowed" 2>/dev/null && continue
        name=$(host_name "$h"); flag=""; local rk=""
        if ! is_lan "$h"; then case "$p" in 80|443) flag=" ${DIM}(web: covered by ALLOW_WEB_OUT=$ALLOW_WEB_OUT)${N}";; *) flag=" ${R}<- internet + odd port: could be red team${N}"; rk=risky;; esac; fi
        plan_add "allow out: $pr $h:$p  ${DIM}$name, seen $c time(s)${N}$flag" "echo $(q "$pr|$h|$p") >> $(q "$FW/allowed")" "$rk"
      done < <(fw_learned)
      say "Pick what the box may keep talking to (everything else outbound gets blocked):"
      plan_apply
      fw_load lock;;
    status)
      hdr "FIREWALL STATUS"
      say "backend: ${BO}$FWB${N}   other firewall on the box: ${BO}$FWMGR${N}"
      if fw_active; then ok "ccdc rules loaded, mode: ${BO}$(cat "$FW/mode" 2>/dev/null || echo ?)${N}"; else warn "ccdc rules are NOT loaded  ->  $ME fw learn"; fi
      [ "$FWMGR" = firewalld ] && say "firewalld zone $(firewall-cmd --get-default-zone 2>/dev/null): $(firewall-cmd --list-services 2>/dev/null) $(firewall-cmd --list-ports 2>/dev/null)"
      [ "$FWMGR" = ufw ] && ufw status 2>/dev/null | head -12 | indent
      say "inbound open now: tcp ${BO}$(listen_ports tcp)${N} udp ${BO}$(listen_ports udp)${N}"
      [ "$(fw_mode)" = learn ] && say "learned so far: ${BO}$(fw_learned | wc -l)${N} destinations  ->  $ME fw lock"
      say "recent drops:"; klog -15min | grep -E 'CCDC-(IN|OUT)-DROP' | tail -6 | awk '{s="";d="";p="";t="";k=""; for(i=1;i<=NF;i++){ if($i ~ /^SRC=/) s=substr($i,5); if($i ~ /^DST=/) d=substr($i,5); if($i ~ /^PROTO=/) p=substr($i,7); if($i ~ /^DPT=/) t=substr($i,5); if($i ~ /^CCDC-/) k=$i} print "      "k" "s" -> "d" "p"/"t}';;
    off)
      hdr "FIREWALL OFF (emergency)"
      if [ "$FWB" = nft ]; then nft list table inet $TABLE > "$FW/before-off.nft" 2>/dev/null; nft delete table inet $TABLE 2>/dev/null
      else sh -c "$FW_OFF_IPT"; fi
      fw_unpersist; rm -f "$FW/mode" "$FW/backend"
      warn "ccdc rules removed ($FWMGR untouched). Turn them back on: $ME fw learn"; note "firewall OFF";;
    render) fw_render_nft "${3:-learn}"; fw_render_ipt "${3:-learn}"; ok "rendered $FW/rules.nft and $FW/rules.sh (not loaded)";;
    *) echo "usage: $ME fw [learn|lock|status|off]";;
  esac
}

# ======================================================================
#  PROTECT THE WEB APP (audit -> plan -> apply), SELinux / AppArmor
# ======================================================================
app_find() { [ -s "$W/dirs" ] || return 0; timeout 60 find $(cat "$W/dirs") -xdev "$@" 2>/dev/null; }
SKIPDIRS='/(node_modules|\.git|cache|tmp|logs?|sessions?)/'
WEBSHELL_RE='eval\([[:space:]]*(base64_decode|gzinflate|str_rot13|gzuncompress)|(system|passthru|shell_exec|popen|proc_open|exec)\([[:space:]]*\$_(GET|POST|REQUEST|COOKIE|SERVER)|assert\([[:space:]]*\$_|\$_(GET|POST|REQUEST)\[.(cmd|exec|c|command)\.\]|child_process.*req\.(query|body)|os\.system\(.*request|subprocess.*request\.(args|form|GET|POST)|Runtime\.getRuntime\(\)\.exec\(.*request|/dev/tcp/|nc -e|bash -i|preg_replace\(.*/e.'
apache_bin() { local x; for x in apachectl apache2ctl httpd; do have $x && { echo $x; return; }; done; }
cmd_protect() {
  hdr "PROTECT THE WEB APP"
  [ -f "$W/pids" ] || { say "running discovery first..."; cmd_web >/dev/null 2>&1; }
  [ -s "$W/urls" ] || { warn "no web app answered on this box - skipping web checks"; protect_mac; return 0; }
  [ -s "$W/dirs" ] || warn "no app folders known - file checks will be limited"
  plan_reset
  local f u code a hits seen=" "

  sub "Webshells and planted code"
  hits=$(app_find -type f -size -3072k \( -name '*.php*' -o -name '*.phtml' -o -name '*.jsp' -o -name '*.aspx' -o -name '*.py' -o -name '*.sh' -o -name '*.pl' -o -name '*.cgi' -o -name '*.js' -o -name '*.rb' \) -print \
     | grep -vE "$SKIPDIRS|vendor/|/dist/|\.min\.js$" | grep -vxF "$SELF" | tr '\n' '\0' | xargs -0 grep -lE "$WEBSHELL_RE" 2>/dev/null)
  if [ -n "$hits" ]; then while read -r f; do bad "suspicious code: $f"; grep -nE 'eval\(|system\(|passthru|shell_exec|/dev/tcp|bash -i|exec\(' "$f" | head -2 | cut -c1-140 | indent "        "
      plan_add "quarantine suspected webshell $f" "quar $(q "$f")"; seen+=" $f "; done <<<"$hits"
  else ok "no obvious webshell patterns in the app's code"; fi
  app_find -type f \( -name '*.php*' -o -name '*.phtml' -o -name '*.jsp' -o -name '*.sh' -o -name '*.py' \) | grep -iE '/(uploads?|media|files|attachments|images?|static)/' | while read -r f; do bad "script inside an upload/static folder: $f"; done
  for f in $(app_find -type f \( -name 'phpinfo.php' -o -name 'info.php' -o -name 'shell*.php' -o -name 'cmd*.php' -o -name 'c99*.php' -o -name 'r57*.php' \)); do warn "risky file: $f"; case "$seen" in *" $f "*) ;; *) plan_add "quarantine $f" "quar $(q "$f")";; esac; done
  say "app files changed in the last 2 days (not counting uploads/cache/logs):"
  app_find -type f -mtime -2 | grep -vE "$SKIPDIRS|\.(db|sqlite3?|db-wal|db-shm|log)$" | head -15 | indent

  sub "Things the app shouldn't show the world"
  local base nope; base=$(head -1 "$W/urls" 2>/dev/null | cut -d'|' -f1)
  if [ -n "$base" ]; then
    http_probe "${base}ccdc-nope-$RANDOM-x" "$D/.body" >/dev/null; nope=$(md5sum < "$D/.body" | cut -c1-32)
    for u in .env .git/config phpinfo.php info.php server-status install install.php setup setup.php installer installer/ admin/install config.php.bak backup.zip .DS_Store wp-config.php.bak .htpasswd; do
      read -r code _ <<<"$(http_probe "${base}${u}" "$D/.body")"
      [ "$code" = 200 ] || continue
      [ "$(md5sum < "$D/.body" | cut -c1-32)" = "$nope" ] && continue
      [ "$(wc -c < "$D/.body")" -gt 20 ] && ! grep -qiE '<title>[^<]*(404|not found|login|sign in)' "$D/.body" && bad "${base}${u} is readable (HTTP 200)"
    done; ok "checked common leaks (.env, .git, phpinfo, installers, backups)"
    tip "If something above is readable: block it in the web server config, or move the file out of the web folder."
  fi

  sub "Web server version leaks"
  pgrep -x nginx >/dev/null || pgrep -x httpd >/dev/null || pgrep -x apache2 >/dev/null || say "no nginx/apache running - the app serves itself (nothing to change here)"
  if have nginx && pgrep -x nginx >/dev/null; then
    if nginx -T 2>/dev/null | grep -qE '^[[:space:]]*server_tokens[[:space:]]+off'; then ok "nginx hides its version"
    else plan_add "nginx: hide version (server_tokens off) - tested with nginx -t before reload" "ccdc_nginx_tokens"; fi; fi
  local ab; ab=$(apache_bin)
  if [ -n "$ab" ] && { pgrep -x httpd >/dev/null || pgrep -x apache2 >/dev/null; }; then
    if $ab -t -D DUMP_RUN_CFG >/dev/null 2>&1 && grep -rqiE '^[[:space:]]*ServerTokens[[:space:]]+Prod' /etc/httpd /etc/apache2 2>/dev/null; then ok "apache hides its version"
    else plan_add "apache: hide version, turn off TRACE - tested with a config check before reload" "ccdc_apache_tokens"; fi; fi

  sub "Secrets readable by every user"
  local appusers; appusers=" $(for a in $(cat "$W/pids" 2>/dev/null); do stat -c %U "/proc/$a" 2>/dev/null; done | sort -u | tr '\n' ' ') "
  while read -r f; do [ -f "$f" ] || continue
    if [ "$(( $(stat -c %a "$f") % 10 ))" -ge 4 ] && grep -qiE 'pass|secret|key|token' "$f" 2>/dev/null; then
      local fo fg okc=0 au; fo=$(stat -c %U "$f"); fg=$(stat -c %G "$f")
      for au in $appusers; do { [ "$au" = "$fo" ] || [ "$au" = root ] || id -nG "$au" 2>/dev/null | tr ' ' '\n' | grep -qx "$fg"; } && okc=1; done
      if [ "$okc" = 1 ]; then warn "world-readable secrets file: $f ($(stat -c '%A %U:%G' "$f"))"; plan_add "make $f unreadable to other users (chmod o-rwx)" "bk $(q "$f"); chmod o-rwx $(q "$f")"
      else warn "world-readable secrets file: $f - the app may read it as 'other', so NOT changing it"; fi
    fi; done < "$W/configs"

  protect_mac
  plan_apply
  sub "Fingerprint the app (so hunt/watch catch defacement)"
  web_fingerprint && ok "fingerprinted $(wc -l < "$W/sha256") app files -> $W/sha256"
  note "protect run"
}
protect_mac() {
  case "$MAC" in
    selinux)
      sub "SELinux"
      local se avc; se=$(getenforce 2>/dev/null)
      case "$se" in
        Enforcing) ok "SELinux is Enforcing (good - leave it on)";;
        Permissive) warn "SELinux is Permissive (logging only). Don't switch it to Enforcing mid-competition - it can break things.";;
      esac
      if have ausearch; then avc=$(ausearch -m avc -ts recent 2>/dev/null | grep -E 'denied' | tail -5)
        if [ -n "$avc" ]; then warn "recent SELinux denials (these can break services):"; echo "$avc" | sed -E 's/.*denied *\{ ([^}]*)\}.*comm="([^"]*)".*tcontext=[^:]*:[^:]*:([^:]*).*/        \2 denied \1 on \3/' | sort -u
          if echo "$avc" | grep -q 'name_connect' && echo "$avc" | grep -q 'httpd_t'; then
            plan_add "SELinux: let the web server connect to databases (setsebool -P httpd_can_network_connect_db 1)" "setsebool -P httpd_can_network_connect_db 1"
            plan_add "SELinux: let the web server open outbound connections (setsebool -P httpd_can_network_connect 1)" "setsebool -P httpd_can_network_connect 1"; fi
        else ok "no recent SELinux denials"; fi; fi;;
    apparmor)
      sub "AppArmor"
      have aa-status && aa-status 2>/dev/null | grep -E 'profiles are (loaded|in enforce|in complain)' | indent
      local den; den=$(klog -30min | grep 'apparmor="DENIED"' | tail -5)
      if [ -n "$den" ]; then warn "recent AppArmor denials:"; echo "$den" | sed -E 's/.*operation="([^"]*)".*profile="([^"]*)".*name="([^"]*)".*/        \2 denied \1 on \3/' | sort -u
        tip "emergency only, if a scored service is blocked:  aa-complain /etc/apparmor.d/<profile>"
      else ok "no recent AppArmor denials"; fi;;
  esac
}
web_fingerprint() { [ -s "$W/dirs" ] || return 1
  app_find -type f -size -20480k | grep -vE "$SKIPDIRS|\.(db|sqlite3?|db-wal|db-shm|db-journal|log|pid|sock)$|/(uploads?|media)/" | head -20000 | tr '\n' '\0' | xargs -0 sha256sum 2>/dev/null > "$W/sha256"; }
ccdc_nginx_tokens() {
  local cur; cur=$(nginx -T 2>/dev/null | grep -nE '^[[:space:]]*server_tokens[[:space:]]+on' | head -1)
  local f
  if [ -n "$cur" ]; then   # an explicit "server_tokens on" exists: edit it instead of duplicating
    f=$(grep -rlE '^[[:space:]]*server_tokens[[:space:]]+on' /etc/nginx | head -1); bk "$f"; sed -i -E 's/^([[:space:]]*)server_tokens[[:space:]]+on/\1server_tokens off/' "$f"
  else
    local dir=/etc/nginx/conf.d; nginx -T 2>/dev/null | grep -qE 'include[[:space:]]+/etc/nginx/http\.d/' && dir=/etc/nginx/http.d
    mkdir -p "$dir"; f=$dir/00-ccdc-hardening.conf; echo "server_tokens off;" > "$f"
  fi
  [ "$MAC" = selinux ] && restorecon "$f" 2>/dev/null
  if nginx -t 2>/dev/null; then svc_reload nginx; else bad "nginx -t failed - undoing"; [ -n "$cur" ] && sed -i -E 's/^([[:space:]]*)server_tokens[[:space:]]+off/\1server_tokens on/' "$f" || rm -f "$f"; return 1; fi
}
ccdc_apache_tokens() {
  local ab f svc=httpd; ab=$(apache_bin)
  if [ -d /etc/apache2/conf-available ]; then f=/etc/apache2/conf-available/zz-ccdc-hardening.conf; svc=apache2
  elif [ -d /etc/apache2/conf.d ]; then f=/etc/apache2/conf.d/zz-ccdc-hardening.conf; svc=apache2
  else f=/etc/httpd/conf.d/zz-ccdc-hardening.conf; fi
  printf 'ServerTokens Prod\nServerSignature Off\nTraceEnable Off\n' > "$f"; [ "$MAC" = selinux ] && restorecon "$f" 2>/dev/null
  [ -d /etc/apache2/conf-available ] && have a2enconf && a2enconf -q zz-ccdc-hardening >/dev/null 2>&1
  if $ab -t 2>/dev/null; then svc_reload "$svc"; else bad "apache config test failed - undoing"; have a2disconf && a2disconf -q zz-ccdc-hardening >/dev/null 2>&1; rm -f "$f"; return 1; fi
}

# ======================================================================
#  RECON / REPORT / BASELINE
# ======================================================================
cmd_recon() {
  hdr "RECON (saved for injects + incident reports)"
  local f; f="$D/recon-$(TS).txt"
  {
    echo "### HOST"; hostname; uptime; date
    echo "### OS"; echo "$OS_PRETTY ($FAMILY, $PKG, $INIT)"; uname -r
    echo "### NETWORK"; ip addr 2>/dev/null || ifconfig 2>/dev/null; ip route 2>/dev/null || route -n 2>/dev/null; cat /etc/resolv.conf
    echo "### LISTENING TCP (addr|port|pid|program)"; net_listen tcp; echo "### LISTENING UDP"; net_listen udp
    echo "### ESTABLISHED (local|lport|remote|rport|pid|program)"; net_estab
    echo "### LOGIN USERS"; awk -F: '$7!~/(nologin|false|sync|shutdown|halt)$/' /etc/passwd
    echo "### ADMINS"; for g in $ADMIN_GRPS; do echo "$g: $(grp_members "$g")"; done; grep -rhv '^[[:space:]]*#' /etc/sudoers /etc/sudoers.d/ /etc/doas.conf /etc/doas.d/ 2>/dev/null | grep .
    echo "### SSH KEYS"; for k in /root/.ssh/authorized_keys* /home/*/.ssh/authorized_keys*; do [ -f "$k" ] && { echo "--- $k"; cat "$k"; }; done
    echo "### SERVICES RUNNING"; svc_running
    echo "### SERVICES ENABLED"; svc_enabled
    [ "$INIT" = systemd ] && { echo "### TIMERS"; systemctl list-timers --all --no-pager 2>/dev/null; }
    echo "### CRON"; ls -la /etc/cron* /var/spool/cron /etc/crontabs /etc/periodic 2>/dev/null; cat /etc/crontab /var/spool/cron/* /var/spool/cron/crontabs/* /etc/crontabs/* 2>/dev/null
    echo "### FIREWALL"; echo "ours: $FWB $(fw_mode)   manager: $FWMGR"; [ "$FWMGR" = firewalld ] && firewall-cmd --list-all 2>/dev/null; [ "$FWMGR" = ufw ] && ufw status verbose 2>/dev/null
    have nft && nft list tables 2>/dev/null; have iptables && iptables -S 2>/dev/null | head -60
    echo "### SELINUX / APPARMOR"; echo "$MAC"; have sestatus && sestatus 2>/dev/null; have aa-status && aa-status 2>/dev/null | head -8
    echo "### CONTAINERS"; have podman && podman ps -a 2>/dev/null; have docker && docker ps -a 2>/dev/null
    echo "### ROLES"; cat "$D/roles" 2>/dev/null
    echo "### WEB APP"; for x in urls units dirs configs sqlite dbtargets localdb; do echo "-- $x"; cat "$W/$x" 2>/dev/null; done
    echo "### DISK / MEMORY"; df -h; free -m 2>/dev/null
    echo "### LAST LOGINS"; last -n 25 2>/dev/null
    echo "### PACKAGES (recent)"; case "$PKG" in rpm) rpm -qa --last 2>/dev/null | head -25;; dpkg) ls -t /var/lib/dpkg/info/*.list 2>/dev/null | head -25 | xargs -n1 basename 2>/dev/null;; apk) apk info 2>/dev/null | head -60;; esac
  } > "$f" 2>&1
  chmod 600 "$f"; ok "saved $f"
  say "OS: $OS_PRETTY   kernel $(uname -r)   IP $MYIP"
  say "login users: ${BO}$(login_users | tr '\n' ' ')${N}"
  say "listening: ${BO}$(net_listen tcp | awk -F'|' '{print $2}' | sort -nu | tr '\n' ' ')${N}"
  note "recon -> $f"
}
cmd_report() {
  hdr "INVENTORY (copy into injects)"
  echo "  Hostname : $(hostname)"
  echo "  IP       : $MYIP   (LAN $LAN)"
  echo "  OS       : $OS_PRETTY, kernel $(uname -r)"
  echo "  Security : SELinux/AppArmor: $MAC$([ "$MAC" = selinux ] && echo " ($(getenforce 2>/dev/null))")   Firewall: $FWMGR + ccdc $(fw_mode)"
  [ -s "$D/roles" ] || roles_detect
  echo "  Roles    : $(cut -d'|' -f1 "$D/roles" 2>/dev/null | tr '\n' ' ')"
  echo; printf '  %-6s %-6s %-20s %s\n' PROTO PORT PROGRAM PACKAGE
  { net_listen tcp | sed 's/^/tcp|/'; net_listen udp | sed 's/^/udp|/'; } | awk -F'|' '!seen[$1$3]++' | while IFS='|' read -r pr addr port pid name; do
    is_loop "$addr" && continue; local exe; exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null)
    printf '  %-6s %-6s %-20s %s\n' "$pr" "$port" "${name:--}" "$( [ -n "$exe" ] && owner_pkg "$exe")"; done | sort -k1,1 -k2n
  echo; [ -s "$W/urls" ] && { echo "  Web app  : $(head -1 "$W/urls" | cut -d'|' -f4) ($(head -1 "$W/urls" | cut -d'|' -f3))"; echo "  Services : $(tr '\n' ' ' < "$W/units")"; echo "  Data     : $(cat "$W/sqlite" "$W/dbtargets" "$W/localdb" 2>/dev/null | tr '\n' ' ')"; }
  echo "  Users    : $(login_users | tr '\n' ' ')"
  for g in $ADMIN_GRPS; do echo "  Admins   : $g = $(grp_members "$g")"; done
}
admins_snapshot() { for g in $ADMIN_GRPS root docker; do echo "$g:$(grp_members "$g")"; done; }
fw_state() { echo "$FWB $(fw_mode)"; }
cmd_rebase() {
  listen_lines > "$D/base.ports"
  awk -F: '{print $1":"$3":"$7}' /etc/passwd | sort > "$D/base.users"
  admins_snapshot > "$D/base.admins"
  service_files > "$D/base.units"
  find / -xdev -perm -4000 -type f 2>/dev/null | sort > "$D/base.suid"
  echo "$MAC $(getenforce 2>/dev/null)" > "$D/base.mac"
  web_fingerprint 2>/dev/null
  touch "$D/base.ts"
  ok "baseline saved: hunt/watch now report only changes after $(date '+%H:%M')"; note "baseline refreshed"
}

# ======================================================================
#  CHECK (is everything up?)  -  read-only
# ======================================================================
svc_wanted() { svc_active "$1" || echo "$ENABLED_CACHE" | grep -qxE "$1(\.service)?"; }
roles_svcs() {   # services that matter on this box (only ones that are running or enabled)
  [ -n "${ENABLED_CACHE+x}" ] || ENABLED_CACHE=$(svc_enabled 2>/dev/null)
  { cat "$W/units" 2>/dev/null; echo "$SSH_SVC"
    has_role mail && for x in postfix dovecot exim4 exim sendmail; do svc_exists_any "$x" \&\& svc_wanted "$x" \&\& echo "$x"; done
    has_role db   && for x in mariadb mysql mysqld postgresql redis redis-server mongod; do svc_exists_any "$x" \&\& svc_wanted "$x" \&\& echo "$x"; done
    has_role nfs  && for x in nfs-server nfs-kernel-server nfs; do svc_exists_any "$x" \&\& svc_wanted "$x" \&\& echo "$x"; done
    has_role ftp  && for x in vsftpd proftpd pure-ftpd; do svc_exists_any "$x" \&\& svc_wanted "$x" \&\& echo "$x"; done
    has_role smb  && for x in smb smbd samba; do svc_exists_any "$x" \&\& svc_wanted "$x" \&\& echo "$x"; done
    has_role dns  && for x in named bind9 dnsmasq unbound; do svc_exists_any "$x" \&\& svc_wanted "$x" \&\& echo "$x"; done
  } 2>/dev/null | grep . | awk '!s[$0]++'
}
cmd_check() {
  hdr "HEALTH CHECK  $(date '+%H:%M:%S')"
  tip "${G}${OKS}${N}${DIM} good   ${Y}${WRS}${N}${DIM} look at it   ${R}${BADS}${N}${DIM} broken${N}"
  [ -s "$D/roles" ] || roles_detect
  local u c s ti a code tm t2
  sub "Web apps"
  if [ -s "$W/urls" ]; then
    while IFS='|' read -r u c s ti a; do
      read -r code tm <<<"$(http_probe "$u" "$D/.body")"
      t2=$(tr -d '\r\n' < "$D/.body" 2>/dev/null | grep -oiE '<title[^>]*>[^<]*' | head -1 | sed -E 's/<[tT][iI][tT][lL][eE][^>]*>//' | cut -c1-60)
      if [ -z "$code" ] || [ "$code" = 000 ]; then bad "$u not answering  ->  $(svc_hint "$(head -1 "$W/units" 2>/dev/null)")"
      elif [ "${code:0:1}" = 5 ]; then bad "$u answers $code (server error)  ->  app/DB problem, see logs"
      else ok "$u  $code  ${tm}s  ${DIM}\"${t2}\"${N}"; fi
      [ -n "$ti" ] && [ -n "$t2" ] && [ "$t2" != "$ti" ] && warn "page title changed: was \"$ti\", now \"$t2\" (defaced? or just a different page)"
      if ! is_loop "$a" && [ -n "$MYIP" ]; then local port=${u##*:}; port=${port%/}; read -r code _ <<<"$(http_probe "${u%%://*}://$MYIP:$port/")"
        [ "${code:-000}" != 000 ] && ok "also answers on the LAN address $MYIP:$port" || bad "doesn't answer on $MYIP:$port (firewall?)"; fi
    done < "$W/urls"
  else say "no web app recorded (run 'discover' if this box should have one)"; fi
  sub "Services"
  for u in $(roles_svcs); do svc_active "$u" && ok "$u running" || bad "$u NOT running  ->  $(svc_hint "$u")"; done
  sub "Ports"
  local lp; lp=$(net_listen tcp | awk -F'|' '{print $2}' | sort -nu | tr '\n' ' ')
  say "listening: $lp"
  for x in 25:mail 143:mail 110:mail 3306:db 5432:db 2049:nfs 21:ftp 445:smb 53:dns; do local pt=${x%%:*} rl=${x#*:}
    has_role "$rl" || continue; case " $lp " in *" $pt "*) ok "port $pt open ($rl)";; esac; done
  sub "Data"
  for u in $(cat "$W/localdb" 2>/dev/null); do pgrep -x "$u" >/dev/null && ok "$u running here" || bad "$u not running"; done
  while IFS=: read -r u c; do [ -n "$c" ] && { port_up "$u" "$c" && ok "DB $u:$c reachable ($(host_name "$u"))" || bad "DB $u:$c UNREACHABLE  ->  DB box down, or a firewall (yours, router, theirs)"; }; done < "$W/dbtargets" 2>/dev/null
  while read -r u; do [ -f "$u" ] && ok "SQLite $u ($(du -h "$u" | cut -f1), changed $(( ($(date +%s)-$(stat -c %Y "$u"))/60 )) min ago)" || bad "SQLite file missing: $u"; done < "$W/sqlite" 2>/dev/null
  sub "Box"
  case " $lp " in *" 22 "*) ok "SSH listening";; *) bad "SSH not listening  ->  $(svc_hint "$SSH_SVC")";; esac
  fw_active && ok "firewall: ccdc rules loaded ($(cat "$FW/mode" 2>/dev/null), $FWB)" || warn "firewall: ccdc rules not loaded"
  case "$MAC" in selinux) say "SELinux: $(getenforce 2>/dev/null)$(have ausearch && echo ", denials last 10 min: $(ausearch -m avc -ts recent 2>/dev/null | grep -c denied)")";; apparmor) say "AppArmor: on";; esac
  local df; df=$(df -P / | awk 'NR==2{gsub("%","",$5); print $5}'); [ "${df:-0}" -lt 90 ] && ok "disk / ${df}% used" || bad "disk / ${df}% full"
  if have timedatectl && [ "$INIT" = systemd ]; then timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes && ok "clock synced" || warn "clock not synced (matters for AD/Kerberos)"; fi
  has_role mail && have postqueue && { local qn; qn=$(postqueue -p 2>/dev/null | grep -c '^[A-F0-9]'); [ "${qn:-0}" -lt 50 ] && ok "mail queue: ${qn:-0}" || warn "mail queue: $qn messages (spam relay?)"; }
  tip "The scoreboard is the source of truth."
}

# ======================================================================
#  HUNT (what changed since the baseline?) - read-only
# ======================================================================
hunt_conns() {   # outbound connections to outside the LAN (inbound ones to our services are normal)
  local lp; lp=" $(net_listen tcp | awk -F'|' '{print $2}' | sort -u | tr '\n' ' ') "
  net_estab | while IFS='|' read -r la lport ra rport pid name; do
    is_lan "$ra" && continue
    case "$lp" in *" $lport "*) echo "in|$ra:$rport -> :$lport|$name";; *) echo "out|$ra:$rport|$name (pid $pid)";; esac; done
}
cmd_hunt() {
  hdr "HUNT  $(date '+%H:%M:%S')"
  [ -f "$D/base.ts" ] || { warn "no baseline yet - making one now (run 'first' or 'rebase')"; cmd_rebase; return; }
  tip "Only RED lines matter. If YOU caused a change:  $ME rebase"
  local x
  sub "Who's on"; who 2>/dev/null | indent
  sub "Connections to outside the LAN ($LAN)"
  x=$(hunt_conns)
  echo "$x" | grep '^out|' | cut -d'|' -f2- | tr '|' ' ' | sed "s/^/      ${R}OUT /; s/$/${N}/"
  local nin; nin=$(echo "$x" | grep -c '^in|'); [ "$nin" -gt 0 ] && say "$nin inbound connection(s) from outside to your services (scorer/users - normal)"
  echo "$x" | grep -q '^out|' || ok "no outbound connections to outside the LAN"
  sub "New since baseline"
  x=$(comm -13 "$D/base.ports" <(listen_lines)); [ -n "$x" ] && bad "new listening ports: $(echo $x)" || ok "no new listening ports"
  x=$(comm -13 "$D/base.users" <(awk -F: '{print $1":"$3":"$7}' /etc/passwd | sort)); [ -n "$x" ] && bad "new/changed accounts: $(echo $x)" || ok "no new accounts"
  x=$(comm -13 <(sort "$D/base.admins") <(admins_snapshot | sort) 2>/dev/null | tr '\n' ' '); [ -n "$x" ] && bad "admin groups changed, now: $x"
  x=$(comm -13 "$D/base.units" <(service_files)); [ -n "$x" ] && { bad "new service / startup files:"; echo "$x" | indent "        "; } || ok "no new services"
  x=$(find /etc/systemd /usr/lib/systemd/system /lib/systemd/system /etc/init.d /etc/local.d /etc/cron* /var/spool/cron /etc/crontabs /etc/periodic /etc/profile.d /etc/pam.d /etc/sudoers.d /etc/doas.d /etc/ssh /etc/ld.so.preload -newer "$D/base.ts" -type f 2>/dev/null | grep -v '/etc/ssh/ssh_host')
  [ -n "$x" ] && { warn "system config changed since baseline:"; echo "$x" | head -15 | indent "        "; }
  x=$(comm -13 "$D/base.suid" <(find / -xdev -perm -4000 -type f 2>/dev/null | sort)); [ -n "$x" ] && bad "new SUID programs: $(echo $x)"
  for x in /root/.ssh/authorized_keys* /home/*/.ssh/authorized_keys*; do [ -s "$x" ] && bad "SSH key file: $x"; done
  grep -q . /etc/ld.so.preload 2>/dev/null && bad "/etc/ld.so.preload is populated"
  [ "$MAC $(getenforce 2>/dev/null)" != "$(cat "$D/base.mac" 2>/dev/null)" ] && bad "SELinux/AppArmor state changed: now $MAC $(getenforce 2>/dev/null)"
  [ -f "$FW/mode" ] && ! fw_active && bad "ccdc firewall rules are GONE  ->  $ME fw $(cat "$FW/mode")"
  sub "Web app files"
  if [ -s "$W/sha256" ]; then x=$(sha256sum -c "$W/sha256" 2>/dev/null | grep -v ': OK$' | head -20); [ -n "$x" ] && { bad "app files changed (defacement/webshell?):"; echo "$x" | indent "        "; } || ok "app files match fingerprint"; fi
  x=$(app_find -type f -newer "$D/base.ts" | grep -vE "$SKIPDIRS|\.(db|sqlite3?|db-wal|db-shm|db-journal|log)$" | head -15); [ -n "$x" ] && { warn "new/changed files in app folders:"; echo "$x" | indent "        "; }
  sub "Processes"
  for x in /proc/[0-9]*; do local e; e=$(readlink "$x/exe" 2>/dev/null) || continue; case "$e" in *" (deleted)"|/tmp/*|/var/tmp/*|/dev/shm/*) bad "PID ${x#/proc/} runs from $e";; esac; done
  if ps -eo pid,user,%cpu,etime,args --sort=-%cpu >/dev/null 2>&1; then ps -eo pid,user,%cpu,etime,args --sort=-%cpu | head -6 | cut -c1-130 | indent
  else top -b -n1 2>/dev/null | head -12 | tail -7 | cut -c1-130 | indent; fi
  sub "Recent logins"
  ssh_log 30 | tail -8 | cut -c1-150 | indent
  note "hunt run"
}

# ======================================================================
#  WATCH (live dashboard) - read-only. q = quit, r = refresh now
# ======================================================================
cmd_watch() {
  local int=${WATCH_INT:-30} key alerts="$D/alerts.log"
  [ -s "$D/roles" ] || roles_detect
  local b_ports b_users b_exe b_units; b_ports=$(listen_lines); b_users=$(cut -d: -f1 /etc/passwd | sort)
  b_exe=$(for p in /proc/[0-9]*; do readlink "$p/exe" 2>/dev/null; done | sort -u); b_units=$(service_files); touch "$D/.watchmark"
  trap '{ have tput && tput cnorm; } 2>/dev/null; echo; exit 0' INT TERM; { have tput && tput civis; } 2>/dev/null
  alert() { local m; m="$(date '+%H:%M:%S') $*"; grep -qF "$*" "$alerts" 2>/dev/null || { echo "$m" >> "$alerts"; printf '\a'; }; }
  while :; do
    local out="" u c s ti a code tm x n
    out+="${B}${BO} $(hostname | tr a-z A-Z) WATCH ${N}  $(date '+%H:%M:%S')  load $(cut -d' ' -f1-3 /proc/loadavg)  ${DIM}$OS_PRETTY${N}\n"
    out+="  fw: ${BO}$(fw_active && cat "$FW/mode" 2>/dev/null || echo "${R}OFF${N}")${N}"
    [ "$(fw_mode)" = learn ] && out+=" ($(fw_learned 2>/dev/null | wc -l) destinations learned -> 'fw lock' when ready)"
    out+="   $MAC$([ "$MAC" = selinux ] && echo ":$(getenforce 2>/dev/null)")   disk: $(df -P / | awk 'NR==2{print $5}')\n\n"
    if [ -s "$W/urls" ]; then out+="${BO}WEB${N}\n"
      while IFS='|' read -r u c s ti a; do read -r code tm <<<"$(http_probe "$u")"
        if [ -z "$code" ] || [ "$code" = 000 ] || [ "${code:0:1}" = 5 ]; then out+="  ${R}${BADS} $u ${code:-down}${N}\n"; alert "WEB DOWN $u ($code)"
        else out+="  ${G}${OKS}${N} $u $code ${tm}s\n"; fi; done < "$W/urls"; fi
    out+="${BO}SERVICES${N}\n  "
    for u in $(roles_svcs); do svc_active "$u" && out+="${G}${OKS}${N}$u " || { out+="${R}${BADS}$u${N} "; alert "SERVICE DOWN $u"; }; done
    while IFS=: read -r u c; do [ -n "$c" ] && { port_up "$u" "$c" && out+=" ${G}${OKS}${N}db $u:$c" || { out+=" ${R}${BADS}db $u:$c${N}"; alert "DB UNREACHABLE $u:$c"; }; }; done < "$W/dbtargets" 2>/dev/null
    out+="\n${BO}WHO${N}\n$(who 2>/dev/null | sed 's/^/  /')\n"
    x=$(hunt_conns | grep '^out|' | cut -d'|' -f2- | tr '|' ' '); n=$(echo -n "$x" | grep -c .)
    out+="${BO}OUTBOUND TO OUTSIDE LAN${N} ($n)\n"; [ -n "$x" ] && out+="${R}$(echo "$x" | head -5 | sed 's/^/  /')${N}\n"
    out+="${BO}NEW SINCE WATCH STARTED${N}\n"
    x=$(comm -13 <(echo "$b_ports") <(listen_lines)); [ -n "$x" ] && { out+="  ${R}ports: $(echo $x)${N}\n"; alert "NEW PORT $(echo $x)"; }
    x=$(comm -13 <(echo "$b_users") <(cut -d: -f1 /etc/passwd | sort)); [ -n "$x" ] && { out+="  ${R}users: $(echo $x)${N}\n"; alert "NEW USER $(echo $x)"; }
    x=$(comm -13 <(echo "$b_units") <(service_files)); [ -n "$x" ] && { out+="  ${R}services: $(echo "$x" | xargs -n1 basename 2>/dev/null | tr '\n' ' ')${N}\n"; alert "NEW SERVICE FILE $(echo $x)"; }
    x=$(comm -13 <(echo "$b_exe") <(for p in /proc/[0-9]*; do readlink "$p/exe" 2>/dev/null; done | sort -u) | grep -vE '/(sleep|curl|wget|ss|netstat|ps|awk|sed|grep|tput|comm|sort|cut|tr|cat|head|tail|bash|sh|systemctl|journalctl|nft|iptables[a-z-]*|xtables[a-z-]*|readlink|date|uptime|who|df|find|sshd|sshd-session|sudo|doas|timeout|less|tmux|busybox|basename|xargs|diff|stat|ls|id|getent|hostname|ip|top|dmesg|rc-service|rc-status|openrc-run|wc|uniq|md5sum|sha256sum|tee|mktemp|env|dirname|pgrep|kill)$' | head -5)
    [ -n "$x" ] && out+="  ${Y}programs: $(echo $x)${N}\n"
    x=$(app_find -type f -newer "$D/.watchmark" 2>/dev/null | grep -vE "$SKIPDIRS|\.(db|sqlite3?|db-wal|db-shm|db-journal|log)$" | head -3); [ -n "$x" ] && { out+="  ${R}app files changed: $(echo $x)${N}\n"; alert "APP FILE CHANGED $(echo $x | cut -c1-120)"; }
    out+="${BO}LOGINS${N}\n$(ssh_log 15 | tail -3 | cut -c1-120 | sed 's/^/  /')\n"
    out+="${BO}ALERTS${N} ${DIM}($alerts)${N}\n$(tail -5 "$alerts" 2>/dev/null | sed "s/^/  ${R}/; s/$/${N}/")\n"
    out+="\n${DIM}refresh every ${int}s   r = refresh now   q = quit   (read-only: changes nothing)${N}"
    printf '\033[H\033[2J%b\n' "$out"
    key=""; read -rsn1 -t "$int" key </dev/tty; [ "$key" = q ] && { { have tput && tput cnorm; } 2>/dev/null; echo; break; }
  done
}
cmd_tmux() {
  have tmux || { say "installing tmux..."; pkg_install tmux || { bad "couldn't install tmux - run '$ME watch' in a second SSH window instead"; return 1; }; }
  if [ -n "${TMUX:-}" ]; then tmux split-window -v -b -l 45% "bash $(q "$SELF") watch"; ok "dashboard opened above. Ctrl-b then arrow keys moves between panes."; return; fi
  if tmux has-session -t ccdc 2>/dev/null; then exec tmux attach -t ccdc; fi
  tmux new-session -d -s ccdc -x "$(tput cols 2>/dev/null || echo 200)" -y "$(tput lines 2>/dev/null || echo 50)" "bash $(q "$SELF") watch"
  tmux split-window -v -t ccdc -l 60% 2>/dev/null || tmux split-window -v -t ccdc; tmux select-pane -t ccdc:0.1
  tmux set -t ccdc mouse on >/dev/null 2>&1
  echo "  Opening tmux: dashboard on top, your shell below.  Ctrl-b d = leave it running   tmux a -t ccdc = come back"; sleep 2
  exec tmux attach -t ccdc
}

# ======================================================================
#  INFO, TOOLS, SELFTEST
# ======================================================================
missing_tools() {   # GNU/full tools that make this script work better (mostly matters on Alpine/BusyBox)
  local m=() x
  for x in ss:iproute2 curl:curl tar:tar; do have "${x%%:*}" || m+=("${x#*:}"); done
  [ "$BUSYBOX" = 1 ] && m+=(coreutils findutils grep procps-ng util-linux)
  [ "$FAMILY" = alpine ] && ! have useradd && m+=(shadow)
  [ "$FWB" = none ] && m+=(nftables)
  [ "$PM" = apt-get ] && for i in "${!m[@]}"; do [ "${m[$i]}" = procps-ng ] && m[$i]=procps; done
  echo "${m[*]}"
}
cmd_tools() {
  local m; m=$(missing_tools); [ -z "$m" ] && { ok "all helper tools present"; return 0; }
  warn "missing helper tools: ${BO}$m${N}"; tip "the script works without them, but some checks get less detail"
  [ "$PM" = none ] && return 0
  if ask "Install them now? ($(pkg_install_cmd $m))"; then pkg_install $m && ok "installed" || warn "install failed (no internet?) - carrying on without them"; detect; fi
}
cmd_info() {
  hdr "THIS BOX"
  say "host      : ${BO}$(hostname)${N}   IP $MYIP   LAN $LAN"
  say "distro    : ${BO}$OS_PRETTY${N}  (family $FAMILY, packages $PKG via $PM)"
  say "init      : $INIT        network tool: $NETT$([ "$BUSYBOX" = 1 ] && echo "   (BusyBox userland)")"
  say "firewall  : ours via ${BO}$FWB${N} ($(fw_mode))   already on the box: ${BO}$FWMGR${N}"
  say "admins    : group ${BO}$SUDOGRP${N}$(admin_grants "$SUDOGRP" && echo " (grants root)" || echo " ${Y}(doesn't grant root yet)${N}")   doas: $([ "$DOAS" = 1 ] && echo yes || echo no)"
  say "security  : $MAC$([ "$MAC" = selinux ] && echo " ($(getenforce 2>/dev/null))")"
  say "ssh       : ${SSHD:-none} (service $SSH_SVC)$([ "$DROPBEAR" = 1 ] && echo " - dropbear")"
  say "logs      : $([ "$JOURNAL" = 1 ] && echo journald) ${AUTHLOG}"
  roles_detect; roles_show
  local m; m=$(missing_tools); [ -n "$m" ] && warn "helper tools missing: $m  ->  $ME tools"
  true
}
SELFTEST_RE='command not found|syntax error|unbound variable|invalid option|unrecognized option|illegal option|bad substitution|integer expression expected|too many arguments|unary operator expected|binary operator expected|ambiguous redirect|printf: |awk: |sed: -e|sed: [^ ]* unknown|grep: (Invalid|Unmatched|trailing|warning)|Usage:|usage:|applet not found|bad array subscript|division by 0|No such file or directory$'
cmd_selftest() {
  hdr "SELFTEST (read-only: plans are shown, nothing is applied)"
  local dir="$D/selftest-$(TS)" t rc probs total=0; mkdir -p "$dir"
  export DRYRUN=1
  for t in info discover harden evict ssh "fw render" check rebase hunt recon report; do
    printf '  %-12s ' "$t"
    ( set -- $t; timeout 600 bash "$SELF" "$@" </dev/null >"$dir/${t// /_}.out" 2>"$dir/${t// /_}.err" ); rc=$?
    probs=$(grep -E "$SELFTEST_RE" "$dir/${t// /_}.err" "$dir/${t// /_}.out" 2>/dev/null | grep -vE 'dry run' | sort -u | head -5)
    if [ "$rc" = 124 ]; then echo "${Y}TIMED OUT${N}"; total=$((total+1))
    elif [ -n "$probs" ]; then echo "${R}$(echo "$probs" | wc -l) problem(s)${N}"; echo "$probs" | cut -c1-160 | indent "      "; total=$((total+1))
    else echo "${G}ok${N} ${DIM}(exit $rc)${N}"; fi
  done
  if [ -s "$FW/rules.nft" ] && have nft; then nft -c -f "$FW/rules.nft" >/dev/null 2>"$dir/nft.err" && ok "nftables rules pass nft -c" || { bad "nftables rules fail nft -c:"; head -3 "$dir/nft.err" | indent; total=$((total+1)); }; fi
  [ -s "$FW/rules.sh" ] && { sh -n "$FW/rules.sh" && ok "iptables rule script parses" || { bad "iptables rule script has a syntax error"; total=$((total+1)); }; }
  echo; [ "$total" = 0 ] && ok "selftest clean on $OS_PRETTY" || warn "$total command(s) need a look. Full output: $dir"
  note "selftest: $total problem(s) on $OS_PRETTY"
}

# ======================================================================
#  FIRST RUN (8 steps, resumable)
# ======================================================================
STEPS=("Passwords (zulu-compatible)|cmd_passwd|creates ccdcuser1+2, you set root/ccdcuser1/ccdcuser2, everyone else gets the seed password|3 passwords, names to leave alone, y + seed phrase twice"
       "Discover|cmd_discover|read-only: web apps, their files and database, plus mail / DB / file share / DNS roles|nothing"
       "Evict backdoors|cmd_evict|finds planted SSH keys, extra admins, fake services, cron jobs, PAM stealers, tampered programs|one plan: apply all / pick numbers / skip"
       "Backups + database dump|cmd_backup|disguised, backdated copies of /etc, app files, service data and databases|optional passphrase (Enter = none)"
       "Harden SSH|cmd_ssh|no root login, 3 tries, no tunnels - passwords stay on|apply / skip"
       "Firewall: inbound lock + outbound learn|cmd_fw fw learn|keeps every listening port open, logs where the box connects out, 90s auto-undo|type yes to keep it"
       "Harden services|cmd_harden|web app audit + checks for every role found (mail, databases, shares, DNS)|one plan per role: apply all / pick / skip"
       "Recon + baseline + health check|cmd_finish|saves the inventory, sets the baseline for hunt/watch, checks every service|nothing")
cmd_finish() { cmd_recon; cmd_rebase; cmd_check; }
cmd_first() {
  hdr "FIRST RUN: ${#STEPS[@]} steps on $OS_PRETTY"
  echo "  Each step shows what it does, then asks before changing anything."
  echo "  ${BO}Ctrl-C${N} pauses a step (skip / retry / quit). Re-running 'first' offers to resume."
  local done_f="$D/first.done" startat=1 i last=0
  if [ -s "$done_f" ]; then last=$(sort -n "$done_f" | tail -1)
    if [ "$last" -lt ${#STEPS[@]} ]; then local a; read -r -p "  ${Y}?${N} Steps 1-$last already done. Resume at step $((last+1))? [Y/n] " a </dev/tty; [[ $a =~ ^[Nn] ]] || startat=$((last+1)); fi
  fi
  [ "$startat" = 1 ] && [ -n "$(missing_tools)" ] && run_step "Helper tools" cmd_tools
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
  echo "  What changed:"; tail -20 "$LOG" | indent "    "
  echo "  Quarantined files: $(ls "$Q" 2>/dev/null | wc -l)  (tell your Injects/IR person)"
  echo; ok "Next:  ${BO}$ME tmux${N}   (dashboard on top, shell below)"
  ok "Later: ${BO}$ME fw lock${N}   (lock outbound once things have run a while)"
  ok "Every 15 min: ${BO}$ME hunt${N}  and  ${BO}$ME check${N}"
}

# ======================================================================
#  MENU
# ======================================================================
menu_status() {
  local u code; u=$(head -1 "$W/urls" 2>/dev/null | cut -d'|' -f1)
  [ -n "$u" ] && read -r code _ <<<"$(http_probe "$u")"
  printf '  web: %s   firewall: %s   first run: %s/%s   backups: %s   quarantined: %s\n' \
    "$( [ -z "$u" ] && echo "${DIM}none${N}" || { [ "${code:-000}" != 000 ] && [ "${code:0:1}" != 5 ] && echo "${G}up ($code)${N}" || echo "${R}DOWN ($code)${N}"; } )" \
    "$(fw_active && echo "${G}$(cat "$FW/mode" 2>/dev/null)${N}" || echo "${Y}off${N}")" \
    "$(sort -u "$D/first.done" 2>/dev/null | wc -l)" "${#STEPS[@]}" "$(wc -l < "$D/backup.list" 2>/dev/null || echo 0)" "$(ls "$Q" 2>/dev/null | wc -l)"
}
cmd_menu() {
  while :; do
    printf '\033[H\033[2J'
    echo "${B}$(line 64)${N}"; echo "${B}${BO}  CCDC toolkit v$VERSION${N}  ${DIM}$(hostname) $MYIP  $OS_PRETTY  $(date '+%H:%M')${N}"; echo "${B}$(line 64)${N}"
    menu_status; echo
    echo "   ${BO}1${N}  First run (start here)        ${BO}6${N}  Firewall: status / learn / lock / off"
    echo "   ${BO}2${N}  Check: is everything up?      ${BO}7${N}  Backup now"
    echo "   ${BO}3${N}  Hunt: what changed?           ${BO}8${N}  Restore something"
    echo "   ${BO}4${N}  Live dashboard (tmux)         ${BO}9${N}  Passwords / show a seed password"
    echo "   ${BO}5${N}  Discover apps + roles         ${BO}h${N}  Harden services (web, mail, DB, shares)"
    echo "   ${BO}e${N}  Evict backdoors again         ${BO}s${N}  SSH hardening"
    echo "   ${BO}r${N}  Inventory report (injects)    ${BO}b${N}  Rebase (accept current state)"
    echo "   ${BO}i${N}  What is this box?             ${BO}t${N}  Selftest (find script problems)"
    echo "   ${BO}q${N}  Quit"
    echo; local c; read -r -n1 -p "  Choose (single key): " c </dev/tty; echo
    [ -z "$c" ] && continue
    case "$c" in
      1) cmd_first;; 2) run_step Check cmd_check;; 3) run_step Hunt cmd_hunt;; 4) cmd_tmux;;
      5) run_step Discover cmd_discover;; h|H) run_step Harden cmd_harden;;
      6) local w; read -r -p "  [s]tatus / [l]earn / loc[k] / [o]ff? " w </dev/tty
         case "$w" in l|L) run_step Firewall cmd_fw fw learn;; k|K) run_step Firewall cmd_fw fw lock;; o|O) ask "Really remove the ccdc firewall rules?" && run_step Firewall cmd_fw fw off;; *) run_step Firewall cmd_fw fw status;; esac;;
      7) run_step Backup cmd_backup;; 8) run_step Restore cmd_restore restore;;
      9) local w; read -r -p "  [c]hange passwords or [s]how a seed password? " w </dev/tty
         if [[ $w =~ ^[Ss] ]]; then local us; read -r -p "  user(s): " us </dev/tty; run_step Seedshow cmd_seedshow seedshow $us; else run_step Passwords cmd_passwd; fi;;
      e|E) run_step Evict cmd_evict;; r|R) cmd_report;; b|B) cmd_rebase;; s|S) run_step SSH cmd_ssh;;
      i|I) cmd_info;; t|T) cmd_selftest;;
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
  info) cmd_info;;  tools) cmd_tools;;  selftest) cmd_selftest;;
  check) run_step Check cmd_check;;  hunt) run_step Hunt cmd_hunt;;
  watch) cmd_watch;;  tmux) cmd_tmux;;
  discover|web) run_step Discover cmd_discover;;  harden) run_step Harden cmd_harden;;  protect) run_step Protect cmd_protect;;
  fw) run_step Firewall cmd_fw "$@";;
  backup) run_step Backup cmd_backup;;  restore) run_step Restore cmd_restore "$@";;
  evict) run_step Evict cmd_evict;;  passwd) run_step Passwords cmd_passwd;;  ssh) run_step SSH cmd_ssh;;
  recon) cmd_recon;;  report) cmd_report;;  rebase) cmd_rebase;;
  seedshow) cmd_seedshow "$@";;
  -h|--help|help) sed -n 's/^#: \{0,1\}//p' "$SELF";;
  *) echo "unknown command: $1"; sed -n 's/^#: \{0,1\}//p' "$SELF"; exit 1;;
esac
exit $?

__WORDLIST__
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
