#!/usr/bin/env bash
# Воспроизведение исследования: сборка StarRocks BE 3.5.11 без StarCache
# и запуск, приводящий к SIGSEGV на старте.
# Источник: отчёт, Приложение A (REPORT.md, раздел 13).
#
# Требования: окружение для сборки StarRocks BE (см. документацию StarRocks),
# свободное место под артефакт ~2.2 GB (с debug-информацией).
# Проверялось на Arch Linux x86_64, kernel 6.18.9. Сборка заняла 9 мин 3 с.
#
# Использование:
#   ./reproduce.sh            # все шаги
#   SKIP_BUILD=1 ./reproduce.sh   # только запуск (если BE уже собран)

set -euo pipefail

SRC_DIR="${SRC_DIR:-$PWD/starrocks}"
TEST_DIR="${TEST_DIR:-/tmp/starrocks_test}"
REPRO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Клонирование репозитория (версия 3.5.11)
if [ ! -d "$SRC_DIR" ]; then
    git clone --depth 1 --branch 3.5.11 https://github.com/StarRocks/starrocks.git "$SRC_DIR"
fi
cd "$SRC_DIR"

if [ -z "${SKIP_BUILD:-}" ]; then
    # 2. Резервное копирование и удаление StarCache
    if [ -d thirdparty/installed/starcache ]; then
        cp -r thirdparty/installed/starcache/ "/tmp/starrocks_binary_backup_$(date +%Y%m%d)/"
        rm -rf thirdparty/installed/starcache/
    fi

    # 3. Сборка BE без StarCache
    ./build.sh --be --without-starcache
fi

# 4. Подготовка тестового окружения
mkdir -p "$TEST_DIR"/{data,spill,meta,log}
cp "$REPRO_DIR/be.conf" "$TEST_DIR/be.conf"

# 5. Попытка запуска (воспроизводит SIGSEGV)
echo ">>> Запуск starrocks_be. Ожидаемый результат: Segmentation fault (core dumped)."
set +e
LD_LIBRARY_PATH="$SRC_DIR/be/output/lib:$SRC_DIR/thirdparty/installed/lib:${LD_LIBRARY_PATH:-}" \
    "$SRC_DIR/be/output/lib/starrocks_be" --config_path="$TEST_DIR/be.conf"
rc=$?
set -e
echo ">>> Код возврата: $rc (139 = SIGSEGV)"

# 6. Анализ core dump (Приложение B) — выполняется вручную:
#   zstd -d /var/lib/systemd/coredump/core.starrocks_be.*.zst -o /tmp/core.unpacked
#   gdb -batch -ex "bt full" -ex "info threads" -ex "quit" \
#       "$SRC_DIR/be/output/lib/starrocks_be" /tmp/core.unpacked
