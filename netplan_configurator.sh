#!/bin/bash

# Функция для проверки IPv4
function is_valid_ipv4() {
    local ip=$1
    local stat=1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 \
            && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

# Функция для проверки IPv6
function is_valid_ipv6() {
    local ip=$1
    local stat=1
    if [[ $ip =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; then
        stat=0
    fi
    return $stat
}

# Определение шлюза
function get_gateway() {
    local ip=$1
    if is_valid_ipv4 "$ip"; then
        IFS='.' read -ra octets <<< "$ip"
        octets[3]=1
        echo "${octets[0]}.${octets[1]}.${octets[2]}.${octets[3]}"
    elif is_valid_ipv6 "$ip"; then
        IFS=':' read -ra hextets <<< "$ip"
        hextets[-1]="1"
        echo "$(IFS=:; echo "${hextets[*]}")"
    else
        echo "Неверный IP-адрес"
        exit 1
    fi
}

# Форматирование DNS для YAML
function format_dns() {
    local formatted=()
    for addr in "$@"; do
        formatted+=("\"$addr\"")
    done
    echo "${formatted[*]}" | sed 's/ /, /g'
}

# Вывод списка доступных интерфейсов
function show_interfaces() {
    echo "Доступные сетевые интерфейсы:"
    ip -o link show | awk -F': ' '{print $2}'
}

# Запрос типа настройки
read -p "Настройка временная (1) или постоянная (2)? Введите 1 или 2: " config_type

# Вывод списка интерфейсов и запрос выбора
show_interfaces
read -p "Введите имя интерфейса (например, eth0): " interface

# Проверка существования интерфейса
if ! ip link show "$interface" &> /dev/null; then
    echo "Интерфейс $interface не найден!"
    exit 1
fi

# Ввод IPv4 адресов
while true; do
    read -p "Введите IPv4 адреса через пробел (первый будет основным): " ipv4_input
    ipv4_addresses=($ipv4_input)
    valid=true
    for ip in "${ipv4_addresses[@]}"; do
        if ! is_valid_ipv4 "$ip"; then
            echo "Неверный формат IPv4: $ip"
            valid=false
            break
        fi
    done
    if $valid; then
        break
    fi
done

# Основной IPv4 и шлюз
main_ipv4=${ipv4_addresses[0]}
ipv4_gateway=$(get_gateway "$main_ipv4")

# Ввод IPv6 адресов (опционально)
read -p "Добавить IPv6 адреса? (y/n): " add_ipv6
if [[ $add_ipv6 == "y" ]]; then
    while true; do
        read -p "Введите IPv6 адреса через пробел (первый будет основным): " ipv6_input
        ipv6_addresses=($ipv6_input)
        valid=true
        for ip in "${ipv6_addresses[@]}"; do
            if ! is_valid_ipv6 "$ip"; then
                echo "Неверный формат IPv6: $ip"
                valid=false
                break
            fi
        done
        if $valid; then
            break
        fi
    done

    # Основной IPv6 и шлюз
    main_ipv6=${ipv6_addresses[0]}
    ipv6_gateway=$(get_gateway "$main_ipv6")
fi

# DNS-серверы
dns=()
read -p "Использовать DNS по умолчанию (Cloudflare)? (y/n): " use_default_dns
if [[ $use_default_dns == "y" ]]; then
    dns=("1.1.1.1" "1.0.0.1" "2606:4700:4700::1111" "2606:4700:4700::1001")
else
    echo "Введите DNS-серверы (завершите пустой строкой):"
    while true; do
        read dns_entry
        [[ -z $dns_entry ]] && break
        dns+=("$dns_entry")
    done
fi
dns_string=$(format_dns "${dns[@]}")

# Временная настройка
if [[ $config_type == "1" ]]; then
    echo "Применение временных настроек..."
    # Добавление IPv4 адресов
    for ip in "${ipv4_addresses[@]}"; do
        sudo ip addr add "$ip/24" dev $interface
    done
    
    # Добавление IPv6 адресов
    if [[ $add_ipv6 == "y" ]]; then
        for ip in "${ipv6_addresses[@]}"; do
            sudo ip addr add "$ip/128" dev $interface
        done
    fi
    
    # Настройка маршрутов
    if [[ -n "$ipv4_gateway" ]]; then
        sudo ip route replace default via $ipv4_gateway dev $interface
    fi
    if [[ -n "$ipv6_gateway" && $add_ipv6 == "y" ]]; then
        sudo ip -6 route replace default via $ipv6_gateway dev $interface
    fi
    
    echo "Временные настройки применены"

# Постоянная настройка для Ubuntu
else
    echo "Применение постоянных настроек для Ubuntu..."
    
    # Создание IPv4 конфига
    if [[ ${#ipv4_addresses[@]} -gt 0 ]]; then
        ipv4_file="/etc/netplan/99-ipv4.yaml"
        cat << EOF | sudo tee $ipv4_file > /dev/null
network:
  version: 2
  renderer: networkd
  ethernets:
    $interface:
      dhcp4: false
      addresses: [$(IFS=,; echo "${ipv4_addresses[@]/%//24}")]
      routes:
        - to: 0.0.0.0/0
          via: $ipv4_gateway
      nameservers:
        addresses: [$dns_string]
EOF
        sudo chmod 600 $ipv4_file
    fi
    
    # Создание IPv6 конфига
    if [[ ${#ipv6_addresses[@]} -gt 0 && $add_ipv6 == "y" ]]; then
        ipv6_file="/etc/netplan/99-ipv6.yaml"
        cat << EOF | sudo tee $ipv6_file > /dev/null
network:
  version: 2
  renderer: networkd
  ethernets:
    $interface:
      dhcp6: false
      addresses: [$(IFS=,; echo "${ipv6_addresses[@]/%//128}")]
      routes:
        - to: ::/0
          via: $ipv6_gateway
      nameservers:
        addresses: [$dns_string]
EOF
        sudo chmod 600 $ipv6_file
    fi
    
    # Резервирование старых конфигов
    sudo mv /etc/netplan/50-cloud-init.yaml /etc/netplan/50-cloud-init.yaml.backup 2>/dev/null
    
    # Применение настроек
    sudo netplan apply
    echo "Настройки применены. Рекомендуется перезагрузить сервер."
fi
