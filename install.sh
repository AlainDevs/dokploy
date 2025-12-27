#!/bin/bash

# Detect version from environment variable or default to latest
# Usage with curl (export first): export DOKPLOY_VERSION=canary && curl -sSL https://dokploy.com/install.sh | sh
# Usage with curl (export first): export DOKPLOY_VERSION=feature && curl -sSL https://dokploy.com/install.sh | sh
# Usage with curl (bash -s): DOKPLOY_VERSION=canary bash -s < <(curl -sSL https://dokploy.com/install.sh)
# Usage with curl (default): curl -sSL https://dokploy.com/install.sh | sh (defaults to latest)
# Usage with bash: DOKPLOY_VERSION=canary bash install.sh
# Usage with bash: DOKPLOY_VERSION=feature bash install.sh
# Usage with bash: bash install.sh (defaults to latest)
detect_version() {
    local version="${DOKPLOY_VERSION:-latest}"
    echo "$version"
}

# Function to detect if running in Proxmox LXC container
is_proxmox_lxc() {
    # Check for LXC in environment
    if [ -n "$container" ] && [ "$container" = "lxc" ]; then
        return 0  # LXC container
    fi
    
    # Check for LXC in /proc/1/environ
    if grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
        return 0  # LXC container
    fi
    
    return 1  # Not LXC
}

# Ask yes/no question with default value
ask_yes_no() {
    local prompt="$1"
    local default="$2"
    local response
    
    if [ "$default" = "y" ]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi
    
    printf "%s" "$prompt"
    read -r response
    
    if [ -z "$response" ]; then
        response="$default"
    fi
    
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# Ask for input with prompt
ask_input() {
    local prompt="$1"
    local response
    printf "%s" "$prompt" >&2
    read -r response
    echo "$response"
}

install_dokploy() {
    # Detect version tag
    VERSION_TAG=$(detect_version)
    # Using custom image with service-level labels support for Traefik
    DOCKER_IMAGE="alan1242/dokploy:service-labels"
    
    echo "Installing Dokploy version: ${VERSION_TAG}"
    if [ "$(id -u)" != "0" ]; then
        echo "This script must be run as root" >&2
        exit 1
    fi

    # check if is Mac OS
    if [ "$(uname)" = "Darwin" ]; then
        echo "This script must be run on Linux" >&2
        exit 1
    fi

    # check if is running inside a container
    if [ -f /.dockerenv ]; then
        echo "This script must be run on Linux" >&2
        exit 1
    fi

    # check if something is running on port 80
    if ss -tulnp | grep ':80 ' >/dev/null; then
        echo "Error: something is already running on port 80" >&2
        exit 1
    fi

    # check if something is running on port 443
    if ss -tulnp | grep ':443 ' >/dev/null; then
        echo "Error: something is already running on port 443" >&2
        exit 1
    fi

    # check if something is running on port 3000
    if ss -tulnp | grep ':3000 ' >/dev/null; then
        echo "Error: something is already running on port 3000" >&2
        echo "Dokploy requires port 3000 to be available. Please stop any service using this port." >&2
        exit 1
    fi

    command_exists() {
      command -v "$@" > /dev/null 2>&1
    }

    if command_exists docker; then
      echo "Docker already installed"
    else
      curl -sSL https://get.docker.com | sh -s -- --version 28.5.0
    fi

    # Check if running in Proxmox LXC container and set endpoint mode
    endpoint_mode=""
    if is_proxmox_lxc; then
        echo "⚠️ WARNING: Detected Proxmox LXC container environment!"
        echo "Adding --endpoint-mode dnsrr to Docker services for LXC compatibility."
        echo "This may affect service discovery but is required for LXC containers."
        echo ""
        endpoint_mode="--endpoint-mode dnsrr"
        echo "Waiting for 5 seconds before continuing..."
        sleep 5
    fi


    docker swarm leave --force 2>/dev/null

    get_ip() {
        local ip=""
        
        # Try IPv4 first
        # First attempt: ifconfig.io
        ip=$(curl -4s --connect-timeout 5 https://ifconfig.io 2>/dev/null)
        
        # Second attempt: icanhazip.com
        if [ -z "$ip" ]; then
            ip=$(curl -4s --connect-timeout 5 https://icanhazip.com 2>/dev/null)
        fi
        
        # Third attempt: ipecho.net
        if [ -z "$ip" ]; then
            ip=$(curl -4s --connect-timeout 5 https://ipecho.net/plain 2>/dev/null)
        fi

        # If no IPv4, try IPv6
        if [ -z "$ip" ]; then
            # Try IPv6 with ifconfig.io
            ip=$(curl -6s --connect-timeout 5 https://ifconfig.io 2>/dev/null)
            
            # Try IPv6 with icanhazip.com
            if [ -z "$ip" ]; then
                ip=$(curl -6s --connect-timeout 5 https://icanhazip.com 2>/dev/null)
            fi
            
            # Try IPv6 with ipecho.net
            if [ -z "$ip" ]; then
                ip=$(curl -6s --connect-timeout 5 https://ipecho.net/plain 2>/dev/null)
            fi
        fi

        if [ -z "$ip" ]; then
            echo "Error: Could not determine server IP address automatically (neither IPv4 nor IPv6)." >&2
            echo "Please set the ADVERTISE_ADDR environment variable manually." >&2
            echo "Example: export ADVERTISE_ADDR=<your-server-ip>" >&2
            exit 1
        fi

        echo "$ip"
    }

    get_private_ip() {
        ip addr show | grep -E "inet (192\.168\.|10\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.)" | head -n1 | awk '{print $2}' | cut -d/ -f1
    }

    advertise_addr="${ADVERTISE_ADDR:-$(get_private_ip)}"

    if [ -z "$advertise_addr" ]; then
        echo "ERROR: We couldn't find a private IP address."
        echo "Please set the ADVERTISE_ADDR environment variable manually."
        echo "Example: export ADVERTISE_ADDR=192.168.1.100"
        exit 1
    fi
    echo "Using advertise address: $advertise_addr"

    # Allow custom Docker Swarm init arguments via DOCKER_SWARM_INIT_ARGS environment variable
    # Example: export DOCKER_SWARM_INIT_ARGS="--default-addr-pool 172.20.0.0/16 --default-addr-pool-mask-length 24"
    # This is useful to avoid CIDR overlapping with cloud provider VPCs (e.g., AWS)
    swarm_init_args="${DOCKER_SWARM_INIT_ARGS:-}"
    
    if [ -n "$swarm_init_args" ]; then
        echo "Using custom swarm init arguments: $swarm_init_args"
        docker swarm init --advertise-addr $advertise_addr $swarm_init_args
    else
        docker swarm init --advertise-addr $advertise_addr
    fi
    
     if [ $? -ne 0 ]; then
        echo "Error: Failed to initialize Docker Swarm" >&2
        exit 1
    fi

    echo "Swarm initialized"

    docker network rm -f dokploy-network 2>/dev/null
    docker network create --driver overlay --attachable dokploy-network

    echo "Network created"

    # Ask about Traefik Global Mode
    echo ""
    echo "=== Traefik Configuration ==="
    TRAEFIK_GLOBAL_MODE="n"
    SPACESHIP_ENABLED="n"
    SPACESHIP_API_KEY=""
    SPACESHIP_API_SECRET=""
    ACME_EMAIL=""

    if ask_yes_no "Do you want to run Traefik in Global Mode (HA for multi-node Swarm)?" "n"; then
        TRAEFIK_GLOBAL_MODE="y"
        echo "Traefik will be deployed in Global Mode."
        
        # Ask about Spaceship DNS provider
        if ask_yes_no "Do you want to use Spaceship DNS provider for SSL certificates?" "n"; then
            SPACESHIP_ENABLED="y"
            
            SPACESHIP_API_KEY=$(ask_input "Enter your Spaceship API Key: ")
            if [ -z "$SPACESHIP_API_KEY" ]; then
                echo "Error: Spaceship API Key is required" >&2
                exit 1
            fi
            
            SPACESHIP_API_SECRET=$(ask_input "Enter your Spaceship API Secret: ")
            if [ -z "$SPACESHIP_API_SECRET" ]; then
                echo "Error: Spaceship API Secret is required" >&2
                exit 1
            fi
            
            ACME_EMAIL=$(ask_input "Enter your email for Let's Encrypt notifications: ")
            if [ -z "$ACME_EMAIL" ]; then
                echo "Error: Email is required for Let's Encrypt" >&2
                exit 1
            fi
            
            echo "Spaceship DNS provider configured."
        fi
    fi

    mkdir -p /etc/dokploy

    chmod 777 /etc/dokploy

    # Get the hostname of the current node to pin services to this specific machine
    # This prevents data persistence issues when services restart in multi-node Swarm
    NODE_HOSTNAME=$(hostname)
    echo "Pinning Dokploy services to node: $NODE_HOSTNAME"

    docker service create \
    --name dokploy-postgres \
    --constraint "node.hostname == $NODE_HOSTNAME" \
    --network dokploy-network \
    --env POSTGRES_USER=dokploy \
    --env POSTGRES_DB=dokploy \
    --env POSTGRES_PASSWORD=amukds4wi9001583845717ad2 \
    --mount type=volume,source=dokploy-postgres,target=/var/lib/postgresql/data \
    $endpoint_mode \
    postgres:16

    docker service create \
    --name dokploy-redis \
    --constraint "node.hostname == $NODE_HOSTNAME" \
    --network dokploy-network \
    --mount type=volume,source=dokploy-redis,target=/data \
    $endpoint_mode \
    redis:7

    # Installation
    # Set RELEASE_TAG environment variable for canary/feature versions
    release_tag_env=""
    if [ "$VERSION_TAG" != "latest" ]; then
        release_tag_env="-e RELEASE_TAG=$VERSION_TAG"
    fi
    
    docker service create \
      --name dokploy \
      --replicas 1 \
      --network dokploy-network \
      --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
      --mount type=bind,source=/etc/dokploy,target=/etc/dokploy \
      --mount type=volume,source=dokploy,target=/root/.docker \
      --publish published=3000,target=3000,mode=host \
      --update-parallelism 1 \
      --update-order stop-first \
      --constraint "node.hostname == $NODE_HOSTNAME" \
      $endpoint_mode \
      $release_tag_env \
      -e ADVERTISE_ADDR=$advertise_addr \
      $DOCKER_IMAGE

    sleep 4

    # Setup Traefik directories (required for all modes)
    mkdir -p /etc/dokploy/traefik/dynamic
    touch /etc/dokploy/traefik/acme.json
    chmod 600 /etc/dokploy/traefik/acme.json

    if [ "$TRAEFIK_GLOBAL_MODE" = "y" ]; then
        echo "Deploying Traefik in Global Mode..."
        
        if [ "$SPACESHIP_ENABLED" = "y" ]; then
            # Global Mode with Spaceship DNS Challenge
            docker service create \
                --name dokploy-traefik \
                --mode global \
                --network dokploy-network \
                --constraint 'node.role == manager' \
                --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
                --mount type=bind,src=/etc/dokploy/traefik,dst=/etc/dokploy/traefik \
                --publish mode=host,target=80,published=80 \
                --publish mode=host,target=443,published=443 \
                --publish mode=host,target=8080,published=8080 \
                --env SPACESHIP_API_KEY="$SPACESHIP_API_KEY" \
                --env SPACESHIP_API_SECRET="$SPACESHIP_API_SECRET" \
                traefik:v3.6 \
                --providers.swarm=true \
                --providers.swarm.exposedbydefault=false \
                --providers.swarm.network=dokploy-network \
                --entrypoints.web.address=:80 \
                --entrypoints.websecure.address=:443 \
                --entrypoints.web.http.redirections.entryPoint.to=websecure \
                --entrypoints.web.http.redirections.entryPoint.scheme=https \
                --certificatesresolvers.letsencrypt.acme.dnschallenge=true \
                --certificatesresolvers.letsencrypt.acme.dnschallenge.provider=spaceship \
                --certificatesresolvers.letsencrypt.acme.dnschallenge.resolvers=1.1.1.1:53 \
                --certificatesresolvers.letsencrypt.acme.dnschallenge.delaybeforecheck=120 \
                --certificatesresolvers.letsencrypt.acme.email="$ACME_EMAIL" \
                --certificatesresolvers.letsencrypt.acme.storage=/etc/dokploy/traefik/acme.json \
                --api.dashboard=true \
                --accesslog=true \
                --log.level=INFO
        else
            # Global Mode without Spaceship (uses traefik.yml config)
            docker service create \
                --name dokploy-traefik \
                --mode global \
                --constraint 'node.role==manager' \
                --network dokploy-network \
                --mount type=bind,source=/etc/dokploy/traefik/traefik.yml,target=/etc/traefik/traefik.yml \
                --mount type=bind,source=/etc/dokploy/traefik/dynamic,target=/etc/dokploy/traefik/dynamic \
                --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
                --publish mode=host,published=443,target=443 \
                --publish mode=host,published=80,target=80 \
                --publish mode=host,published=443,target=443,protocol=udp \
                traefik:v3.6.1
        fi
    else
        # Default: Single container mode (original behavior)
        docker run -d \
            --name dokploy-traefik \
            --restart always \
            -v /etc/dokploy/traefik/traefik.yml:/etc/traefik/traefik.yml \
            -v /etc/dokploy/traefik/dynamic:/etc/dokploy/traefik/dynamic \
            -v /var/run/docker.sock:/var/run/docker.sock:ro \
            -p 80:80/tcp \
            -p 443:443/tcp \
            -p 443:443/udp \
            traefik:v3.6.1
        
        docker network connect dokploy-network dokploy-traefik
    fi

    GREEN="\033[0;32m"
    YELLOW="\033[1;33m"
    BLUE="\033[0;34m"
    NC="\033[0m" # No Color

    format_ip_for_url() {
        local ip="$1"
        if echo "$ip" | grep -q ':'; then
            # IPv6
            echo "[${ip}]"
        else
            # IPv4
            echo "${ip}"
        fi
    }

    public_ip="${ADVERTISE_ADDR:-$(get_ip)}"
    formatted_addr=$(format_ip_for_url "$public_ip")
    echo ""
    printf "${GREEN}Congratulations, Dokploy is installed!${NC}\n"
    printf "${BLUE}Wait 15 seconds for the server to start${NC}\n"
    printf "${YELLOW}Please go to http://${formatted_addr}:3000${NC}\n\n"
}

update_dokploy() {
    # Detect version tag
    VERSION_TAG=$(detect_version)
    # Using custom image with service-level labels support for Traefik
    DOCKER_IMAGE="alan1242/dokploy:service-labels"
    
    echo "Updating Dokploy to version: ${VERSION_TAG}"
    
    # Pull the image
    docker pull $DOCKER_IMAGE

    # Update the service
    docker service update --image $DOCKER_IMAGE dokploy

    echo "Dokploy has been updated to version: ${VERSION_TAG}"
}

# Main script execution
if [ "$1" = "update" ]; then
    update_dokploy
else
    install_dokploy
fi
