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
        if [[ $ip == *"::"* ]]; then
            echo "Ошибка: IPv6 адрес с :: не поддерживается для автоматического определения шлюза"
            exit 1
        fi
        IFS=':' read -ra hextets <<< "$ip"
        last_hextet=$(printf "%x" $((0x${hextets[-1]} & 0xfffe)))
        hextets[-1]="1"
        echo "$(IFS=:; echo "${hextets[*]}")"
    else
        echo "Неверный IP-адрес"
        exit 1
    fi
}

# Запрос типа настройки
read -p "Настройка временная (1) или постоянная (2)? Введите 1 или 2: " config_type

# Запрос интерфейса
read -p "Введите имя интерфейса (например, eth0): " interface

# Ввод основного IP
read -p "Введите основной IP-адрес: " main_ip

# Определение типа IP и маски
if is_valid_ipv4 "$main_ip"; then
    mask="/24"
    gateway=$(get_gateway "$main_ip")
elif is_valid_ipv6 "$main_ip"; then
    mask="/128"
    gateway=$(get_gateway "$main_ip")
else
    echo "Неверный IP-адрес"
    exit 1
fi

# Дополнительные IP
additional_ips=()
while true; do
    read -p "Добавить дополнительный IP? (y/n): " add_more
    if [[ $add_more != "y" ]]; then
        break
    fi
    read -p "Введите дополнительный IP: " ip
    if is_valid_ipv4 "$ip" || is_valid_ipv6 "$ip"; then
        additional_ips+=("$ip")
    else
        echo "Неверный IP, пропускаем"
    fi
done

# DNS-серверы
dns=("1.1.1.1" "1.0.0.1" "2606:4700:4700::1111" "2606:4700:4700::1001")
read -p "Использовать DNS по умолчанию (Cloudflare)? (y/n): " use_default_dns
if [[ $use_default_dns == "n" ]]; then
    dns=()
    echo "Введите DNS-серверы (завершите пустой строкой):"
    while true; do
        read dns_entry
        if [[ -z $dns_entry ]]; then
            break
        fi
        dns+=("$dns_entry")
    done
fi

# Временная настройка
if [[ $config_type == "1" ]]; then
    echo "Применение временных настроек..."
    ip addr add "$main_ip$mask" dev $interface
    for ip in "${additional_ips[@]}"; do
        if is_valid_ipv4 "$ip"; then
            ip addr add "$ip/24" dev $interface
        else
            ip addr add "$ip/128" dev $interface
        fi
    done
    current_gateway=$(ip route show default | awk '/default/ {print $3}')
    if [[ -z $current_gateway ]]; then
        ip route add default via $gateway dev $interface
    fi
    echo "Временные настройки применены"

# Постоянная настройка для Ubuntu
else
    echo "Применение постоянных настроек для Ubuntu..."
    ipv4_ips=()
    ipv6_ips=()
    for ip in "$main_ip" "${additional_ips[@]}"; do
        if is_valid_ipv4 "$ip"; then
            ipv4_ips+=("$ip/24")
        else
            ipv6_ips+=("$ip/128")
        fi
    done

    # Создание IPv4 конфига
    ipv4_file="/etc/netplan/99-ipv4.yaml"
    cat << EOF | sudo tee $ipv4_file > /dev/null
network:
  version: 2
  renderer: networkd
  ethernets:
    $interface:
      dhcp4: false
      addresses: [$(IFS=,; echo "${ipv4_ips[*]}")]
      routes:
        - to: 0.0.0.0/0
          via: $gateway
      nameservers:
        addresses: [$(IFS=,; echo "${dns[*]}")]
EOF
    sudo chmod 600 $ipv4_file

    # Создание IPv6 конфига
    ipv6_gateway=$(get_gateway "$main_ip")
    ipv6_file="/etc/netplan/99-ipv6.yaml"
    cat << EOF | sudo tee $ipv6_file > /dev/null
network:
  version: 2
  renderer: networkd
  ethernets:
    $interface:
      dhcp6: false
      addresses: [$(IFS=,; echo "${ipv6_ips[*]}")]
      routes:
        - to: ::/0
          via: $ipv6_gateway
      nameservers:
        addresses: [$(IFS=,; echo "${dns[*]}")]
EOF
    sudo chmod 600 $ipv6_file

    # Отключение старых конфигов
    sudo mv /etc/netplan/50-cloud-init.yaml /etc/netplan/50-cloud-init.yaml.backup 2>/dev/null

    # Применение настроек
    sudo netplan apply
    echo "Настройки применены. Рекомендуется перезагрузить сервер."
fi
