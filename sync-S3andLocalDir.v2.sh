#!/bin/bash
set -euo pipefail
sync_time_start=$(date +%s.%N)

# ==================== КОНФИГУРАЦИЯ ====================
OBS_BUCKET="black-box"
OBS_CONFIG_FILE="$HOME/.obsutilconfig"
MAX_RETRIES=3
LOCAL_DIR="/backup-data/S3-1"
TG_BOT_TOKEN="6735752447:AAFyoJcKxorLSdqaJbs73IV-fY28TJMIA4Y"
TG_CHAT_ID="816382525"
TG_API_URL="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
HOSTNAME=$(hostname)
TIMESTAMP=$(date +%Y%m%d)
LOG_FILE="/var/log/obs_sync_${TIMESTAMP}.log"

# ==================== ФУНКЦИИ ====================
log() {
    local message="$*"
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${message}" | tee -a "$LOG_FILE"
}

send_telegram() {
    local message="$1"
    curl -s -X POST "$TG_API_URL" \
        -d chat_id="$TG_CHAT_ID" \
        -d text="$message" \
        -d parse_mode="Markdown" >/dev/null 2>&1
}

format_duration() {
    local seconds=${1%.*}
    printf "%02dч %02dм %02dс" $((seconds/3600)) $(( (seconds%3600)/60 )) $((seconds%60))
}

format_bytes() {
    numfmt --to=iec --suffix=B "$1"
}

check_deps() {
    local missing=()
    for cmd in obsutil; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log "❌ Отсутствуют зависимости: ${missing[*]}"
        send_telegram "*🚫 Ошибка синхронизации*
*Хост:* \`${HOSTNAME}\`
*Проблема:* Отсутствуют зависимости - ${missing[*]}"
        exit 1
    fi
    log "✅ Все зависимости доступны"

    if [ ! -f "$OBS_CONFIG_FILE" ]; then
        log "❌ Конфигурационный файл obsutil не найден: $OBS_CONFIG_FILE"
        send_telegram "*🚫 Ошибка синхронизации*
*Хост:* \`${HOSTNAME}\`
*Проблема:* Отсутствует конфиг obsutil"
        exit 1
    fi
}

check_disk_space() {
    log "🔍 Проверка места на диске и размера бакета"
    
    # Получаем размер бакета в байтах из stat
    local bucket_size_bytes=$(obsutil stat "obs://${OBS_BUCKET}" -config="$OBS_CONFIG_FILE" | awk '/^Size:/ {print $2}')
    
    if [ -z "$bucket_size_bytes" ] || [ "$bucket_size_bytes" -eq 0 ]; then
        log "⚠️ Не удалось получить размер бакета или бакет пуст"
        bucket_size_bytes=0
    fi
    
    # Получаем доступное место на диске в байтах
    local available_space_bytes=$(df -k --output=avail "$LOCAL_DIR" | awk 'NR==2 {print $1 * 1024}')
    
    # Добавляем 10% запаса к размеру бакета
    local required_space=$((bucket_size_bytes * 11 / 10))
    
    log "📊 Статистика:"
    log "• Размер бакета: $(format_bytes "$bucket_size_bytes")"
    log "• Требуется места (с запасом 10%): $(format_bytes "$required_space")"
    log "• Доступно места: $(format_bytes "$available_space_bytes")"
    
    if [ "$available_space_bytes" -lt "$required_space" ]; then
        local msg="❌ Недостаточно места в $LOCAL_DIR. Требуется: $(format_bytes "$required_space"), доступно: $(format_bytes "$available_space_bytes")"
        log "$msg"
        send_telegram "*🚫 Ошибка синхронизации*
*Хост:* \`${HOSTNAME}\`
*Проблема:* $msg
*Размер бакета:* \`$(format_bytes "$bucket_size_bytes")\`
*Требуется места:* \`$(format_bytes "$required_space")\` (с запасом 10%)
*Доступно места:* \`$(format_bytes "$available_space_bytes")\`"
        exit 1
    fi
    
    log "✅ Достаточно места для синхронизации"
}

sync_obs_to_local() {
    local attempt=0
    local success=false

    log "🔄 Начало синхронизации obs://${OBS_BUCKET} -> ${LOCAL_DIR}"
    send_telegram "*🔄 Начата синхронизация OBS*
*Хост:* \`${HOSTNAME}\`
*Источник:* \`obs://${OBS_BUCKET}\`
*Назначение:* \`${LOCAL_DIR}\`"

    while [ $attempt -lt $MAX_RETRIES ] && [ "$success" = false ]; do
        ((attempt++))
        local sync_start=$(date +%s.%N)
        log "🔄 Попытка $attempt/$MAX_RETRIES: синхронизация obs://${OBS_BUCKET} -> ${LOCAL_DIR}"

        if obsutil sync "obs://${OBS_BUCKET}" "$LOCAL_DIR" \
           -config="$OBS_CONFIG_FILE" >> "$LOG_FILE" 2>&1
        then
            local sync_end=$(date +%s.%N)
            local sync_dur=$(echo "$sync_end - $sync_start" | bc -l 2>/dev/null || echo 0)
            log "✅ Синхронизация успешно завершена за $(format_duration "$sync_dur")"
            success=true
        else
            local sync_end=$(date +%s.%N)
            local sync_dur=$(echo "$sync_end - $sync_start" | bc -l 2>/dev/null || echo 0)
            log "⚠️ Ошибка при синхронизации, попытка $attempt/$MAX_RETRIES (время: $(format_duration "$sync_dur"))"
            sleep $((attempt * 10))
        fi
    done

    if [ "$success" = false ]; then
        log "❌ Не удалось выполнить синхронизацию после $MAX_RETRIES попыток"
        send_telegram "*🚫 Ошибка синхронизации*
*Хост:* \`${HOSTNAME}\`
*Источник:* \`obs://${OBS_BUCKET}\`
*Назначение:* \`${LOCAL_DIR}\`
*Попыток:* $MAX_RETRIES"
        return 1
    fi

    return 0
}

calculate_stats() {
    log "📊 Расчет статистики синхронизации"

    local total_files=$(find "$LOCAL_DIR" -type f | wc -l)
    local total_size=$(du -sh "$LOCAL_DIR" | awk '{print $1}')

    log "📌 Итоговая статистика:"
    log "• Всего файлов в локальном каталоге: $total_files"
    log "• Общий размер: $total_size"

    local sync_time_end=$(date +%s.%N)
    local sync_dur=$(echo "$sync_time_end - $sync_time_start" | bc -l 2>/dev/null || echo 0)

    local tg_message="*✅ Синхронизация OBS завершена*
*Хост:* \`${HOSTNAME}\`
*Источник:* \`obs://${OBS_BUCKET}\`
*Назначение:* \`${LOCAL_DIR}\`
*Общее время:* \`$(format_duration "$sync_dur")\`
*Всего файлов:* \`$total_files\`
*Общий размер:* \`$total_size\`
*Лог-файл:* \`${LOG_FILE}\`"

    send_telegram "$tg_message"
}

# ==================== ОСНОВНОЙ ПРОЦЕСС ====================
main() {
    log "=== НАЧАЛО СИНХРОНИЗАЦИИ OBS S3 ==="
    log "🖥️ Хост: $HOSTNAME"
    log "📦 Источник: obs://${OBS_BUCKET}"
    log "📂 Назначение: $LOCAL_DIR"

    check_deps
    check_disk_space

    mkdir -p "$LOCAL_DIR"
    log "📂 Локальный каталог готов: $LOCAL_DIR"

    if ! sync_obs_to_local; then
        exit 1
    fi

    calculate_stats

    log "=== СИСТЕМНАЯ ИНФОРМАЦИЯ ==="
    log "ОС: $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)"
    log "Свободное место: $(df -h "$LOCAL_DIR" | awk 'NR==2 {print $4}')"
    log "Лог-файл: $LOG_FILE"

    log "=== СИНХРОНИЗАЦИЯ ЗАВЕРШЕНА ==="
}

if ! main; then
    log "❌ Критическая ошибка! Скрипт завершен с ошибкой."
    send_telegram "*🚫 Синхронизация OBS завершена с ошибкой*
*Хост:* \`${HOSTNAME}\`
*Источник:* \`obs://${OBS_BUCKET}\`
*Лог-файл:* \`${LOG_FILE}\`"
    exit 1
fi

exit 0