#!/bin/bash
set -euo pipefail

# ==================== КОНФИГУРАЦИЯ ====================
OBS_BUCKET="black-box"
OBS_CONFIG_FILE="$HOME/.obsutilconfig"
RETENTION_DAYS=30
OBS_BASE_PATH="DB"

# ==================== ФУНКЦИИ ====================
log() {
    local message="$*"
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${message}" >&2
}

print_separator() {
    echo "============================================================" >&2
}

check_deps() {
    local missing=()
    for cmd in obsutil date; do
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
    log "🔍 Поиск хостовых директорий в ${base_path}"
    
    obsutil ls "obs://${OBS_BUCKET}/${base_path}/" -d -config="$OBS_CONFIG_FILE" 2>/dev/null | \
    grep "obs://${OBS_BUCKET}/${base_path}/" | \
    grep -v "obs://${OBS_BUCKET}/${base_path}/$" | \
    while read -r line; do
        if [[ "$line" =~ obs://${OBS_BUCKET}/(.*)/$ ]]; then
            echo "${BASH_REMATCH[1]}"
        fi
    done
}

get_date_directories() {
    local host_path="$1"
    local cutoff_date=$(date -d "-${RETENTION_DAYS} days" +%Y-%m-%d)
    
    log "📅 Поиск каталогов с датами в ${host_path}"
    
    obsutil ls "obs://${OBS_BUCKET}/${host_path}/" -d -config="$OBS_CONFIG_FILE" 2>/dev/null | \
    grep "obs://${OBS_BUCKET}/${host_path}/" | \
    while read -r line; do
        if [[ "$line" =~ obs://${OBS_BUCKET}/(.*)/$ ]]; then
            local full_path="${BASH_REMATCH[1]}"
            local folder_name=$(basename "$full_path")
            
            if is_valid_date "$folder_name"; then
                if [[ "$folder_name" < "$cutoff_date" ]]; then
                    echo "$full_path $folder_name"
                    log "📌 Найден старый каталог: ${full_path} (дата: ${folder_name})"
                else
                    log "✅ Сохраняем актуальный каталог: ${full_path} (дата: ${folder_name})"
                fi
            fi
        fi
    done
}

find_date_folders() {
    local base_path="$1"
    local cutoff_date=$(date -d "-${RETENTION_DAYS} days" +%Y-%m-%d)
    
    log "🔍 Рекурсивный поиск каталогов с датами в ${base_path}"
    
    # Находим все хостовые директории
    while IFS= read -r host_path; do
        if [ -n "$host_path" ]; then
            # Для каждой хостовой директории ищем каталоги с датами
            get_date_directories "$host_path"
        fi
    done < <(get_host_directories "$base_path")
}

get_folder_size() {
    local folder_path="$1"
    local total_size_bytes=0
    
    # Получаем информацию о каталоге
    local output=$(obsutil ls "obs://${OBS_BUCKET}/${folder_path}/" -config="$OBS_CONFIG_FILE" 2>/dev/null)
    
    # Ищем строку с общим размером
    if [[ "$output" =~ Total\ size\ of\ prefix\ .*\ is:\ ([0-9.]+)([KMGT]?B) ]]; then
        local size_value="${BASH_REMATCH[1]}"
        local size_unit="${BASH_REMATCH[2]}"
        
        # Конвертируем в байты
        case "$size_unit" in
            "B")   total_size_bytes=$(echo "$size_value" | awk '{printf "%.0f", $1}') ;;
            "KB")  total_size_bytes=$(echo "$size_value * 1024" | bc | awk '{printf "%.0f", $1}') ;;
            "MB")  total_size_bytes=$(echo "$size_value * 1024 * 1024" | bc | awk '{printf "%.0f", $1}') ;;
            "GB")  total_size_bytes=$(echo "$size_value * 1024 * 1024 * 1024" | bc | awk '{printf "%.0f", $1}') ;;
            "TB")  total_size_bytes=$(echo "$size_value * 1024 * 1024 * 1024 * 1024" | bc | awk '{printf "%.0f", $1}') ;;
            *)     total_size_bytes=0 ;;
        esac
    fi
    
    echo "$total_size_bytes"
}

confirm_deletion() {
    local folders=("$@")
    local total_count=${#folders[@]}
    local total_size=0
    
    if [ $total_count -eq 0 ]; then
        log "✅ Нет старых каталогов для удаления"
        return 1
    fi
    
    echo ""
    echo "📋 НАЙДЕНО КАТАЛОГОВ ДЛЯ УДАЛЕНИЯ: ${total_count}" >&2
    echo "==================================================================================" >&2
    echo "№   | Полный путь каталога                               | Размер" >&2
    echo "==================================================================================" >&2
    
    # Выводим список и считаем общий размер
    for i in "${!folders[@]}"; do
        local folder="${folders[$i]}"
        local folder_size=$(get_folder_size "$folder")
        total_size=$((total_size + folder_size))
        
        # Форматируем размер без запятых (заменяем их на точку для выравнивания)
        local formatted_size=$(numfmt --to=iec "$folder_size" | sed 's/,/./g')
        
        printf "%-3d | %-50s | %10s\n" \
            "$((i+1))" \
            "$folder" \
            "$formatted_size" >&2
    done
    
    echo "==================================================================================" >&2
    # Форматируем общий размер тоже без запятых
    local formatted_total_size=$(numfmt --to=iec "$total_size" | sed 's/,/./g')
    echo "📊 ОБЩИЙ РАЗМЕР: $formatted_total_size" >&2
    echo "📅 Будет удалено: ${total_count} каталогов старше ${RETENTION_DAYS} дней" >&2
    echo "" >&2
    
    # Запрос подтверждения
    read -p "❓ Продолжить удаление? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        return 0
    else
        log "❌ Удаление отменено пользователем"
        return 1
    fi
}

delete_folders() {
    local folders=("$@")
    local deleted_count=0
    local total_freed=0
    
    log "\n🗑️ Начало удаления каталогов..."
    
    for folder in "${folders[@]}"; do
        local folder_size=$(get_folder_size "$folder")
        log "🔨 Удаление: ${folder} ($(numfmt --to=iec "$folder_size"))"
        
        if obsutil rm "obs://${OBS_BUCKET}/${folder}/" -config="$OBS_CONFIG_FILE" -f -r >/dev/null 2>&1; then
            ((deleted_count++))
            total_freed=$((total_freed + folder_size))
            log "✅ Удалено: ${folder}"
        else
            log "⚠️ Не удалось удалить: ${folder}"
        fi
    done
    
    echo "$deleted_count $total_freed"
}

clean_empty_directories() {
    log "🧽 Очистка пустых директорий..."
    
    # Сначала очищаем хостовые директории
    while IFS= read -r host_path; do
        if [ -n "$host_path" ]; then
            # Проверяем, есть ли подкаталоги в хостовой директории
            local has_subdirs=$(obsutil ls "obs://${OBS_BUCKET}/${host_path}/" -d -config="$OBS_CONFIG_FILE" 2>/dev/null | \
                               grep -c "obs://${OBS_BUCKET}/${host_path}/")
            
            if [ "$has_subdirs" -eq 0 ]; then
                log "🗑️ Удаление пустой хостовой директории: ${host_path}"
                obsutil rm "obs://${OBS_BUCKET}/${host_path}/" -config="$OBS_CONFIG_FILE" -f -folder >/dev/null 2>&1 || true
            fi
        fi
    done < <(get_host_directories "$OBS_BASE_PATH")
}

# ==================== ОСНОВНОЙ ПРОЦЕСС ====================
main() {
    log "=== НАЧАЛО ОЧИСТКИ СТАРЫХ БЭКАПОВ В OBS ==="
    log "🪣 Бакет: $OBS_BUCKET"
    log "📅 Удержание: $RETENTION_DAYS дней"
    log "📁 Базовый путь: $OBS_BASE_PATH"
    log "⏰ Текущая дата: $(date '+%Y-%m-%d')"
    log "📅 Дата отсечения: $(date -d "-${RETENTION_DAYS} days" '+%Y-%m-%d')"
    
    check_deps
    check_s3_connection
    
    # Находим все каталоги с датами
    local folders_to_delete=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            read -r path date_str <<< "$line"
            folders_to_delete+=("$path")
        fi
    done < <(find_date_folders "$OBS_BASE_PATH")
    
    # Запрашиваем подтверждение
    if confirm_deletion "${folders_to_delete[@]}"; then
        # Удаляем каталоги
        result=$(delete_folders "${folders_to_delete[@]}")
        read -r deleted_count total_freed <<< "$result"
        
        # Очищаем пустые директории
        clean_empty_directories
        
        log "\n=== ИТОГИ ОЧИСТКИ ==="
        log "🗑️ Удалено каталогов: ${deleted_count}"
        log "💾 Освобождено места: $(numfmt --to=iec "$total_freed")"
        log "✅ Очистка завершена успешно"
    else
        log "ℹ️ Очистка не выполнена"
    fi
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