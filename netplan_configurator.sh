#!/bin/bash

# Логирование
LOG_FILE="/var/log/netplan_setup.log"
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Проверка IPv4
validate_ipv4() {
    if [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        return 0
    else
        log "Ошибка: Некорректный IPv4-адрес или маска: $1"
        return 1
    fi
}

# Проверка IPv6
validate_ipv6() {
    if [[ $1 =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}/[0-9]{1,3}$ ]]; then
        return 0
    else
        log "Ошибка: Некорректный IPv6-адрес или маска: $1"
        return 1
    fi
}

# Резервное копирование
backup_config() {
    local backup_dir="/etc/netplan/backup_$(date +"%Y%m%d_%H%M%S")"
    mkdir -p "$backup_dir"
    cp /etc/netplan/*.yaml "$backup_dir"
    log "Резервная копия создана в $backup_dir"
}

# Откат изменений
rollback_config() {
    local backup_dir=$(ls -td /etc/netplan/backup_* | head -1)
    if [[ -d "$backup_dir" ]]; then
        cp "$backup_dir"/*.yaml /etc/netplan/
        netplan apply
        log "Изменения откачены из резервной копии: $backup_dir"
    else
        log "Резервная копия не найдена. Откат невозможен."
    fi
}

# Настройка IP-адресов
setup_ips() {
    # Вывод списка доступных интерфейсов
    echo "Доступные сетевые интерфейсы:"
    ip -o link show | awk -F': ' '{print $2}'
    read -p "Введите имя сетевого интерфейса (например, eth0): " INTERFACE

    # Проверка, существует ли интерфейс
    if ! ip link show $INTERFACE &> /dev/null; then
        log "Интерфейс $INTERFACE не найден. Завершение скрипта."
        exit 1
    fi

    # Ввод IPv4-адресов
    while true; do
        read -p "Введите IPv4-адреса через пробел (например, 192.168.1.100/24 192.168.1.101/24): " IPV4_ADDRESSES
        valid=true
        for ip in $IPV4_ADDRESSES; do
            if ! validate_ipv4 "$ip"; then
                valid=false
                break
            fi
        done
        if $valid; then
            break
        fi
    done

    # Ввод IPv6-адресов
    while true; do
        read -p "Введите IPv6-адреса через пробел (например, 2001:db8::1/64 2001:db8::2/64): " IPV6_ADDRESSES
        valid=true
        for ip in $IPV6_ADDRESSES; do
            if ! validate_ipv6 "$ip"; then
                valid=false
                break
            fi
        done
        if $valid; then
            break
        fi
    done

    # Ввод шлюзов
    read -p "Введите IPv4-шлюз (например, 192.168.1.1): " GATEWAY_IPV4
    read -p "Введите IPv6-шлюз (например, 2001:db8::1): " GATEWAY_IPV6

    # Резервное копирование
    backup_config

    # Создание файла для IPv4
    cat <<EOF | sudo tee /etc/netplan/99-ipv4.yaml > /dev/null
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE:
      dhcp4: false
      addresses:
        - $(echo $IPV4_ADDRESSES | sed 's/ /\n        - /g')
      routes:
        - to: 0.0.0.0/0
          via: $GATEWAY_IPV4
      nameservers:
        addresses:
          - 1.1.1.1
          - 1.0.0.1
EOF

    # Создание файла для IPv6
    cat <<EOF | sudo tee /etc/netplan/99-ipv6.yaml > /dev/null
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE:
      dhcp6: false
      addresses:
        - $(echo $IPV6_ADDRESSES | sed 's/ /\n        - /g')
      routes:
        - to: ::/0
          via: $GATEWAY_IPV6
      nameservers:
        addresses:
          - 2606:4700:4700::1111
          - 2606:4700:4700::1001
EOF

    # Закрытие прав доступа к файлам
    chmod 600 /etc/netplan/99-ipv4.yaml
    chmod 600 /etc/netplan/99-ipv6.yaml

    log "Файлы netplan созданы."

    # Вывод объединенной конфигурации
    echo "Объединенная конфигурация netplan:"
    netplan get

    # Применение настроек
    if netplan --debug apply; then
        log "Настройки netplan успешно применены."
    else
        log "Ошибка применения настроек. Откат изменений..."
        rollback_config
        exit 1
    fi
}

# Меню
show_menu() {
    echo "1. Настроить IP-адреса"
    echo "2. Откатить изменения"
    echo "3. Выйти"
}

# Основной цикл
while true; do
    show_menu
    read -p "Выберите действие: " choice
    case $choice in
        1) setup_ips ;;
        2) rollback_config ;;
        3) break ;;
        *) echo "Неверный выбор." ;;
    esac
done

log "Скрипт завершен."
