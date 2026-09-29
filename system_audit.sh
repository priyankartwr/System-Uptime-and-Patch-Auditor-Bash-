#!/usr/bin/env bash
# =============================================================================
# Blue Team — System Uptime & Patch Auditor
# Role   : System Health & Patch Management Auditor
# Author : Priyankar
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
REPORT_DIR="/var/log/blue_team_audit"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_FILE="${REPORT_DIR}/system_health_report_${TIMESTAMP}.txt"
HTML_REPORT="${REPORT_DIR}/system_health_report_${TIMESTAMP}.html"
UPTIME_THRESHOLD_DAYS=90          # Alert if system hasn't been rebooted in 90+ days
PATCH_STALENESS_DAYS=30           # Alert if last patch was 30+ days ago
DISK_WARN_PERCENT=80
DISK_CRIT_PERCENT=90

# ── Colour codes (stdout only, stripped from file) ───────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
log()      { echo -e "${CYAN}[*]${RESET} $*"; }
ok()       { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()     { echo -e "${YELLOW}[WARN]${RESET} $*"; }
critical() { echo -e "${RED}[CRITICAL]${RESET} $*"; }
section()  { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }

# Write to both terminal (coloured) and plain-text report file
tee_report() {
    local plain
    plain=$(echo -e "$*" | sed 's/\x1b\[[0-9;]*m//g')
    echo -e "$*"
    echo "$plain" >> "$REPORT_FILE"
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        warn "Some checks require root. Re-run with sudo for full results."
    fi
}

detect_pkg_manager() {
    if   command -v apt-get &>/dev/null; then echo "apt"
    elif command -v dnf     &>/dev/null; then echo "dnf"
    elif command -v yum     &>/dev/null; then echo "yum"
    elif command -v zypper  &>/dev/null; then echo "zypper"
    elif command -v pacman  &>/dev/null; then echo "pacman"
    else echo "unknown"
    fi
}

days_since_epoch() {
    local ts="$1"
    local now; now=$(date +%s)
    echo $(( (now - ts) / 86400 ))
}

# ── Setup ─────────────────────────────────────────────────────────────────────
mkdir -p "$REPORT_DIR"
: > "$REPORT_FILE"   # truncate / create

AUDIT_START=$(date)
PKG_MGR=$(detect_pkg_manager)

SCORE=100          # deduct points for findings; printed at end
FINDINGS=0

deduct() { SCORE=$(( SCORE - $1 )); FINDINGS=$(( FINDINGS + 1 )); }

# =============================================================================
# SECTION 1 — REPORT HEADER
# =============================================================================
{
echo "============================================================"
echo "   BLUE TEAM — SYSTEM HEALTH & PATCH AUDIT REPORT"
echo "============================================================"
echo "Generated  : $AUDIT_START"
echo "Hostname   : $(hostname -f 2>/dev/null || hostname)"
echo "Auditor    : $(whoami)"
echo "Report     : $REPORT_FILE"
echo "============================================================"
} | tee -a "$REPORT_FILE"

# =============================================================================
# SECTION 2 — SYSTEM INFORMATION
# =============================================================================
section "SYSTEM INFORMATION" | tee -a "$REPORT_FILE"

OS_NAME=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -s)
KERNEL=$(uname -r)
ARCH=$(uname -m)
HOSTNAME=$(hostname -f 2>/dev/null || hostname)
CURRENT_USER=$(whoami)

tee_report "  OS          : $OS_NAME"
tee_report "  Kernel      : $KERNEL"
tee_report "  Architecture: $ARCH"
tee_report "  Hostname    : $HOSTNAME"
tee_report "  Date/Time   : $(date)"
tee_report "  Timezone    : $(timedatectl show --property=Timezone --value 2>/dev/null || date +%Z)"
tee_report "  Pkg Manager : $PKG_MGR"

# =============================================================================
# SECTION 3 — UPTIME AUDIT
# =============================================================================
section "UPTIME AUDIT" | tee -a "$REPORT_FILE"

RAW_UPTIME=$(uptime -p 2>/dev/null || uptime)
BOOT_TIME_STR=$(who -b 2>/dev/null | awk '{print $3, $4}')
BOOT_EPOCH=$(date -d "$BOOT_TIME_STR" +%s 2>/dev/null || echo 0)
UPTIME_DAYS=$(days_since_epoch "$BOOT_EPOCH")

tee_report "  System Uptime : $RAW_UPTIME"
tee_report "  Last Boot     : ${BOOT_TIME_STR:-unknown}"
tee_report "  Days Since Boot: $UPTIME_DAYS days"

if [[ $UPTIME_DAYS -ge $UPTIME_THRESHOLD_DAYS ]]; then
    critical "System has been up for $UPTIME_DAYS days (threshold: ${UPTIME_THRESHOLD_DAYS}d). Reboot pending or missed!"
    tee_report "  [CRITICAL] Uptime exceeds ${UPTIME_THRESHOLD_DAYS}-day threshold — reboot required."
    deduct 20
elif [[ $UPTIME_DAYS -ge 60 ]]; then
    warn "Uptime is $UPTIME_DAYS days. Consider scheduling a maintenance window."
    tee_report "  [WARN] Uptime $UPTIME_DAYS days — maintenance window recommended."
    deduct 10
else
    ok "Uptime is within acceptable range ($UPTIME_DAYS days)."
    tee_report "  [OK] Uptime $UPTIME_DAYS days — within acceptable range."
fi

# Load averages
LOAD=$(cut -d' ' -f1-3 /proc/loadavg)
CPU_CORES=$(nproc)
tee_report "  Load Average  : $LOAD  (CPU cores: $CPU_CORES)"

# =============================================================================
# SECTION 4 — PATCH / UPDATE AUDIT
# =============================================================================
section "PATCH & UPDATE AUDIT" | tee -a "$REPORT_FILE"

get_last_patch_date() {
    local last_patch=""
    case "$PKG_MGR" in
        apt)
            last_patch=$(stat -c %Y /var/log/dpkg.log 2>/dev/null \
                || stat -c %Y /var/lib/dpkg/status 2>/dev/null \
                || echo 0)
            ;;
        dnf)
            last_patch=$(rpm -q --last kernel 2>/dev/null | head -1 \
                | awk '{print $2,$3,$4,$5}' | xargs -I{} date -d "{}" +%s 2>/dev/null \
                || stat -c %Y /var/log/dnf.log 2>/dev/null || echo 0)
            ;;
        yum)
            last_patch=$(stat -c %Y /var/log/yum.log 2>/dev/null || echo 0)
            ;;
        zypper)
            last_patch=$(stat -c %Y /var/log/zypp/history 2>/dev/null || echo 0)
            ;;
        pacman)
            last_patch=$(stat -c %Y /var/log/pacman.log 2>/dev/null || echo 0)
            ;;
        *) last_patch=0 ;;
    esac
    echo "$last_patch"
}

LAST_PATCH_EPOCH=$(get_last_patch_date)
PATCH_AGE=$(days_since_epoch "$LAST_PATCH_EPOCH")

if [[ "$LAST_PATCH_EPOCH" -eq 0 ]]; then
    tee_report "  Last Patch Date : UNKNOWN (log not accessible)"
    warn "Cannot determine last patch date."
    deduct 15
else
    LAST_PATCH_HUMAN=$(date -d "@$LAST_PATCH_EPOCH" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")
    tee_report "  Last Patch Date  : $LAST_PATCH_HUMAN"
    tee_report "  Days Since Patch : $PATCH_AGE days"

    if [[ $PATCH_AGE -ge $PATCH_STALENESS_DAYS ]]; then
        critical "Last patch was $PATCH_AGE days ago — system is STALE (threshold: ${PATCH_STALENESS_DAYS}d)."
        tee_report "  [CRITICAL] Patch staleness ${PATCH_AGE}d exceeds threshold."
        deduct 25
    elif [[ $PATCH_AGE -ge 14 ]]; then
        warn "Last patch was $PATCH_AGE days ago."
        tee_report "  [WARN] Patch age $PATCH_AGE days — update soon."
        deduct 10
    else
        ok "System patched $PATCH_AGE day(s) ago — up to date."
        tee_report "  [OK] Patch age ${PATCH_AGE}d — current."
    fi
fi

# ── Pending Security Updates ──────────────────────────────────────────────────
section "PENDING SECURITY UPDATES" | tee -a "$REPORT_FILE"

count_pending_security() {
    case "$PKG_MGR" in
        apt)
            apt-get -s upgrade 2>/dev/null \
                | grep -c "^Inst" || true
            ;;
        dnf)
            dnf check-update --security -q 2>/dev/null \
                | grep -c "^[a-zA-Z]" || true
            ;;
        yum)
            yum check-update --security -q 2>/dev/null \
                | grep -c "^[a-zA-Z]" || true
            ;;
        zypper)
            zypper list-patches --category security 2>/dev/null \
                | grep -c "^|" || true
            ;;
        *) echo -1 ;;
    esac
}

list_pending_security() {
    case "$PKG_MGR" in
        apt)
            apt-get -s upgrade 2>/dev/null | grep "^Inst" | head -20 || true
            ;;
        dnf)
            dnf check-update --security -q 2>/dev/null | head -20 || true
            ;;
        yum)
            yum check-update --security -q 2>/dev/null | head -20 || true
            ;;
        zypper)
            zypper list-patches --category security 2>/dev/null | head -20 || true
            ;;
    esac
}

log "Checking for pending security updates (may take a moment)..."
PENDING=$(count_pending_security)

if [[ "$PENDING" -eq -1 ]]; then
    tee_report "  [INFO] Package manager $PKG_MGR not supported for security check."
elif [[ "$PENDING" -eq 0 ]]; then
    ok "No pending security updates."
    tee_report "  [OK] 0 pending security updates."
else
    critical "$PENDING pending security update(s) found!"
    tee_report "  [CRITICAL] $PENDING pending security updates."
    deduct $(( PENDING > 10 ? 30 : PENDING * 2 ))

    tee_report ""
    tee_report "  --- Top pending security packages ---"
    list_pending_security | while read -r line; do
        tee_report "    $line"
    done
fi

# =============================================================================
# SECTION 5 — DISK HEALTH
# =============================================================================
section "DISK HEALTH" | tee -a "$REPORT_FILE"

tee_report "  Filesystem Usage:"
df -h --output=source,fstype,size,used,avail,pcent,target 2>/dev/null \
    | grep -v "^Filesystem\|tmpfs\|udev\|overlay" \
    | while IFS= read -r line; do
        PUSE=$(echo "$line" | awk '{print $6}' | tr -d '%')
        if [[ "$PUSE" =~ ^[0-9]+$ ]]; then
            if   [[ $PUSE -ge $DISK_CRIT_PERCENT ]]; then
                tee_report "  [CRITICAL] $line"
                deduct 20
            elif [[ $PUSE -ge $DISK_WARN_PERCENT ]]; then
                tee_report "  [WARN]     $line"
                deduct 10
            else
                tee_report "  [OK]       $line"
            fi
        fi
    done

# =============================================================================
# SECTION 6 — MEMORY & SWAP
# =============================================================================
section "MEMORY & SWAP" | tee -a "$REPORT_FILE"

MEM_TOTAL=$(awk '/MemTotal/  {printf "%.1f", $2/1024}' /proc/meminfo)
MEM_AVAIL=$(awk '/MemAvailable/{printf "%.1f", $2/1024}' /proc/meminfo)
MEM_USED=$(echo "$MEM_TOTAL $MEM_AVAIL" | awk '{printf "%.1f", $1-$2}')
MEM_PCT=$(echo "$MEM_TOTAL $MEM_AVAIL" | awk '{printf "%d", (($1-$2)/$1)*100}')

SWAP_TOTAL=$(awk '/SwapTotal/{printf "%.1f", $2/1024}' /proc/meminfo)
SWAP_FREE=$(awk '/SwapFree/ {printf "%.1f", $2/1024}' /proc/meminfo)

tee_report "  RAM  : ${MEM_USED}MB used / ${MEM_TOTAL}MB total  (${MEM_PCT}% used)"
tee_report "  Swap : ${SWAP_FREE}MB free / ${SWAP_TOTAL}MB total"

if [[ $MEM_PCT -ge 90 ]]; then
    critical "Memory usage critical: ${MEM_PCT}%"
    tee_report "  [CRITICAL] Memory usage ${MEM_PCT}%"
    deduct 15
elif [[ $MEM_PCT -ge 75 ]]; then
    warn "Memory usage elevated: ${MEM_PCT}%"
    tee_report "  [WARN] Memory usage ${MEM_PCT}%"
    deduct 5
else
    ok "Memory usage normal: ${MEM_PCT}%"
    tee_report "  [OK] Memory usage ${MEM_PCT}%"
fi

# =============================================================================
# SECTION 7 — SECURITY AUDIT
# =============================================================================
section "SECURITY AUDIT" | tee -a "$REPORT_FILE"

# ── Failed SSH logins ────────────────────────────────────────────────────────
tee_report "  --- Failed SSH Login Attempts (last 24h) ---"
FAIL_COUNT=0
if [[ -f /var/log/auth.log ]]; then
    FAIL_COUNT=$(awk -v d="$(date --date='24 hours ago' '+%b %_d')" \
        'substr($0,1,6) >= d && /sshd.*Failed/' /var/log/auth.log 2>/dev/null | wc -l || echo 0)
elif [[ -f /var/log/secure ]]; then
    FAIL_COUNT=$(grep -c "Failed password" /var/log/secure 2>/dev/null || echo 0)
fi

tee_report "  Failed logins (24h): $FAIL_COUNT"
if [[ $FAIL_COUNT -gt 100 ]]; then
    critical "High brute-force activity: $FAIL_COUNT failed logins."
    tee_report "  [CRITICAL] Possible brute-force — $FAIL_COUNT failed logins."
    deduct 20
elif [[ $FAIL_COUNT -gt 20 ]]; then
    warn "$FAIL_COUNT failed login attempts detected."
    tee_report "  [WARN] $FAIL_COUNT failed login attempts."
    deduct 10
else
    ok "Failed login count acceptable: $FAIL_COUNT"
fi

# ── Sudo usage ────────────────────────────────────────────────────────────────
tee_report ""
tee_report "  --- Recent Sudo Usage ---"
if [[ -f /var/log/auth.log ]]; then
    grep "sudo:" /var/log/auth.log 2>/dev/null | tail -10 \
        | awk '{print "   ", $0}' >> "$REPORT_FILE" || true
elif [[ -f /var/log/secure ]]; then
    grep "sudo:" /var/log/secure 2>/dev/null | tail -10 \
        | awk '{print "   ", $0}' >> "$REPORT_FILE" || true
else
    tee_report "  [INFO] Auth log not accessible."
fi

# ── World-writable files ──────────────────────────────────────────────────────
tee_report ""
tee_report "  --- World-Writable Files in /etc (potential config tampering) ---"
WW_COUNT=0
if [[ $EUID -eq 0 ]]; then
    WW_FILES=$(find /etc -maxdepth 3 -type f -perm -o+w 2>/dev/null)
    WW_COUNT=$(echo "$WW_FILES" | grep -c . || true)
    if [[ $WW_COUNT -gt 0 ]]; then
        critical "$WW_COUNT world-writable file(s) in /etc!"
        echo "$WW_FILES" | while read -r f; do
            tee_report "  [CRITICAL] World-writable: $f"
        done
        deduct 25
    else
        ok "No world-writable files found in /etc."
        tee_report "  [OK] No world-writable files in /etc."
    fi
else
    tee_report "  [SKIP] Root required for world-writable scan."
fi

# ── SUID/SGID binaries ────────────────────────────────────────────────────────
tee_report ""
tee_report "  --- SUID/SGID Binaries (unexpected can be privilege escalation vectors) ---"
if [[ $EUID -eq 0 ]]; then
    find /usr/bin /usr/sbin /bin /sbin -perm /6000 -type f 2>/dev/null \
        | while read -r f; do
            tee_report "  [INFO] SUID/SGID: $f"
        done
else
    tee_report "  [SKIP] Root required for SUID/SGID scan."
fi

# ── Open listening ports ──────────────────────────────────────────────────────
tee_report ""
tee_report "  --- Open Listening Ports ---"
if command -v ss &>/dev/null; then
    ss -tlnp 2>/dev/null | grep LISTEN | while IFS= read -r line; do
        tee_report "  $line"
    done
elif command -v netstat &>/dev/null; then
    netstat -tlnp 2>/dev/null | grep LISTEN | while IFS= read -r line; do
        tee_report "  $line"
    done
else
    tee_report "  [INFO] Neither ss nor netstat available."
fi

# ── UFW / Firewall status ─────────────────────────────────────────────────────
tee_report ""
tee_report "  --- Firewall Status ---"
if command -v ufw &>/dev/null; then
    UFW_STATUS=$(ufw status 2>/dev/null | head -1)
    tee_report "  UFW: $UFW_STATUS"
    if echo "$UFW_STATUS" | grep -qi "inactive"; then
        critical "UFW firewall is INACTIVE."
        tee_report "  [CRITICAL] Firewall is inactive!"
        deduct 20
    else
        ok "UFW firewall is active."
    fi
elif command -v firewall-cmd &>/dev/null; then
    FW_STATE=$(firewall-cmd --state 2>/dev/null || echo "unknown")
    tee_report "  firewalld: $FW_STATE"
    if [[ "$FW_STATE" != "running" ]]; then
        critical "firewalld is NOT running."
        deduct 20
    fi
elif command -v iptables &>/dev/null; then
    IPTS=$(iptables -L INPUT --line-numbers 2>/dev/null | wc -l)
    tee_report "  iptables INPUT rules: $IPTS"
else
    warn "No firewall management tool detected."
    tee_report "  [WARN] No firewall tool detected (ufw/firewalld/iptables)."
    deduct 15
fi

# ── SELinux / AppArmor ────────────────────────────────────────────────────────
tee_report ""
tee_report "  --- Mandatory Access Control ---"
if command -v getenforce &>/dev/null; then
    SE=$(getenforce 2>/dev/null)
    tee_report "  SELinux: $SE"
    if [[ "$SE" == "Disabled" ]]; then
        warn "SELinux is disabled."
        tee_report "  [WARN] SELinux disabled."
        deduct 10
    fi
elif command -v aa-status &>/dev/null; then
    AA=$(aa-status --enabled 2>/dev/null && echo "enabled" || echo "disabled")
    tee_report "  AppArmor: $AA"
else
    tee_report "  [INFO] SELinux and AppArmor not detected."
fi

# =============================================================================
# SECTION 8 — SERVICE HEALTH
# =============================================================================
section "SERVICE HEALTH" | tee -a "$REPORT_FILE"

if command -v systemctl &>/dev/null; then
    tee_report "  --- Failed Systemd Services ---"
    FAILED_SVCS=$(systemctl list-units --state=failed --no-legend 2>/dev/null | awk '{print $1}')
    FAILED_COUNT=$(echo "$FAILED_SVCS" | grep -c . || true)

    if [[ $FAILED_COUNT -gt 0 ]]; then
        warn "$FAILED_COUNT failed service(s) detected."
        echo "$FAILED_SVCS" | while read -r svc; do
            tee_report "  [WARN] Failed service: $svc"
        done
        deduct $(( FAILED_COUNT * 5 ))
    else
        ok "No failed services."
        tee_report "  [OK] No failed systemd services."
    fi

    tee_report ""
    tee_report "  --- Critical Security Services ---"
    for svc in ssh sshd auditd fail2ban clamav-daemon ufw firewalld; do
        STATUS=$(systemctl is-active "$svc" 2>/dev/null || echo "not-found")
        if [[ "$STATUS" == "active" ]]; then
            tee_report "  [OK]   $svc : $STATUS"
        elif [[ "$STATUS" == "not-found" ]]; then
            tee_report "  [INFO] $svc : not installed"
        else
            tee_report "  [WARN] $svc : $STATUS"
        fi
    done
fi

# =============================================================================
# SECTION 9 — KERNEL & CVE INDICATORS
# =============================================================================
section "KERNEL & CVE INDICATORS" | tee -a "$REPORT_FILE"

tee_report "  Running Kernel : $KERNEL"

# Check if a newer kernel is installed but not booted (common on apt systems)
if command -v dpkg &>/dev/null; then
    INSTALLED_KERNEL=$(dpkg -l 'linux-image-*' 2>/dev/null \
        | awk '/^ii/{print $3}' | sort -V | tail -1)
    tee_report "  Latest Installed Kernel Pkg: ${INSTALLED_KERNEL:-unknown}"
fi

# Spectre / Meltdown mitigations
MITIG_DIR="/sys/devices/system/cpu/vulnerabilities"
if [[ -d "$MITIG_DIR" ]]; then
    tee_report ""
    tee_report "  --- CPU Vulnerability Mitigations ---"
    for vf in "$MITIG_DIR"/*; do
        NAME=$(basename "$vf")
        STATUS=$(cat "$vf" 2>/dev/null || echo "unreadable")
        if echo "$STATUS" | grep -qi "vulnerable\|not affected\|unknown"; then
            tee_report "  $(printf '%-30s' "$NAME") : $STATUS"
        else
            tee_report "  $(printf '%-30s' "$NAME") : $STATUS"
        fi
    done
fi

# =============================================================================
# SECTION 10 — COMPLIANCE SNAPSHOT
# =============================================================================
section "COMPLIANCE SNAPSHOT" | tee -a "$REPORT_FILE"

tee_report "  --- Password Policy (PAM / login.defs) ---"
if [[ -f /etc/login.defs ]]; then
    PASS_MAX=$(awk '/^PASS_MAX_DAYS/{print $2}' /etc/login.defs)
    PASS_MIN=$(awk '/^PASS_MIN_DAYS/{print $2}' /etc/login.defs)
    PASS_WARN=$(awk '/^PASS_WARN_AGE/{print $2}' /etc/login.defs)
    tee_report "  PASS_MAX_DAYS  : ${PASS_MAX:-not set}"
    tee_report "  PASS_MIN_DAYS  : ${PASS_MIN:-not set}"
    tee_report "  PASS_WARN_AGE  : ${PASS_WARN:-not set}"
    if [[ -n "$PASS_MAX" && "$PASS_MAX" -gt 90 ]]; then
        warn "PASS_MAX_DAYS ($PASS_MAX) exceeds 90-day CIS recommendation."
        tee_report "  [WARN] PASS_MAX_DAYS $PASS_MAX > 90 days."
        deduct 5
    fi
fi

tee_report ""
tee_report "  --- Users with UID 0 (root equivalents) ---"
awk -F: '($3==0){print "  [ALERT] UID-0 user: "$1}' /etc/passwd | tee -a "$REPORT_FILE"

tee_report ""
tee_report "  --- Accounts with Empty Passwords ---"
EMPTY_PASS=$(awk -F: '($2=="" || $2=="!!" ){print $1}' /etc/shadow 2>/dev/null || echo "")
if [[ -n "$EMPTY_PASS" ]]; then
    critical "Accounts with empty/locked passwords found!"
    echo "$EMPTY_PASS" | while read -r u; do
        tee_report "  [CRITICAL] No password: $u"
    done
    deduct 30
else
    ok "No accounts with empty passwords."
    tee_report "  [OK] No empty-password accounts."
fi

# =============================================================================
# SECTION 11 — AUDIT SCORE & SUMMARY
# =============================================================================
section "AUDIT SCORE & SUMMARY" | tee -a "$REPORT_FILE"

# Clamp score
[[ $SCORE -lt 0 ]] && SCORE=0

if   [[ $SCORE -ge 90 ]]; then GRADE="A — Excellent";   LEVEL="LOW RISK"
elif [[ $SCORE -ge 75 ]]; then GRADE="B — Good";        LEVEL="LOW-MEDIUM RISK"
elif [[ $SCORE -ge 60 ]]; then GRADE="C — Fair";        LEVEL="MEDIUM RISK"
elif [[ $SCORE -ge 40 ]]; then GRADE="D — Poor";        LEVEL="HIGH RISK"
else                            GRADE="F — Critical";    LEVEL="CRITICAL RISK"
fi

tee_report ""
tee_report "  ┌──────────────────────────────────────────┐"
tee_report "  │  HEALTH SCORE : ${SCORE}/100                    │"
tee_report "  │  GRADE        : ${GRADE}               │"
tee_report "  │  RISK LEVEL   : ${LEVEL}                  │"
tee_report "  │  TOTAL FINDINGS: ${FINDINGS}                       │"
tee_report "  └──────────────────────────────────────────┘"

tee_report ""
tee_report "  Recommendations:"
[[ $UPTIME_DAYS    -ge $UPTIME_THRESHOLD_DAYS ]] && tee_report "  -> Schedule immediate reboot to apply pending kernel updates."
[[ $PATCH_AGE      -ge $PATCH_STALENESS_DAYS  ]] && tee_report "  -> Run: sudo $PKG_MGR upgrade  (or security equivalent) immediately."
[[ "${PENDING:-0}" -gt 0                       ]] && tee_report "  -> Apply $PENDING pending security update(s)."
[[ $FAILED_COUNT   -gt 0                       ]] 2>/dev/null && tee_report "  -> Investigate and restart failed systemd services."
[[ $FAIL_COUNT     -gt 20                      ]] && tee_report "  -> Review /etc/ssh/sshd_config; consider fail2ban or key-only auth."

tee_report ""
tee_report "============================================================"
tee_report " Report saved to : $REPORT_FILE"
tee_report " Audit completed : $(date)"
tee_report "============================================================"

# =============================================================================
# SECTION 12 — HTML REPORT
# =============================================================================
generate_html() {
    local score="$1" grade="$2" level="$3"
    local color
    if   [[ $score -ge 90 ]]; then color="#27ae60"
    elif [[ $score -ge 75 ]]; then color="#2980b9"
    elif [[ $score -ge 60 ]]; then color="#f39c12"
    elif [[ $score -ge 40 ]]; then color="#e67e22"
    else                           color="#c0392b"
    fi

    cat > "$HTML_REPORT" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Blue Team — System Health Report</title>
<style>
  body{font-family:'Courier New',monospace;background:#0d1117;color:#c9d1d9;margin:0;padding:20px}
  h1{color:#58a6ff;border-bottom:2px solid #30363d;padding-bottom:10px}
  h2{color:#79c0ff;margin-top:30px;border-left:4px solid #58a6ff;padding-left:10px}
  .score{display:inline-block;background:${color};color:#fff;font-size:2em;padding:10px 30px;border-radius:8px;margin:10px 0}
  .ok{color:#3fb950}.warn{color:#d29922}.critical{color:#f85149}.info{color:#79c0ff}
  pre{background:#161b22;border:1px solid #30363d;padding:15px;border-radius:6px;overflow-x:auto;white-space:pre-wrap}
  table{width:100%;border-collapse:collapse;margin-top:10px}
  th{background:#161b22;color:#58a6ff;padding:8px;text-align:left;border:1px solid #30363d}
  td{padding:8px;border:1px solid #30363d}
  .meta{color:#8b949e;font-size:0.9em}
  footer{margin-top:40px;color:#8b949e;font-size:0.85em;border-top:1px solid #30363d;padding-top:10px}
</style>
</head>
<body>
<h1>Blue Team — System Health &amp; Patch Audit Report</h1>
<p class="meta">Generated: $AUDIT_START | Host: $HOSTNAME | Auditor: $CURRENT_USER</p>

<h2>Audit Score</h2>
<div class="score">${score}/100 — ${grade}</div>
<p>Risk Level: <strong>${level}</strong> | Total Findings: <strong>${FINDINGS}</strong></p>

<h2>System Information</h2>
<table>
<tr><th>Field</th><th>Value</th></tr>
<tr><td>OS</td><td>$OS_NAME</td></tr>
<tr><td>Kernel</td><td>$KERNEL</td></tr>
<tr><td>Architecture</td><td>$ARCH</td></tr>
<tr><td>Hostname</td><td>$HOSTNAME</td></tr>
<tr><td>Package Manager</td><td>$PKG_MGR</td></tr>
</table>

<h2>Uptime &amp; Patch Status</h2>
<table>
<tr><th>Metric</th><th>Value</th><th>Status</th></tr>
<tr><td>System Uptime</td><td>$RAW_UPTIME ($UPTIME_DAYS days)</td>
  <td class="$([ $UPTIME_DAYS -ge $UPTIME_THRESHOLD_DAYS ] && echo critical || echo ok)">
    $([ $UPTIME_DAYS -ge $UPTIME_THRESHOLD_DAYS ] && echo "CRITICAL" || echo "OK")</td></tr>
<tr><td>Last Patch</td><td>${PATCH_AGE} day(s) ago</td>
  <td class="$([ $PATCH_AGE -ge $PATCH_STALENESS_DAYS ] && echo critical || echo ok)">
    $([ $PATCH_AGE -ge $PATCH_STALENESS_DAYS ] && echo "STALE" || echo "CURRENT")</td></tr>
<tr><td>Pending Security Updates</td><td>${PENDING:-unknown}</td>
  <td class="$([ "${PENDING:-0}" -gt 0 ] && echo critical || echo ok)">
    $([ "${PENDING:-0}" -gt 0 ] && echo "ACTION REQUIRED" || echo "NONE")</td></tr>
</table>

<h2>Full Audit Log</h2>
<pre>$(cat "$REPORT_FILE" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')</pre>

<footer>Blue Team Audit Script | Report: $REPORT_FILE | HTML: $HTML_REPORT</footer>
</body>
</html>
EOF
}

generate_html "$SCORE" "$GRADE" "$LEVEL"
log "HTML report saved to: $HTML_REPORT"
