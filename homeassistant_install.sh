#!/bin/bash

# Script de configuração completa para Tanix TX3 (S905X3)
# Instala: Home Assistant, Node-RED, MQTT, Python/YOLO
# Autor: Configuração automática para servidor IoT

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Função para log
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# Verificar se está rodando como root
if [ "$EUID" -ne 0 ]; then
    error "Este script deve ser executado como root. Use: sudo $0"
fi

log "🚀 Iniciando configuração do servidor Tanix TX3..."

# 1. Atualizar sistema
log "📦 Atualizando sistema..."
apt update && apt upgrade -y

# 2. Instalar dependências básicas
log "🔧 Instalando dependências básicas..."
apt install -y \
    curl \
    wget \
    git \
    htop \
    nano \
    unzip \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    python3-opencv \
    python3-numpy \
    build-essential \
    cmake \
    pkg-config \
    libopencv-dev \
    avahi-daemon \
    avahi-utils

# 3. Otimizações para S905X3
log "⚡ Aplicando otimizações para S905X3..."

# Configurar CMA para aceleração de hardware
if ! grep -q "extraargs=cma=256M" /boot/armbianEnv.txt; then
    echo 'extraargs=cma=256M' >> /boot/armbianEnv.txt
    log "✅ Aceleração de hardware configurada"
fi

# Configurar swap para YOLO
if [ ! -f /swapfile ]; then
    log "💾 Configurando swap de 2GB..."
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    if ! grep -q "/swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    log "✅ Swap configurado"
fi

# 4. Instalar Docker
log "🐳 Instalando Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
    
    # Adicionar usuário ao grupo docker
    usermod -aG docker $USER
    systemctl enable docker
    systemctl start docker
    log "✅ Docker instalado e configurado"
else
    log "✅ Docker já está instalado"
fi

# 5. Instalar Docker Compose
log "🔧 Instalando Docker Compose..."
if ! command -v docker-compose &> /dev/null; then
    pip3 install docker-compose
    log "✅ Docker Compose instalado"
else
    log "✅ Docker Compose já está instalado"
fi

# 6. Criar diretórios para os serviços
log "📁 Criando estrutura de diretórios..."
mkdir -p /opt/homeassistant
mkdir -p /opt/nodered
mkdir -p /opt/mosquitto/{config,data,log}
mkdir -p /opt/yolo/{models,scripts,data}
mkdir -p /opt/docker-compose

# 7. Configurar Mosquitto MQTT
log "🦟 Configurando Mosquitto MQTT..."
cat > /opt/mosquitto/config/mosquitto.conf << 'EOF'
# Mosquitto configuration
persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log
log_type all
log_timestamp true
listener 1883
allow_anonymous true

# Uncomment for websockets support
# listener 9001
# protocol websockets
EOF

# 8. Criar docker-compose.yml
log "🐋 Criando docker-compose.yml..."
cat > /opt/docker-compose/docker-compose.yml << 'EOF'
version: '3.8'

services:
  homeassistant:
    container_name: homeassistant
    image: ghcr.io/home-assistant/home-assistant:stable
    volumes:
      - /opt/homeassistant:/config
      - /etc/localtime:/etc/localtime:ro
      - /run/dbus:/run/dbus:ro
    restart: unless-stopped
    privileged: true
    network_mode: host
    environment:
      - TZ=America/Sao_Paulo
    depends_on:
      - mosquitto

  nodered:
    container_name: nodered
    image: nodered/node-red:latest
    ports:
      - "1880:1880"
    volumes:
      - /opt/nodered:/data
    restart: unless-stopped
    environment:
      - TZ=America/Sao_Paulo
    depends_on:
      - mosquitto

  mosquitto:
    container_name: mosquitto
    image: eclipse-mosquitto:latest
    ports:
      - "1883:1883"
      - "9001:9001"
    volumes:
      - /opt/mosquitto/config:/mosquitto/config
      - /opt/mosquitto/data:/mosquitto/data
      - /opt/mosquitto/log:/mosquitto/log
    restart: unless-stopped
    user: "1000:1000"
    environment:
      - TZ=America/Sao_Paulo

  portainer:
    container_name: portainer
    image: portainer/portainer-ce:latest
    ports:
      - "9000:9000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    restart: unless-stopped

volumes:
  portainer_data:
EOF

# 9. Configurar permissões
log "🔐 Configurando permissões..."
chown -R 1000:1000 /opt/mosquitto
chown -R 1000:1000 /opt/nodered
chown -R 1000:1000 /opt/homeassistant
chown -R 1000:1000 /opt/yolo

# 10. Instalar Python packages para YOLO
log "🐍 Instalando pacotes Python para YOLO..."
pip3 install --upgrade pip
pip3 install \
    ultralytics \
    opencv-python-headless \
    torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu \
    paho-mqtt \
    numpy \
    pillow \
    requests \
    flask \
    fastapi \
    uvicorn

# 11. Criar script de exemplo para YOLO
log "🎯 Criando script de exemplo YOLO..."
cat > /opt/yolo/scripts/yolo_mqtt.py << 'EOF'
#!/usr/bin/env python3
"""
Script de exemplo: YOLO com MQTT
Detecta objetos e envia resultados via MQTT
"""

import cv2
import json
import time
from ultralytics import YOLO
import paho.mqtt.client as mqtt
from datetime import datetime

# Configurações
MQTT_BROKER = "localhost"
MQTT_PORT = 1883
MQTT_TOPIC = "yolo/detections"

# Carregar modelo YOLO
model = YOLO('yolov8n.pt')  # Modelo nano para melhor performance

def on_connect(client, userdata, flags, rc):
    print(f"Conectado ao MQTT broker com código {rc}")

def process_detection(results):
    """Processa resultados da detecção"""
    detections = []
    
    for result in results:
        boxes = result.boxes
        if boxes is not None:
            for box in boxes:
                detection = {
                    "class": result.names[int(box.cls[0])],
                    "confidence": float(box.conf[0]),
                    "bbox": box.xyxy[0].tolist(),
                    "timestamp": datetime.now().isoformat()
                }
                detections.append(detection)
    
    return detections

def main():
    # Configurar MQTT
    client = mqtt.Client()
    client.on_connect = on_connect
    client.connect(MQTT_BROKER, MQTT_PORT, 60)
    client.loop_start()
    
    # Exemplo com câmera (descomente para usar)
    # cap = cv2.VideoCapture(0)
    
    # Exemplo com imagem
    print("Processando imagem de exemplo...")
    
    # Fazer detecção
    results = model("https://ultralytics.com/images/bus.jpg")
    
    # Processar resultados
    detections = process_detection(results)
    
    # Enviar via MQTT
    if detections:
        message = {
            "source": "yolo_detector",
            "detections": detections,
            "count": len(detections)
        }
        
        client.publish(MQTT_TOPIC, json.dumps(message))
        print(f"Enviadas {len(detections)} detecções via MQTT")
        
        for det in detections:
            print(f"- {det['class']}: {det['confidence']:.2f}")
    
    client.loop_stop()
    client.disconnect()

if __name__ == "__main__":
    main()
EOF

chmod +x /opt/yolo/scripts/yolo_mqtt.py

# 12. Criar script de inicialização
log "🚀 Criando script de inicialização..."
cat > /opt/start_server.sh << 'EOF'
#!/bin/bash

echo "🚀 Iniciando servidor Tanix TX3..."

# Ir para diretório do docker-compose
cd /opt/docker-compose

# Iniciar serviços
echo "📦 Iniciando containers..."
docker-compose up -d

# Aguardar serviços iniciarem
echo "⏳ Aguardando serviços iniciarem..."
sleep 30

# Mostrar status
echo "📊 Status dos serviços:"
docker-compose ps

echo ""
echo "🌐 Serviços disponíveis:"
echo "• Home Assistant: http://$(hostname -I | awk '{print $1}'):8123"
echo "• Node-RED: http://$(hostname -I | awk '{print $1}'):1880"
echo "• Portainer: http://$(hostname -I | awk '{print $1}'):9000"
echo "• MQTT Broker: $(hostname -I | awk '{print $1}'):1883"
echo ""
echo "📁 Diretórios de configuração:"
echo "• Home Assistant: /opt/homeassistant"
echo "• Node-RED: /opt/nodered"
echo "• MQTT: /opt/mosquitto"
echo "• YOLO: /opt/yolo"
echo ""
echo "🐍 Para testar YOLO:"
echo "cd /opt/yolo/scripts && python3 yolo_mqtt.py"
EOF

chmod +x /opt/start_server.sh

# 13. Criar serviço systemd
log "⚙️ Criando serviço systemd..."
cat > /etc/systemd/system/tanix-server.service << 'EOF'
[Unit]
Description=Tanix TX3 Server
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/start_server.sh
ExecStop=/bin/bash -c 'cd /opt/docker-compose && docker-compose down'
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tanix-server.service

# 14. Configurar firewall básico
log "🛡️ Configurando firewall..."
if command -v ufw &> /dev/null; then
    ufw --force enable
    ufw allow 22/tcp    # SSH
    ufw allow 8123/tcp  # Home Assistant
    ufw allow 1880/tcp  # Node-RED
    ufw allow 9000/tcp  # Portainer
    ufw allow 1883/tcp  # MQTT
    ufw allow 9001/tcp  # MQTT WebSocket
    log "✅ Firewall configurado"
fi

# 15. Iniciar serviços
log "🚀 Iniciando serviços..."
cd /opt/docker-compose
docker-compose up -d

# 16. Aguardar inicialização
log "⏳ Aguardando serviços iniciarem..."
sleep 30

# 17. Mostrar informações finais
log "🎉 Configuração concluída!"
echo ""
echo "=========================================="
echo "🌐 SERVIÇOS DISPONÍVEIS:"
echo "=========================================="
echo "• Home Assistant: http://$(hostname -I | awk '{print $1}'):8123"
echo "• Node-RED: http://$(hostname -I | awk '{print $1}'):1880"
echo "• Portainer: http://$(hostname -I | awk '{print $1}'):9000"
echo "• MQTT Broker: $(hostname -I | awk '{print $1}'):1883"
echo ""
echo "📁 DIRETÓRIOS:"
echo "• Configurações: /opt/"
echo "• Scripts YOLO: /opt/yolo/scripts/"
echo ""
echo "🔧 COMANDOS ÚTEIS:"
echo "• Iniciar servidor: sudo systemctl start tanix-server"
echo "• Parar servidor: sudo systemctl stop tanix-server"
echo "• Status: docker-compose ps"
echo "• Logs: docker-compose logs [serviço]"
echo "• Testar YOLO: cd /opt/yolo/scripts && python3 yolo_mqtt.py"
echo ""
echo "⚠️  IMPORTANTE:"
echo "• Reinicie o sistema para aplicar todas as configurações"
echo "• Configure Home Assistant no primeiro acesso"
echo "• Instale complementos do Node-RED conforme necessário"
echo "=========================================="

log "✅ Script executado com sucesso!"
log "🔄 Reinicie o sistema: sudo reboot"
