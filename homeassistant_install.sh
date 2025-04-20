#!/bin/bash
#######################################################################
##                                                                   ##
## INSTALADOR COMPLETO PARA HOME ASSISTANT SUPERVISED + ECOSSISTEMA ##
## FEITO PARA TANIX TX3 COM ARMBIAN (aarch64)                        ##
##                                                                   ##
#######################################################################

set -o errexit
set -o errtrace
set -o nounset
set -o pipefail

readonly HOSTNAME="homeassistant"

update_hostname() {
    echo "Alterando hostname para: ${HOSTNAME}"
    hostnamectl set-hostname "${HOSTNAME}"
}

install_dependencies() {
  echo "Instalando dependências básicas..."
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
    systemd-resolved \
    avahi-daemon \
    mosquitto \
    mosquitto-clients \
    python3 \
    python3-pip \
    python3-venv
}

install_docker() {
  echo "Instalando Docker..."
  curl -fsSL https://get.docker.com | sh
}

install_os_agent() {
  echo "Instalando os-agent..."
  ARCH=$(uname -m)
  if [[ "$ARCH" == "aarch64" ]]; then
    wget https://github.com/home-assistant/os-agent/releases/latest/download/os-agent_1.6.0_linux_aarch64.deb
    dpkg -i os-agent_1.6.0_linux_aarch64.deb || apt --fix-broken install -y
  else
    echo "Arquitetura não suportada para os-agent: $ARCH"
    exit 1
  fi
}

install_supervised() {
  echo "Instalando Home Assistant Supervised..."
  wget https://github.com/home-assistant/supervised-installer/releases/latest/download/homeassistant-supervised.deb
  dpkg -i homeassistant-supervised.deb || apt --fix-broken install -y
}

setup_directories() {
  echo "Criando diretórios para Mosquitto e Node-RED..."
  mkdir -p /opt/mosquitto/config /opt/mosquitto/data /opt/mosquitto/log
  mkdir -p /opt/nodered/data

  echo "Criando configuração do Mosquitto..."
  cat <<EOF > /opt/mosquitto/config/mosquitto.conf
allow_anonymous false
password_file /mosquitto/config/password.txt
persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log
EOF

  echo "Criando usuário MQTT..."
  mosquitto_passwd -b -c /opt/mosquitto/config/password.txt HAENFASE HAENFASE2025
}

create_docker_services() {
  echo "Criando containers adicionais: Mosquitto e Node-RED..."
  
  docker run -d --restart unless-stopped --network host \
    -v /opt/mosquitto/config:/mosquitto/config \
    -v /opt/mosquitto/data:/mosquitto/data \
    -v /opt/mosquitto/log:/mosquitto/log \
    --name mosquitto eclipse-mosquitto:latest

  docker run -d --restart unless-stopped --network host \
    -v /opt/nodered/data:/data \
    --name nodered nodered/node-red:latest
}

install_python_yolo() {
  echo "Instalando ambiente virtual para YOLOv8..."
  mkdir -p /opt/yolo-env
  python3 -m venv /opt/yolo-env
  source /opt/yolo-env/bin/activate
  pip install --upgrade pip
  pip install ultralytics opencv-python numpy requests paho-mqtt imutils schedule
  deactivate
}

main() {
  if [[ $EUID -ne 0 ]]; then
    echo "Este script deve ser executado como root"
    exit 1
  fi

  update_hostname
  install_dependencies
  install_docker
  install_os_agent
  install_supervised
  setup_directories
  create_docker_services
  install_python_yolo

  ip_addr=$(hostname -I | cut -d ' ' -f1)
  echo ""
  echo "======================================================================="
  echo "✅ Ambiente instalado com sucesso!"
  echo "Home Assistant Supervised: http://${HOSTNAME}.local:8123 ou http://${ip_addr}:8123"
  echo "Node-RED: http://${ip_addr}:1880"
  echo "MQTT em funcionamento com:"
  echo "  Usuário: HAENFASE"
  echo "  Senha:   HAENFASE2025"
  echo "YOLOv8 disponível em: /opt/yolo-env (use 'source bin/activate')"
  echo "======================================================================="
}

main
