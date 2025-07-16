#!/bin/bash
set -euo pipefail
total_time_start=$(date +%s.%N)

source ./config.sh
# Переменные из config.sh
# DB_USER
# DATABASE
# DB_HOST
# DB_PORT
# PGPASSWORD

# ==================== КОНФИГУРАЦИЯ ====================
OBS_BUCKET="black-box"                      # Имя бакета в тенанте sberservice_infra_s3
OBS_CONFIG_FILE="$HOME/.obsutilconfig"      # Путь к конфигурации obsutil
COMPRESS_LEVEL=6                            # Уровень сжатия для архива
MAX_RETRIES=3                               # Количество попыток выгрузки в S3
TMP_DIR="./tmp"                             # Временный каталог для обработки
CHUNK_SIZE="50G"                            # Размер частей для разбиения
KEYFILE="$HOME/encryption.key"              # Путь к ключу openssl
DUMP_DIR="./dump"                           # Директория для дампов БД
ARCHIVE_DIR="./dump_archive"                # Архивная директория
RETENTION_DAYS=3                            # Хранение старых бэкапов (дней)

# ==================== ИНИЦИАЛИЗАЦИЯ ====================
BACKUP_DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date +%Y%m%d)
BACKUP_NAME="backup_${DB_HOST}_${TIMESTAMP}"
ARCHIVE_FILE="${TMP_DIR}/${BACKUP_NAME}.tar.gz"
ENCRYPTED_FILE="${TMP_DIR}/${BACKUP_NAME}.enc"
LOG_FILE="./${BACKUP_NAME}.log"
PART_PREFIX="${TMP_DIR}/${BACKUP_NAME}_part_"
SOURCE_DUMP="${DUMP_DIR}/${DATABASE}.bac"
SOURCE="${ARCHIVE_DIR}/${DATABASE}-${BACKUP_DATE}.bac"

# ==================== ФУНКЦИИ ====================
log() {
    local message
    message="$*"
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${message}" | tee -a "$LOG_FILE"
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

prepare_temp_dir() {
    if [ ! -d "$TMP_DIR" ]; then
        mkdir -p "$TMP_DIR"
        log "✅ Создана временная директория: $TMP_DIR"
    else
        rm -rf "${TMP_DIR:?}/"*
        log "✅ Очищена временная директория: $TMP_DIR"
    fi

    mkdir -p "$(dirname "$LOG_FILE")"
}

check_deps() {
    local missing=()
    for cmd in tar pigz openssl obsutil split pg_dump; do
        if ! command -v $cmd &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log "❌ Отсутствуют зависимости: ${missing[*]}"
        exit 1
    fi
    log "✅ Все зависимости доступны"

    if [ ! -f "$OBS_CONFIG_FILE" ]; then
        log "❌ Конфигурационный файл obsutil не найден: $OBS_CONFIG_FILE"
        exit 1
    fi
}

check_disk_space() {
    local needed=$(($(get_size "$SOURCE") /2 / 1024))
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

clean_old_backups() {
    log "\n=== ПЕРЕНОС СТАРЫХ БЭКАПОВ ==="
    local clean_start=$(date +%s.%N)

    # Перемещение текущего дампа в архив
    log "🔄 Перемещение текущего дампа в архив"
    if [ -f "$SOURCE_DUMP" ]; then
        mv "$SOURCE_DUMP" "$SOURCE"
        log "✅ Файл перемещен: ${SOURCE_DUMP} -> ${SOURCE}"
    else
        log "⚠️ Файл дампа не найден: $SOURCE_DUMP"
    fi

    # Удаление старых бэкапов
    log "🧹 Удаление архивных бэкапов старше $RETENTION_DAYS дней"
    find "$ARCHIVE_DIR" -name "*.bac" -type f -mtime +$RETENTION_DAYS -delete -print | while read -r file; do
        log "🗑️ Удален: $file"
    done

    local clean_end=$(date +%s.%N)
    local clean_dur=$(echo "$clean_end - $clean_start" | bc)
    log "✅ Очистка завершена за $(format_duration ${clean_dur%.*})"
}

create_db_dump() {
    log "\n=== СОЗДАНИЕ ДАМПА БД ==="
    local dump_start=$(date +%s.%N)

    log "🛡️ Начало создания дампа БД ${DATABASE} с хоста ${DB_HOST}"
    export PGPASSWORD

    if pg_dump -U "$DB_USER" "$DATABASE" -h "$DB_HOST" -p "$DB_PORT" > "$SOURCE_DUMP" 2>>"${DUMP_DIR}/pg_dump_error_mes.log"; then
        local dump_end=$(date +%s.%N)
        local dump_dur=$(echo "$dump_end - $dump_start" | bc)
        log "✅ Дамп БД успешно создан за $(format_duration ${dump_dur%.*})"
        log "📊 Размер дампа: $(numfmt --to=iec $(get_size "$SOURCE_DUMP"))"
    else
        log "❌ Ошибка при создании дампа БД (код $?)"
        log "⚠️ Подробности в ${DUMP_DIR}/pg_dump_error_mes.log"
        exit 1
    fi

    unset PGPASSWORD
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
        rm -f "$input_file"
        log "🧹 Удален исходный файл после разбиения: $(basename "$input_file")"
    else
        log "❌ Ошибка разбиения файла (код $exit_code)"
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
        log "🔼 Попытка $attempt/$MAX_RETRIES: загрузка $(basename "$file") -> obs://${OBS_BUCKET}/${DB_HOST}/${object_path}"

        if obsutil cp "$file" "obs://${OBS_BUCKET}/DB/${DB_HOST}/${object_path}" \
           -config="$OBS_CONFIG_FILE" >> "$LOG_FILE" 2>&1
        then
            local upload_end=$(date +%s.%N)
            local upload_dur=$(echo "$upload_end - $upload_start" | bc)
            log "✅ Успешно загружено за $(format_duration ${upload_dur%.*})"
            log "🔗 Путь: obs://${OBS_BUCKET}/${DB_HOST}/${object_path}"
            return 0
        else
            log "⚠️ Ошибка при загрузке части $(basename "$file"), попытка $attempt/$MAX_RETRIES"
            sleep $((attempt * 5))
        fi
    done

    log "❌ Не удалось загрузить часть $(basename "$file") после $MAX_RETRIES попыток"
    return 1
}

upload_all_to_obs() {
    local upload_start=$(date +%s.%N)
    local files=("$TMP_DIR"/*)
    local total_files=${#files[@]}
    local uploaded_files=0

    log "\n⬆️ Начало загрузки $total_files файлов из $TMP_DIR в OBS"

    for file in "${files[@]}"; do
        if [ "$file" = "$LOG_FILE" ]; then
            continue
        fi

        if upload_to_obs "$file"; then
            ((uploaded_files++))
            rm -f "$file"
            log "🧹 Удален временный файл: $(basename "$file")"
        else
            exit 1
        fi
    done

    log "\n📝 Загрузка лог-файла в OBS"
    if upload_to_obs "$LOG_FILE"; then
        ((uploaded_files++))
    else
        log "⚠️ Не удалось загрузить лог-файл, но продолжаем выполнение"
    fi

    local upload_end=$(date +%s.%N)
    local upload_dur=$(echo "$upload_end - $upload_start" | bc)
    log "✅ Загружено $uploaded_files/$total_files файлов за $(format_duration ${upload_dur%.*})"
}

# ==================== ОСНОВНОЙ ПРОЦЕСС ====================
main() {
    log "=== НАЧАЛО РЕЗЕРВНОГО КОПИРОВАНИЯ ==="
    log "🖥️ Хост БД: $DB_HOST"
    log "🗃️ База данных: $DATABASE"
    log "📂 Директория дампов: $DUMP_DIR"
    log "📦 Архивная директория: $ARCHIVE_DIR"

    # 1. Очистка старых бэкапов
    clean_old_backups

    # 2. Создание нового дампа БД
    create_db_dump

    # Подготовка к обработке
    prepare_temp_dir
    check_deps
    check_disk_space

    # 3. Сжатие
    log "\n=== СЖАТИЕ ==="
    local compress_start=$(date +%s.%N)

    log "🔹 Сжатие файла..."
    pigz -$COMPRESS_LEVEL -k -c "$SOURCE" > "$ARCHIVE_FILE"

    local compress_end=$(date +%s.%N)
    local compress_dur=$(echo "$compress_end - $compress_start" | bc)
    local compressed_size=$(get_size "$ARCHIVE_FILE")

    log "✅ Сжатие завершено за $(format_duration ${compress_dur%.*})"
    log "📊 Результат: $(numfmt --to=iec $compressed_size) (коэф. $(echo "scale=2; $(get_size "$SOURCE")/$compressed_size" | bc)x)"

    # 4. Шифрование
    log "\n=== ШИФРОВАНИЕ ==="
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

    rm -f "$ARCHIVE_FILE"
    log "🧹 Удален временный архив: $(basename "$ARCHIVE_FILE")"

    # 5. Разбиение на части (если нужно) и загрузка в OBS
    log "\n=== РАЗБИЕНИЕ И ЗАГРУЗКА В OBS ==="

    local file_size=$(get_size "$ENCRYPTED_FILE")
    local chunk_size_bytes=$(convert_to_bytes "$CHUNK_SIZE")

    if [ "$file_size" -gt "$chunk_size_bytes" ]; then
        log "🔍 Размер файла превышает $CHUNK_SIZE ($(numfmt --to=iec $file_size)), начинаем разбиение..."
        split_large_file "$ENCRYPTED_FILE" "$CHUNK_SIZE" "$PART_PREFIX"
    else
        log "ℹ️ Размер файла не превышает $CHUNK_SIZE, выгружаю как есть"
    fi

    upload_all_to_obs

    # 6. Очистка
    log "\n🧹 Очистка временных файлов"
    rm -f "${TMP_DIR}"/*
    log "✅ Временные файлы удалены"

    # Итоговая информация
    total_time_end=$(date +%s.%N)
    total_dur=$(echo "$total_time_end - $total_time_start" | bc)
    log "\n=== СВОДКА ==="
    log "⏳ Общее время выполнения: $(format_duration ${total_dur%.*})"
    log "🗃️ Коэффициент сжатия: $(echo "scale=2; $(get_size "$SOURCE")/$compressed_size" | bc)x"
    log "📝 Лог-файл: $LOG_FILE"

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
    exit 1
fi

exit 0