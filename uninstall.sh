#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_PATH="/usr/local/bin/cascade-forward"

if [[ "$EUID" -ne 0 ]]; then
    echo "[ERROR] Запустите через sudo"
    exit 1
fi

if [[ ! -f "${INSTALL_PATH}" ]]; then
    echo "[INFO] Скрипт уже не установлен"
    exit 0
fi

read -r -p "Удалить ${INSTALL_PATH}? [y/N]: " confirm
[[ "$confirm" =~ ^[yY]$ ]] || exit 0

rm -f "${INSTALL_PATH}"

echo "[OK] Удалено"
