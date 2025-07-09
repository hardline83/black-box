#!/bin/bash
set -euo pipefail

# --- Конфигурация S3 ---
S3_ENDPOINT="coca-cola.obs.ru-moscow-1.hc.sbercloud.ru"
S3_CREDENTIALS_FILE="/etc/s3_credentials.conf"  # Формат: ACCESS_KEY=xxx\nSECRET_KEY=yyy

# Проверка аргументов
if [ "$#" -ne 3 ]; then
    echo "Использование: $0 <исходный_файл_или_папка> <ключ_шифрования.key> <выходной_файл.enc>"
    echo "Пример: $0 /data/large_file.dat /secure/keyfile.key backup_2023.enc"
    exit 1
fi

SOURCE="$1"
KEYFILE="$2"
OUTPUT="$3"
LOG_FILE="${OUTPUT%.*}.log"
HOSTNAME=$(hostname)
BACKUP_DATE=$(date +%Y-%m-%d)
S3_BASE_PATH="s3://$HOSTNAME/$BACKUP_DATE/"

# Проверка учетных данных S3
if [ ! -f "$S3_CREDENTIALS_FILE" ]; then
    echo "❌ Файл учетных данных S3 не найден: $S3_CREDENTIALS_FILE" | tee -a "$LOG_FILE"
    exit 1
fi

# Загрузка данных в S3
upload_to_s3() {
    local file_path=$1
    local s3_path="${S3_BASE_PATH}$(basename "$file_path")"
    
    source "$S3_CREDENTIALS_FILE"
    
    echo "🔼 Загрузка $file_path в S3..." | tee -a "$LOG_FILE"
    
    AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
    AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
    aws s3 cp "$file_path" "$s3_path" \
        --endpoint-url "https://$S3_ENDPOINT" \
        --region ru-moscow-1 2>&1 | tee -a "$LOG_FILE"
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        echo "✅ Успешно загружено: $s3_path" | tee -a "$LOG_FILE"
        echo "🔗 S3 URL: https://${S3_BASE_PATH#s3://}$(basename "$file_path")" | tee -a "$LOG_FILE"
    else
        echo "❌ Ошибка загрузки в S3!" | tee -a "$LOG_FILE"
        return 1
    fi
}

# Инициализация лог-файла
{
    echo "=== НАЧАЛО ОБРАБОТКИ $(date) ==="
    echo "Параметры запуска: $0 $SOURCE $KEYFILE $OUTPUT"
} | tee -a "$LOG_FILE"

# Проверка зависимостей
for cmd in tar openssl pigz; do
    if ! command -v $cmd &> /dev/null; then
        echo "❌ Ошибка: $cmd не установлен" | tee -a "$LOG_FILE"
        exit 1
    fi
done

# Проверка ключа
if [ ! -f "$KEYFILE" ]; then
    echo "❌ Файл ключа $KEYFILE не найден!" | tee -a "$LOG_FILE"
    exit 1
fi

# Функция для двойного вывода
log() {
    echo -e "$@" | tee -a "$LOG_FILE"
}

# Функция для форматирования времени
format_time() {
    local seconds=$1
    local hours=$((seconds/3600))
    local minutes=$(( (seconds%3600)/60 ))
    local secs=$((seconds%60))
    printf "%02d:%02d:%02d" $hours $minutes $secs
}

# Получение размера источника
get_size() {
    if [ -d "$SOURCE" ]; then
        du -sb "$SOURCE" | cut -f1
    else
        stat -c %s "$SOURCE"
    fi
}

TOTAL_SIZE=$(get_size)
log "\n=== ИНФОРМАЦИЯ ОБ ИСТОЧНИКЕ ==="
log "🔹 Источник: $SOURCE"
log "🔹 Тип: $([ -d "$SOURCE" ] && echo "Папка" || echo "Файл")"
log "🔹 Общий размер: $(numfmt --to=iec $TOTAL_SIZE)"

# Временные метки
COMPRESS_START=$(date +%s.%N)

# Потоковая обработка
if [ -d "$SOURCE" ]; then
    COMPRESS_CMD="tar -cf - -C $(dirname "$SOURCE") $(basename "$SOURCE") | pigz -9 -k 2>/dev/null"
else
    COMPRESS_CMD="pigz -9 -k -c $SOURCE 2>/dev/null"
fi

# Этап сжатия
log "\n=== ЭТАП СЖАТИЯ ==="
eval "$COMPRESS_CMD | wc -c > /tmp/compressed_size &"
COMPRESS_PID=$!

# Прогресс-бар с записью в лог
while kill -0 $COMPRESS_PID 2>/dev/null; do
    printf "⏳ Сжатие... [%-50s]\r" $(yes "#" | head -n $((SECONDS%50)) | tr -d '\n')
    sleep 0.5
done

COMPRESS_END=$(date +%s.%N)
COMPRESSED_SIZE=$(cat /tmp/compressed_size)
rm /tmp/compressed_size

COMPRESS_TIME=$(echo "$COMPRESS_END - $COMPRESS_START" | bc)
log "\n🔹 Время сжатия: $(format_time ${COMPRESS_TIME%.*})"
log "🔹 Размер после сжатия: $(numfmt --to=iec $COMPRESSED_SIZE)"
log "🔹 Коэффициент сжатия: $(echo "scale=2; $TOTAL_SIZE/$COMPRESSED_SIZE" | bc)x"

# Этап шифрования
log "\n=== ЭТАП ШИФРОВАНИЯ ==="
ENCRYPT_START=$(date +%s.%N)

eval "$COMPRESS_CMD | openssl enc -aes-256-cbc -salt -pbkdf2 -out $OUTPUT -pass file:$KEYFILE"

ENCRYPT_END=$(date +%s.%N)
ENCRYPT_TIME=$(echo "$ENCRYPT_END - $ENCRYPT_START" | bc)

# Итоговая информация
log "\n=== РЕЗУЛЬТАТ ==="
log "🔹 Итоговый файл: $OUTPUT"
log "🔹 Размер зашифрованного файла: $(du -h $OUTPUT | cut -f1)"
log "🔹 Общее время обработки: $(format_time $(echo "$ENCRYPT_END - $COMPRESS_START" | bc))"
log "🔹 Скорость обработки: $(numfmt --to=iec $(echo "$TOTAL_SIZE/($ENCRYPT_END - $COMPRESS_START)" | bc)/сек"

# Диаграмма времени
log "\n=== ВРЕМЕННАЯ ДИАГРАММА ==="
TOTAL_TIME=$(echo "$ENCRYPT_END - $COMPRESS_START" | bc)
COMPRESS_PERCENT=$(echo "scale=1; $COMPRESS_TIME*100/$TOTAL_TIME" | bc)
ENCRYPT_PERCENT=$(echo "scale=1; $ENCRYPT_TIME*100/$TOTAL_TIME" | bc)

log "Сжатие  [$(printf '%*s' ${COMPRESS_PERCENT%.*} '' | tr ' ' '#')] ${COMPRESS_PERCENT}%"
log "Шифров. [$(printf '%*s' ${ENCRYPT_PERCENT%.*} '' | tr ' ' '#')] ${ENCRYPT_PERCENT}%"

# Финализация лога
{
    echo -e "\n=== СИСТЕМНАЯ ИНФОРМАЦИЯ ==="
    echo "Хост: $HOSTNAME"
    echo "ОС: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    echo "CPU: $(lscpu | grep 'Model name' | cut -d':' -f2 | xargs)"
    echo "RAM: $(free -h | awk '/Mem:/ {print $2}')"
    echo "Диски:"
    df -h | grep -v "tmpfs" | tee -a "$LOG_FILE"
    echo -e "\n=== ЗАВЕРШЕНО $(date) ==="
} | tee -a "$LOG_FILE"

# --- Загрузка результатов в S3 ---
echo -e "\n=== ЗАГРУЗКА В S3 ===" | tee -a "$LOG_FILE"

# Создание структуры каталогов в S3
AWS_ACCESS_KEY_ID=$(grep ACCESS_KEY "$S3_CREDENTIALS_FILE" | cut -d'=' -f2) \
AWS_SECRET_ACCESS_KEY=$(grep SECRET_KEY "$S3_CREDENTIALS_FILE" | cut -d'=' -f2) \
aws s3api put-object \
    --bucket "$HOSTNAME" \
    --key "$BACKUP_DATE/" \
    --endpoint-url "https://$S3_ENDPOINT" \
    --region ru-moscow-1 >/dev/null 2>&1 || true

# Загрузка файлов
upload_to_s3 "$OUTPUT"
upload_to_s3 "$LOG_FILE"

# Итоговое сообщение
echo -e "\n=== РЕЗЮМЕ ===" | tee -a "$LOG_FILE"
echo "Архив: $OUTPUT" | tee -a "$LOG_FILE"
echo "Лог-файл: $LOG_FILE" | tee -a "$LOG_FILE"
echo "S3 Location: https://$S3_ENDPOINT/$HOSTNAME/$BACKUP_DATE/" | tee -a "$LOG_FILE"