# caddyctl library module: 30-service.sh
# shellcheck shell=bash
service_ready() {
    command_exists systemctl || command_exists rc-service
}

# ── 服务抽象层（systemd / OpenRC） ──

detect_svc_backend() {
    if [[ -n "${SVC_BACKEND:-}" ]]; then
        return 0
    fi
    if command_exists systemctl; then
        SVC_BACKEND="systemd"
    elif command_exists rc-service; then
        SVC_BACKEND="openrc"
    else
        SVC_BACKEND=""
    fi
}

svc_is_active() {
    detect_svc_backend
    case "$SVC_BACKEND" in
        systemd) systemctl is-active --quiet caddy 2>/dev/null ;;
        openrc)  rc-service -q caddy status >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

_svc_with_timeout() {
    local cmd="$1"; shift
    if [[ "$SVC_BACKEND" == "systemd" ]] && command_exists timeout; then
        local to rc
        to="$(get_systemctl_timeout_seconds)"
        # BusyBox timeout lacks --foreground; detect and skip when unavailable
        local _fg_opt=""
        if timeout --foreground 0 true 2>/dev/null; then
            _fg_opt="--foreground"
        fi
        if timeout $_fg_opt "${to}s" systemctl "$cmd" caddy "$@"; then return 0; fi
        rc=$?
        if (( rc == 124 )); then
            fail "systemctl $cmd 超时（${to}s）"
        else
            fail "systemctl $cmd 执行失败"
        fi
        return "$rc"
    fi
    case "$SVC_BACKEND" in
        systemd) systemctl "$cmd" caddy "$@" ;;
        openrc)  rc-service caddy "$cmd" ;;
        *) fail "未检测到 service manager"; return 1 ;;
    esac
}

svc_reload()     { _svc_with_timeout reload; }
svc_restart()    { _svc_with_timeout restart; }
svc_start()      { _svc_with_timeout start; }
svc_stop()       { _svc_with_timeout stop; }
svc_daemon_reload() {
    detect_svc_backend
    case "$SVC_BACKEND" in
        systemd) systemctl daemon-reload >/dev/null 2>&1 || true ;;
        openrc)  : ;;  # OpenRC has no daemon-reload equivalent
    esac
}

svc_enable() {
    detect_svc_backend
    case "$SVC_BACKEND" in
        systemd) systemctl enable caddy >/dev/null 2>&1 || true ;;
        openrc)  rc-update add caddy default >/dev/null 2>&1 || true ;;
    esac
}

svc_status_show() {
    detect_svc_backend
    case "$SVC_BACKEND" in
        systemd) systemctl status caddy --no-pager ;;
        openrc)  rc-service caddy status ;;
        *) fail "未检测到 service manager"; return 1 ;;
    esac
}

svc_unit_exists() {
    detect_svc_backend
    case "$SVC_BACKEND" in
        systemd) systemctl list-unit-files caddy.service --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq caddy.service ;;
        openrc)  [[ -f /etc/init.d/caddy ]] ;;
        *) return 1 ;;
    esac
}

svc_backend_name() { detect_svc_backend; echo "${SVC_BACKEND:-无}"; }

service_is_active_by_name() {
    local name="$1"
    detect_svc_backend
    case "$SVC_BACKEND" in
        systemd) systemctl is-active --quiet "$name" 2>/dev/null ;;
        openrc)  rc-service -q "$name" status >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

service_is_enabled_by_name() {
    local name="$1"
    detect_svc_backend
    case "$SVC_BACKEND" in
        systemd) systemctl is-enabled --quiet "$name" 2>/dev/null ;;
        openrc)  rc-update show default 2>/dev/null | awk '{print $1}' | grep -Fxq "$name" ;;
        *) return 1 ;;
    esac
}

report_service_state() {
    local name="$1"
    local label="$2"

    if service_is_active_by_name "$name"; then
        echo "[OK] $label 正在运行"
    else
        echo "[WARN] $label 未运行"
    fi

    if service_is_enabled_by_name "$name"; then
        echo "[OK] $label 已设置开机启动"
    else
        echo "[INFO] $label 未设置开机启动或未安装服务单元"
    fi
}

report_conflicting_service_state() {
    local name="$1"
    local label="$2"

    if service_is_active_by_name "$name"; then
        echo "[WARN] $label 正在运行，可能与 Caddy 抢占 80/443 端口"
    else
        echo "[OK] $label 未运行"
    fi

    if service_is_enabled_by_name "$name"; then
        echo "[WARN] $label 已设置开机启动，重启后可能重新抢占端口"
    else
        echo "[OK] $label 未设置开机启动或未安装服务单元"
    fi
}
