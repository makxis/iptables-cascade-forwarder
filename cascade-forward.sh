#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="Каскадное перенаправление"
RULE_TAG="cascade-rule"

HAS_WHIPTAIL=0
if command -v whiptail >/dev/null 2>&1; then
    HAS_WHIPTAIL=1
fi

# -------------------- БАЗОВЫЕ ФУНКЦИИ --------------------

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "Ошибка: скрипт нужно запускать от root." >&2
        exit 1
    fi
}

require_commands() {
    local missing=()
    local cmd
    for cmd in iptables ip awk grep sed; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        echo "Ошибка: отсутствуют команды: ${missing[*]}" >&2
        exit 1
    fi
}

pause() {
    read -r -p "Нажмите Enter для продолжения..." _
}

msg() {
    local text="$1"
    if (( HAS_WHIPTAIL )); then
        whiptail --title "$APP_NAME" --msgbox "$text" 16 90
    else
        echo
        echo "$text"
        echo
        pause
    fi
}

confirm() {
    local text="$1"
    if (( HAS_WHIPTAIL )); then
        whiptail --title "$APP_NAME" --yesno "$text" 16 90
    else
        local ans
        echo
        read -r -p "$text [y/N]: " ans
        [[ "$ans" =~ ^([yY]|[дД])$ ]]
    fi
}

prompt() {
    local text="$1"
    local default="${2:-}"
    local result=""

    if (( HAS_WHIPTAIL )); then
        result=$(whiptail --title "$APP_NAME" --inputbox "$text" 12 90 "$default" 3>&1 1>&2 2>&3) || return 1
    else
        echo
        read -r -p "$text ${default:+[$default]}: " result
        result="${result:-$default}"
    fi

    printf '%s' "$result"
}

show_text() {
    local content="$1"
    local tmp
    tmp=$(mktemp)
    printf '%s\n' "$content" > "$tmp"

    if (( HAS_WHIPTAIL )); then
        whiptail --title "$APP_NAME" --scrolltext --textbox "$tmp" 26 100
    else
        clear
        cat "$tmp"
        echo
        pause
    fi

    rm -f "$tmp"
}

# -------------------- ВАЛИДАЦИЯ --------------------

validate_ip() {
    local ip="$1"
    local IFS=.
    local -a octets

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    read -r -a octets <<< "$ip"

    local o
    for o in "${octets[@]}"; do
        [[ "$o" =~ ^[0-9]+$ ]] || return 1
        (( o >= 0 && o <= 255 )) || return 1
    done

    return 0
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 ))
}

validate_proto() {
    local proto="$1"
    [[ "$proto" == "tcp" || "$proto" == "udp" ]]
}

get_default_iface() {
    ip route get 1.1.1.1 2>/dev/null | awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev") {
                    print $(i+1)
                    exit
                }
            }
        }
    '
}

# -------------------- СИСТЕМНАЯ ПОДГОТОВКА --------------------

ensure_ip_forward() {
    local current
    current="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"

    if [[ "$current" == "1" ]]; then
        return 0
    fi

    if confirm "Сейчас IP forwarding выключен.

Что это значит:
- без него сервер не сможет пересылать трафик дальше;
- скрипт не заработает, пока пересылка не будет включена.

Если продолжить:
- параметр net.ipv4.ip_forward будет включён сразу;
- настройка будет сохранена в /etc/sysctl.d/99-cascade-forward.conf.

Включить IP forwarding?"; then
        cat > /etc/sysctl.d/99-cascade-forward.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
        sysctl --system >/dev/null
    else
        msg "Операция отменена. Без IP forwarding правила перенаправления работать не будут."
        return 1
    fi
}

maybe_install_persistence() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        return 0
    fi

    if ! confirm "Пакет netfilter-persistent не найден.

Что это значит:
- правила будут работать сразу после применения;
- после перезагрузки сервера они, скорее всего, исчезнут.

Для автоматического сохранения после перезагрузки нужен пакет:
iptables-persistent / netfilter-persistent

Попробовать установить сейчас?"; then
        return 0
    fi

    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y iptables-persistent netfilter-persistent
    else
        msg "Автоматическая установка предусмотрена только для Debian/Ubuntu.
Установите пакет netfilter-persistent вручную."
    fi
}

save_rules_if_possible() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || true
        msg "Правила применены и сохранены для перезагрузки."
    else
        msg "Правила применены, но не сохранены для перезагрузки.
Установите netfilter-persistent, если нужна постоянная конфигурация."
    fi
}

firewall_note() {
    local notes=""
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            notes+="\n- UFW активен: входящий порт нужно открыть вручную."
        fi
    fi

    if command -v firewall-cmd >/dev/null 2>&1; then
        if systemctl is-active --quiet firewalld 2>/dev/null; then
            notes+="\n- firewalld активен: входящий порт нужно открыть вручную."
        fi
    fi

    printf '%b' "$notes"
}

# -------------------- IPTABLES --------------------

rule_exists() {
    local table="$1"
    shift
    iptables -t "$table" -C "$@" 2>/dev/null
}

add_rule_if_missing() {
    local table="$1"
    shift
    if ! rule_exists "$table" "$@"; then
        iptables -t "$table" -A "$@"
    fi
}

delete_rule_if_exists() {
    local table="$1"
    shift
    if rule_exists "$table" "$@"; then
        iptables -t "$table" -D "$@"
    fi
}

apply_forward_rule() {
    local proto="$1"
    local in_port="$2"
    local out_port="$3"
    local target_ip="$4"
    local iface="$5"

    add_rule_if_missing nat PREROUTING \
        -p "$proto" --dport "$in_port" \
        -m comment --comment "$RULE_TAG" \
        -j DNAT --to-destination "$target_ip:$out_port"

    add_rule_if_missing nat POSTROUTING \
        -p "$proto" -d "$target_ip" --dport "$out_port" -o "$iface" \
        -m comment --comment "$RULE_TAG" \
        -j MASQUERADE

    add_rule_if_missing filter FORWARD \
        -p "$proto" -d "$target_ip" --dport "$out_port" \
        -m conntrack --ctstate NEW,ESTABLISHED,RELATED \
        -m comment --comment "$RULE_TAG" \
        -j ACCEPT

    add_rule_if_missing filter FORWARD \
        -p "$proto" -s "$target_ip" --sport "$out_port" \
        -m conntrack --ctstate ESTABLISHED,RELATED \
        -m comment --comment "$RULE_TAG" \
        -j ACCEPT
}

remove_forward_rule() {
    local proto="$1"
    local in_port="$2"
    local out_port="$3"
    local target_ip="$4"
    local iface="$5"

    delete_rule_if_exists nat PREROUTING \
        -p "$proto" --dport "$in_port" \
        -m comment --comment "$RULE_TAG" \
        -j DNAT --to-destination "$target_ip:$out_port"

    delete_rule_if_exists nat POSTROUTING \
        -p "$proto" -d "$target_ip" --dport "$out_port" -o "$iface" \
        -m comment --comment "$RULE_TAG" \
        -j MASQUERADE

    delete_rule_if_exists filter FORWARD \
        -p "$proto" -d "$target_ip" --dport "$out_port" \
        -m conntrack --ctstate NEW,ESTABLISHED,RELATED \
        -m comment --comment "$RULE_TAG" \
        -j ACCEPT

    delete_rule_if_exists filter FORWARD \
        -p "$proto" -s "$target_ip" --sport "$out_port" \
        -m conntrack --ctstate ESTABLISHED,RELATED \
        -m comment --comment "$RULE_TAG" \
        -j ACCEPT
}

parse_rule_line() {
    local line="$1"

    PARSED_PROTO=""
    PARSED_IN_PORT=""
    PARSED_TARGET_IP=""
    PARSED_OUT_PORT=""

    [[ "$line" =~ -p[[:space:]]+([a-z]+) ]] && PARSED_PROTO="${BASH_REMATCH[1]}"
    [[ "$line" =~ --dport[[:space:]]+([0-9]+) ]] && PARSED_IN_PORT="${BASH_REMATCH[1]}"
    [[ "$line" =~ --to-destination[[:space:]]+([0-9.]+):([0-9]+) ]] && {
        PARSED_TARGET_IP="${BASH_REMATCH[1]}"
        PARSED_OUT_PORT="${BASH_REMATCH[2]}"
    }
}

get_script_rules() {
    iptables -t nat -S PREROUTING | grep -F -- '--comment "cascade-rule"' || true
}

# -------------------- ИНТЕРАКТИВНЫЕ СЦЕНАРИИ --------------------

show_main_help() {
    show_text "Что делает этот скрипт

Скрипт создаёт каскадное перенаправление трафика через текущий сервер.

Схема работы:
Клиент -> этот сервер -> конечный сервер

Что именно меняется:
1. Включается IP forwarding, если он был выключен.
2. Добавляются правила iptables:
   - DNAT в таблице nat;
   - MASQUERADE для исходящего трафика;
   - FORWARD для пропуска пакетов.
3. Если установлен netfilter-persistent, правила сохраняются после перезагрузки.

Что скрипт НЕ делает:
- не копирует сам себя в систему;
- не включает BBR;
- не меняет UFW/firewalld без вашего подтверждения;
- не добавляет рекламу, ссылки, QR-коды и прочий мусор.

Важно понимать:
- если на этом сервере уже работает сервис на входящем порту,
  новый DNAT может перехватить трафик на этот порт;
- если активен UFW/firewalld, порт может понадобиться открыть вручную;
- удаление правил этого скрипта не отключает IP forwarding обратно."
}

explain_same_port_mode() {
    local name="$1"
    local proto="$2"

    confirm "Будет создано правило для режима: $name

Что произойдёт:
- сервер начнёт принимать $proto-трафик на выбранном входящем порту;
- этот трафик будет перенаправляться на указанный IP;
- входящий и выходящий порт будут одинаковыми;
- будут добавлены правила DNAT, FORWARD и MASQUERADE.

Подходит, если клиент и конечный сервис используют один и тот же порт.

Продолжить?"
}

explain_custom_mode() {
    confirm "Будет создано пользовательское правило.

Что произойдёт:
- сервер примет трафик на одном порту;
- затем отправит его на другой IP и, при необходимости, на другой порт;
- будут добавлены правила DNAT, FORWARD и MASQUERADE.

Подходит для случаев:
- разные входной и выходной порт;
- нестандартные сервисы;
- TCP или UDP на ваш выбор.

Продолжить?"
}

configure_same_port_rule() {
    local name="$1"
    local proto="$2"
    local target_ip=""
    local port=""
    local iface=""

    explain_same_port_mode "$name" "$proto" || return
    ensure_ip_forward || return
    maybe_install_persistence

    while true; do
        target_ip="$(prompt "Введите IP конечного сервера")" || return
        validate_ip "$target_ip" && break
        msg "Некорректный IPv4-адрес. Пример: 203.0.113.10"
    done

    while true; do
        port="$(prompt "Введите порт. Он будет использоваться и на входе, и на выходе")" || return
        validate_port "$port" && break
        msg "Некорректный порт. Допустимый диапазон: 1..65535"
    done

    iface="$(get_default_iface)"
    if [[ -z "$iface" ]]; then
        msg "Не удалось определить основной сетевой интерфейс."
        return
    fi

    if ! confirm "Сейчас будет применено правило:

Протокол: $proto
Входящий порт на этом сервере: $port
Конечный сервер: $target_ip
Выходящий порт на конечном сервере: $port
Сетевой интерфейс для исходящего трафика: $iface

Применить?"; then
        return
    fi

    apply_forward_rule "$proto" "$port" "$port" "$target_ip" "$iface"
    save_rules_if_possible

    local note
    note="$(firewall_note)"

    msg "Правило добавлено.

Схема:
клиент -> этот сервер:$port -> $target_ip:$port ($proto)$note"
}

configure_custom_rule() {
    local proto=""
    local target_ip=""
    local in_port=""
    local out_port=""
    local iface=""

    explain_custom_mode || return
    ensure_ip_forward || return
    maybe_install_persistence

    while true; do
        proto="$(prompt "Введите протокол: tcp или udp" "tcp")" || return
        proto="${proto,,}"
        validate_proto "$proto" && break
        msg "Допустимые значения: tcp или udp"
    done

    while true; do
        target_ip="$(prompt "Введите IP конечного сервера")" || return
        validate_ip "$target_ip" && break
        msg "Некорректный IPv4-адрес. Пример: 203.0.113.10"
    done

    while true; do
        in_port="$(prompt "Введите входящий порт на ЭТОМ сервере")" || return
        validate_port "$in_port" && break
        msg "Некорректный порт. Допустимый диапазон: 1..65535"
    done

    while true; do
        out_port="$(prompt "Введите выходящий порт на КОНЕЧНОМ сервере")" || return
        validate_port "$out_port" && break
        msg "Некорректный порт. Допустимый диапазон: 1..65535"
    done

    iface="$(get_default_iface)"
    if [[ -z "$iface" ]]; then
        msg "Не удалось определить основной сетевой интерфейс."
        return
    fi

    if ! confirm "Сейчас будет применено пользовательское правило:

Протокол: $proto
Входящий порт на этом сервере: $in_port
Конечный сервер: $target_ip
Выходящий порт на конечном сервере: $out_port
Сетевой интерфейс для исходящего трафика: $iface

Применить?"; then
        return
    fi

    apply_forward_rule "$proto" "$in_port" "$out_port" "$target_ip" "$iface"
    save_rules_if_possible

    local note
    note="$(firewall_note)"

    msg "Правило добавлено.

Схема:
клиент -> этот сервер:$in_port -> $target_ip:$out_port ($proto)$note"
}

list_rules() {
    local rules
    rules="$(get_script_rules)"

    if [[ -z "$rules" ]]; then
        msg "Сейчас нет правил, созданных этим скриптом."
        return
    fi

    local output=""
    local line
    while IFS= read -r line; do
        parse_rule_line "$line"
        output+="Протокол: ${PARSED_PROTO}\n"
        output+="Входящий порт: ${PARSED_IN_PORT}\n"
        output+="Назначение: ${PARSED_TARGET_IP}:${PARSED_OUT_PORT}\n"
        output+="----------------------------------------\n"
    done <<< "$rules"

    show_text "$output"
}

delete_single_rule() {
    local iface
    iface="$(get_default_iface)"
    if [[ -z "$iface" ]]; then
        msg "Не удалось определить основной сетевой интерфейс."
        return
    fi

    mapfile -t lines < <(get_script_rules)
    if (( ${#lines[@]} == 0 )); then
        msg "Нет правил для удаления."
        return
    fi

    local items=()
    local i=1
    local line
    for line in "${lines[@]}"; do
        parse_rule_line "$line"
        items+=("$i" "${PARSED_PROTO}: ${PARSED_IN_PORT} -> ${PARSED_TARGET_IP}:${PARSED_OUT_PORT}")
        ((i++))
    done

    local choice=""
    if (( HAS_WHIPTAIL )); then
        choice=$(whiptail --title "$APP_NAME" --menu \
            "Выберите правило для удаления.
Будут удалены только записи, созданные этим скриптом." \
            22 100 12 \
            "${items[@]}" \
            3>&1 1>&2 2>&3) || return
    else
        echo
        echo "Выберите правило для удаления:"
        local idx=1
        for ((idx=1; idx<=${#lines[@]}; idx++)); do
            echo "$idx) ${items[$(( (idx-1)*2 + 1 ))]}"
        done
        read -r -p "Номер правила: " choice
    fi

    [[ "$choice" =~ ^[0-9]+$ ]] || return
    (( choice >= 1 && choice <= ${#lines[@]} )) || return

    parse_rule_line "${lines[$((choice - 1))]}"

    if ! confirm "Будет удалено правило:

${PARSED_PROTO}: ${PARSED_IN_PORT} -> ${PARSED_TARGET_IP}:${PARSED_OUT_PORT}

Удалить?"; then
        return
    fi

    remove_forward_rule "$PARSED_PROTO" "$PARSED_IN_PORT" "$PARSED_OUT_PORT" "$PARSED_TARGET_IP" "$iface"
    save_rules_if_possible
    msg "Правило удалено."
}

delete_all_script_rules() {
    local iface
    iface="$(get_default_iface)"
    if [[ -z "$iface" ]]; then
        msg "Не удалось определить основной сетевой интерфейс."
        return
    fi

    mapfile -t lines < <(get_script_rules)
    if (( ${#lines[@]} == 0 )); then
        msg "Нет правил, созданных этим скриптом."
        return
    fi

    if ! confirm "Будут удалены ВСЕ правила, созданные этим скриптом.

Что важно:
- будут затронуты только правила с меткой $RULE_TAG;
- посторонние правила iptables не будут тронуты;
- IP forwarding не будет выключен автоматически.

Удалить все правила этого скрипта?"; then
        return
    fi

    local line
    for line in "${lines[@]}"; do
        parse_rule_line "$line"
        remove_forward_rule "$PARSED_PROTO" "$PARSED_IN_PORT" "$PARSED_OUT_PORT" "$PARSED_TARGET_IP" "$iface"
    done

    save_rules_if_possible
    msg "Все правила этого скрипта удалены."
}

# -------------------- МЕНЮ --------------------

main_menu() {
    while true; do
        local choice=""

        if (( HAS_WHIPTAIL )); then
            choice=$(whiptail --title "$APP_NAME" --menu \
                "Выберите действие" \
                22 100 12 \
                "1" "WireGuard / AmneziaWG (UDP, одинаковый входной/выходной порт)" \
                "2" "VLESS / XRay (TCP, одинаковый входной/выходной порт)" \
                "3" "MTProto / TProxy (TCP, одинаковый входной/выходной порт)" \
                "4" "Пользовательское правило (TCP/UDP, можно указать разные порты)" \
                "5" "Показать правила, созданные этим скриптом" \
                "6" "Удалить одно правило" \
                "7" "Удалить все правила этого скрипта" \
                "8" "Справка: что именно делает скрипт" \
                "0" "Выход" \
                3>&1 1>&2 2>&3) || break
        else
            clear
            cat <<'EOF'
========================================
Каскадное перенаправление
========================================
1) WireGuard / AmneziaWG (UDP, одинаковый порт)
2) VLESS / XRay (TCP, одинаковый порт)
3) MTProto / TProxy (TCP, одинаковый порт)
4) Пользовательское правило (TCP/UDP, разные порты)
5) Показать правила, созданные этим скриптом
6) Удалить одно правило
7) Удалить все правила этого скрипта
8) Справка
0) Выход
EOF
            echo
            read -r -p "Ваш выбор: " choice
        fi

        case "$choice" in
            1) configure_same_port_rule "WireGuard / AmneziaWG" "udp" ;;
            2) configure_same_port_rule "VLESS / XRay" "tcp" ;;
            3) configure_same_port_rule "MTProto / TProxy" "tcp" ;;
            4) configure_custom_rule ;;
            5) list_rules ;;
            6) delete_single_rule ;;
            7) delete_all_script_rules ;;
            8) show_main_help ;;
            0) break ;;
        esac
    done
}

# -------------------- ЗАПУСК --------------------

require_root
require_commands
main_menu
