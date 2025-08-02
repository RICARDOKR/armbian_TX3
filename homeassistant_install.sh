#!/bin/bash
#######################################################################
##                                                                   ##
## INSTALADOR MELHORADO PARA HOME ASSISTANT SUPERVISED + ECOSSISTEMA ##
## VERSÃO ATUALIZADA COM CORREÇÕES DE SEGURANÇA                      ##
##                                                                   ##
#######################################################################

set -o errexit
set -o errtrace
set -o nounset
set -o pipefail

readonly HOSTNAME="homeassistant"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Este script deve ser executado como root"
    fi
}

check_system_compatibility() {
    log "Verificando compatibilidade do sistema..."
    
    # Verificar arquitetura
    ARCH=$(uname -m)
    if [[ "$ARCH" != "aarch64" ]]; then
        warn "Arquitetura detectada: $ARCH"
        warn "Este script foi otimizado para ARM64/aarch64"
    fi
    
    # Verificar SoC (se possível)
    if [[ -f /proc/device-tree/compatible ]]; then
        SOC=$(cat /proc/device-tree/compatible | grep -o "amlogic,s905x3" || echo "unknown")
        if [[ "$SOC" == "amlogic,s905x3" ]]; then
            log "✅ S905X3 detectado - otimizações ARM64 ativadas"
        else
            log "SoC: $(cat /proc/device-tree/compatible | tr '\0' ' ')"
        fi
    fi
    
    # Verificar RAM disponível
    RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
    if [[ $RAM_GB -lt 2 ]]; then
        warn "⚠️  RAM disponível: ${RAM_GB}GB - Recomendado: 2GB+ para YOLOv8"
        warn "⚠️  Performance do YOLO pode ser limitada"
    else
        log "✅ RAM: ${RAM_GB}GB - Adequada para YOLOv8"
    fi
    
    # Verificar espaço em disco
    DISK_GB=$(df -BG / | awk 'NR==2{gsub(/G/,"",$4); print $4}')
    if [[ $DISK_GB -lt 8 ]]; then
        warn "⚠️  Espaço livre: ${DISK_GB}GB - Recomendado: 8GB+"
    else
        log "✅ Espaço livre: ${DISK_GB}GB"
    fi
}

update_hostname() {
    log "Alterando hostname para: ${HOSTNAME}"
    hostnamectl set-hostname "${HOSTNAME}"
}

install_dependencies() {
    log "Atualizando repositórios..."
    apt-get update
    
    log "Instalando dependências básicas..."
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
        systemd-resolved \
        avahi-daemon \
        mosquitto \
        mosquitto-clients \
        python3 \
        python3-pip \
        python3-venv
}

install_docker() {
    log "Verificando se Docker já está instalado..."
    if command -v docker &> /dev/null; then
        log "Docker já está instalado"
        return
    fi
    
    log "Instalando Docker..."
    curl -fsSL https://get.docker.com | sh
    
    log "Habilitando Docker no boot..."
    systemctl enable docker
    systemctl start docker
}

get_latest_os_agent_version() {
    log "Obtendo versão mais recente do os-agent..."
    LATEST_VERSION=$(curl -s https://api.github.com/repos/home-assistant/os-agent/releases/latest | jq -r .tag_name)
    echo $LATEST_VERSION
}

install_os_agent() {
    log "Instalando os-agent..."
    ARCH=$(uname -m)
    
    if [[ "$ARCH" == "aarch64" ]]; then
        LATEST_VERSION=$(get_latest_os_agent_version)
        log "Baixando os-agent versão: $LATEST_VERSION"
        
        wget "https://github.com/home-assistant/os-agent/releases/download/${LATEST_VERSION}/os-agent_${LATEST_VERSION#v}_linux_aarch64.deb"
        dpkg -i "os-agent_${LATEST_VERSION#v}_linux_aarch64.deb" || apt --fix-broken install -y
        rm -f "os-agent_${LATEST_VERSION#v}_linux_aarch64.deb"
    else
        error "Arquitetura não suportada para os-agent: $ARCH"
    fi
}

install_supervised() {
    log "Instalando Home Assistant Supervised..."
    wget https://github.com/home-assistant/supervised-installer/releases/latest/download/homeassistant-supervised.deb
    dpkg -i homeassistant-supervised.deb || apt --fix-broken install -y
    rm -f homeassistant-supervised.deb
}

generate_mqtt_credentials() {
    # Gerar credenciais aleatórias
    MQTT_USER="hauser_$(openssl rand -hex 4)"
    MQTT_PASS="$(openssl rand -base64 16)"
    
    echo "MQTT_USER=$MQTT_USER" > /opt/mqtt_credentials.txt
    echo "MQTT_PASS=$MQTT_PASS" >> /opt/mqtt_credentials.txt
    chmod 600 /opt/mqtt_credentials.txt
    
    echo "$MQTT_USER:$MQTT_PASS"
}

setup_directories() {
    log "Criando diretórios para Mosquitto e Node-RED..."
    mkdir -p /opt/mosquitto/config /opt/mosquitto/data /opt/mosquitto/log
    mkdir -p /opt/nodered/data

    log "Criando configuração do Mosquitto..."
    cat <<EOF > /opt/mosquitto/config/mosquitto.conf
allow_anonymous false
password_file /mosquitto/config/password.txt
persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log
listener 1883
EOF

    log "Gerando credenciais MQTT seguras..."
    MQTT_CREDS=$(generate_mqtt_credentials)
    MQTT_USER=$(echo $MQTT_CREDS | cut -d: -f1)
    MQTT_PASS=$(echo $MQTT_CREDS | cut -d: -f2)
    
    mosquitto_passwd -b -c /opt/mosquitto/config/password.txt "$MQTT_USER" "$MQTT_PASS"
    
    # Salvar credenciais para o usuário
    echo "MQTT_USER=$MQTT_USER" > /root/mqtt_credentials.txt
    echo "MQTT_PASS=$MQTT_PASS" >> /root/mqtt_credentials.txt
}

create_docker_services() {
    log "Removendo containers antigos se existirem..."
    docker rm -f mosquitto nodered 2>/dev/null || true
    
    log "Criando container Mosquitto..."
    docker run -d --restart unless-stopped \
        -p 1883:1883 \
        -v /opt/mosquitto/config:/mosquitto/config \
        -v /opt/mosquitto/data:/mosquitto/data \
        -v /opt/mosquitto/log:/mosquitto/log \
        --name mosquitto eclipse-mosquitto:latest

    log "Criando container Node-RED..."
    docker run -d --restart unless-stopped \
        -p 1880:1880 \
        -v /opt/nodered/data:/data \
        --name nodered nodered/node-red:latest
}

install_python_yolo() {
    log "Instalando ambiente virtual para YOLOv8 otimizado para ARM64..."
    mkdir -p /opt/yolo-env
    python3 -m venv /opt/yolo-env
    source /opt/yolo-env/bin/activate
    
    log "Atualizando pip..."
    pip install --upgrade pip
    
    log "Instalando dependências base..."
    pip install numpy==1.24.3 pillow requests paho-mqtt imutils schedule
    
    log "Instalando OpenCV otimizado..."
    # OpenCV com otimizações ARM
    pip install opencv-python-headless
    
    log "Instalando frameworks de ML otimizados..."
    # TensorFlow Lite para ARM64 (mais eficiente)
    pip install tflite-runtime
    
    # ONNX Runtime ARM64
    pip install onnxruntime
    
    # Ultralytics YOLOv8 (última versão)
    pip install ultralytics
    
    log "Instalando utilitários adicionais..."
    pip install matplotlib psutil
    
    deactivate
    
    # Criar script de ativação otimizado
    cat <<EOF > /opt/yolo-env/activate.sh
#!/bin/bash
source /opt/yolo-env/bin/activate
echo "🤖 Ambiente YOLOv8 ARM64 ativado"
echo "💡 Para melhor performance:"
echo "   - Use modelo nano: YOLO('yolov8n.pt')"
echo "   - Resolução baixa: imgsz=320"
echo "   - Considere TensorFlow Lite para produção"
EOF
    chmod +x /opt/yolo-env/activate.sh
    
    # Criar script de exemplo otimizado para S905X3
    cat <<EOF > /opt/yolo-env/yolo_example_optimized.py
#!/usr/bin/env python3
"""
Exemplo YOLOv8 otimizado para S905X3 (ARM64)
Performance: ~5-15 FPS dependendo da resolução
"""

import cv2
import time
from ultralytics import YOLO
import numpy as np

def main():
    # Usar modelo nano (mais rápido)
    print("🔄 Carregando YOLOv8 nano...")
    model = YOLO('yolov8n.pt')  # Baixa automaticamente na primeira vez
    
    # Configurações otimizadas para ARM64
    model.overrides['imgsz'] = 320  # Resolução menor = mais rápido
    model.overrides['conf'] = 0.5   # Confiança mínima
    model.overrides['iou'] = 0.7    # IoU threshold
    
    # Teste com webcam ou arquivo
    cap = cv2.VideoCapture(0)  # Webcam
    # cap = cv2.VideoCapture('video.mp4')  # Arquivo
    
    if not cap.isOpened():
        print("❌ Erro ao abrir câmera/vídeo")
        return
    
    # Reduzir resolução da câmera
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    
    fps_counter = 0
    start_time = time.time()
    
    print("🚀 Iniciando detecção... (Pressione 'q' para sair)")
    
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        
        # YOLOv8 inference
        results = model(frame, verbose=False)
        
        # Desenhar resultados
        annotated_frame = results[0].plot()
        
        # Calcular FPS
        fps_counter += 1
        if fps_counter % 30 == 0:
            elapsed = time.time() - start_time
            fps = 30 / elapsed
            print(f"📊 FPS: {fps:.1f}")
            start_time = time.time()
        
        # Mostrar frame
        cv2.imshow('YOLOv8 ARM64 Optimized', annotated_frame)
        
        if cv2.waitKey(1) & 0xFF == ord('q'):
            break
    
    cap.release()
    cv2.destroyAllWindows()
    print("✅ Detecção finalizada")

if __name__ == "__main__":
    main()
EOF
    chmod +x /opt/yolo-env/yolo_example_optimized.py
    
    log "✅ Ambiente YOLOv8 otimizado para ARM64 instalado"
    log "📝 Exemplo: /opt/yolo-env/yolo_example_optimized.py"
}

create_backup_script() {
    log "Criando script de backup..."
    cat <<EOF > /opt/backup_ha.sh
#!/bin/bash
# Script de backup automático do Home Assistant
BACKUP_DIR="/opt/backups"
DATE=\$(date +%Y%m%d_%H%M%S)

mkdir -p \$BACKUP_DIR

# Backup configuração HA
tar -czf "\$BACKUP_DIR/ha_config_\$DATE.tar.gz" -C /usr/share/hassio/homeassistant .

# Backup Mosquitto
tar -czf "\$BACKUP_DIR/mosquitto_\$DATE.tar.gz" -C /opt/mosquitto .

# Backup Node-RED
tar -czf "\$BACKUP_DIR/nodered_\$DATE.tar.gz" -C /opt/nodered .

# Manter apenas últimos 7 backups
find \$BACKUP_DIR -name "*.tar.gz" -mtime +7 -delete

echo "Backup concluído em: \$BACKUP_DIR"
EOF
    chmod +x /opt/backup_ha.sh
}

wait_for_ha() {
    log "Aguardando Home Assistant inicializar..."
    for i in {1..30}; do
        if curl -s http://localhost:8123 > /dev/null; then
            log "Home Assistant está rodando!"
            break
        fi
        echo -n "."
        sleep 10
    done
}

main() {
    check_root
    check_system_compatibility
    
    warn "ATENÇÃO: Home Assistant Supervised será descontinuado em 2025.12"
    warn "Considere migrar para Home Assistant OS no futuro"
    echo "Pressione ENTER para continuar ou Ctrl+C para cancelar..."
    read
    
    log "Iniciando instalação do Home Assistant Supervised otimizado para ARM64..."
    
    update_hostname
    install_dependencies
    install_docker
    install_os_agent
    install_supervised
    setup_directories
    create_docker_services
    install_python_yolo
    create_backup_script
    
    wait_for_ha
    
    # Obter informações do sistema
    ip_addr=$(hostname -I | cut -d ' ' -f1)
    mqtt_user=$(grep MQTT_USER /root/mqtt_credentials.txt | cut -d= -f2)
    mqtt_pass=$(grep MQTT_PASS /root/mqtt_credentials.txt | cut -d= -f2)
    
    echo ""
    echo "======================================================================="
    log "✅ Ambiente instalado com sucesso!"
    echo ""
    echo "🏠 Home Assistant: http://${HOSTNAME}.local:8123 ou http://${ip_addr}:8123"
    echo "🔴 Node-RED: http://${ip_addr}:1880"
    echo "📡 MQTT Broker: ${ip_addr}:1883"
    echo "   Usuário: ${mqtt_user}"
    echo "   Senha: ${mqtt_pass}"
    echo ""
    echo "🤖 YOLOv8 ARM64: /opt/yolo-env"
    echo "   Ativar: source /opt/yolo-env/activate.sh"
    echo "   Exemplo: python3 /opt/yolo-env/yolo_example_optimized.py"
    echo "   💡 Performance: ~5-15 FPS com yolov8n modelo nano"
    echo ""
    echo "💾 Backup: /opt/backup_ha.sh"
    echo "🔑 Credenciais MQTT: /root/mqtt_credentials.txt"
    echo ""
    echo "🎯 Dicas de otimização YOLOv8 para S905X3:"
    echo "   - Use modelo nano (yolov8n.pt) - mais rápido"
    echo "   - Resolução 320x320 em vez de 640x640"
    echo "   - Considere TensorFlow Lite para produção"
    echo "   - OpenCV headless instalado (sem GUI dependencies)"
    echo ""
    warn "⚠️  Home Assistant Supervised será descontinuado em 2025.12"
    warn "⚠️  Considere migrar para Home Assistant OS"
    echo "======================================================================="
}

main "$@"
