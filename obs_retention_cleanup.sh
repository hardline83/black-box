#!/bin/bash
set -euo pipefail

# ==================== КОНФИГУРАЦИЯ ====================
OBS_BUCKET="black-box"
OBS_CONFIG_FILE="$HOME/.obsutilconfig"
RETENTION_DAYS=30
OBS_BASE_PATH="DB-test"

# Telegram Notifications
TG_BOT_TOKEN="7627195198:AAGD3W0IFbk4Ebn23Zfnd1BkgfTYHy_as5s"
TG_CHAT_ID="-1002682982923"
TG_API_URL="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"

# ==================== ФУНКЦИИ ====================
log() {
    local message="$*"
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${message}"
}

send_telegram() {
    local message="$1"
    curl -s -X POST "$TG_API_URL" \
        -d chat_id="$TG_CHAT_ID" \
        -d text="$message" \
        -d parse_mode="Markdown" >/dev/null 2>&1 || log "⚠️ Не удалось отправить сообщение в Telegram"
}

check_deps() {
    local missing=()
    for cmd in obsutil date jq; do
        if ! command -v "$cmd" &>/dev/null; then
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

check_s3_connection() {
    log "🔄 Проверка подключения к OBS S3 (bucket: ${OBS_BUCKET})..."
    
    if obsutil ls "obs://${OBS_BUCKET}" -config="$OBS_CONFIG_FILE" >/dev/null 2>&1; then
        log "✅ Подключение к OBS S3 успешно установлено"
        return 0
    else
        log "❌ Ошибка подключения к OBS S3"
        exit 1
    fi
}

is_valid_date() {
    local date_str="$1"
    if [[ "$date_str" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        date -d "$date_str" >/dev/null 2>&1
        return $?
    fi
    return 1
}

get_host_directories() {
    local base_path="$1"
    log "🔍 Поиск хостов в ${base_path}"
    
    # Используем JSON вывод для надежного парсинга
    obsutil ls "obs://${OBS_BUCKET}/${base_path}" -dir -config="$OBS_CONFIG_FILE" -j 2>/dev/null | \
    jq -r '.Contents[]? | select(.Key != null) | .Key' | \
    grep -E "/[^/]+/$" | \
    awk -F/ '{print $(NF-1)}' | \
    sort -u | \
    while read -r host; do
        if [ -n "$host" ]; then
            echo "${base_path}/${host}"
        fi
    done
}

get_date_directories() {
    local host_path="$1"
    log "📅 Поиск каталогов с датами в ${host_path}"
    
    # Используем JSON вывод для надежного парсинга
    obsutil ls "obs://${OBS_BUCKET}/${host_path}" -dir -config="$OBS_CONFIG_FILE" -j 2>/dev/null | \
    jq -r '.Contents[]? | select(.Key != null) | .Key' | \
    grep -E "/[0-9]{4}-[0-9]{2}-[0-9]{2}/$" | \
    while read -r full_path; do
        local date_str=$(basename "$full_path" | sed 's|/$||')
        if is_valid_date "$date_str"; then
            echo "${full_path} ${date_str}"
        else
            log "⚠️ Пропускаем некорректную дату: ${date_str}"
        fi
    done
}

delete_old_date_directory() {
    local full_path="$1"
    local date_str="$2"
    local cutoff_date=$(date -d "-${RETENTION_DAYS} days" +%Y-%m-%d)
    
    if [[ "$date_str" < "$cutoff_date" ]]; then
        log "🗑️ Удаление старого каталога: ${full_path} (дата: ${date_str})"
        
        # Получаем размер каталога
        local total_size=0
        obsutil ls "obs://${OBS_BUCKET}/${full_path}" -recursive -config="$OBS_CONFIG_FILE" -j 2>/dev/null | \
        jq -r '.Contents[]? | select(.Size != null) | .Size' | \
        while read -r size; do
            total_size=$((total_size + size))
        done
        
        # Удаляем каталог
        if obsutil rm "obs://${OBS_BUCKET}/${full_path}" -config="$OBS_CONFIG_FILE" -f -recursive >/dev/null 2>&1; then
            log "✅ Удалено: ${full_path} ($(numfmt --to=iec "$total_size"))"
            echo "$total_size"
        else
            log "⚠️ Не удалось удалить: ${full_path}"
            echo "0"
        fi
    else
        log "✅ Сохраняем: ${full_path} (дата: ${date_str})"
        echo "0"
    fi
}

clean_host_directory() {
    local host_path="$1"
    local deleted_count=0
    local total_freed=0
    
    log "\n📂 Обработка хоста: ${host_path}"
    
    # Получаем все каталоги с датами для этого хоста
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            read -r date_path date_str <<< "$line"
            freed_size=$(delete_old_date_directory "$date_path" "$date_str")
            if [ "$freed_size" -gt 0 ]; then
                ((deleted_count++))
                total_freed=$((total_freed + freed_size))
            fi
        fi
    done < <(get_date_directories "$host_path")
    
    if [ $deleted_count -gt 0 ]; then
        log "📊 Итог по хосту ${host_path}: удалено ${deleted_count} каталогов, освобождено $(numfmt --to=iec "$total_freed")"
    else
        log "✅ Нет старых каталогов для удаления в ${host_path}"
    fi
    
    echo "$deleted_count $total_freed"
}

clean_empty_host_directories() {
    local base_path="$1"
    
    log "🧽 Проверка пустых хостовых директорий в ${base_path}"
    
    while IFS= read -r host_path; do
        if [ -n "$host_path" ]; then
            # Проверяем, есть ли подкаталоги
            local has_dates=$(obsutil ls "obs://${OBS_BUCKET}/${host_path}" -dir -config="$OBS_CONFIG_FILE" -j 2>/dev/null | \
                            jq -r '.Contents[]? | select(.Key != null) | .Key' | wc -l)
            
            if [ "$has_dates" -eq 0 ]; then
                log "🗑️ Удаление пустой хостовой директории: ${host_path}"
                obsutil rm "obs://${OBS_BUCKET}/${host_path}" -config="$OBS_CONFIG_FILE" -f -folder >/dev/null 2>&1
            fi
        fi
    done < <(get_host_directories "$base_path")
}

# ==================== ОСНОВНОЙ ПРОЦЕСС ====================
main() {
    local total_deleted=0
    local total_freed=0
    local host_count=0
    
    log "=== НАЧАЛО ОЧИСТКИ СТАРЫХ БЭКАПОВ В OBS ==="
    log "🪣 Бакет: $OBS_BUCKET"
    log "📅 Удержание: $RETENTION_DAYS дней"
    log "📁 Базовый путь: $OBS_BASE_PATH"
    log "⏰ Текущая дата: $(date '+%Y-%m-%d')"
    log "📅 Дата отсечения: $(date -d "-${RETENTION_DAYS} days" '+%Y-%m-%d')"
    
    check_deps
    check_s3_connection
    
    # Получаем список всех хостовых директорий
    while IFS= read -r host_path; do
        if [ -n "$host_path" ]; then
            ((host_count++))
            result=$(clean_host_directory "$host_path")
            read -r deleted freed <<< "$result"
            total_deleted=$((total_deleted + deleted))
            total_freed=$((total_freed + freed))
        fi
    done < <(get_host_directories "$OBS_BASE_PATH")
    
    log "🔍 Найдено хостовых директорий: ${host_count}"
    
    # Очищаем пустые хостовые директории
    clean_empty_host_directories "$OBS_BASE_PATH"
    
    # Итоговый отчет
    log "\n=== ИТОГИ ОЧИСТКИ ==="
    log "🗑️ Всего удалено каталогов: ${total_deleted}"
    log "💾 Освобождено места: $(numfmt --to=iec "$total_freed")"
    
    # Отправляем уведомление в Telegram
    if [ $total_deleted -gt 0 ]; then
        local message="*🧹 Очистка старых бэкапов в OBS*
*Бакет:* \`${OBS_BUCKET}\`
*Базовый путь:* \`${OBS_BASE_PATH}\`
*Удержание:* \`${RETENTION_DAYS}\` дней
*Удалено каталогов:* \`${total_deleted}\`
*Освобождено места:* \`$(numfmt --to=iec "$total_freed")\`
*Дата выполнения:* \`$(date '+%Y-%m-%d %H:%M:%S')\`"
        
        send_telegram "$message"
    else
        log "✅ Нет старых бэкапов для удаления"
    fi
    
    log "=== ОЧИСТКА ЗАВЕРШЕНА ==="
}

# Обработка аргументов командной строки
while getopts ":b:d:r:c:" opt; do
    case $opt in
        b) OBS_BUCKET="$OPTARG" ;;
        d) OBS_BASE_PATH="$OPTARG" ;;
        r) RETENTION_DAYS="$OPTARG" ;;
        c) OBS_CONFIG_FILE="$OPTARG" ;;
        \?) echo "Использование: $0 [-b <bucket>] [-d <base_path>] [-r <retention_days>] [-c <config_file>]" >&2; exit 1 ;;
    esac
done

# Запуск основного процесса
if ! main; then
    log "❌ Ошибка при выполнении очистки!"
    exit 1
fi

exit 0