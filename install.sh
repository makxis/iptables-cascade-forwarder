#!/usr/bin/env bash
set -Eeuo pipefail

REPO="makxis/iptables-cascade-forwarder"
BRANCH="main"

SCRIPT_SOURCE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/cascade-forward.sh"
INSTALL_PATH="/usr/local/bin/cascade-forward"

echo "========================================"
echo " Installing iptables-cascade-forwarder"
echo "========================================"
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "[ERROR] Запустите через sudo"
    exit 1
fi

for cmd in wget chmod; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[ERROR] Не найдена команда: $cmd"
        exit 1
    fi
done

cat <<EOF
Будет выполнено:
- скачивание основного скрипта из GitHub
- установка в ${INSTALL_PATH}
- немедленный запуск после установки

После этого скрипт можно будет запускать командой:
  sudo cascade-forward
EOF
echo

read -r -p "Продолжить? [y/N]: " confirm
[[ "$confirm" =~ ^[yY]$ ]] || exit 0

echo "[*] Скачивание..."
wget -qO "${INSTALL_PATH}" "${SCRIPT_SOURCE_URL}"

echo "[*] Установка прав..."
chmod +x "${INSTALL_PATH}"

if [[ ! -f "${INSTALL_PATH}" ]]; then
    echo "[ERROR] Не удалось установить файл"
    exit 1
fi

echo "[OK] Установлено: ${INSTALL_PATH}"
echo
echo "[*] Запуск..."
echo

exec "${INSTALL_PATH}"
