#!/usr/bin/env bash
set -u -o pipefail
M="${1:-cool}"
[[ $EUID -eq 0 ]] || { echo "sudo bro"; exit 1; }
command -v apt-get >/dev/null || { echo "apt only. get ubuntu"; exit 1; }
case "$M" in cool|balanced|max) ;; *) echo "cool, balanced or max. not hard"; exit 1 ;; esac
export DEBIAN_FRONTEND=noninteractive
U="${SUDO_USER:-}"
[[ "$U" == root ]] && U=""
FAIL=0
APT="apt-get -y -qq -o DPkg::Lock::Timeout=180 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
say(){ echo -e "\033[1;32m>> $*\033[0m"; }
try(){ "$@" >/dev/null 2>&1 || { echo "meh, failed: $*"; FAIL=$((FAIL+1)); }; }
inst(){
  $APT install --no-install-recommends "$@" >/dev/null 2>&1 && return 0
  local p
  for p in "$@"; do
    $APT install --no-install-recommends "$p" >/dev/null 2>&1 || { echo "meh, no $p"; FAIL=$((FAIL+1)); }
  done
}

say "ugh updating"
try $APT update
try $APT upgrade

say "grabbing dev junk"
inst build-essential git curl wget ca-certificates pkg-config libssl-dev python3 python3-dev python3-pip python3-venv tmux vim htop jq ripgrep fd-find fzf tree ncdu unzip zip sqlite3 net-tools bash-completion bat openssh-client

say "anti-melt stuff"
inst lm-sensors thermald tlp zram-tools earlyoom
try sensors-detect --auto
try systemctl enable --now thermald
try systemctl enable --now tlp
printf 'EARLYOOM_ARGS="-m 5 -s 5"\n' > /etc/default/earlyoom
try systemctl enable earlyoom
try systemctl restart earlyoom

say "zram so 2gb isnt a joke"
printf 'ALGO=zstd\nPERCENT=60\nPRIORITY=100\n' > /etc/default/zramswap
try systemctl enable zramswap
try systemctl restart zramswap

say "kernel tweaks idk"
printf 'vm.swappiness=100\nvm.vfs_cache_pressure=50\nvm.dirty_ratio=10\nvm.dirty_background_ratio=5\nvm.page-cluster=0\nkernel.nmi_watchdog=0\nfs.inotify.max_user_watches=262144\n' > /etc/sysctl.d/99-celeron.conf
try sysctl --system

say "cpu mode: $M"
cat > /usr/local/bin/celeron-mode <<'EOF'
#!/usr/bin/env bash
C=/etc/celeron-mode
if [[ "${1:-}" == --apply ]]; then
  M=$(cat "$C" 2>/dev/null || echo cool)
else
  M="${1:-}"
  case "$M" in cool|balanced|max) ;; *) echo "usage: sudo celeron-mode cool|balanced|max"; exit 1 ;; esac
  [[ $EUID -eq 0 ]] || { echo "sudo bro"; exit 1; }
  echo "$M" > "$C"
fi
case "$M" in cool) P=70; T=1 ;; balanced) P=85; T=0 ;; *) M=max; P=100; T=0 ;; esac
w(){ echo "$1" 2>/dev/null > "$2"; }
S="${SYSROOT:-}/sys/devices/system/cpu"
if [[ -d "$S/intel_pstate" ]]; then
  w "$P" "$S/intel_pstate/max_perf_pct"
  w "$T" "$S/intel_pstate/no_turbo"
fi
for c in "$S"/cpu[0-9]*/cpufreq; do
  [[ -d "$c" ]] || continue
  d=$(cat "$c/scaling_driver" 2>/dev/null)
  a=$(cat "$c/scaling_available_governors" 2>/dev/null)
  if [[ $M == max ]]; then want="performance"
  elif [[ $d == intel_pstate ]]; then want="powersave"
  else want="schedutil ondemand conservative"; fi
  for g in $want; do
    if [[ " $a " == *" $g "* ]]; then w "$g" "$c/scaling_governor"; break; fi
  done
  if [[ $d != intel_pstate ]]; then
    f=$(cat "$c/cpuinfo_max_freq" 2>/dev/null)
    [[ -n "$f" ]] && w "$(( f * P / 100 ))" "$c/scaling_max_freq"
  fi
done
echo "mode: $M"
EOF
chmod +x /usr/local/bin/celeron-mode
cat > /etc/systemd/system/celeron-cpu.service <<'EOF'
[Unit]
Description=celeron cpu mode
After=tlp.service thermald.service suspend.target hibernate.target hybrid-sleep.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/celeron-mode --apply
[Install]
WantedBy=multi-user.target suspend.target hibernate.target hybrid-sleep.target
EOF
try systemctl daemon-reload
try systemctl enable celeron-cpu.service
try /usr/local/bin/celeron-mode "$M"

say "killing useless crap"
for s in cups-browsed ModemManager avahi-daemon whoopsie apport; do
  systemctl disable --now "$s" >/dev/null 2>&1
done

say "noatime, less disk spam"
if ! grep -qE '^[^#].*\s/\s+ext4.*noatime' /etc/fstab; then
  sed -i.bak -E '/^[^#].*\s\/\s+ext4/ s/(ext4\s+)(\S+)/\1noatime,\2/' /etc/fstab
  try mount -o remount,noatime /
fi

say "shrinking logs"
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=50M\n' > /etc/systemd/journald.conf.d/size.conf
try systemctl restart systemd-journald

say "making the shell fancy"
cat > /etc/celeron-shell.sh <<'EOF'
shopt -s histappend cdspell autocd globstar checkwinsize 2>/dev/null
HISTSIZE=50000
HISTFILESIZE=100000
HISTCONTROL=ignoreboth:erasedups
export EDITOR=vim
export LESS='-R'
alias ls='ls --color=auto'
alias ll='ls -alFh'
alias la='ls -A'
alias grep='grep --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
alias gs='git status -sb'
alias gl='git log --oneline --graph --decorate -15'
alias gd='git diff'
alias ga='git add -A'
alias gc='git commit -m'
alias gp='git push'
alias temp='watch -n2 sensors'
alias mem='free -h && swapon --show'
alias ports='ss -tulpn'
alias update='sudo apt update && sudo apt upgrade -y'
command -v fdfind >/dev/null && alias fd=fdfind
command -v batcat >/dev/null && alias bat=batcat
mkcd(){ mkdir -p "$1" && cd "$1"; }
for f in /usr/share/doc/fzf/examples/key-bindings.bash /usr/share/bash-completion/completions/fzf; do
  [[ -r $f ]] && . "$f"
done
if [[ ${LANG:-} == *UTF-8* ]]; then __ARROW='❯'; else __ARROW='$'; fi
__celeron_ps1(){
  local e=$? x="" c=32
  history -a
  (( e )) && { x="\[\e[31m\][$e]\[\e[0m\] "; c=31; }
  __CG=$(git symbolic-ref --short -q HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
  [[ -n $__CG ]] && __CG=" ($__CG)"
  PS1="${x}\[\e[36m\]\u@\h\[\e[0m\] \[\e[34m\]\w\[\e[0m\]\[\e[35m\]\${__CG}\[\e[0m\]\n\[\e[${c}m\]${__ARROW}\[\e[0m\] "
}
[[ ${PROMPT_COMMAND:-} == *__celeron_ps1* ]] || PROMPT_COMMAND="__celeron_ps1${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
if [[ $- == *i* && ${SHLVL:-1} -le 1 ]]; then
  __t=0
  for __f in /sys/class/thermal/thermal_zone*/temp; do
    [[ -r $__f ]] || continue
    __v=$(cat "$__f" 2>/dev/null)
    [[ $__v =~ ^[0-9]+$ ]] && (( __v > __t )) && __t=$__v
  done
  __t=$((__t/1000))
  if (( __t == 0 )); then
    __tc="n/a"
  else
    __k=32
    (( __t >= 70 )) && __k=33
    (( __t >= 80 )) && __k=31
    __tc="\e[${__k}m${__t}C\e[0m"
  fi
  __m=$(awk '/MemAvailable/{printf "%d",$2/1024}' /proc/meminfo)
  __md=$(cat /etc/celeron-mode 2>/dev/null || echo cool)
  echo -e "\e[1;36m$(hostname)\e[0m  temp $__tc  free ram ${__m}MB  mode $__md"
  unset __t __f __v __tc __k __m __md
fi
EOF
grep -q celeron-shell /etc/bash.bashrc || printf '\n[ -f /etc/celeron-shell.sh ] && . /etc/celeron-shell.sh\n' >> /etc/bash.bashrc
[[ -e /etc/tmux.conf ]] || cat > /etc/tmux.conf <<'EOF'
set -g mouse on
set -g history-limit 20000
set -g default-terminal "screen-256color"
set -sg escape-time 10
set -g base-index 1
set -g status-style bg=colour235,fg=colour250
set -g status-left "#[fg=colour39,bold] #S "
set -g status-right "#[fg=colour245]%H:%M "
EOF
mkdir -p /etc/vim
printf 'syntax on\nset number\nset incsearch\nset hlsearch\nset ignorecase\nset smartcase\n' > /etc/vim/vimrc.local

say "ssh time"
inst openssh-server fail2ban ufw
mkdir -p /etc/ssh/sshd_config.d /run/sshd /etc/fail2ban/jail.d
grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
cat > /etc/ssh/sshd_config.d/00-celeron.conf <<'EOF'
PasswordAuthentication yes
PermitEmptyPasswords no
PermitRootLogin no
MaxAuthTries 3
LoginGraceTime 30
MaxStartups 5:50:10
X11Forwarding no
UseDNS no
ClientAliveInterval 120
ClientAliveCountMax 3
EOF
if command -v sshd >/dev/null && sshd -t >/dev/null 2>&1; then
  try systemctl enable ssh
  try systemctl restart ssh
else
  rm -f /etc/ssh/sshd_config.d/00-celeron.conf
  echo "meh, ssh config was broken so i removed mine"
  FAIL=$((FAIL+1))
fi
cat > /etc/fail2ban/jail.d/celeron.local <<'EOF'
[sshd]
enabled = true
maxretry = 4
findtime = 10m
bantime = 1h
EOF
try systemctl enable fail2ban
try systemctl restart fail2ban
try ufw default deny incoming
try ufw default allow outgoing
try ufw limit 22/tcp
try ufw --force enable

if [[ -z "$U" ]]; then
  echo "ran as plain root, ssh root login is off. make a user: adduser name"
else
  st=$(passwd -S "$U" 2>/dev/null | awk '{print $2}')
  if [[ -t 0 ]]; then
    a=n
    if [[ "$st" != P ]]; then
      say "no password on $U, set one for ssh"
      a=y
    else
      read -rp "change ssh password for $U? [y/N] " a
    fi
    if [[ "$a" =~ ^[Yy]$ ]]; then
      for i in 1 2 3; do passwd "$U" && break; done
    fi
  elif [[ "$st" != P ]]; then
    echo "no password for $U, run: sudo passwd $U"
  fi
  say "node via nvm"
  try sudo -u "$U" -H bash -c 'curl -fsSo- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash && . ~/.nvm/nvm.sh && nvm install --lts'
fi

try $APT autoremove
try $APT clean

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
say "done. reboot or whatever"
[[ $FAIL -gt 0 ]] && echo "$FAIL things failed, scroll up. usually no big deal"
echo "ssh in:  ssh ${U:-user}@${IP:-this-pc-ip}"
echo "temps:   watch -n2 sensors"
echo "ram:     free -h && swapon --show"
echo "mode:    sudo celeron-mode cool|balanced|max"
echo "shell:   open a new terminal to see it"
