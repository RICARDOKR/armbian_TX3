#!/bin/bash

# Script de configuração completa para Tanix TX3 (S905X3)
# Instala: Home Assistant, Node-RED, MQTT, Python/YOLO
# Versão corrigida e otimizada

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

# Detectar usuário não-root que executou sudo
REAL_USER=${SUDO_USER:-$(whoami)}
REAL_HOME=$(eval echo ~$REAL_USER)

log "🚀 Iniciando configuração do servidor Tanix TX3..."

# 1. Atualizar sistema
log "📦 Atualizando sistema..."
apt update && apt upgrade -y

# 2. Verificar distribuição e versão Python
log "🐧 Verificando sistema operacional..."
OS_INFO=$(lsb_release -a 2>/dev/null | grep "Description" | cut -d: -f2 | xargs)
log "Sistema: $OS_INFO"

PYTHON_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
log "Python atual: $PYTHON_VERSION"

# Ubuntu Jammy vem com Python 3.10 (ideal para YOLO)
if [[ "$OS_INFO" == *"Ubuntu"* && "$OS_INFO" == *"22.04"* ]]; then
    log "✅ Ubuntu Jammy 22.04 detectado - Python 3.10 nativo"
    # Python 3.10 é perfeito para YOLO
elif python3 -c "import sys; exit(0 if (3,8) <= sys.version_info < (3,12) else 1)" 2>/dev/null; then
    log "✅ Versão do Python compatível com YOLOv8"
else
    log "⚠️ Instalando Python 3.10 para compatibilidade com YOLOv8..."
    
    # Para Ubuntu/Debian
    if command -v add-apt-repository &> /dev/null; then
        add-apt-repository -y ppa:deadsnakes/ppa
    fi
    apt update
    
    apt install -y \
        python3.10 \
        python3.10-venv \
        python3.10-dev \
        python3.10-distutils
    
    log "✅ Python 3.10 instalado para YOLO"
fi

# 3. Instalar dependências básicas
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
    python3-pip \
    build-essential \
    cmake \
    pkg-config \
    avahi-daemon \
    avahi-utils \
    ffmpeg \
    libsm6 \
    libxext6 \
    libfontconfig1 \
    libxrender1 \
    libgl1-mesa-glx \
    libglib2.0-0 \
    libgomp1

# 3. Otimizações para S905X3
log "⚡ Aplicando otimizações para S905X3..."

# Verificar se existe armbianEnv.txt
if [ -f /boot/armbianEnv.txt ]; then
    # Configurar CMA para aceleração de hardware
    if ! grep -q "extraargs=cma=256M" /boot/armbianEnv.txt; then
        echo 'extraargs=cma=256M' >> /boot/armbianEnv.txt
        log "✅ Aceleração de hardware configurada"
    fi
else
    warn "Arquivo /boot/armbianEnv.txt não encontrado. Pulando configuração CMA."
fi


# Configurar swap para YOLO (reduzido para 1GB devido às limitações do TX3)
if [ ! -f /swapfile ]; then
    log "💾 Configurando swap de 1GB..."
    fallocate -l 1G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    if ! grep -q "/swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    log "✅ Swap configurado"
fi
echo "[INFO] Instalando Docker e Docker Compose Plugin V2..."

# Atualiza pacotes
apt update && apt upgrade -y

# Instala dependências
apt install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common

# Adiciona chave GPG do Docker
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Adiciona repositório do Docker
ARCH=$(dpkg --print-architecture)
echo \
  "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Atualiza e instala Docker Engine + CLI + Containerd + plugin Compose
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Habilita e inicia o serviço Docker
systemctl enable docker
systemctl start docker

# Verifica instalação
docker --version
docker compose version

# Remove docker-compose legado se existir
pip uninstall -y docker-compose || true

echo "[OK] Docker e Docker Compose (V2) instalados com sucesso!"


# 6. Criar diretórios para os serviços
log "📁 Criando estrutura de diretórios..."
mkdir -p /opt/homeassistant
mkdir -p /opt/nodered
mkdir -p /opt/mosquitto/{config,data,log}
mkdir -p /opt/yolo/{models,scripts,data,venv}
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

# Websockets support
listener 9001
protocol websockets
EOF

# 8. Criar docker-compose.yml otimizado para ARM64
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
    # Limitar recursos para TX3
    deploy:
      resources:
        limits:
          memory: 512M

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
    deploy:
      resources:
        limits:
          memory: 256M

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
    deploy:
      resources:
        limits:
          memory: 128M

  portainer:
    container_name: portainer
    image: portainer/portainer-ce:latest
    ports:
      - "9000:9000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 128M

volumes:
  portainer_data:
EOF

# 9. Configurar permissões
log "🔐 Configurando permissões..."
chown -R 1000:1000 /opt/mosquitto
chown -R 1000:1000 /opt/nodered
chown -R 1000:1000 /opt/homeassistant
chown -R $REAL_USER:$REAL_USER /opt/yolo

# 10. Criar ambiente virtual Python para YOLO
log "🐍 Criando ambiente virtual Python para YOLO..."

# Para Ubuntu Jammy, usar Python 3.10 nativo (ideal)
if [[ "$OS_INFO" == *"Ubuntu"* && "$OS_INFO" == *"22.04"* ]]; then
    PYTHON_CMD="python3"  # Python 3.10 nativo no Jammy
    log "Usando Python 3.10 nativo do Ubuntu Jammy"
elif command -v python3.10 &> /dev/null; then
    PYTHON_CMD="python3.10"
    log "Usando Python 3.10 para YOLO"
else
    PYTHON_CMD="python3"
    log "Usando Python padrão para YOLO"
fi

$PYTHON_CMD -m venv /opt/yolo/venv
source /opt/yolo/venv/bin/activate

# Verificar versão no ambiente virtual
log "Versão Python no venv: $(python --version)"

# Atualizar pip no ambiente virtual
python -m pip install --upgrade pip setuptools wheel

# Instalar dependências YOLO com versões específicas para ARM64
log "📦 Instalando pacotes YOLO otimizados para ARM64..."

# Instalar PyTorch primeiro (versão compatível com ARM64)
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu

# Instalar outras dependências
pip install \
    "numpy<1.25" \
    "opencv-python-headless==4.8.*" \
    "pillow>=8.0.0" \
    paho-mqtt \
    requests \
    flask \
    fastapi \
    uvicorn \
    matplotlib \
    scipy

# Instalar ultralytics por último com versão específica
log "📦 Instalando Ultralytics YOLOv8..."
pip install ultralytics==8.3.102

# Verificar instalação
if python -c "from ultralytics import YOLO; print('✅ YOLO importado com sucesso')" 2>/dev/null; then
    log "✅ YOLOv8 instalado e funcionando"
else
    warn "❌ Problema na instalação do YOLOv8"
fi

deactivate

# 11. Criar script de exemplo para YOLO corrigido
log "🎯 Criando script de exemplo YOLO..."
cat > /opt/yolo/scripts/yolo_mqtt.py << 'EOF'
#!/usr/bin/env python3
"""
Script de exemplo: YOLO com MQTT
Detecta objetos e envia resultados via MQTT
Otimizado para Tanix TX3 (S905X3)
"""

import os
import sys
import cv2
import json
import time
import numpy as np
from datetime import datetime
import logging

# Configurar logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

try:
    from ultralytics import YOLO
    import paho.mqtt.client as mqtt
except ImportError as e:
    logger.error(f"Erro ao importar dependências: {e}")
    logger.info("Execute: source /opt/yolo/venv/bin/activate")
    sys.exit(1)

# Configurações
MQTT_BROKER = "localhost"
MQTT_PORT = 1883
MQTT_TOPIC = "yolo/detections"
MODEL_PATH = "/opt/yolo/models/yolov8n.pt"

class YOLODetector:
    def __init__(self):
        self.model = None
        self.mqtt_client = None
        self.setup_mqtt()
        self.load_model()
    
    def setup_mqtt(self):
        """Configurar cliente MQTT"""
        try:
            self.mqtt_client = mqtt.Client()
            self.mqtt_client.on_connect = self.on_mqtt_connect
            self.mqtt_client.on_disconnect = self.on_mqtt_disconnect
            self.mqtt_client.connect(MQTT_BROKER, MQTT_PORT, 60)
            self.mqtt_client.loop_start()
            logger.info("Cliente MQTT configurado")
        except Exception as e:
            logger.error(f"Erro ao configurar MQTT: {e}")
    
    def on_mqtt_connect(self, client, userdata, flags, rc):
        if rc == 0:
            logger.info("Conectado ao broker MQTT")
        else:
            logger.error(f"Falha na conexão MQTT: {rc}")
    
    def on_mqtt_disconnect(self, client, userdata, rc):
        logger.info("Desconectado do broker MQTT")
    
    def load_model(self):
        """Carregar modelo YOLO"""
        try:
            # Tentar carregar modelo local primeiro
            if os.path.exists(MODEL_PATH):
                self.model = YOLO(MODEL_PATH)
                logger.info(f"Modelo carregado de {MODEL_PATH}")
            else:
                # Baixar modelo se não existir
                logger.info("Baixando modelo YOLOv8n...")
                self.model = YOLO('yolov8n.pt')
                # Salvar modelo localmente
                os.makedirs(os.path.dirname(MODEL_PATH), exist_ok=True)
                # Copiar modelo para diretório local
                import shutil
                shutil.copy('yolov8n.pt', MODEL_PATH)
                logger.info(f"Modelo salvo em {MODEL_PATH}")
                
            # Configurar modelo para CPU
            if hasattr(self.model, 'to'):
                self.model.to('cpu')
            
            # Fazer uma predição de teste para verificar se está funcionando
            logger.info("Testando modelo...")
            test_results = self.model("https://ultralytics.com/images/bus.jpg", verbose=False)
            logger.info("✅ Modelo testado com sucesso")
            
        except Exception as e:
            logger.error(f"Erro ao carregar modelo YOLO: {e}")
            logger.error("Possíveis soluções:")
            logger.error("1. Verificar versão do Python (recomendado 3.8-3.11)")
            logger.error("2. Reinstalar: sudo /opt/reinstall_yolo.sh")
            logger.error("3. Verificar dependências ARM64")
            raise
    
    def process_detection(self, results, source="unknown"):
        """Processar resultados da detecção"""
        detections = []
        
        try:
            for result in results:
                if hasattr(result, 'boxes') and result.boxes is not None:
                    boxes = result.boxes
                    for box in boxes:
                        detection = {
                            "class": result.names[int(box.cls[0])],
                            "confidence": float(box.conf[0]),
                            "bbox": [float(x) for x in box.xyxy[0].tolist()],
                            "timestamp": datetime.now().isoformat(),
                            "source": source
                        }
                        detections.append(detection)
        except Exception as e:
            logger.error(f"Erro ao processar detecções: {e}")
        
        return detections
    
    def publish_detections(self, detections, source="yolo_detector"):
        """Publicar detecções via MQTT"""
        if not detections:
            return
            
        try:
            message = {
                "source": source,
                "detections": detections,
                "count": len(detections),
                "timestamp": datetime.now().isoformat()
            }
            
            payload = json.dumps(message, indent=2)
            self.mqtt_client.publish(MQTT_TOPIC, payload)
            logger.info(f"Publicadas {len(detections)} detecções via MQTT")
            
            # Log das detecções
            for det in detections:
                logger.info(f"- {det['class']}: {det['confidence']:.2f}")
                
        except Exception as e:
            logger.error(f"Erro ao publicar via MQTT: {e}")
    
    def detect_from_image(self, image_path):
        """Detectar objetos em uma imagem"""
        try:
            logger.info(f"Processando imagem: {image_path}")
            
            # Configurar inferência otimizada para ARM64
            results = self.model(
                image_path,
                conf=0.25,  # Confiança mínima
                iou=0.45,   # IoU threshold
                max_det=50, # Máximo de detecções
                verbose=False
            )
            
            detections = self.process_detection(results, f"image:{image_path}")
            self.publish_detections(detections)
            
            return detections
            
        except Exception as e:
            logger.error(f"Erro na detecção de imagem: {e}")
            return []
    
    def detect_from_camera(self, camera_id=0, duration=10):
        """Detectar objetos da câmera por um tempo determinado"""
        try:
            logger.info(f"Iniciando detecção da câmera {camera_id} por {duration}s")
            
            cap = cv2.VideoCapture(camera_id)
            if not cap.isOpened():
                logger.error(f"Não foi possível abrir câmera {camera_id}")
                return
            
            # Configurar resolução menor para melhor performance
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
            cap.set(cv2.CAP_PROP_FPS, 10)
            
            start_time = time.time()
            frame_count = 0
            
            while (time.time() - start_time) < duration:
                ret, frame = cap.read()
                if not ret:
                    logger.warning("Falha ao capturar frame")
                    continue
                
                # Processar apenas a cada 30 frames para economizar recursos
                frame_count += 1
                if frame_count % 30 != 0:
                    continue
                
                results = self.model(
                    frame,
                    conf=0.5,
                    iou=0.45,
                    max_det=20,
                    verbose=False
                )
                
                detections = self.process_detection(results, f"camera:{camera_id}")
                if detections:
                    self.publish_detections(detections)
                
                time.sleep(0.1)  # Pequena pausa
            
            cap.release()
            logger.info("Detecção da câmera finalizada")
            
        except Exception as e:
            logger.error(f"Erro na detecção da câmera: {e}")
    
    def cleanup(self):
        """Limpar recursos"""
        if self.mqtt_client:
            self.mqtt_client.loop_stop()
            self.mqtt_client.disconnect()

def main():
    detector = YOLODetector()
    
    try:
        # Exemplo 1: Detectar em imagem de teste
        logger.info("=== Teste 1: Imagem de exemplo ===")
        detections = detector.detect_from_image("https://ultralytics.com/images/bus.jpg")
        
        if detections:
            print(f"\n✅ Encontradas {len(detections)} detecções:")
            for det in detections:
                print(f"  - {det['class']}: {det['confidence']:.2f}")
        else:
            print("❌ Nenhuma detecção encontrada")
        
        # Exemplo 2: Câmera (descomente para usar)
        # logger.info("\n=== Teste 2: Câmera (5 segundos) ===")
        # detector.detect_from_camera(camera_id=0, duration=5)
        
        print("\n🎉 Teste concluído com sucesso!")
        print("📊 Verifique os logs MQTT em: mosquitto_sub -h localhost -t 'yolo/detections'")
        
    except KeyboardInterrupt:
        logger.info("Interrompido pelo usuário")
    except Exception as e:
        logger.error(f"Erro durante execução: {e}")
    finally:
        detector.cleanup()

if __name__ == "__main__":
    main()
EOF

chmod +x /opt/yolo/scripts/yolo_mqtt.py

# 12. Criar script wrapper para YOLO
log "🎯 Criando script wrapper para YOLO..."
cat > /opt/yolo/run_yolo.sh << 'EOF'
#!/bin/bash
# Script wrapper para executar YOLO no ambiente virtual

cd /opt/yolo/scripts

# Verificar se ambiente virtual existe
if [ ! -d "/opt/yolo/venv" ]; then
    echo "❌ Ambiente virtual não encontrado em /opt/yolo/venv"
    exit 1
fi

# Ativar ambiente virtual
source /opt/yolo/venv/bin/activate

# Verificar se YOLO está instalado
if ! python -c "from ultralytics import YOLO" 2>/dev/null; then
    echo "❌ YOLOv8 não está instalado ou há problema de compatibilidade"
    echo "💡 Versão Python: $(python --version)"
    echo "💡 Tente reinstalar: sudo /opt/reinstall_yolo.sh"
    exit 1
fi

echo "🚀 Iniciando detector YOLO..."
echo "💡 Versão Python: $(python --version)"
echo "💡 Pressione Ctrl+C para parar"
echo ""

# Definir variáveis de ambiente para ARM64
export OPENBLAS_NUM_THREADS=2
export OMP_NUM_THREADS=2
export MKL_NUM_THREADS=2

python3 yolo_mqtt.py "$@"
EOF

chmod +x /opt/yolo/run_yolo.sh

# 13. Criar script de reinstalação do YOLO
log "🔧 Criando script de reinstalação do YOLO..."
cat > /opt/reinstall_yolo.sh << 'EOF'
#!/bin/bash
# Script para reinstalar YOLO em caso de problemas

echo "🔄 Reinstalando YOLOv8..."

# Detectar sistema
OS_INFO=$(lsb_release -a 2>/dev/null | grep "Description" | cut -d: -f2 | xargs)

# Remover ambiente virtual
rm -rf /opt/yolo/venv

# Recriar ambiente virtual com melhor Python disponível
if [[ "$OS_INFO" == *"Ubuntu"* && "$OS_INFO" == *"22.04"* ]]; then
    python3 -m venv /opt/yolo/venv  # Python 3.10 nativo
elif command -v python3.10 &> /dev/null; then
    python3.10 -m venv /opt/yolo/venv
else
    python3 -m venv /opt/yolo/venv
fi

source /opt/yolo/venv/bin/activate

echo "Sistema: $OS_INFO"
echo "Versão Python: $(python --version)"

# Atualizar pip
python -m pip install --upgrade pip setuptools wheel

# Instalar dependências específicas para Ubuntu Jammy/ARM64
if [[ "$OS_INFO" == *"Ubuntu"* && "$OS_INFO" == *"22.04"* ]]; then
    echo "🎯 Instalação otimizada para Ubuntu Jammy ARM64"
    pip install torch==2.6.0 torchvision==0.21.0 torchaudio --index-url https://download.pytorch.org/whl/cpu
    pip install "numpy==1.23.5" "opencv-python==4.11.0.86"
else
    echo "🎯 Instalação genérica ARM64"
    pip install torch==2.6.0 torchvision==0.21.0 torchaudio --index-url https://download.pytorch.org/whl/cpu
    pip install "numpy==1.23.5" "opencv-python==4.11.0.86"
fi

pip install pillow paho-mqtt requests matplotlib scipy
pip install "ultralytics>=8.0.0,<9.0.0"

# Testar instalação
if python -c "from ultralytics import YOLO; print('✅ YOLO reinstalado com sucesso')"; then
    echo "✅ Reinstalação concluída para $OS_INFO"
else
    echo "❌ Falha na reinstalação"
fi

deactivate
EOF

chmod +x /opt/reinstall_yolo.sh

# 13. Criar script de inicialização melhorado
log "🚀 Criando script de inicialização..."
cat > /opt/start_server.sh << 'EOF'
#!/bin/bash

echo "🚀 Iniciando servidor Tanix TX3..."

# Verificar se Docker está rodando
if ! systemctl is-active --quiet docker; then
    echo "📦 Iniciando Docker..."
    systemctl start docker
    sleep 5
fi

# Ir para diretório do docker-compose
cd /opt/docker-compose

# Parar containers existentes (se houver)
docker-compose down 2>/dev/null || true

# Iniciar serviços
echo "📦 Iniciando containers..."
docker-compose up -d

# Aguardar serviços iniciarem
echo "⏳ Aguardando serviços iniciarem..."
sleep 45

# Verificar status
echo "📊 Status dos serviços:"
docker-compose ps

# Verificar se serviços estão respondendo
echo ""
echo "🔍 Testando conectividade..."

# Testar Home Assistant
if curl -s -o /dev/null -w "%{http_code}" http://localhost:8123 | grep -q "200\|302"; then
    echo "✅ Home Assistant: OK"
else
    echo "❌ Home Assistant: Não respondendo"
fi

# Testar Node-RED
if curl -s -o /dev/null -w "%{http_code}" http://localhost:1880 | grep -q "200"; then
    echo "✅ Node-RED: OK"
else
    echo "❌ Node-RED: Não respondendo"
fi

# Testar Portainer
if curl -s -o /dev/null -w "%{http_code}" http://localhost:9000 | grep -q "200"; then
    echo "✅ Portainer: OK"
else
    echo "❌ Portainer: Não respondendo"
fi

# Testar MQTT
if timeout 5 mosquitto_pub -h localhost -t test -m "test" 2>/dev/null; then
    echo "✅ MQTT Broker: OK"
else
    echo "❌ MQTT Broker: Não respondendo"
fi

echo ""
echo "🌐 Serviços disponíveis:"
IP=$(hostname -I | awk '{print $1}')
echo "• Home Assistant: http://$IP:8123"
echo "• Node-RED: http://$IP:1880"
echo "• Portainer: http://$IP:9000"
echo "• MQTT Broker: $IP:1883"
echo ""
echo "🎯 Para testar YOLO:"
echo "sudo -u $SUDO_USER /opt/yolo/run_yolo.sh"
echo ""
echo "📊 Para monitorar MQTT:"
echo "mosquitto_sub -h localhost -t 'yolo/detections'"
EOF

chmod +x /opt/start_server.sh

# 14. Criar serviço systemd melhorado
log "⚙️ Criando serviço systemd..."
cat > /etc/systemd/system/tanix-server.service << 'EOF'
[Unit]
Description=Tanix TX3 IoT Server
After=docker.service network.target
Requires=docker.service
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/start_server.sh
ExecStop=/bin/bash -c 'cd /opt/docker-compose && docker-compose down'
ExecReload=/bin/bash -c 'cd /opt/docker-compose && docker-compose restart'
TimeoutStartSec=300
TimeoutStopSec=60
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tanix-server.service

# 15. Instalar cliente MQTT para testes
log "🦟 Instalando cliente MQTT..."
apt install -y mosquitto-clients

# 16. Configurar firewall básico
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

# 17. Criar arquivo de informações do sistema
log "📋 Criando arquivo de informações..."
cat > /opt/system_info.txt << EOF
===========================================
TANIX TX3 IoT SERVER - INFORMAÇÕES
===========================================

Instalado em: $(date)
IP do sistema: $(hostname -I | awk '{print $1}')

SERVIÇOS:
• Home Assistant: http://$(hostname -I | awk '{print $1}'):8123
• Node-RED: http://$(hostname -I | awk '{print $1}'):1880  
• Portainer: http://$(hostname -I | awk '{print $1}'):9000
• MQTT Broker: $(hostname -I | awk '{print $1}'):1883

DIRETÓRIOS:
• Configurações: /opt/
• Home Assistant: /opt/homeassistant
• Node-RED: /opt/nodered
• MQTT: /opt/mosquitto
• YOLO: /opt/yolo

COMANDOS ÚTEIS:
• Iniciar servidor: sudo systemctl start tanix-server
• Parar servidor: sudo systemctl stop tanix-server
• Reiniciar servidor: sudo systemctl restart tanix-server
• Status: sudo systemctl status tanix-server
• Logs Docker: cd /opt/docker-compose && docker-compose logs [serviço]
• Testar YOLO: sudo -u $REAL_USER /opt/yolo/run_yolo.sh
• Monitor MQTT: mosquitto_sub -h localhost -t 'yolo/detections'

AMBIENTE YOLO:
• Ambiente virtual: /opt/yolo/venv
• Scripts: /opt/yolo/scripts
• Modelos: /opt/yolo/models
• Ativar env: source /opt/yolo/venv/bin/activate

ESPECIFICAÇÕES DO SISTEMA:
• CPU: $(nproc) cores
• RAM: $(free -h | awk '/^Mem:/{print $2}')
• Swap: $(free -h | awk '/^Swap:/{print $2}')
• Armazenamento: $(df -h / | awk 'NR==2{print $2}') total

===========================================
EOF

chown $REAL_USER:$REAL_USER /opt/system_info.txt

# 18. Iniciar serviços
log "🚀 Iniciando serviços..."
/opt/start_server.sh

# 19. Mostrar informações finais
clear
log "🎉 Configuração concluída com sucesso!"
echo ""
cat /opt/system_info.txt
echo ""
echo "⚠️  PRÓXIMOS PASSOS:"
echo "1. Reinicie o sistema: sudo reboot"
echo "2. Acesse Home Assistant e configure inicial"
echo "3. Configure Node-RED conforme necessário"
echo "4. Teste YOLO: sudo -u $REAL_USER /opt/yolo/run_yolo.sh"
echo "5. Se YOLO falhar: sudo /opt/reinstall_yolo.sh"
echo ""
echo "⚠️ PROBLEMAS COMUNS YOLO:"
echo "• Python incompatível: Use Python 3.8-3.11"
echo "• Erro ARM64: Reinstale com /opt/reinstall_yolo.sh"
echo "• Falta memória: Aumente swap ou reduza carga"
echo ""
echo "📖 Informações salvas em: /opt/system_info.txt"
echo "=========================================="

log "✅ Script executado com sucesso!"
log "🔄 Recomendado reiniciar: sudo reboot"
