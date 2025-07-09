#!/bin/bash
set -euo pipefail

# Конфигурация
S3_ENDPOINT="coca-cola.obs.ru-moscow-1.hc.sbercloud.ru"
S3_CREDENTIALS_FILE="/etc/s3_credentials.conf"  # Формат: ACCESS_KEY=xxx\nSECRET_KEY=yyy
COMPRESS_LEVEL=9                                # Уровень сжатия (1-9)

# Проверка аргументов
if [ "$#" -ne 2 ]; then
    echo "Использование: $0 <исходный_файл_или_папка> <ключ_шифрования.key>"
    echo "Пример: $0 /data/project_files encryption.key"
    exit 1
fi

SOURCE="$1"
KEYFILE="$2"
HOSTNAME=$(hostname)
BACKUP_DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="backup_${HOSTNAME}_${TIMESTAMP}"
ARCHIVE_FILE="/backup-data/dev-blackbox/tmp/${BACKUP_NAME}.tar.gz"
ENCRYPTED_FILE="/backup-data/dev-blackbox/tmp/${BACKUP_NAME}.enc"
LOG_FILE="/backup-data/dev-blackbox/backup_${BACKUP_NAME}.log"

# Инициализация лога
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== НАЧАЛО РЕЗЕРВНОГО КОПИРОВАНИЯ $(date) ==="
echo "Хост: $HOSTNAME"
echo "Источник: $SOURCE"
echo "Тип: $([ -d "$SOURCE" ] && echo "Каталог" || echo "Файл")"

# Проверка зависимостей
check_deps() {
    for cmd in tar pigz openssl aws; do
        if ! command -v $cmd &>/dev/null; then
            echo "❌ Ошибка: $cmd не установлен"
            exit 1
        fi
    done
    echo "✅ Проверка зависимостей успешна"
}
check_deps

# Получение размера
get_size() {
    if [ -d "$1" ]; then
        du -sb "$1" | cut -f1
    else
        stat -c %s "$1"
    fi
}

# Форматирование времени
format_duration() {
    local seconds=$1
    printf "%02d:%02d:%02d" $((seconds/3600)) $(( (seconds%3600)/60 )) $((seconds%60))
}

# Загрузка в S3
upload_to_s3() {
    local file=$1
    local s3_path="s3://${HOSTNAME}/${BACKUP_DATE}/$(basename "$file")"
    
    source "$S3_CREDENTIALS_FILE"
    local start=$(date +%s.%N)
    
    echo "🔼 Начало загрузки $(basename "$file") в S3 ($(numfmt --to=iec $(get_size "$file")))"
    AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
    AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
    aws s3 cp "$file" "$s3_path" \
        --endpoint-url "https://$S3_ENDPOINT" \
        --region ru-moscow-1
    
    local exit_code=$?
    local end=$(date +%s.%N)
    local duration=$(echo "$end - $start" | bc | awk '{printf "%.2f", $0}')
    
    if [ $exit_code -eq 0 ]; then
        echo "✅ Успешно загружено за $duration сек. S3 Path: $s3_path"
        echo "🔗 URL: https://${HOSTNAME}.${S3_ENDPOINT}/${BACKUP_DATE}/$(basename "$file")"
    else
        echo "❌ Ошибка загрузки (код $exit_code)"
        exit 1
    fi
}

# --- ОСНОВНОЙ ПРОЦЕСС ---

# 1. Сжатие
echo -e "\n=== ЭТАП СЖАТИЯ ==="
COMPRESS_START=$(date +%s.%N)
ORIGINAL_SIZE=$(get_size "$SOURCE")

echo "📦 Исходный размер: $(numfmt --to=iec $ORIGINAL_SIZE)"
echo "⚙️ Используется уровень сжатия: $COMPRESS_LEVEL"

if [ -d "$SOURCE" ]; then
    echo "🔹 Архивирование каталога..."
    tar -cf - -C "$(dirname "$SOURCE")" "$(basename "$SOURCE")" | \
        pigz -$COMPRESS_LEVEL -k > "$ARCHIVE_FILE"
else
    echo "🔹 Сжатие файла..."
    pigz -$COMPRESS_LEVEL -k -c "$SOURCE" > "$ARCHIVE_FILE"
fi

COMPRESS_END=$(date +%s.%N)
COMPRESS_DUR=$(echo "$COMPRESS_END - $COMPRESS_START" | bc | awk '{printf "%.2f", $0}')
COMPRESSED_SIZE=$(get_size "$ARCHIVE_FILE")

echo "✅ Сжатие завершено за $COMPRESS_DUR сек."
echo "📊 Результат: $(numfmt --to=iec $COMPRESSED_SIZE) (коэф. $(echo "scale=2; $ORIGINAL_SIZE/$COMPRESSED_SIZE" | bc)x)"

# 2. Шифрование
echo -e "\n=== ЭТАП ШИФРОВАНИЯ ==="
ENCRYPT_START=$(date +%s.%N)

echo "🔒 Шифрование с помощью AES-256-CBC..."
openssl enc -aes-256-cbc -salt -pbkdf2 \
    -in "$ARCHIVE_FILE" \
    -out "$ENCRYPTED_FILE" \
    -pass file:"$KEYFILE"

ENCRYPT_END=$(date +%s.%N)
ENCRYPT_DUR=$(echo "$ENCRYPT_END - $ENCRYPT_START" | bc | awk '{printf "%.2f", $0}')
ENCRYPTED_SIZE=$(get_size "$ENCRYPTED_FILE")

echo "✅ Шифрование завершено за $ENCRYPT_DUR сек."
echo "📦 Размер зашифрованного файла: $(numfmt --to=iec $ENCRYPTED_SIZE)"

# 3. Загрузка в S3
echo -e "\n=== ЭТАП ЗАГРУЗКИ В S3 ==="
upload_to_s3 "$ENCRYPTED_FILE"
upload_to_s3 "$LOG_FILE"

# 4. Очистка
rm -f "$ARCHIVE_FILE" "$ENCRYPTED_FILE"
echo -e "\n⚠️ Временные файлы удалены"

# Итоговая информация
echo -e "\n=== СВОДКА ==="
TOTAL_DUR=$(echo "$(date +%s.%N) - $(echo "$COMPRESS_START" | cut -d'.' -f1)" | bc)
echo "Общее время: $(format_duration $TOTAL_DUR)"
echo "Исходный размер: $(numfmt --to=iec $ORIGINAL_SIZE)"
echo "Финальный размер: $(numfmt --to=iec $ENCRYPTED_SIZE)"
echo "Коэффициент сжатия: $(echo "scale=2; $ORIGINAL_SIZE/$COMPRESSED_SIZE" | bc)x"
echo "Лог-файл: $LOG_FILE"

# Системная информация
echo -e "\n=== СИСТЕМНАЯ ИНФОРМАЦИЯ ==="
echo "ОС: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo "CPU: $(lscpu | grep 'Model name' | cut -d':' -f2 | xargs)"
echo "RAM: $(free -h | awk '/Mem:/ {print $2}')"
echo "Дисковое пространство:"
df -h | grep -v "tmpfs"

echo -e "\n=== РЕЗЕРВНОЕ КОПИРОВАНИЕ УСПЕШНО ЗАВЕРШЕНО $(date) ==="