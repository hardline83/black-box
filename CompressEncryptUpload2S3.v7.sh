#!/bin/bash
set -euo pipefail
total_time_start=$(date +%s.%N)

# ==================== КОНФИГУРАЦИЯ ====================
S3_ENDPOINT="coca-cola.obs.ru-moscow-1.hc.sbercloud.ru"
S3_CREDENTIALS_FILE="/etc/s3_credentials.conf"  # Формат: ACCESS_KEY=xxx\nSECRET_KEY=yyy
COMPRESS_LEVEL=6                                # Уровень сжатия (1-9)
MAX_RETRIES=3                                   # Попытки загрузки в S3
TMP_DIR="/backup-data/tmp"                      # Каталог для временных файлов
CHUNK_SIZE="100GB"                              # Размер частей для split

# ==================== ИНИЦИАЛИЗАЦИЯ ====================
SOURCE="$1"
KEYFILE="$2"
HOSTNAME=$(hostname)
BACKUP_DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="backup_${HOSTNAME}_${TIMESTAMP}"
ARCHIVE_FILE="${TMP_DIR}/${BACKUP_NAME}.tar.gz"
ENCRYPTED_FILE="${TMP_DIR}/${BACKUP_NAME}.enc"
LOG_FILE="/backup-data/dev-blackbox/backup_${BACKUP_NAME}.log"
PART_PREFIX="${TMP_DIR}/${BACKUP_NAME}_"                  # Префикс для частей файла

# Создаем лог-каталог если нужно
mkdir -p "$(dirname "$LOG_FILE")" "$TMP_DIR"

# ==================== ФУНКЦИИ ====================
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $@" | tee -a "$LOG_FILE"
}

format_duration() {
    local seconds=$1
    printf "%02dч %02dм %02dс" $((seconds/3600)) $(( (seconds%3600)/60 )) $((seconds%60))
}

check_deps() {
    local missing=()
    for cmd in tar pigz openssl aws split; do
        if ! command -v $cmd &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log "❌ Отсутствуют зависимости: ${missing[*]}"
        exit 1
    fi
    log "✅ Все зависимости доступны"
}

check_disk_space() {
    local needed=$(($(get_size "$SOURCE") * 3 / 1024))  # KB с запасом (x3 для частей)
    local available=$(df -k "$TMP_DIR" | awk 'NR==2 {print $4}')

    if [ "$available" -lt "$needed" ]; then
        log "❌ Недостаточно места в $TMP_DIR. Нужно: $(numfmt --to=iec ${needed}K), доступно: $(numfmt --to=iec ${available}K)"
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
    
    log "✂️ Разбиение файла на части по $chunk_size..."
    local split_start=$(date +%s.%N)
    
    split -b "$chunk_size" --verbose "$input_file" "$prefix" | tee -a "$LOG_FILE"
    
    local split_end=$(date +%s.%N)
    local split_dur=$(echo "$split_end - $split_start" | bc | awk '{printf "%.2f", $0}')
    log "✅ Файл разбит за $split_dur сек."
    
    # Возвращаем список созданных частей
    ls "${prefix}"* | sort
}

upload_to_s3() {
    local file=$1
    local s3_path="s3://${HOSTNAME}/${BACKUP_DATE}/$(basename "$file")"
    local attempt=0

    source "$S3_CREDENTIALS_FILE"

    while [ $attempt -lt $MAX_RETRIES ]; do
        ((attempt++))
        log "🔼 Попытка $attempt/$MAX_RETRIES: загрузка $(basename "$file")"

        if AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
           AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
           aws s3 cp "$file" "$s3_path" \
           --endpoint-url "https://$S3_ENDPOINT" \
           --region ru-moscow-1 >> "$LOG_FILE" 2>&1
        then
            log "✅ Успешно загружено: $s3_path"
            log "🔗 URL: https://${HOSTNAME}.${S3_ENDPOINT}/${BACKUP_DATE}/$(basename "$file")"
            return 0
        fi

        sleep $((attempt * 5))
    done

    log "❌ Не удалось загрузить после $MAX_RETRIES попыток"
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
    local compress_dur=$(echo "$compress_end - $compress_start" | bc | awk '{printf "%.2f", $0}')
    local compressed_size=$(get_size "$ARCHIVE_FILE")

    log "✅ Сжатие завершено за $compress_dur сек."
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
    local encrypt_dur=$(echo "$encrypt_end - $encrypt_start" | bc | awk '{printf "%.2f", $0}')

    log "✅ Шифрование завершено за $encrypt_dur сек."
    log "📦 Размер зашифрованного файла: $(numfmt --to=iec $(get_size "$ENCRYPTED_FILE"))"

    # 3. Разбиение на части и загрузка в S3
    log "\n=== ЭТАП РАЗБИЕНИЯ И ЗАГРУЗКИ В S3 ==="
    local upload_start=$(date +%s.%N)
    
    # Проверяем размер файла для определения необходимости разбиения
    local file_size=$(get_size "$ENCRYPTED_FILE")
    local size_100gb=$((100 * 1024 * 1024 * 1024))  # 100GB в байтах
    
    if [ "$file_size" -gt "$size_100gb" ]; then
        # Разбиваем файл на части
        parts=($(split_large_file "$ENCRYPTED_FILE" "$CHUNK_SIZE" "$PART_PREFIX"))
        
        # Загружаем каждую часть
        for part in "${parts[@]}"; do
            upload_to_s3 "$part"
            rm -f "$part"  # Удаляем часть после загрузки
        done
    else
        # Загружаем целый файл если он меньше 100GB
        upload_to_s3 "$ENCRYPTED_FILE"
    fi
    
    # Загружаем лог-файл
    upload_to_s3 "$LOG_FILE"
    
    local upload_end=$(date +%s.%N)
    local upload_dur=$(echo "$upload_end - $upload_start" | bc | awk '{printf "%.2f", $0}')
    log "✅ Все части загружены за $upload_dur сек."

    # 4. Очистка
    rm -f "$ARCHIVE_FILE" "$ENCRYPTED_FILE" "${PART_PREFIX}"*
    log "✅ Временные файлы удалены"

    # Итоговая информация
    total_time_end=$(date +%s.%N)
    total_dur=$(echo "$total_time_end - $total_time_start" | bc | awk '{printf "%.2f", $0}')
    log "\n=== СВОДКА ==="
    log "⏳ Общее время: $(format_duration ${total_dur%.*})"
    log "🗃️ Коэффициент сжатия: $(echo "scale=2; $(get_size "$SOURCE")/$compressed_size" | bc)x"
    log "📝 Лог-файл: $LOG_FILE"
    [ -n "${parts+x}" ] && log "🧩 Количество частей: ${#parts[@]}"

    # Системная информация
    log "\n=== СИСТЕМНАЯ ИНФОРМАЦИЯ ==="
    log "ОС: $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)"
    log "CPU: $(lscpu | grep 'Model name' | cut -d':' -f2 | xargs)"
    log "RAM: $(free -h | awk '/Mem:/ {print $2}')"
    log "Дисковое пространство:"
    df -h | grep -v "tmpfs" | while read line; do log "$line"; done

    log "\n=== РЕЗЕРВНОЕ КОПИРОВАНИЕ УСПЕШНО ЗАВЕРШЕНО ==="
}

# Запуск с обработкой ошибок
if ! main; then
    log "❌ Критическая ошибка! Скрипт завершен с ошибкой."
    exit 1
fi

exit 0