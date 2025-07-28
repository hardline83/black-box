#!/bin/bash
set -euo pipefail
total_time_start=$(date +%s.%N)

# ИНСТРУКЦИЯ ПО ИСПОЛЬЗОВАНИЮ:
# Обязательный аргумент:
# -c <путь>  Полный путь к config.sh (например: /backup-data/db-prod/db_prod_config.sh)
#
# Флаги для пропуска этапов:
# -s  Пропустить создание дампа БД (будет использован существующий файл)
# -r  Пропустить очистку старых бэкапов
# -t  Проверить подключение к БД и S3, затем выйти (dry-run режим)
#
# Дополнительные параметры:
# -d  Путь к директории DUMP_DIR (по умолчанию: ${SCRIPT_DIR}/dump)
# -a  Путь к директории ARCHIVE_DIR (по умолчанию: ${SCRIPT_DIR}/dump_archive)
# -o  Путь в OBS (по умолчанию: DB/${DB_HOST})
#
# Примеры использования:
# Полный процесс: /opt/backup_scripts/complex_backup.sh -c /etc/backup/configs/db_prod_config.sh
# Пропустить очистку: /opt/backup_scripts/complex_backup.sh -c /path/to/config.sh -r
# Dry-run: /opt/backup_scripts/complex_backup.sh -c /path/to/config.sh -t
# С кастомными путями: /opt/backup_scripts/complex_backup.sh -c /path/to/config.sh -d /mnt/backup/dump -a /mnt/backup/archive -o custom/path

# ==================== ПАРСИНГ АРГУМЕНТОВ ====================
SKIP_DUMP=false
SKIP_CLEAN=false
DRY_RUN=false
CONFIG_FILE=""
CUSTOM_DUMP_DIR=""
CUSTOM_ARCHIVE_DIR=""
CUSTOM_OBS_PATH=""

while getopts ":c:srtd:a:o:" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG" ;;
        s) SKIP_DUMP=true ;;
        r) SKIP_CLEAN=true ;;
        t) DRY_RUN=true ;;
        d) CUSTOM_DUMP_DIR="$OPTARG" ;;
        a) CUSTOM_ARCHIVE_DIR="$OPTARG" ;;
        o) CUSTOM_OBS_PATH="$OPTARG" ;;
        \?) echo "Использование: $0 -c <путь к config.sh> [-s] [-r] [-t] [-d <DUMP_DIR>] [-a <ARCHIVE_DIR>] [-o <OBS_PATH>]" >&2; exit 1 ;;
    esac
done

# Проверка обязательного аргумента -c
if [ -z "$CONFIG_FILE" ]; then
    echo "❌ Ошибка: Не указан путь к config.sh (используйте -c)" >&2
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Ошибка: Файл config.sh не найден: $CONFIG_FILE" >&2
    exit 1
fi

# Определяем базовые каталоги относительно config.sh
SCRIPT_DIR=$(dirname "$(readlink -f "$CONFIG_FILE")")

# Загрузка конфигурации
source "$CONFIG_FILE"

# ==================== КОНФИГУРАЦИЯ ====================
# Все пути вычисляются относительно SCRIPT_DIR
OBS_BUCKET="black-box"
OBS_CONFIG_FILE="$HOME/.obsutilconfig"
COMPRESS_LEVEL=6
MAX_RETRIES=3
TMP_DIR="${SCRIPT_DIR}/tmp"
CHUNK_SIZE="50G"
KEYFILE="$HOME/encryption.key"

# Применяем кастомные пути или используем значения по умолчанию
DUMP_DIR="${CUSTOM_DUMP_DIR:-${SCRIPT_DIR}/dump}"
ARCHIVE_DIR="${CUSTOM_ARCHIVE_DIR:-${SCRIPT_DIR}/dump_archive}"
OBS_BASE_PATH="${CUSTOM_OBS_PATH:-DB/${DB_HOST}}"

RETENTION_DAYS=3

# Telegram Notifications
TG_BOT_TOKEN="7627195198:AAGD3W0IFbk4Ebn23Zfnd1BkgfTYHy_as5s"
TG_CHAT_ID="-1002682982923"
TG_API_URL="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"

# ==================== ИНИЦИАЛИЗАЦИЯ ====================
HOSTNAME=$(hostname)
BACKUP_DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date +%Y%m%d)
BACKUP_NAME="backup_${DB_HOST}_${TIMESTAMP}"
ARCHIVE_FILE="${TMP_DIR}/${BACKUP_NAME}.tar.gz"
ENCRYPTED_FILE="${TMP_DIR}/${BACKUP_NAME}.enc"
LOG_FILE="${SCRIPT_DIR}/log/${BACKUP_NAME}.log"
PART_PREFIX="${TMP_DIR}/${BACKUP_NAME}_part_"
SOURCE_DUMP="${DUMP_DIR}/${DATABASE}.bac"
SOURCE="${ARCHIVE_DIR}/${DATABASE}-${BACKUP_DATE}.bac"

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
        -d parse_mode="Markdown" >/dev/null 2>&1 || log "⚠️ Не удалось отправить сообщение в Telegram"
}

# Функции для работы со временем без использования восьмеричных чисел
get_timestamp() {
    date +%s.%N | tr -d '\n'
}

calculate_duration() {
    local start=$1
    local end=$2
    
    # Разделяем секунды и наносекунды
    local start_sec=${start%.*}
    local start_nsec=${start#*.}
    local end_sec=${end%.*}
    local end_nsec=${end#*.}
    
    # Удаляем ведущие нули, чтобы избежать интерпретации как восьмеричных чисел
    start_sec=${start_sec#0}
    start_nsec=${start_nsec#0}
    end_sec=${end_sec#0}
    end_nsec=${end_nsec#0}
    
    # Если значения пустые после удаления нулей, устанавливаем 0
    start_sec=${start_sec:-0}
    start_nsec=${start_nsec:-0}
    end_sec=${end_sec:-0}
    end_nsec=${end_nsec:-0}
    
    # Вычисляем разницу в секундах и наносекундах
    local sec_diff=$((end_sec - start_sec))
    local nsec_diff=$((end_nsec - start_nsec))
    
    # Корректируем, если наносекунды отрицательные
    if [ "$nsec_diff" -lt 0 ]; then
        nsec_diff=$((nsec_diff + 1000000000))
        sec_diff=$((sec_diff - 1))
    fi
    
    # Возвращаем только целые секунды
    echo "$sec_diff"
}

format_duration() {
    local total_seconds=${1:-0}
    local hours=$((total_seconds / 3600))
    local minutes=$(( (total_seconds % 3600) / 60 ))
    local seconds=$((total_seconds % 60))
    printf "%02dч %02dм %02dс" "$hours" "$minutes" "$seconds"
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

check_db_connection() {
    log "\n=== ПРОВЕРКА ПОДКЛЮЧЕНИЯ К БД ==="
    local check_start=$(get_timestamp)
    
    export PGPASSWORD
    log "🔄 Проверка подключения к БД ${DATABASE} на хосте ${DB_HOST}..."
    
    if psql -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" -d "$DATABASE" -c "SELECT 1;" >/dev/null 2>>"${DUMP_DIR}/db_connection.log"; then
        local check_end=$(get_timestamp)
        local check_dur=$(calculate_duration "$check_start" "$check_end")
        log "✅ Подключение к БД успешно установлено за $(format_duration "$check_dur")"
        return 0
    else
        log "❌ Ошибка подключения к БД (код $?)"
        log "⚠️ Подробности в ${DUMP_DIR}/db_connection.log"
        send_telegram "*🚫 Ошибка подключения к БД*
*Сервер БД:* \`${DB_HOST}\`
*БД:* \`${DATABASE}\`
*Бекап сервер:* \`${HOSTNAME}\`
*Статус:* Проверка подключения не удалась"
        exit 1
    fi
    
    unset PGPASSWORD
}

check_s3_connection() {
    log "\n=== ПРОВЕРКА ПОДКЛЮЧЕНИЯ К OBS S3 ==="
    local check_start=$(get_timestamp)
    
    log "🔄 Проверка подключения к OBS S3 (bucket: ${OBS_BUCKET})..."
    
    if obsutil ls "obs://${OBS_BUCKET}" -config="$OBS_CONFIG_FILE" >/dev/null 2>>"${TMP_DIR}/s3_connection.log"; then
        local check_end=$(get_timestamp)
        local check_dur=$(calculate_duration "$check_start" "$check_end")
        log "✅ Подключение к OBS S3 успешно установлено за $(format_duration "$check_dur")"
        log "ℹ️ Путь для загрузки: obs://${OBS_BUCKET}/${OBS_BASE_PATH}"
        return 0
    else
        log "❌ Ошибка подключения к OBS S3 (код $?)"
        log "⚠️ Подробности в ${TMP_DIR}/s3_connection.log"
        send_telegram "*🚫 Ошибка подключения к OBS S3*
*Сервер БД:* \`${DB_HOST}\`
*Бекап сервер:* \`${HOSTNAME}\`
*Bucket:* \`${OBS_BUCKET}\`
*Статус:* Проверка подключения не удалась"
        exit 1
    fi
}

prepare_directories() {
    # Создаем необходимые каталоги
    mkdir -p "$DUMP_DIR" "$ARCHIVE_DIR" "$(dirname "$LOG_FILE")" "$TMP_DIR"
    log "✅ Проверены/созданы каталоги:"
    log "   - DUMP_DIR: $DUMP_DIR"
    log "   - ARCHIVE_DIR: $ARCHIVE_DIR"
    log "   - LOG_DIR: $(dirname "$LOG_FILE")"
    log "   - TMP_DIR: $TMP_DIR"
}

prepare_temp_dir() {
    if [ ! -d "$TMP_DIR" ]; then
        mkdir -p "$TMP_DIR"
        log "✅ Создана временная директория: $TMP_DIR"
    else
        rm -rf "${TMP_DIR:?}/"*
        log "✅ Очищена временная директория: $TMP_DIR"
    fi
}

check_deps() {
    local missing=()
    for cmd in tar pigz openssl obsutil split pg_dump psql; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log "❌ Отсутствуют зависимости: ${missing[*]}"
        send_telegram "*🚫 Ошибка резервного копирования*
*Сервер БД:* \`${DB_HOST}\`
*Бекап сервер:* \`${HOSTNAME}\`
*Проблема:* Отсутствуют зависимости - ${missing[*]}"
        exit 1
    fi
    log "✅ Все зависимости доступны"

    if [ ! -f "$OBS_CONFIG_FILE" ]; then
        log "❌ Конфигурационный файл obsutil не найден: $OBS_CONFIG_FILE"
        send_telegram "*🚫 Ошибка резервного копирования*
*Сервер БД:* \`${DB_HOST}\`
*Бекап сервер:* \`${HOSTNAME}\`
*Проблема:* Отсутствует конфиг obsutil"
        exit 1
    fi
}

get_root_partition() {
    local path="$1"
    # Получаем корневой раздел для указанного пути
    df -P "$path" | awk 'NR==2 {print $1}'
}

get_largest_backup_size() {
    local dir="$1"
    local max_size=0
    
    # Находим самый большой файл в ARCHIVE_DIR и его размер в байтах
    if [ -d "$dir" ]; then
        max_size=$(find "$dir" -type f -exec stat -c %s {} \; 2>/dev/null | sort -nr | head -1)
        max_size=${max_size:-0}
    fi
    
    echo "$max_size"
}

check_disk_space() {
    # Определяем корневой раздел для TMP_DIR
    local root_partition=$(get_root_partition "$TMP_DIR")
    local root_mount_point=$(df -P "$TMP_DIR" | awk 'NR==2 {print $6}')
    
    # Получаем размер самого большого бэкапа в ARCHIVE_DIR
    local largest_backup=$(get_largest_backup_size "$ARCHIVE_DIR")
    local needed_space=$((largest_backup * 2))  # Умножаем на 2 для запаса
    
    # Получаем доступное место на корневом разделе
    local available_space=$(df -k --output=avail "$root_mount_point" | awk 'NR==2 {print $1}')
    available_space=$((available_space * 1024))  # Конвертируем килобайты в байты
    
    log "\n=== ПРОВЕРКА ДИСКОВОГО ПРОСТРАНСТВА ==="
    log "📌 Корневой раздел: $root_partition (точка монтирования: $root_mount_point)"
    log "📊 Размер самого большого бэкапа: $(numfmt --to=iec "$largest_backup")"
    log "🔍 Требуется места (с запасом): $(numfmt --to=iec "$needed_space")"
    log "💾 Доступно места: $(numfmt --to=iec "$available_space")"
    
    if [ "$available_space" -lt "$needed_space" ]; then
        log "❌ Недостаточно места на диске $root_partition. Нужно: $(numfmt --to=iec "$needed_space"), доступно: $(numfmt --to=iec "$available_space")"
        send_telegram "*🚫 Ошибка резервного копирования*
*Сервер БД:* \`${DB_HOST}\`
*Бекап сервер:* \`${HOSTNAME}\`
*Проблема:* Недостаточно места на диске
*Раздел:* \`$root_partition\` (\`$root_mount_point\`)
*Требуется:* \`$(numfmt --to=iec "$needed_space")\`
*Доступно:* \`$(numfmt --to=iec "$available_space")\`"
        exit 1
    fi
    
    log "✅ Проверка дискового пространства завершена успешно"
}

get_size() {
    if [ -d "$1" ]; then
        du -sb "$1" | awk '{print $1}'
    else
        stat -c %s "$1" 2>/dev/null || echo 0
    fi
}

clean_old_backups() {
    if $SKIP_CLEAN; then
        log "\n=== ПРОПУСК ОЧИСТКИ СТАРЫХ БЭКАПОВ (по запросу пользователя) ==="
        return 0
    fi

    log "\n=== ПЕРЕНОС СТАРЫХ БЭКАПОВ ==="
    local clean_start=$(get_timestamp)

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

    local clean_end=$(get_timestamp)
    local clean_dur=$(calculate_duration "$clean_start" "$clean_end")
    log "✅ Очистка завершена за $(format_duration "$clean_dur")"
}

create_db_dump() {
    if $SKIP_DUMP; then
        log "\n=== ПРОПУСК СОЗДАНИЯ ДАМПА БД (по запросу пользователя) ==="
        
        if [ ! -f "$SOURCE_DUMP" ]; then
            log "❌ Файл дампа не найден: $SOURCE_DUMP"
            send_telegram "*🚫 Ошибка резервного копирования*
*Сервер БД:* \`${DB_HOST}\`
*Бекап сервер:* \`${HOSTNAME}\`
*Проблема:* Файл дампа не найден: $SOURCE_DUMP"
            exit 1
        fi
        
        log "ℹ️ Используется существующий дамп: $SOURCE_DUMP"
        return 0
    fi

    log "\n=== СОЗДАНИЕ ДАМПА БД ==="
    local dump_start=$(get_timestamp)

    log "🛡️ Начало создания дампа БД ${DATABASE} с хоста ${DB_HOST}"
    export PGPASSWORD

    if pg_dump -U "$DB_USER" "$DATABASE" -h "$DB_HOST" -p "$DB_PORT" > "$SOURCE_DUMP" 2>>"${DUMP_DIR}/pg_dump_error_mes.log"; then
        local dump_end=$(get_timestamp)
        local dump_dur=$(calculate_duration "$dump_start" "$dump_end")
        log "✅ Дамп БД успешно создан за $(format_duration "$dump_dur")"
        log "📊 Размер дампа: $(numfmt --to=iec "$(get_size "$SOURCE_DUMP")")"
    else
        log "❌ Ошибка при создании дампа БД (код $?)"
        log "⚠️ Подробности в ${DUMP_DIR}/pg_dump_error_mes.log"
        send_telegram "*🚫 Ошибка создания дампа БД*
*Сервер БД:* \`${DB_HOST}\`
*БД:* \`${DATABASE}\`
*Бекап сервер:* \`${HOSTNAME}\`
*Статус:* Ошибка при создании дампа"
        exit 1
    fi

    unset PGPASSWORD
}

split_large_file() {
    local input_file="$1"
    local chunk_size="$2"
    local prefix="$3"

    local split_start=$(get_timestamp)
    log "✂️ Начало разбиения файла на части по $chunk_size..."

    split -b "$chunk_size" --verbose "$input_file" "$prefix" 2>&1 | tee -a "$LOG_FILE"
    local exit_code=${PIPESTATUS[0]}

    local split_end=$(get_timestamp)
    local split_dur=$(calculate_duration "$split_start" "$split_end")

    if [ $exit_code -eq 0 ]; then
        log "✅ Файл успешно разбит за $(format_duration "$split_dur")"
        rm -f "$input_file"
        log "🧹 Удален исходный файл после разбиения: $(basename "$input_file")"
    else
        log "❌ Ошибка разбиения файла (код $exit_code)"
        send_telegram "*🚫 Ошибка резервного копирования*
*Сервер БД:* \`${DB_HOST}\`
*Бекап сервер:* \`${HOSTNAME}\`
*Проблема:* Ошибка разбиения файла
Код ошибки: $exit_code"
        exit 1
    fi

    ls "${prefix}"* | sort
}

upload_to_obs() {
    local file="$1"
    local object_path="${BACKUP_DATE}/$(basename "$file")"
    local attempt=0
    local upload_dur=0

    log "📤 Начало загрузки части: $(basename "$file") (размер: $(numfmt --to=iec "$(get_size "$file")"))"

    while [ $attempt -lt $MAX_RETRIES ]; do
        ((attempt++))
        local upload_start=$(get_timestamp)
        log "🔼 Попытка $attempt/$MAX_RETRIES: загрузка $(basename "$file") -> obs://${OBS_BUCKET}/${OBS_BASE_PATH}/${object_path}"

        if obsutil cp "$file" "obs://${OBS_BUCKET}/${OBS_BASE_PATH}/${object_path}" \
           -config="$OBS_CONFIG_FILE" >> "$LOG_FILE" 2>&1
        then
            local upload_end=$(get_timestamp)
            upload_dur=$(calculate_duration "$upload_start" "$upload_end")
            log "✅ Успешно загружено за $(format_duration "$upload_dur")"
            log "🔗 Путь: obs://${OBS_BUCKET}/${OBS_BASE_PATH}/${object_path}"
            return 0
        else
            log "⚠️ Ошибка при загрузке части $(basename "$file"), попытка $attempt/$MAX_RETRIES"
            sleep $((attempt * 5))
        fi
    done

    log "❌ Не удалось загрузить часть $(basename "$file") после $MAX_RETRIES попыток"
    send_telegram "*⚠️ Проблема при загрузке в OBS*
*Сервер БД:* \`${DB_HOST}\`
*Бекап сервер:* \`${HOSTNAME}\`
*Файл:* \`$(basename "$file")\`
*Попыток:* $MAX_RETRIES"
    return 1
}

upload_all_to_obs() {
    local upload_start=$(get_timestamp)
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
            send_telegram "*🚫 Критическая ошибка загрузки*
*Сервер БД:* \`${DB_HOST}\`
*Бекап сервер:* \`${HOSTNAME}\`
*Файл:* \`$(basename "$file")\`
*Статус:* Прерывание выполнения"
            exit 1
        fi
    done

    log "\n📝 Загрузка лог-файла в OBS"
    if upload_to_obs "$LOG_FILE"; then
        ((uploaded_files++))
    else
        log "⚠️ Не удалось загрузить лог-файл, но продолжаем выполнение"
    fi

    local upload_end=$(get_timestamp)
    local upload_dur=$(calculate_duration "$upload_start" "$upload_end")
    log "✅ Загружено $uploaded_files/$total_files файлов за $(format_duration "$upload_dur")"
}

# ==================== ОСНОВНОЙ ПРОЦЕСС ====================
main() {
    # Инициализация
    prepare_directories

    log "=== НАЧАЛО РЕЗЕРВНОГО КОПИРОВАНИЯ ==="
    log "🖥️ Хост БД: $DB_HOST"
    log "🏷️ Бекап сервер: $HOSTNAME"
    log "🗃️ База данных: $DATABASE"
    log "📂 Конфигурационный файл: $CONFIG_FILE"
    log "⚙️ Параметры запуска:"
    log "  - Пропуск создания дампа: $SKIP_DUMP"
    log "  - Пропуск очистки: $SKIP_CLEAN"
    log "  - Режим dry-run: $DRY_RUN"
    log "  - DUMP_DIR: $DUMP_DIR"
    log "  - ARCHIVE_DIR: $ARCHIVE_DIR"
    log "  - OBS путь: $OBS_BASE_PATH"

    send_telegram "*🔹 Начато резервное копирование БД*
*Сервер БД:* \`${DB_HOST}\`
*БД:* \`${DATABASE}\`
*Бекап сервер:* \`${HOSTNAME}\`
*Режим:* $($DRY_RUN && echo "Dry-run" || echo "Полный")
*DUMP_DIR:* \`${DUMP_DIR}\`
*ARCHIVE_DIR:* \`${ARCHIVE_DIR}\`
*OBS путь:* \`${OBS_BASE_PATH}\`"

    # Проверка подключения к БД и S3 (если не пропущено создание дампа или dry-run)
    if ! $SKIP_DUMP || $DRY_RUN; then
        check_db_connection
        check_s3_connection
        check_deps
        check_disk_space
        
        if $DRY_RUN; then
            log "\n=== DRY RUN ЗАВЕРШЕН ==="
            log "✅ Проверка подключения к БД и OBS S3 выполнена успешно"
            log "✅ Проверка зависимостей завершена успешно"
            log "✅ Проверка дискового пространства завершена успешно"
            
            # Получаем информацию о дисковом пространстве для отчета
            local root_partition=$(get_root_partition "$TMP_DIR")
            local root_mount_point=$(df -P "$TMP_DIR" | awk 'NR==2 {print $6}')
            local available_space=$(df -k --output=avail "$root_mount_point" | awk 'NR==2 {print $1}')
            available_space=$((available_space * 1024))  # Конвертируем килобайты в байты
            
            send_telegram "*✅ Dry-run проверка завершена*
*Сервер БД:* \`${DB_HOST}\`
*БД:* \`${DATABASE}\`
*Бекап сервер:* \`${HOSTNAME}\`
*Bucket:* \`${OBS_BUCKET}\`
*OBS путь:* \`${OBS_BASE_PATH}\`
*Статус:* Все проверки пройдены успешно

*Информация о диске:*
*Раздел:* \`$root_partition\` (\`$root_mount_point\`)
*Доступно места:* \`$(numfmt --to=iec "$available_space")\`"
            exit 0
        fi
    fi

    # 1. Очистка старых бэкапов (если не пропущена)
    clean_old_backups

    # 2. Создание нового дампа БД (если не пропущено)
    create_db_dump

    # Подготовка к обработке
    prepare_temp_dir

    # 3. Сжатие
    log "\n=== СЖАТИЕ ==="
    local compress_start=$(get_timestamp)

    log "🔹 Сжатие файла..."
    pigz -$COMPRESS_LEVEL -k -c "$SOURCE" > "$ARCHIVE_FILE"

    local compress_end=$(get_timestamp)
    local compress_dur=$(calculate_duration "$compress_start" "$compress_end")
    local compressed_size=$(get_size "$ARCHIVE_FILE")

    log "✅ Сжатие завершено за $(format_duration "$compress_dur")"
    log "📊 Результат: $(numfmt --to=iec "$compressed_size") (коэф. $(echo "scale=2; $(get_size "$SOURCE")/$compressed_size" | bc)x)"

    # 4. Шифрование
    log "\n=== ШИФРОВАНИЕ ==="
    local encrypt_start=$(get_timestamp)

    log "🔒 Шифрование с помощью AES-256-CBC..."
    openssl enc -aes-256-cbc -salt -pbkdf2 \
        -in "$ARCHIVE_FILE" \
        -out "$ENCRYPTED_FILE" \
        -pass file:"$KEYFILE"

    local encrypt_end=$(get_timestamp)
    local encrypt_dur=$(calculate_duration "$encrypt_start" "$encrypt_end")

    log "✅ Шифрование завершено за $(format_duration "$encrypt_dur")"
    log "📦 Размер зашифрованного файла: $(numfmt --to=iec "$(get_size "$ENCRYPTED_FILE")")"

    rm -f "$ARCHIVE_FILE"
    log "🧹 Удален временный архив: $(basename "$ARCHIVE_FILE")"

    # 5. Разбиение на части (если нужно) и загрузка в OBS
    log "\n=== РАЗБИЕНИЕ И ЗАГРУЗКА В OBS ==="

    local file_size=$(get_size "$ENCRYPTED_FILE")
    local chunk_size_bytes=$(convert_to_bytes "$CHUNK_SIZE")

    if [ "$file_size" -gt "$chunk_size_bytes" ]; then
        log "🔍 Размер файла превышает $CHUNK_SIZE ($(numfmt --to=iec "$file_size")), начинаем разбиение..."
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
    total_time_end=$(get_timestamp)
    local total_dur=$(calculate_duration "$total_time_start" "$total_time_end")
    log "\n=== СВОДКА ==="
    log "⏳ Общее время выполнения: $(format_duration "$total_dur")"
    log "🗃️ Коэффициент сжатия: $(echo "scale=2; $(get_size "$SOURCE")/$compressed_size" | bc)x)"
    log "📝 Лог-файл: $LOG_FILE"

    # Финальное сообщение в Telegram
    local tg_message="*✅ Резервное копирование успешно завершено*
*Сервер БД:* \`${DB_HOST}\`
*БД:* \`${DATABASE}\`
*Бекап сервер:* \`${HOSTNAME}\`
*Общее время:* \`$(format_duration "$total_dur")\`
*Исходный размер:* \`$(numfmt --to=iec "$(get_size "$SOURCE")")\`
*Сжатый размер:* \`$(numfmt --to=iec "$compressed_size")\` (\`$(echo "scale=2; $(get_size "$SOURCE")/$compressed_size" | bc)x\`)
*Зашифрованный файл:* \`$(basename "$ENCRYPTED_FILE")\`
*OBS путь:* \`${OBS_BASE_PATH}\`
*Лог-файл:* \`${LOG_FILE}\`"

    send_telegram "$tg_message"

    log "\n=== СИСТЕМНАЯ ИНФОРМАЦИЯ ==="
    log "ОС: $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2 || echo "Неизвестно")"
    log "CPU: $(lscpu | grep 'Model name' | cut -d':' -f2 | xargs || echo "Неизвестно")"
    log "RAM: $(free -h | awk '/Mem:/ {print $2}' || echo "Неизвестно")"
    log "Дисковое пространство:"
    df -h | grep -v "tmpfs" | while read -r line; do log "$line"; done || log "Не удалось получить информацию о дисках"

    log "\n=== РЕЗЕРВНОЕ КОПИРОВАНИЕ УСПЕШНО ЗАВЕРШЕНО ==="
}

# Запуск основного процесса
if ! main; then
    log "❌ Критическая ошибка! Скрипт завершен с ошибкой."
    send_telegram "*🚫 Резервное копирование завершено с ошибкой*
*Сервер БД:* \`${DB_HOST}\`
*БД:* \`${DATABASE}\`
*Бекап сервер:* \`${HOSTNAME}\`
*Лог-файл:* \`${LOG_FILE}\`
*Статус:* ❌ Критическая ошибка"
    exit 1
fi

exit 0