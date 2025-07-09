#!/bin/bash
set -euo pipefail
sync_time_start=$(date +%s.%N)

# ==================== КОНФИГУРАЦИЯ ====================
OBS_BUCKET="black-box"
OBS_CONFIG_FILE="$HOME/.obsutilconfig"
MAX_RETRIES=3
LOCAL_DIR="/nsk-black-box"
TG_BOT_TOKEN="6735752447:AAFyoJcKxorLSdqaJbs73IV-fY28TJMIA4Y"
TG_CHAT_ID="816382525"
TG_API_URL="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
HOSTNAME=$(hostname)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="/var/log/obs_sync_${TIMESTAMP}.log"

# ==================== ФУНКЦИИ ====================
log() {
    local message
    message="$*"
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${message}" | tee -a "$LOG_FILE"
}

send_telegram() {
    local message="$1"
    curl -s -X POST "$TG_API_URL" \
        -d chat_id="$TG_CHAT_ID" \
        -d text="$message" \
        -d parse_mode="Markdown" >/dev/null
}

format_duration() {
    local seconds=$1
    printf "%02dч %02dм %02dс" $((seconds/3600)) $(( (seconds%3600)/60 )) $((seconds%60))
}

check_deps() {
    local missing=()
    for cmd in obsutil; do
        if ! command -v $cmd &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log "❌ Отсутствуют зависимости: ${missing[*]}"
        send_telegram "*🚫 Ошибка синхронизации*\n*Хост:* \`${HOSTNAME}\`\n*Проблема:* Отсутствуют зависимости - ${missing[*]}"
        exit 1
    fi
    log "✅ Все зависимости доступны"

    if [ ! -f "$OBS_CONFIG_FILE" ]; then
        log "❌ Конфигурационный файл obsutil не найден: $OBS_CONFIG_FILE"
        send_telegram "*🚫 Ошибка синхронизации*\n*Хост:* \`${HOSTNAME}\`\n*Проблема:* Отсутствует конфиг obsutil"
        exit 1
    fi
}

check_disk_space() {
    local needed=$(df -k "$LOCAL_DIR" | awk 'NR==2 {print $4}')
    if [ "$needed" -lt 1048576 ]; then  # 1GB minimum
        log "❌ Недостаточно места в $LOCAL_DIR. Доступно: $(numfmt --to=iec ${needed}K)"
        send_telegram "*🚫 Ошибка синхронизации*\n*Хост:* \`${HOSTNAME}\`\n*Проблема:* Менее 1GB свободного места в $LOCAL_DIR"
        exit 1
    fi
}

sync_obs_to_local() {
    local attempt=0
    local success=false

    log "🔄 Начало синхронизации obs://${OBS_BUCKET} -> ${LOCAL_DIR}"
    send_telegram "*🔄 Начата синхронизация OBS*\n*Хост:* \`${HOSTNAME}\`\n*Источник:* \`obs://${OBS_BUCKET}\`\n*Назначение:* \`${LOCAL_DIR}\`"

    while [ $attempt -lt $MAX_RETRIES ] && [ "$success" = false ]; do
        ((attempt++))
        local sync_start=$(date +%s.%N)
        log "🔄 Попытка $attempt/$MAX_RETRIES: синхронизация obs://${OBS_BUCKET} -> ${LOCAL_DIR}"

        if obsutil sync "obs://${OBS_BUCKET}" "$LOCAL_DIR" \
           -config="$OBS_CONFIG_FILE" \
           -update \
           -parallel=4 \
           -threshold=16 \
           -flat >> "$LOG_FILE" 2>&1
        then
            local sync_end=$(date +s.%N)
            local sync_dur=$(echo "$sync_end - $sync_start" | bc)
            log "✅ Синхронизация успешно завершена за $(format_duration ${sync_dur%.*})"
            success=true
        else
            local sync_end=$(date +s.%N)
            local sync_dur=$(echo "$sync_end - $sync_start" | bc)
            log "⚠️ Ошибка при синхронизации, попытка $attempt/$MAX_RETRIES (время: $(format_duration ${sync_dur%.*}))"
            sleep $((attempt * 10))
        fi
    done

    if [ "$success" = false ]; then
        log "❌ Не удалось выполнить синхронизацию после $MAX_RETRIES попыток"
        send_telegram "*🚫 Ошибка синхронизации*\n*Хост:* \`${HOSTNAME}\`\n*Источник:* \`obs://${OBS_BUCKET}\`\n*Назначение:* \`${LOCAL_DIR}\`\n*Попыток:* $MAX_RETRIES"
        return 1
    fi

    return 0
}

calculate_stats() {
    log "\n📊 Расчет статистики синхронизации"
    
    local total_files=$(find "$LOCAL_DIR" -type f | wc -l)
    local total_size=$(du -sh "$LOCAL_DIR" | awk '{print $1}')
    local new_files=$(grep -c "Downloaded object" "$LOG_FILE" || echo 0)
    local updated_files=$(grep -c "Updated object" "$LOG_FILE" || echo 0)
    local skipped_files=$(grep -c "Skipped object" "$LOG_FILE" || echo 0)
    local failed_files=$(grep -c "Failed to download object" "$LOG_FILE" || echo 0)

    log "📌 Итоговая статистика:"
    log "• Всего файлов в локальном каталоге: $total_files"
    log "• Общий размер: $total_size"
    log "• Новых файлов загружено: $new_files"
    log "• Файлов обновлено: $updated_files"
    log "• Файлов пропущено (без изменений): $skipped_files"
    log "• Файлов с ошибками загрузки: $failed_files"

    # Формируем сообщение для Telegram
    local sync_time_end=$(date +%s.%N)
    local sync_dur=$(echo "$sync_time_end - $sync_time_start" | bc)
    
    local tg_message="*✅ Синхронизация OBS завершена*
*Хост:* \`${HOSTNAME}\`
*Источник:* \`obs://${OBS_BUCKET}\`
*Назначение:* \`${LOCAL_DIR}\`
*Общее время:* \`$(format_duration ${sync_dur%.*})\`
*Всего файлов:* \`$total_files\`
*Общий размер:* \`$total_size\`
*Новых файлов:* \`$new_files\`
*Обновленных:* \`$updated_files\`
*Пропущено:* \`$skipped_files\`
*Ошибок:* \`$failed_files\`
*Лог-файл:* \`${LOG_FILE}\`"

    send_telegram "$tg_message"
}

# ==================== ОСНОВНОЙ ПРОЦЕСС ====================
main() {
    log "=== НАЧАЛО СИНХРОНИЗАЦИИ OBS S3 ==="
    log "🖥️ Хост: $HOSTNAME"
    log "📦 Источник: obs://${OBS_BUCKET}"
    log "📂 Назначение: $LOCAL_DIR"

    # Проверка зависимостей и свободного места
    check_deps
    check_disk_space

    # Создаем локальный каталог если его нет
    mkdir -p "$LOCAL_DIR"
    log "📂 Локальный каталог готов: $LOCAL_DIR"

    # Выполняем синхронизацию
    if ! sync_obs_to_local; then
        exit 1
    fi

    # Считаем статистику и отправляем отчет
    calculate_stats

    log "\n=== СИСТЕМНАЯ ИНФОРМАЦИЯ ==="
    log "ОС: $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)"
    log "Свободное место: $(df -h $LOCAL_DIR | awk 'NR==2 {print $4}')"
    log "Лог-файл: $LOG_FILE"

    log "\n=== СИНХРОНИЗАЦИЯ УСПЕШНО ЗАВЕРШЕНА ==="
}

# Запуск основного процесса
if ! main; then
    log "❌ Критическая ошибка! Скрипт завершен с ошибкой."
    send_telegram "*🚫 Синхронизация OBS завершена с ошибкой*\n*Хост:* \`${HOSTNAME}\`\n*Источник:* \`obs://${OBS_BUCKET}\`\n*Лог-файл:* \`${LOG_FILE}\`"
    exit 1
fi

exit 0