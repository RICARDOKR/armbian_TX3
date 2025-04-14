#######################################################################
##                                                                   ##
## THIS SCRIPT SHOULD ONLY BE RUN ON A TANIX TX3 BOX RUNNING ARMBIAN ##
##                                                                   ##
#######################################################################

set -o errexit
set -o errtrace
set -o nounset
set -o pipefail

readonly HOSTNAME="homeassistant"

update_hostname() {
    echo ""
    echo "Alterando hostname para: ${HOSTNAME}"
    hostnamectl set-hostname "${HOSTNAME}"
}

install_dependences() {
  echo ""
  echo "Instalando dependências básicas..."
  echo ""
  apt-get update
  apt-get install \
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
    mosquitto mosquitto-clients \
    python3 python3-pip python3-venv -y
}

install_docker() {
  echo ""
  echo "Instalando Docker..."
  echo ""
  curl -fsSL https://get.docker.com | sh
}

setup_directories() {
  echo "Criando diretórios para Docker volumes..."
  mkdir -p /opt/homeassistant/config
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

  echo "Criando usuário do MQTT..."
  mosquitto_passwd -b -c /opt/mosquitto/config/password.txt HAENFASE HAENFASE2025
}

create_docker_compose() {
  echo "Criando docker-compose.yml..."
  cat <<EOF > /opt/docker-compose.yml
version: '3.7'
services:
  homeassistant:
    container_name: homeassistant
    image: ghcr.io/home-assistant/home-assistant:stable
    volumes:
      - /opt/homeassistant/config:/config
      - /etc/localtime:/etc/localtime:ro
    restart: unless-stopped
    network_mode: host

  mosquitto:
    container_name: mosquitto
    image: eclipse-mosquitto:latest
    volumes:
      - /opt/mosquitto/config:/mosquitto/config
      - /opt/mosquitto/data:/mosquitto/data
      - /opt/mosquitto/log:/mosquitto/log
    restart: unless-stopped
    network_mode: host

  nodered:
    container_name: nodered
    image: nodered/node-red:latest
    user: "0:0"
    volumes:
      - /opt/nodered/data:/data
    restart: unless-stopped
    network_mode: host
EOF
}

install_python_yolo() {
  echo "Instalando Python + ambiente virtual para YOLOv8..."
  mkdir -p /opt/yolo-env
  python3 -m venv /opt/yolo-env
  source /opt/yolo-env/bin/activate
  pip install --upgrade pip
  pip install ultralytics opencv-python numpy requests paho-mqtt imutils schedule
  deactivate
}

start_containers() {
  echo "Iniciando containers com Docker Compose..."
  cd /opt
  docker compose up -d
}

main() {
  if [[ $EUID -ne 0 ]]; then
    echo "Este script deve ser executado como root. Rode:"
    echo "  sudo su"
    exit 1
  fi

  update_hostname
  install_dependences
  install_docker
  setup_directories
  create_docker_compose
  install_python_yolo
  start_containers

  ip_addr=$(hostname -I | cut -d ' ' -f1)
  echo ""
  echo "======================================================================="
  echo "Home Assistant, Mosquitto (MQTT), Node-RED e YOLOv8 agora estão prontos!"
  echo "Acesse o Home Assistant em: http://${HOSTNAME}.local:8123 ou http://${ip_addr}:8123"
  echo "Node-RED: http://${ip_addr}:1880"
  echo "MQTT está pronto para uso com:"
  echo "  Usuário: HAENFASE"
  echo "  Senha:   HAENFASE2025"
  echo "YOLOv8 está disponível em: /opt/yolo-env (use source bin/activate para ativar)"
  echo "======================================================================="
}

main
