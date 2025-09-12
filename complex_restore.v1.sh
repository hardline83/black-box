#!/bin/bash
set -euo pipefail

# ==================== КОНФИГУРАЦИЯ ====================
OBS_BUCKET="black-box"
OBS_CONFIG_FILE="$HOME/.obsutilconfig"
KEYFILE="$HOME/encryption.key"
TMP_DIR="/tmp/restore_backup"
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

# Telegram Notifications (опционально)
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
    for cmd in openssl pigz obsutil psql; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log "❌ Отсутствуют зависимости: ${missing[*]}"
        exit 1
    fi
    log "✅ Все зависимости доступны"
}

prepare_directories() {
    mkdir -p "$TMP_DIR" "$RESTORE_DIR"
    log "✅ Созданы временные директории"
}

cleanup() {
    log "🧹 Очистка временных файлов..."
    rm -rf "${TMP_DIR:?}/"*
    log "✅ Временные файлы удалены"
}

download_from_obs() {
    local obs_path="$1"
    local download_start=$(date +%s)
    
    log "📥 Загрузка файлов из OBS: obs://${OBS_BUCKET}/${obs_path}"
    
    # Создаем лог файл для отладки
    local log_file="${TMP_DIR}/obs_download.log"
    
    # Выполняем команду с подробным выводом
    echo "Команда: obsutil cp \"obs://${OBS_BUCKET}/${obs_path}\" \"$TMP_DIR/\" -config=\"$OBS_CONFIG_FILE\" -r -f" >> "$log_file"
    
    if obsutil cp "obs://${OBS_BUCKET}/${obs_path}" "$TMP_DIR/" \
       -config="$OBS_CONFIG_FILE" -r -f >> "$log_file" 2>&1; then
        local download_end=$(date +%s)
        local download_dur=$((download_end - download_start))
        
        # Проверяем, что файлы действительно загрузились
        local file_count=$(find "$TMP_DIR" -type f | wc -l)
        log "✅ Загружено файлов: $file_count за ${download_dur} секунд"
        
        if [ "$file_count" -eq 0 ]; then
            log "❌ Файлы не были загружены (пустая директория)"
            log "📋 Лог загрузки:"
            cat "$log_file"
            return 1
        fi
        
        return 0
    else
        local exit_code=$?
        local download_end=$(date +%s)
        local download_dur=$((download_end - download_start))
        
        log "❌ Ошибка загрузки файлов из OBS (код: $exit_code, время: ${download_dur}сек)"
        log "📋 Лог загрузки:"
        cat "$log_file"
        return 1
    fi
}

combine_parts() {
    local output_file="$1"
    local parts=("$TMP_DIR"/*)
    
    if [ ${#parts[@]} -eq 0 ]; then
        log "❌ В временной директории нет файлов"
        return 1
    fi

    log "🔗 Объединение ${#parts[@]} частей файла..."
    
    # Сортируем файлы по имени для правильного порядка объединения
    local sorted_parts=($(ls "$TMP_DIR"/* | sort))
    log "📋 Части для объединения: ${sorted_parts[*]}"
    
    cat "${sorted_parts[@]}" > "$output_file"
    
    if [ $? -eq 0 ]; then
        local output_size=$(du -h "$output_file" | cut -f1)
        log "✅ Файлы успешно объединены: $(basename "$output_file") (размер: $output_size)"
        return 0
    else
        log "❌ Ошибка объединения файлов"
        return 1
    fi
}

decrypt_file() {
    local encrypted_file="$1"
    local decrypted_file="$2"
    local decrypt_start=$(date +%s)
    
    log "🔓 Дешифрование файла: $(basename "$encrypted_file")"
    
    if openssl enc -aes-256-cbc -d -pbkdf2 \
        -in "$encrypted_file" \
        -out "$decrypted_file" \
        -pass file:"$KEYFILE" 2>"${TMP_DIR}/decrypt.log"; then
        local decrypt_end=$(date +%s)
        local decrypt_dur=$((decrypt_end - decrypt_start))
        local decrypted_size=$(du -h "$decrypted_file" | cut -f1)
        log "✅ Файл успешно дешифрован за ${decrypt_dur} секунд (размер: $decrypted_size)"
        return 0
    else
        log "❌ Ошибка дешифрования файла"
        log "📋 Лог дешифрования:"
        cat "${TMP_DIR}/decrypt.log"
        return 1
    fi
}

decompress_file() {
    local compressed_file="$1"
    local output_file="$2"
    local decompress_start=$(date +%s)
    
    log "📦 Распаковка файла: $(basename "$compressed_file")"
    
    if pigz -d -c "$compressed_file" > "$output_file" 2>"${TMP_DIR}/decompress.log"; then
        local decompress_end=$(date +%s)
        local decompress_dur=$((decompress_end - decompress_start))
        local output_size=$(du -h "$output_file" | cut -f1)
        log "✅ Файл успешно распакован за ${decompress_dur} секунд (размер: $output_size)"
        return 0
    else
        log "❌ Ошибка распаковки файла"
        log "📋 Лог распаковки:"
        cat "${TMP_DIR}/decompress.log"
        return 1
    fi
}

get_user_input() {
    echo "=============================================="
    echo "         СКРИПТ ВОССТАНОВЛЕНИЯ БД"
    echo "=============================================="
    echo
    
    # Запрос OBS пути
    read -p "Введите OBS путь для восстановления (например: DB/itsm-p-dba01/2024-01-15): " OBS_PATH
    if [ -z "$OBS_PATH" ]; then
        echo "❌ OBS путь не может быть пустым"
        exit 1
    fi
    
    # Запрос директории для восстановления
    read -p "Введите путь для восстановления файлов [по умолчанию: ${SCRIPT_DIR}/restore]: " RESTORE_DIR
    RESTORE_DIR="${RESTORE_DIR:-${SCRIPT_DIR}/restore}"
    
    echo
    echo "Параметры восстановления:"
    echo "• OBS путь: ${OBS_PATH}"
    echo "• Директория восстановления: ${RESTORE_DIR}"
    echo
    read -p "Продолжить? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Восстановление отменено"
        exit 0
    fi
}

# ==================== ОСНОВНОЙ ПРОЦЕСС ====================
main() {
    total_start=$(date +%s)
    
    # Получение параметров от пользователя
    get_user_input
    
    # Инициализация
    check_deps
    prepare_directories
    
    log "=== НАЧАЛО ВОССТАНОВЛЕНИЯ ==="
    log "📁 OBS путь: ${OBS_PATH}"
    log "📂 Директория восстановления: ${RESTORE_DIR}"
    log "🔑 Ключ шифрования: ${KEYFILE}"
    log "📦 OBS бакет: ${OBS_BUCKET}"
    
    # Проверяем существование ключа шифрования
    if [ ! -f "$KEYFILE" ]; then
        log "❌ Файл ключа шифрования не найден: $KEYFILE"
        exit 1
    fi
    
    # Проверяем существование конфига obsutil
    if [ ! -f "$OBS_CONFIG_FILE" ]; then
        log "❌ Конфигурационный файл obsutil не найден: $OBS_CONFIG_FILE"
        exit 1
    fi

    # 1. Загрузка из OBS
    if ! download_from_obs "$OBS_PATH"; then
        log "❌ Не удалось загрузить файлы из OBS"
        cleanup
        exit 1
    fi
    
    # Показываем список загруженных файлов
    log "📋 Загруженные файлы:"
    ls -la "$TMP_DIR/" | while read -r line; do
        log "   $line"
    done
    
    # Проверяем, есть ли части файла или один файл
    local files=("$TMP_DIR"/*)
    local encrypted_file=""
    
    if [ ${#files[@]} -gt 1 ]; then
        # Если multiple parts - объединяем
        encrypted_file="${TMP_DIR}/combined_backup.enc"
        if ! combine_parts "$encrypted_file"; then
            cleanup
            exit 1
        fi
    else
        # Если один файл
        encrypted_file="${files[0]}"
        log "ℹ️ Используется единственный файл: $(basename "$encrypted_file")"
    fi
    
    # 2. Дешифрование
    local decrypted_file="${TMP_DIR}/backup_decrypted.tar.gz"
    if ! decrypt_file "$encrypted_file" "$decrypted_file"; then
        cleanup
        exit 1
    fi
    
    # 3. Распаковка
    local final_output="${RESTORE_DIR}/database_backup.bac"
    if ! decompress_file "$decrypted_file" "$final_output"; then
        cleanup
        exit 1
    fi
    
    # Завершение
    cleanup
    
    local total_end=$(date +%s)
    local total_dur=$((total_end - total_start))
    
    log "=============================================="
    log "✅ ВОССТАНОВЛЕНИЕ УСПЕШНО ЗАВЕРШЕНО"
    log "⏱️ Общее время: ${total_dur} секунд"
    log "📁 Файл восстановлен: ${final_output}"
    log "💾 Размер файла: $(du -h "$final_output" | cut -f1)"
    log "=============================================="
    
    # Отправка уведомления в Telegram
    local tg_message="*✅ Восстановление БД завершено*
*OBS путь:* \`${OBS_PATH}\`
*Директория:* \`${RESTORE_DIR}\`
*Время выполнения:* \`${total_dur} секунд\`
*Файл:* \`$(basename "$final_output")\`"
    
    send_telegram "$tg_message"
}

# Обработка прерывания
trap 'echo; log "❌ Восстановление прервано пользователем"; cleanup; exit 1' INT

# Запуск основного процесса
main

exit 0