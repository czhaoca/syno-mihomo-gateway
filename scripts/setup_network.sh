#!/bin/bash

# Load environment variables
if [ -f .env ]; then
  export $(cat .env | grep -v '#' | xargs)
else
  echo "Error: .env file not found. Please copy .env.example to .env and configure it."
  exit 1
fi

echo "========================================"
echo " Synology Mihomo Gateway Setup Script "
echo "========================================"

# 1. Fix TUN Permissions (Crucial for Synology)
echo "[1/3] Setting up TUN device permissions..."
if [ ! -c /dev/net/tun ]; then
  mkdir -p /dev/net
  mknod /dev/net/tun c 10 200
fi
chmod 666 /dev/net/tun
echo "      Done."

# 2. Detect Active Interface
echo "[2/3] Auto-detecting active network interface..."
# Logic: Find the interface that routes to the Router IP
PARENT_INTERFACE=$(ip route get $ROUTER_IP | grep -oP 'dev \K\S+')

if [ -z "$PARENT_INTERFACE" ]; then
    # Fallback method
    PARENT_INTERFACE=$(ip route show | grep default | awk '{print $5}' | head -n 1)
fi

if [ -z "$PARENT_INTERFACE" ]; then
    echo "      Error: Could not detect active interface. Please check .env settings."
    exit 1
fi
echo "      Detected Interface: $PARENT_INTERFACE"

# 3. Create Docker Macvlan Network
echo "[3/3] Creating Docker Network ($SUBNET_CIDR)..."

# Remove old network if exists to avoid conflicts
if docker network ls | grep -q "tproxy_network"; then
    echo "      Network 'tproxy_network' exists. Removing to re-create..."
    docker network rm tproxy_network > /dev/null
fi

docker network create -d macvlan \
  --subnet=$SUBNET_CIDR \
  --gateway=$ROUTER_IP \
  -o parent=$PARENT_INTERFACE \
  tproxy_network

if [ $? -eq 0 ]; then
    echo "      Success! Network created."
    echo "========================================"
    echo "Ready to deploy! Run: docker-compose up -d"
else
    echo "      Failed to create network. Check Docker logs."
    exit 1
fi

# 4. Docker Registry & Image Pull (China/Private Support)
if [ -n "$DOCKER_REGISTRY" ]; then
    echo
    echo "[4/4] Docker Registry Setup ($DOCKER_REGISTRY)..."
    echo "      Custom registry detected."
    read -p "      Do you want to login and pull images now? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Login
        if [ -z "$DOCKER_USERNAME" ]; then
             read -p "      Enter Docker Username: " DOCKER_USERNAME
        fi
        
        echo "      Logging in to $DOCKER_REGISTRY..."
        # Interactive password input is handled by docker login automatically
        docker login $DOCKER_REGISTRY -u "$DOCKER_USERNAME"
        
        if [ $? -eq 0 ]; then
            # Pull
            echo "      Pulling Mihomo Image: $MIHOMO_IMAGE..."
            docker pull "$MIHOMO_IMAGE"
            
            echo "      Pulling Dashboard Image: $METACUBEXD_IMAGE..."
            docker pull "$METACUBEXD_IMAGE"
            
            echo "      Images pulled successfully."
        else
            echo "      Login failed. Skipping image pull."
        fi
    else
        echo "      Skipping login/pull."
    fi
else
    echo
    echo "[4/4] No Custom Registry configured. Skipping login."
fi

