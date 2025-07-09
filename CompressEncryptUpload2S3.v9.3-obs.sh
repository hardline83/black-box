#!/bin/bash
set -euo pipefail
total_time_start=$(date +%s.%N)

# ==================== КОНФИГУРАЦИЯ ====================
OBS_BUCKET="coca-cola"
OBS_CONFIG_FILE="$HOME/.obsutilconfig"
COMPRESS_LEVEL=6
MAX_RETRIES=3
TMP_DIR="/backup-data/tmp"
CHUNK_SIZE="100MB"

# Telegram Notifications
TG_BOT_TOKEN="6735752447:AAFyoJcKxorLSdqaJbs73IV-fY28TJMIA4Y"
TG_CHAT_ID="816382525"
TG_API_URL="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"

# ==================== ИНИЦИАЛИЗАЦИЯ ====================
SOURCE="$1"
KEYFILE="$2"
HOSTNAME=$(hostname)
BACKUP_DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="backup_${HOSTNAME}_${TIMESTAMP}"
ARCHIVE_FILE="${TMP_DIR}/${BACKUP_NAME}.tar.gz"
ENCRYPTED_FILE="${TMP_DIR}/${BACKUP_NAME}.enc"
LOG_FILE="/backup-data/dev-blackbox/${BACKUP_NAME}.log"
PART_PREFIX="${TMP_DIR}/${BACKUP_NAME}_part_"

mkdir -p "$(dirname "$LOG_FILE")" "$TMP_DIR"

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

convert_to_bytes() {
    local size=$1
    echo "$size" | awk '{
        if ($0 ~ /[0-9]+K$/) {size=$0+0; size=size*1024}
        else if ($0 ~ /[0-9]+M$/) {size=$0+0; size=size*1024*1024}
        else if ($0 ~ /[0-9]+G$/) {size=$0+0; size=size*1024*1024*1024}
        else if ($0 ~ /[0-9]+T$/) {size=$0+0; size=size*1024*1024*1024*1024}
        else {size=$0+0}
        print size
    }' | tr -d '[:alpha:]'
}

check_deps() {
    local missing=()
    for cmd in tar pigz openssl obsutil split; do
        if ! command -v $cmd &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log "❌ Отсутствуют зависимости: ${missing[*]}"
        send_telegram "*🚫 Ошибка резервного копирования*\n*Хост:* \`${HOSTNAME}\`\n*Проблема:* Отсутствуют зависимости - ${missing[*]}"
        exit 1
    fi
    log "✅ Все зависимости доступны"
    
    if [ ! -f "$OBS_CONFIG_FILE" ]; then
        log "❌ Конфигурационный файл obsutil не найден: $OBS_CONFIG_FILE"
        send_telegram "*🚫 Ошибка резервного копирования*\n*Хост:* \`${HOSTNAME}\`\n*Проблема:* Отсутствует конфиг obsutil"
        exit 1
    fi
}

check_disk_space() {
    local needed=$(($(get_size "$SOURCE") * 2 / 1024))
    local available=$(df -k "$TMP_DIR" | awk 'NR==2 {print $4}')

    if [ "$available" -lt "$needed" ]; then
        log "❌ Недостаточно места в $TMP_DIR. Нужно: $(numfmt --to=iec ${needed}K), доступно: $(numfmt --to=iec ${available}K)"
        send_telegram "*🚫 Ошибка резервного копирования*\n*Хост:* \`${HOSTNAME}\`\n*Проблема:* Недостаточно места в $TMP_DIR\nТребуется: $(numfmt --to=iec ${needed}K), Доступно: $(numfmt --to=iec ${available}K)"
        exit 1
    fi
}

get_size() {
    if [ -d "$1" ]; then
        du -sb "$1" | awk '{print $1}'
    else
        stat -c %s "$1"
    fi
}

split_large_file() {
    local input_file="$1"
    local chunk_size="$2"
    local prefix="$3"
    
    local split_start=$(date +%s.%N)
    log "✂️ Начало разбиения файла на части по $chunk_size..."
    
    split -b "$chunk_size" --verbose "$input_file" "$prefix" 2>&1 | tee -a "$LOG_FILE"
    local exit_code=${PIPESTATUS[0]}
    
    local split_end=$(date +%s.%N)
    local split_dur=$(echo "$split_end - $split_start" | bc)
    
    if [ $exit_code -eq 0 ]; then
        log "✅ Файл успешно разбит за $(format_duration ${split_dur%.*})"
    else
        log "❌ Ошибка разбиения файла (код $exit_code)"
        send_telegram "*🚫 Ошибка резервного копирования*\n*Хост:* \`${HOSTNAME}\`\n*Проблема:* Ошибка разбиения файла\nКод ошибки: $exit_code"
        exit 1
    fi
    
    ls "${prefix}"* | sort
}

upload_to_obs() {
    local file="$1"
    local object_path="${BACKUP_DATE}/$(basename "$file")"
    local attempt=0

    log "📤 Начало загрузки части: $(basename "$file") (размер: $(numfmt --to=iec $(get_size "$file")))"

    while [ $attempt -lt $MAX_RETRIES ]; do
        ((attempt++))
        local upload_start=$(date +%s.%N)
        log "🔼 Попытка $attempt/$MAX_RETRIES: загрузка $(basename "$file") -> obs://${OBS_BUCKET}/${HOSTNAME}/${object_path}"

        if obsutil cp "$file" "obs://${OBS_BUCKET}/${HOSTNAME}/${object_path}" \
           -config="$OBS_CONFIG_FILE" >> "$LOG_FILE" 2>&1
        then
            local upload_end=$(date +%s.%N)
            local upload_dur=$(echo "$upload_end - $upload_start" | bc)
            log "✅ Успешно загружено за $(format_duration ${upload_dur%.*})"
            log "🔗 Путь: obs://${OBS_BUCKET}/${HOSTNAME}/${object_path}"
            return 0
        else
            log "⚠️ Ошибка при загрузке части $(basename "$file"), попытка $attempt/$MAX_RETRIES"
            sleep $((attempt * 5))
        fi
    done

    log "❌ Не удалось загрузить часть $(basename "$file") после $MAX_RETRIES попыток"
    send_telegram "*⚠️ Проблема при загрузке в OBS*\n*Хост:* \`${HOSTNAME}\`\n*Файл:* \`$(basename "$file")\`\n*Попыток:* $MAX_RETRIES"
    return 1
}

# ==================== ОСНОВНОЙ ПРОЦЕСС ====================
main() {
    log "=== НАЧАЛО РЕЗЕРВНОГО КОПИРОВАНИЯ ==="
    log "🖥️ Хост: $HOSTNAME"
    log "ℹ️ Источник: $SOURCE"
    log "⚙️ Используется уровень сжатия: $COMPRESS_LEVEL"
    log "ℹ️ Тип: $([ -d "$SOURCE" ] && echo "📂 Каталог" || echo "📄 Файл")"
    log "ℹ️ Размер: $(numfmt --to=iec $(get_size "$SOURCE"))"

    send_telegram "*🔹 Начато резервное копирование*\n*Хост:* \`${HOSTNAME}\`\n*Источник:* \`${SOURCE}\`\n*Размер:* \`$(numfmt --to=iec $(get_size "$SOURCE"))\`"

    check_deps
    check_disk_space

    # 1. Сжатие
    log "\n=== ЭТАП СЖАТИЯ ==="
    local compress_start=$(date +%s.%N)

    if [ -d "$SOURCE" ]; then
        log "🔹 Архивирование каталога..."
        tar -cf - -C "$(dirname "$SOURCE")" "$(basename "$SOURCE")" | \
            pigz -$COMPRESS_LEVEL -k > "$ARCHIVE_FILE"
    else
        log "🔹 Сжатие файла..."
        pigz -$COMPRESS_LEVEL -k -c "$SOURCE" > "$ARCHIVE_FILE"
    fi

    local compress_end=$(date +%s.%N)
    local compress_dur=$(echo "$compress_end - $compress_start" | bc)
    local compressed_size=$(get_size "$ARCHIVE_FILE")

    log "✅ Сжатие завершено за $(format_duration ${compress_dur%.*})"
    log "📊 Результат: $(numfmt --to=iec $compressed_size) (коэф. $(echo "scale=2; $(get_size "$SOURCE")/$compressed_size" | bc)x)"

    # 2. Шифрование
    log "\n=== ЭТАП ШИФРОВАНИЯ ==="
    local encrypt_start=$(date +%s.%N)

    log "🔒 Шифрование с помощью AES-256-CBC..."
    openssl enc -aes-256-cbc -salt -pbkdf2 \
        -in "$ARCHIVE_FILE" \
        -out "$ENCRYPTED_FILE" \
        -pass file:"$KEYFILE"

    local encrypt_end=$(date +%s.%N)
    local encrypt_dur=$(echo "$encrypt_end - $encrypt_start" | bc)

    log "✅ Шифрование завершено за $(format_duration ${encrypt_dur%.*})"
    log "📦 Размер зашифрованного файла: $(numfmt --to=iec $(get_size "$ENCRYPTED_FILE"))"

    # 3. Разбиение на части и загрузка в OBS
    log "\n=== ЭТАП РАЗБИЕНИЯ И ЗАГРУЗКИ В OBS ==="
    local split_upload_start=$(date +%s.%N)
    
    local file_size=$(get_size "$ENCRYPTED_FILE")
    local chunk_size_bytes=$(convert_to_bytes "$CHUNK_SIZE")
    
    if [ "$file_size" -gt "$chunk_size_bytes" ]; then
        log "🔍 Размер файла превышает $CHUNK_SIZE ($(numfmt --to=iec $file_size)), начинаем разбиение..."
        parts=($(split_large_file "$ENCRYPTED_FILE" "$CHUNK_SIZE" "$PART_PREFIX"))
        
        log "\n⬆️ Начало загрузки ${#parts[@]} частей в OBS"
        for part in "${parts[@]}"; do
            log "---"
            log "📦 Обработка части: $(basename "$part") (размер: $(numfmt --to=iec $(get_size "$part")))"
            
            if ! upload_to_obs "$part"; then
                send_telegram "*🚫 Критическая ошибка загрузки*\n*Хост:* \`${HOSTNAME}\`\n*Файл:* \`$(basename "$part")\`\n*Статус:* Прерывание выполнения"
                exit 1
            fi
            rm -f "$part"
            log "🧹 Удалена временная часть: $(basename "$part")"
        done
    else
        log "🔍 Размер файла менее $CHUNK_SIZE ($(numfmt --to=iec $file_size)), загружаем целиком"
        log "---"
        log "📦 Обработка файла: $(basename "$ENCRYPTED_FILE") (размер: $(numfmt --to=iec $file_size))"
        
        if ! upload_to_obs "$ENCRYPTED_FILE"; then
            send_telegram "*🚫 Критическая ошибка загрузки*\n*Хост:* \`${HOSTNAME}\`\n*Файл:* \`$(basename "$ENCRYPTED_FILE")\`\n*Статус:* Прерывание выполнения"
            exit 1
        fi
    fi
    
    # Загружаем лог-файл
    log "\n📝 Загрузка лог-файла в OBS"
    if ! upload_to_obs "$LOG_FILE"; then
        log "⚠️ Не удалось загрузить лог-файл, но продолжаем выполнение"
    fi
    
    local split_upload_end=$(date +%s.%N)
    local split_upload_dur=$(echo "$split_upload_end - $split_upload_start" | bc)
    log "✅ Все этапы загрузки завершены за $(format_duration ${split_upload_dur%.*})"

    # 4. Очистка
    log "\n🧹 Очистка временных файлов"
    rm -f "$ARCHIVE_FILE" "$ENCRYPTED_FILE" "${PART_PREFIX}"*
    log "✅ Временные файлы удалены"

    # Итоговая информация
    total_time_end=$(date +%s.%N)
    total_dur=$(echo "$total_time_end - $total_time_start" | bc)
    log "\n=== СВОДКА ==="
    log "⏳ Общее время выполнения: $(format_duration ${total_dur%.*})"
    log "🗃️ Коэффициент сжатия: $(echo "scale=2; $(get_size "$SOURCE")/$compressed_size" | bc)x"
    log "📝 Лог-файл: $LOG_FILE"
    [ -n "${parts+x}" ] && log "🧩 Количество частей: ${#parts[@]}"

    # Формируем финальное сообщение для Telegram
    local tg_message="*✅ Резервное копирование успешно завершено*\n*Хост:* \`${HOSTNAME}\`\n*Источник:* \`${SOURCE}\`\n*Общее время:* \`$(format_duration ${total_dur%.*})\`\n*Исходный размер:* \`$(numfmt --to=iec $(get_size "$SOURCE"))\`\n*Сжатый размер:* \`$(numfmt --to=iec $compressed_size)\` (\`$(echo "scale=2; $(get_size "$SOURCE")/$compressed_size" | bc)x\`)\n*Зашифрованный файл:* \`$(basename "$ENCRYPTED_FILE")\`"

    if [ -n "${parts+x}" ]; then
        tg_message+="\n*Частей:* \`${#parts[@]}\`"
    fi

    tg_message+="\n*Лог-файл:* \`${LOG_FILE}\`"

    send_telegram "$tg_message"

    # Системная информация
    log "\n=== СИСТЕМНАЯ ИНФОРМАЦИЯ ==="
    log "ОС: $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)"
    log "CPU: $(lscpu | grep 'Model name' | cut -d':' -f2 | xargs)"
    log "RAM: $(free -h | awk '/Mem:/ {print $2}')"
    log "Дисковое пространство:"
    df -h | grep -v "tmpfs" | while read line; do log "$line"; done

    log "\n=== РЕЗЕРВНОЕ КОПИРОВАНИЕ УСПЕШНО ЗАВЕРШЕНО ==="
}

if ! main; then
    log "❌ Критическая ошибка! Скрипт завершен с ошибкой."
    send_telegram "*🚫 Резервное копирование завершено с ошибкой*\n*Хост:* \`${HOSTNAME}\`\n*Источник:* \`${SOURCE}\`\n*Лог-файл:* \`${LOG_FILE}\`\n*Статус:* ❌ Критическая ошибка"
    exit 1
fi

exit 0