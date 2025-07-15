#!/bin/bash
#######################################################################
##                                                                   ##
## INSTALADOR COMPLETO PARA HOME ASSISTANT SUPERVISED + ECOSSISTEMA ##
## OTIMIZADO PARA TANIX TX3 COM DEBIAN BULLSEYE 6.1 (aarch64)       ##
##                                                                   ##
#######################################################################

set -o errexit
set -o errtrace
set -o nounset
set -o pipefail

readonly HOSTNAME="homeassistant"

# Função para log com timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Verifica sistema e recursos
check_system() {
    log "Verificando sistema..."
    
    if [[ $EUID -ne 0 ]]; then
        echo "Este script deve ser executado como root"
        exit 1
    fi

    # Verifica se é Debian 11 (Bullseye)
    if ! grep -q "bullseye\|11" /etc/debian_version 2>/dev/null; then
        log "AVISO: Script otimizado para Debian 11 (Bullseye)"
    fi

    # Verifica arquitetura
    ARCH=$(uname -m)
    if [[ "$ARCH" != "aarch64" ]]; then
        echo "AVISO: Script otimizado para aarch64, detectado: $ARCH"
    fi

    # Verifica recursos
    MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
    DISK_FREE=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    
    log "Sistema: Debian $(cat /etc/debian_version)"
    log "Arquitetura: $ARCH"
    log "Memória total: ${MEM_TOTAL}MB"
    log "Espaço livre: ${DISK_FREE}GB"
    
    if [[ ${MEM_TOTAL} -lt 1500 ]]; then
        log "AVISO: Memória baixa (${MEM_TOTAL}MB). Criando swap..."
        create_swap
    fi
    
    if [[ ${DISK_FREE} -lt 10 ]]; then
        echo "ERRO: Espaço insuficiente (${DISK_FREE}GB). Mínimo: 10GB"
        exit 1
    fi
}

# Cria arquivo de swap se necessário
create_swap() {
    if ! swapon --show | grep -q "/swapfile"; then
        log "Criando swap de 1GB..."
        fallocate -l 1G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
        log "Swap criado com sucesso"
    fi
}

# Atualiza hostname
update_hostname() {
    log "Alterando hostname para: ${HOSTNAME}"
    hostnamectl set-hostname "${HOSTNAME}"
    
    # Atualiza /etc/hosts
    sed -i "s/127.0.1.1.*/127.0.1.1\t${HOSTNAME}/" /etc/hosts
    if ! grep -q "127.0.1.1.*${HOSTNAME}" /etc/hosts; then
        echo "127.0.1.1	${HOSTNAME}" >> /etc/hosts
    fi
}

# Instala dependências do sistema
install_dependencies() {
    log "Atualizando sistema e instalando dependências..."
    apt-get update
    apt-get upgrade -y
    
    # Remove possíveis fontes de backports que causam conflitos
    sed -i '/bullseye-backports/d' /etc/apt/sources.list
    apt-get update
    
    apt-get install -y \
        apparmor \
        jq \
        curl \
        dbus \
        lsb-release \
        network-manager \
        software-properties-common \
        apt-transport-https \
        ca-certificates \
        gnupg \
        udisks2 \
        wget \
        systemd-journal-remote \
        avahi-daemon \
        mosquitto \
        mosquitto-clients \
        python3 \
        python3-pip \
        python3-venv \
        python3-dev \
        build-essential \
        libssl-dev \
        libffi-dev \
        libjpeg-dev \
        zlib1g-dev \
        libatlas-base-dev \
        libopenblas-dev \
        liblapack-dev \
        pkg-config \
        cmake \
        git \
        resolvconf
    
    log "Dependências instaladas com sucesso"
}

# Instala Docker otimizado para ARM64
install_docker() {
    log "Instalando Docker para ARM64..."
    curl -fsSL https://get.docker.com | sh
    
    # Configura Docker para ARM64
    mkdir -p /etc/docker
    cat <<EOF > /etc/docker/daemon.json
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "storage-driver": "overlay2",
    "default-ulimits": {
        "nofile": {
            "hard": 64000,
            "soft": 64000
        }
    }
}
EOF
    
    systemctl restart docker
    systemctl enable docker
    log "Docker instalado e configurado"
}

# Instala OS Agent
install_os_agent() {
    log "Instalando OS Agent..."
    
    if [[ "$ARCH" == "aarch64" ]]; then
        wget -O os-agent.deb https://github.com/home-assistant/os-agent/releases/latest/download/os-agent_1.6.0_linux_aarch64.deb
        dpkg -i os-agent.deb || apt --fix-broken install -y
        rm os-agent.deb
        
        # Verifica se o serviço está rodando
        sleep 5
        if systemctl is-active --quiet haos-agent; then
            log "OS Agent instalado e rodando"
        else
            systemctl start haos-agent
            systemctl enable haos-agent
        fi
    else
        echo "Arquitetura não suportada para os-agent: $ARCH"
        exit 1
    fi
}

# Instala Home Assistant Supervised
install_supervised() {
    log "Instalando Home Assistant Supervised..."
    wget -O homeassistant-supervised.deb https://github.com/home-assistant/supervised-installer/releases/latest/download/homeassistant-supervised.deb
    
    # Instala com bypass do check do OS
    BYPASS_OS_CHECK=true dpkg -i homeassistant-supervised.deb || apt --fix-broken install -y
    rm homeassistant-supervised.deb
    
    log "Home Assistant Supervised instalado"
}

# Configura diretórios e serviços
setup_directories() {
    log "Criando diretórios para Mosquitto e Node-RED..."
    mkdir -p /opt/mosquitto/config /opt/mosquitto/data /opt/mosquitto/log
    mkdir -p /opt/nodered/data
    mkdir -p /opt/yolo-projects

    log "Criando configuração do Mosquitto..."
    cat <<EOF > /opt/mosquitto/config/mosquitto.conf
allow_anonymous false
password_file /mosquitto/config/password.txt
persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log
listener 1883 0.0.0.0
EOF

    log "Criando usuário MQTT..."
    mosquitto_passwd -b -c /opt/mosquitto/config/password.txt HAENFASE HAENFASE2025
    
    # Ajusta permissões
    chown -R 1883:1883 /opt/mosquitto/
    chmod -R 755 /opt/mosquitto/
}

# Cria containers Docker
create_docker_services() {
    log "Criando containers: Mosquitto e Node-RED..."
    
    # Remove containers existentes se houver
    docker rm -f mosquitto nodered 2>/dev/null || true
    
    # Mosquitto MQTT Broker
    docker run -d --restart unless-stopped \
        -p 1883:1883 \
        -v /opt/mosquitto/config:/mosquitto/config \
        -v /opt/mosquitto/data:/mosquitto/data \
        -v /opt/mosquitto/log:/mosquitto/log \
        --name mosquitto eclipse-mosquitto:latest

    # Node-RED
    docker run -d --restart unless-stopped \
        -p 1880:1880 \
        -v /opt/nodered/data:/data \
        --name nodered nodered/node-red:latest
    
    log "Containers criados com sucesso"
}

# Instala ambiente Python + YOLO
install_python_yolo() {
    log "Instalando ambiente virtual para YOLOv8..."
    mkdir -p /opt/yolo-env
    python3 -m venv /opt/yolo-env
    source /opt/yolo-env/bin/activate
    
    # Atualiza pip
    pip install --upgrade pip setuptools wheel
    
    # Instala dependências principais
    pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu
    pip install ultralytics opencv-python numpy requests paho-mqtt imutils schedule
    pip install Pillow matplotlib seaborn pandas
    
    # Cria script de exemplo YOLO
    cat <<EOF > /opt/yolo-projects/yolo_example.py
#!/usr/bin/env python3
"""
Exemplo básico de detecção YOLO
Para usar: source /opt/yolo-env/bin/activate && python3 /opt/yolo-projects/yolo_example.py
"""
from ultralytics import YOLO
import cv2
import numpy as np

def main():
    # Carrega modelo YOLO
    model = YOLO('yolov8n.pt')  # nano version for ARM
    
    # Teste com imagem de exemplo
    results = model('https://ultralytics.com/images/bus.jpg')
    
    # Processa resultados
    for r in results:
        print(f"Detectadas {len(r.boxes)} objetos")
        for box in r.boxes:
            print(f"Classe: {model.names[int(box.cls)]}, Confiança: {box.conf:.2f}")
    
    print("YOLO funcionando corretamente!")

if __name__ == "__main__":
    main()
EOF
    
    chmod +x /opt/yolo-projects/yolo_example.py
    deactivate
    
    log "Ambiente Python + YOLO instalado"
}

# Cria script de ativação rápida
create_helper_scripts() {
    log "Criando scripts auxiliares..."
    
    # Script para ativar ambiente YOLO
    cat <<EOF > /usr/local/bin/yolo-env
#!/bin/bash
source /opt/yolo-env/bin/activate
cd /opt/yolo-projects
echo "Ambiente YOLO ativado. Use 'deactivate' para sair."
exec bash
EOF
    chmod +x /usr/local/bin/yolo-env
    
    # Script de status dos serviços
    cat <<EOF > /usr/local/bin/ha-status
#!/bin/bash
echo "=== STATUS DOS SERVIÇOS ==="
echo "Docker: \$(systemctl is-active docker)"
echo "Home Assistant: \$(systemctl is-active hassos-supervisor 2>/dev/null || echo 'iniciando...')"
echo "OS Agent: \$(systemctl is-active haos-agent)"
echo ""
echo "=== CONTAINERS DOCKER ==="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo "=== RECURSOS ==="
echo "Memória: \$(free -h | grep '^Mem:' | awk '{print \$3 "/" \$2}')"
echo "Disco: \$(df -h / | awk 'NR==2 {print \$3 "/" \$2 " (" \$5 " usado)"}')"
EOF
    chmod +x /usr/local/bin/ha-status
    
    log "Scripts auxiliares criados"
}

# Configurações finais
final_setup() {
    log "Aplicando configurações finais..."
    
    # Configura resolução DNS sem systemd-resolved
    echo "nameserver 8.8.8.8" > /etc/resolvconf/resolv.conf.d/head
    echo "nameserver 1.1.1.1" >> /etc/resolvconf/resolv.conf.d/head
    resolvconf -u
    
    # Reinicia serviços essenciais
    systemctl restart avahi-daemon
    systemctl restart NetworkManager
    
    # Aguarda containers iniciarem
    sleep 10
    
    # Verifica se containers estão rodando
    if docker ps | grep -q mosquitto; then
        log "Mosquitto MQTT rodando na porta 1883"
    fi
    
    if docker ps | grep -q nodered; then
        log "Node-RED rodando na porta 1880"
    fi
}

# Função principal
main() {
    log "=== INICIANDO INSTALAÇÃO COMPLETA ==="
    log "Sistema: Tanix TX3 - Debian Bullseye 6.1"
    
    check_system
    update_hostname
    install_dependencies
    install_docker
    install_os_agent
    install_supervised
    setup_directories
    create_docker_services
    install_python_yolo
    create_helper_scripts
    final_setup

    # Informações finais
    ip_addr=$(hostname -I | cut -d ' ' -f1)
    
    echo ""
    echo "======================================================================="
    echo "✅ INSTALAÇÃO COMPLETA FINALIZADA!"
    echo "======================================================================="
    echo "🏠 Home Assistant: http://${HOSTNAME}.local:8123 ou http://${ip_addr}:8123"
    echo "🔗 Node-RED: http://${ip_addr}:1880"
    echo "📡 MQTT Broker: ${ip_addr}:1883"
    echo "   Usuário: HAENFASE"
    echo "   Senha: HAENFASE2025"
    echo ""
    echo "🐍 Python + YOLO:"
    echo "   • Use: yolo-env (para ativar ambiente)"
    echo "   • Teste: python3 /opt/yolo-projects/yolo_example.py"
    echo "   • Local: /opt/yolo-env"
    echo ""
    echo "🛠️ Comandos úteis:"
    echo "   • ha-status (verificar status)"
    echo "   • docker logs homeassistant (logs do HA)"
    echo "   • docker logs mosquitto (logs do MQTT)"
    echo ""
    echo "⚠️  IMPORTANTE: Reinicie o sistema para aplicar todas as configurações!"
    echo "   sudo reboot"
    echo "======================================================================="
}

# Executa instalação
main "$@"
