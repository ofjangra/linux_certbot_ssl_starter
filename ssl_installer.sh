#!/bin/bash

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to check if running on Linux
check_os() {
    if [[ "$(uname)" != "Linux" ]]; then
        print_message "$RED" "This script supports only Linux-based systems."
        exit 1
    fi
}

# Function to detect package manager
detect_package_manager() {
    if command -v apt &>/dev/null; then
        echo "apt"
    elif command -v yum &>/dev/null; then
        echo "yum"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    else
        print_message "$RED" "Unsupported package manager."
        exit 1
    fi
}

# Function to update system packages
update_system() {
    local pkg_manager=$1
    print_message "$YELLOW" "Updating system packages..."
    
    case $pkg_manager in
        "apt")
            sudo apt update -y
            ;;
        "yum")
            sudo yum update -y
            ;;
        "pacman")
            sudo pacman -Syu --noconfirm
            ;;
    esac
}

# Function to install web server
install_web_server() {
    local pkg_manager=$1
    local web_server=$2
    
    print_message "$YELLOW" "Installing $web_server..."
    
    case $pkg_manager in
        "apt")
            sudo apt install -y $web_server
            ;;
        "yum")
            sudo yum install -y $web_server
            ;;
        "pacman")
            sudo pacman -S --noconfirm $web_server
            ;;
    esac
}

# Function to install Certbot
install_certbot() {
    local pkg_manager=$1
    local web_server=$2
    
    print_message "$YELLOW" "Installing Certbot and plugins..."
    
    case $pkg_manager in
        "apt")
            sudo apt install -y certbot python3-certbot-${web_server}
            ;;
        "yum")
            sudo yum install -y certbot python3-certbot-${web_server}
            ;;
        "pacman")
            sudo pacman -S --noconfirm certbot certbot-${web_server}
            ;;
    esac
}

# Function to create Nginx configuration
create_nginx_config() {
    local app_name=$1
    local domain=$2
    local port=$3
    
    local config_file="/etc/nginx/nginx.conf"
    local template_file="${SCRIPT_DIR}/templates/nginx/site-template.conf"
    
    # Get template content
    local template_content=$(cat "$template_file")
    
    # Replace placeholders
    local server_block=$(echo "$template_content" | sed "s/{{DOMAIN}}/$domain/g" | sed "s/{{PORT}}/$port/g")
    
    # Check if there's an existing server block for this domain
    if grep -q "server_name $domain;" "$config_file"; then
        print_message "$YELLOW" "Configuration for $domain already exists in nginx.conf"
        return
    fi
    
    # Backup the original configuration
    sudo cp "$config_file" "${config_file}.backup.$(date +%Y%m%d%H%M%S)"
    
    # Add the server block before the last closing brace in http section
    sudo sed -i "/http {/,\$s/.*}/server {\n    listen 80;\n    listen [::]:80;\n    server_name $domain;\n\n    location \/ {\n        proxy_pass http:\/\/localhost:$port;\n        proxy_set_header Host \$host;\n        proxy_set_header X-Real-IP \$remote_addr;\n        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto \$scheme;\n    }\n}\n}/1" "$config_file"
    
    print_message "$GREEN" "Added configuration for $domain to nginx.conf"
}

# Function to create Apache configuration
create_apache_config() {
    local app_name=$1
    local domain=$2
    local port=$3
    
    local config_file="/etc/apache2/sites-available/000-default.conf"
    local template_file="${SCRIPT_DIR}/templates/apache/site-template.conf"
    
    # Get template content and replace placeholders
    local virtual_host=$(cat "$template_file" | sed "s/{{DOMAIN}}/$domain/g" | sed "s/{{PORT}}/$port/g")
    
    # Check if there's an existing VirtualHost for this domain
    if grep -q "ServerName $domain" "$config_file"; then
        print_message "$YELLOW" "Configuration for $domain already exists in default Apache config"
        return
    fi
    
    # Backup the original configuration
    sudo cp "$config_file" "${config_file}.backup.$(date +%Y%m%d%H%M%S)"
    
    # Append the VirtualHost block to the default config
    echo "$virtual_host" | sudo tee -a "$config_file" > /dev/null
    
    print_message "$GREEN" "Added configuration for $domain to default Apache config"
}

# Function to setup SSL renewal
setup_ssl_renewal() {
    local web_server=$1
    
    print_message "$YELLOW" "Setting up automatic SSL renewal..."
    
    # Create renewal script
    cat << 'EOF' | sudo tee /usr/local/bin/ssl-renewal.sh > /dev/null
#!/bin/bash
certbot renew --quiet

if [ $? -eq 0 ]; then
    systemctl reload WEBSERVER
fi
EOF

    # Replace WEBSERVER placeholder with actual web server
    sudo sed -i "s/WEBSERVER/$web_server/" /usr/local/bin/ssl-renewal.sh
    
    # Make script executable
    sudo chmod +x /usr/local/bin/ssl-renewal.sh
    
    # Add cron job for twice daily renewal
    (crontab -l 2>/dev/null; echo "0 0,12 * * * /usr/local/bin/ssl-renewal.sh") | crontab -
}

# Main script starts here
check_os

# Check for template files
if [[ ! -d "${SCRIPT_DIR}/templates" ]]; then
    print_message "$RED" "Templates directory not found at ${SCRIPT_DIR}/templates"
    exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/templates/nginx/site-template.conf" ]]; then
    print_message "$RED" "Nginx template file not found at ${SCRIPT_DIR}/templates/nginx/site-template.conf"
    exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/templates/apache/site-template.conf" ]]; then
    print_message "$RED" "Apache template file not found at ${SCRIPT_DIR}/templates/apache/site-template.conf"
    exit 1
fi

# Web server selection
while true; do
    print_message "$GREEN" "Select your web server:"
    echo "1) Nginx"
    echo "2) Apache"
    read -p "Enter your choice (1 or 2): " server_choice
    
    case $server_choice in
        1)
            web_server="nginx"
            break
            ;;
        2)
            web_server="apache"
            break
            ;;
        *)
            print_message "$RED" "Invalid choice. Please select 1 or 2."
            ;;
    esac
done

# Detect and update package manager
pkg_manager=$(detect_package_manager)
update_system "$pkg_manager"

# Install web server if not present
if ! command -v $web_server &>/dev/null; then
    install_web_server "$pkg_manager" "$web_server"
fi

# Install Certbot
install_certbot "$pkg_manager" "$web_server"

# App configuration
print_message "$GREEN" "How many apps do you want to configure?"
read -p "Enter number of apps: " num_apps

declare -a domains=()

for ((i=1; i<=num_apps; i++)); do
    print_message "$GREEN" "Configuring app $i"
    
    read -p "Enter app name: " app_name
    read -p "Enter domain name: " domain_name
    read -p "Enter internal port: " port
    
    domains+=("$domain_name")
    
    if [ "$web_server" = "nginx" ]; then
        create_nginx_config "$app_name" "$domain_name" "$port"
    else
        create_apache_config "$app_name" "$domain_name" "$port"
    fi
done

# Reload web server
sudo systemctl reload $web_server

# Install SSL certificates
for domain in "${domains[@]}"; do
    print_message "$YELLOW" "Installing SSL certificate for $domain"
    sudo certbot --"$web_server" -d "$domain" --non-interactive --agree-tos --email "admin@${domain}" --redirect
done

# Setup automatic renewal
read -p "Do you want to enable automatic SSL renewal? (Yes/No): " enable_renewal
if [[ "${enable_renewal,,}" =~ ^(yes|y)$ ]]; then
    setup_ssl_renewal "$web_server"
fi

# Display summary
print_message "$GREEN" "Configuration Summary:"
echo "Web Server: $web_server"
echo "Configured Domains:"
for domain in "${domains[@]}"; do
    echo "- $domain"
done
echo "SSL Renewal: ${enable_renewal,,}"

# Offer renewal test
read -p "Would you like to test the SSL renewal? (Yes/No): " test_renewal
if [[ "${test_renewal,,}" =~ ^(yes|y)$ ]]; then
    sudo certbot renew --dry-run
fi

print_message "$GREEN" "SSL installation completed successfully!"