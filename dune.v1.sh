#!/bin/bash
set -euo pipefail

# ==================== КОНФИГУРАЦИЯ ====================
S3_ENDPOINT="https://coca-cola.obs.ru-moscow-1.hc.sbercloud.ru"
S3_CREDENTIALS_FILE="/etc/s3_credentials.conf"  # Формат: ACCESS_KEY=xxx\nSECRET_KEY=yyy
TMP_DIR="/tmp"                                  # Каталог для временных файлов
OUTPUT_DIR="./restored_data"                    # Куда распаковывать

# ==================== ИНИЦИАЛИЗАЦИЯ ====================
echo "Введите путь к бэкапу в формате s3://bucket/path/to/file.enc:"
read -r S3_PATH

# Парсинг S3 пути
if [[ ! "$S3_PATH" =~ ^s3://([^/]+)/(.+)$ ]]; then
    echo "❌ Неверный формат пути. Ожидается: s3://bucket/path/to/file.enc"
    exit 1
fi

BUCKET="${BASH_REMATCH[1]}"
OBJECT_PATH="${BASH_REMATCH[2]}"
BACKUP_NAME=$(basename "$OBJECT_PATH" .enc)
LOG_FILE="./restore_${BACKUP_NAME}_$(date +%Y%m%d_%H%M%S).log"

# Проверка ключа
if [ $# -ne 1 ]; then
    echo "Использование: $0 <ключ_шифрования.key>"
    exit 1
fi
KEYFILE="$1"

# ==================== ФУНКЦИИ ====================
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $@" | tee -a "$LOG_FILE"
}

format_duration() {
    local seconds=$1
    printf "%02dч %02dм %02dс" $((seconds/3600)) $(( (seconds%3600)/60 )) $((seconds%60))
}

check_deps() {
    for cmd in aws openssl pigz tar; do
        if ! command -v $cmd &>/dev/null; then
            log "❌ Отсутствует зависимость: $cmd"
            exit 1
        fi
    done
    log "✅ Все зависимости доступны"
}

# ==================== ОСНОВНОЙ ПРОЦЕСС ====================
main() {
    log "=== НАЧАЛО ВОССТАНОВЛЕНИЯ ==="
    log "🪣 Bucket: $BUCKET"
    log "📂 Object: $OBJECT_PATH"
    log "🔑 Keyfile: $KEYFILE"

    check_deps
    mkdir -p "$TMP_DIR" "$OUTPUT_DIR"

    # 1. Скачивание из S3
    local download_start=$(date +%s.%N)
    local encrypted_file="${TMP_DIR}/${BACKUP_NAME}.enc"

    log "\n=== ЭТАП ЗАГРУЗКИ ИЗ S3 ==="
    source "$S3_CREDENTIALS_FILE"

    AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
    AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
    aws s3 cp "$S3_PATH" "$encrypted_file" \
        --endpoint-url "$S3_ENDPOINT" \
        --region ru-moscow-1 2>&1 | tee -a "$LOG_FILE"

    [ ${PIPESTATUS[0]} -ne 0 ] && {
        log "❌ Ошибка загрузки из S3"
        exit 1
    }

    local download_end=$(date +%s.%N)
    local download_dur=$(echo "$download_end - $download_start" | bc | awk '{printf "%.2f", $0}')
    log "✅ Файл скачан за $download_dur сек. ($(numfmt --to=iec $(stat -c %s "$encrypted_file")))"

    # 2. Дешифровка
    local decrypt_start=$(date +%s.%N)
    local archive_file="${TMP_DIR}/${BACKUP_NAME}.tar.gz"

    log "\n=== ЭТАП ДЕШИФРОВАНИЯ ==="
    openssl enc -d -aes-256-cbc -pbkdf2 \
        -in "$encrypted_file" \
        -out "$archive_file" \
        -pass file:"$KEYFILE" 2>&1 | tee -a "$LOG_FILE"

    [ ${PIPESTATUS[0]} -ne 0 ] && {
        log "❌ Ошибка дешифровки"
        exit 1
    }

    local decrypt_end=$(date +%s.%N)
    local decrypt_dur=$(echo "$decrypt_end - $decrypt_start" | bc | awk '{printf "%.2f", $0}')
    log "✅ Файл дешифрован за $decrypt_dur сек."

    # 3. Распаковка
    local extract_start=$(date +%s.%N)

    log "\n=== ЭТАП РАСПАКОВКИ ==="
    if file "$archive_file" | grep -q "gzip compressed"; then
        log "📦 Распаковка архива..."
        pigz -dc "$archive_file" | tar -xC "$OUTPUT_DIR" 2>&1 | tee -a "$LOG_FILE"
    else
        log "🔄 Извлечение без распаковки..."
        tar -xf "$archive_file" -C "$OUTPUT_DIR" 2>&1 | tee -a "$LOG_FILE"
    fi

    [ ${PIPESTATUS[0]} -ne 0 ] && {
        log "❌ Ошибка распаковки"
        exit 1
    }

    local extract_end=$(date +%s.%N)
    local extract_dur=$(echo "$extract_end - $extract_start" | bc | awk '{printf "%.2f", $0}')
    log "✅ Данные распакованы в $OUTPUT_DIR за $extract_dur сек."

    # Итоговая информация
    local total_dur=$(echo "$(date +%s.%N) - $download_start" | bc | awk '{printf "%.0f", $0}')
    log "\n=== СВОДКА ==="
    log "⌛ Общее время: $(format_duration $total_dur)"
    log "📊 Размер данных: $(du -sh "$OUTPUT_DIR" | cut -f1)"
    log "📝 Лог-файл: $LOG_FILE"

    # Очистка
    rm -f "$encrypted_file" "$archive_file"
    log "\n🧹 Временные файлы удалены"
    log "=== ВОССТАНОВЛЕНИЕ УСПЕШНО ЗАВЕРШЕНО ==="
}

# Запуск
main