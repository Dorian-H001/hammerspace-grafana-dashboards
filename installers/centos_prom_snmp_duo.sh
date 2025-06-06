#!/bin/bash

# Intro and User confirmation
echo ""
echo "================================================================="
echo "Unified Prometheus + SNMP Exporter Setup for CentOS 8.5+ Systems"
echo "================================================================="
echo ""
echo "This script will:"
echo " - Install needed modules and packages."
echo " - Install Docker and Docker compose v2 if needed."
echo " - Install Grafana (unless already running)."
echo " - Download a default snmp.yml file."
echo " - Prompt user for full file path to prometheus.yml after generation."
echo " - Build a Docker container with Prometheus and SNMP Exporter."
echo ""
echo "IMPORTANT:"
echo " - Ensure you also have the repository hammerspace-grafana-dashboards from hammer-space cloned or on your CentOS environment."
echo "   (Needed for generation of prometheus.yml, has instructions for generation)"
echo " - You may run this script first to install Grafana, it will stop and prompt for the prometheus.yml file path after."
echo " - You will need to create a service account:"
echo "    - Administration > Users and Access > Service Accounts"
echo "    - Create the Service Account with role of admin."
echo ""
echo "If unsure, stop and consult setup documentation."
echo ""

while true; do
  read -p "Continue with setup? (y/n): " confirm
  if [[ $confirm =~ ^[Yy]$ || $confirm =~ ^[Yy][Ee][Ss]$ ]]; then
    break
  elif [[ $confirm =~ ^[Nn]$ || $confirm =~ ^[Nn][Oo]$ ]]; then
    echo ""
    echo "Aborted."
    exit 1
  else
    echo "Please enter yes or no."
  fi
done


# centos_prom_snmp_duo.sh
# INTERNAL USE ONLY CUSTOMERS GET A DIFFERENT ONE.
# Set up Docker and runs a unified Prometheus + SNMP Exporter service together on CentOS 8.5+.
set -euo pipefail
echo ""
echo "Starting Prometheus + SNMP Exporter Duo Setup..."
if [[ $EUID -ne 0 ]]; then
  echo "This script has to run as root. Exiting."
  exit 1
fi

# Checks for Missing Python packages/modules.
echo ""
echo "Checking for required Python packages..."
MISSING=false
# Check PyYAML
if python3 -c "import yaml; v=yaml.__version__.split('.'); exit(0) if int(v[0]) > 5 or (int(v[0]) == 5 and int(v[1]) >= 1) else exit(1)" 2>/dev/null; then
  echo "PyYAML version is compatible"
else
  echo "PyYAML is missing or outdated"
  MISSING=true
fi
# Check requests
if python3 -c "import requests" 2>/dev/null; then
  echo "requests module is present."
else
  echo "requests module is missing."
  MISSING=true
fi
# Check urllib3
if python3 -c "import urllib3" 2>/dev/null; then
  echo "urllib3 module is present."
else
  echo "urllib3 module is missing."
  MISSING=true
fi

# Prompt user to install missing packages or modules.
if [ "$MISSING" = true ]; then
  echo ""
  while true; do
    read -p "One or more required Python modules are missing or outdated. Install required modules now? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ || "$confirm" =~ ^[Yy][Ee][Ss]$ ]]; then
      echo ""
      echo "Installing required packages with pip3..."
      pip3 install --user --upgrade PyYAML requests urllib3
      echo ""
      sleep 1
      echo "Required Python packages are now installed."
      break
    elif [[ "$confirm" =~ ^[Nn]$ || "$confirm" =~ ^[Nn][Oo]$ ]]; then
      echo ""
      echo "Exiting setup. Required Python packages must be installed manually."
      exit 1
    else
      echo "Please enter yes or no."
    fi
  done
fi

# Checks for Docker
if ! command -v docker &> /dev/null; then
  echo "Docker not found. Installing..."
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  dnf install -y docker-ce docker-ce-cli containerd.io
  systemctl enable docker
  systemctl start docker
  echo "Docker installed and started."
else
  echo "Docker is already installed."
fi

# Checks for Docker compose v2
if ! docker compose version &> /dev/null; then
  echo "Docker Compose v2 not found. Installing..."
  mkdir -p ~/.docker/cli-plugins
  curl -SL https://github.com/docker/compose/releases/download/v2.27.1/docker-compose-linux-x86_64 \
    -o ~/.docker/cli-plugins/docker-compose
  chmod +x ~/.docker/cli-plugins/docker-compose
  echo "Docker Compose v2 installed."
else
  echo "Docker Compose v2 is already installed."
fi

# Checks for Grafana, Installs if not already.
if ! systemctl is-active --quiet grafana-server; then
  echo "Grafana not installed or running. Installing..."

  cat <<EOF > /etc/yum.repos.d/grafana.repo
[grafana]
name=Grafana OSS
baseurl=https://packages.grafana.com/oss/rpm
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://packages.grafana.com/gpg.key
EOF

  dnf install -y grafana
  systemctl daemon-reexec
  systemctl enable --now grafana-server
  echo ""
  echo "Grafana installed and running on port 3000 (default user/pass = admin/admin)."
  echo "NOTE: CentOS systems usually block ports by default."
else
  echo "Grafana is already installed and running."
fi

# Prompt user to open required ports.
echo ""
while true; do
  read -p "Would you like to open firewall ports for Grafana (3000), Prometheus (9090), and SNMP Exporter (9116)? (y/n): " confirm
  if [[ $confirm =~ ^[Yy]$ || $confirm =~ ^[Yy][Ee][Ss]$ ]]; then
    firewall-cmd --add-port=3000/tcp --permanent
    firewall-cmd --add-port=9090/tcp --permanent
    firewall-cmd --add-port=9116/tcp --permanent
    firewall-cmd --reload
    echo "Ports 3000, 9090, 9116 are now open."
    echo ""
    break
  elif [[ $confirm =~ ^[Nn]$ || $confirm =~ ^[Nn][Oo]$ ]]; then
    echo "Skipping port configuration, you may need to open ports manually."
    echo ""
    break
  else
    echo "Please enter yes or no."
  fi
done

# Set up project directory
echo "Setting up Directory Structure at /opt/monitoring-duo..."
mkdir -p /opt/monitoring-duo/config
mkdir -p /opt/monitoring-duo/snmp
echo "Directories created."

# Default official download for snmp.yml file from Prometheus Repo
echo "Fetching snmp.yml from Prometheus GitHub..."
curl -sSL https://raw.githubusercontent.com/prometheus/snmp_exporter/main/snmp.yml \
  -o /opt/monitoring-duo/snmp/snmp.yml
echo "snmp.yml downloaded to /opt/monitoring-duo/snmp/"

# Remove deprecated config fields to prevent SNMP Exporter from crashing
sed -i '/datetime_pattern:/d' /opt/monitoring-duo/snmp/snmp.yml
echo "Cleaned deprecated datetime_pattern fields from snmp.yml."

# Additional instructions for prometheus.yml generation.
# Prompt user for path of prometheus.yml
SERVER_IP=$(hostname -I | awk '{print $1}')
while true; do
  echo ""
  echo "If you haven't generated the prometheus.yml file yet, follow these steps:"
  echo "  1. Ensure you have the repo hammerspace-grafana-dashboards by hammer-space cloned or on your CentOS system."
  echo "  2. Navigate to the installers folder"
  echo "      (cd /hammerspace-grafana-dashboards/installers/)"
  echo "  3. Run: ./config.py --sample_config"
  echo "      This generates the config_tooling.ini file needed for prometheus.yml"
  echo "  4. Enter default user/pass = admin/admin and set up a new password for Grafana"
  echo ""
  echo "      Access Grafana at: http://$SERVER_IP:3000"
  echo ""
  echo "  5. Navigate to the service accounts section and set up a new service account with the role of admin,"
  echo "      also generate a service token for your account."
  echo "      (Administration > Users and Access > Service Accounts)"
  echo "  6. Enter your grafana-service-account token and place the IP of the Hammerspace anvil where it says hammerspace1"
  echo "      in the config_tooling.ini file."
  echo "  7. Log into the anvil UI from browser (Google Chrome) with default credentials if you haven't done so already."
  echo "  8. Then run ./config.py --prometheus."
  echo ""
  echo "Example path: /root/hammerspace-grafana-dashboards/installers/prometheus.yml"
  echo ""
  echo "Please enter the full path to the generated prometheus.yml file."
  echo ""
  read -r PROM_YML_PATH
  if [[ -f "$PROM_YML_PATH" ]]; then
    cp "$PROM_YML_PATH" /opt/monitoring-duo/config/prometheus.yml
    echo "prometheus.yml copied to /opt/monitoring-duo/config/"
    break
  else
    echo ""
    echo "Error: prometheus.yml file not found at '$PROM_YML_PATH'. Please try again."
  fi
done

# Generate custom Dockerfile that builds a container that holds Prometheus and SNMP Exporter
# Update PROM_VERSION and SNMP_VERSION manually as newer versions are released
# *** NOTE: update LABEL maintainer ***
echo "Writing Dockerfile to /opt/monitoring-duo..."
cat <<'EOF' > /opt/monitoring-duo/Dockerfile
FROM debian:bullseye-slim

LABEL maintainer="Test Test user.name@email.com"

ENV PROM_VERSION=2.52.0
ENV SNMP_VERSION=0.26.0

RUN apt-get update && \
    apt-get install -y curl tar gzip && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/prometheus /snmp

RUN curl -sSL https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz \
    | tar -xz --strip-components=1 -C /usr/local/bin --wildcards '*/prometheus' '*/promtool'

RUN curl -sSL https://github.com/prometheus/snmp_exporter/releases/download/v${SNMP_VERSION}/snmp_exporter-${SNMP_VERSION}.linux-amd64.tar.gz \
    | tar -xz -C /usr/local/bin --strip-components=1 --wildcards '*/snmp_exporter'

COPY config/prometheus.yml /etc/prometheus/prometheus.yml
COPY snmp/snmp.yml /snmp/snmp.yml
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh
EXPOSE 9090 9116
ENTRYPOINT ["/entrypoint.sh"]
EOF
echo "Dockerfile created."
sleep 1

# Create entrypoint.sh script to launch both Prometheus + SNMP Exporter in the same container.
echo "Creating entrypoint.sh script..."
cat <<'EOF' > /opt/monitoring-duo/entrypoint.sh
#!/bin/bash
# entrypoint.sh
# launches both Prometheus + SNMP Exporter in the same container.

set -e

echo "Starting Prometheus..."
/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prometheus &
PROM_PID=$!

# Handle graceful shutdown if container receives SIGINT/SIGTERM
trap "echo 'Stopping Prometheus...'; kill \$PROM_PID; exit" SIGINT SIGTERM

echo "Starting SNMP Exporter..."
/usr/local/bin/snmp_exporter \
  --config.file=/snmp/snmp.yml
wait "$PROM_PID"
EOF
chmod +x /opt/monitoring-duo/entrypoint.sh
echo "entrypoint.sh script created and made executable."

# Creation of docker-compose.yml
echo "Creating docker-compose.yml"
cat <<'EOF' > /opt/monitoring-duo/docker-compose.yml
version: '3.8'

services:
  prom-snmp:
    build: .
    container_name: prom-snmp-duo
    restart: unless-stopped
    volumes:
      - ./config/prometheus.yml:/etc/prometheus/prometheus.yml
      - ./snmp/snmp.yml:/snmp/snmp.yml
    ports:
      - "9090:9090" # Prometheus
      - "9116:9116" # SNMP Exporter
EOF
echo "docker-compose.yml created at /opt/monitoring-duo/"

# Build the Docker image and start the container
echo "Building Docker image and starting the container..."
cd /opt/monitoring-duo
if docker compose up -d --build; then
  echo ""
  echo "Container launched successfully."
else
  echo ""
  echo "Docker build or launch failed. Check the logs above and fix any errors."
  exit 1
fi

# Brief pause before checking container status
sleep 2
SERVER_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "================================================================="
echo "Access Prometheus at: http://$SERVER_IP:9090"
echo "Access SNMP Exporter at: http://$SERVER_IP:9116/metrics"
echo ""
echo "Checking container status..."
docker ps --filter "name=prom-snmp-duo"
echo ""
echo "================================================================="
echo "Setup complete."