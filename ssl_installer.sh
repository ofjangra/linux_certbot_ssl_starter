#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

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

# Function to check if service is installed and running
check_service_status() {
    local service_name=$1
    
    # Check if service exists
    if ! command -v $service_name &>/dev/null; then
        print_message "$RED" "$service_name is not installed."
        return 1
    fi
    
    # Check if service is running
    if ! systemctl is-active --quiet $service_name; then
        print_message "$RED" "$service_name is not running."
        print_message "$YELLOW" "Attempting to start $service_name..."
        sudo systemctl start $service_name
        
        # Check again after attempting to start
        if ! systemctl is-active --quiet $service_name; then
            print_message "$RED" "Failed to start $service_name. Please check system logs."
            return 1
        fi
    fi
    
    print_message "$GREEN" "$service_name is running properly."
    return 0
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
    
    # Check if installation was successful and service is running
    if ! check_service_status $web_server; then
        print_message "$RED" "Failed to install or start $web_server. Exiting."
        exit 1
    fi
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
    
    # Create sites-available directory if it doesn't exist
    sudo mkdir -p /etc/nginx/sites-available
    
    local config_file="/etc/nginx/sites-available/$app_name"
    local template_file="$SCRIPT_DIR/templates/nginx/site-template.conf"
    
    # Check if template exists
    if [ ! -f "$template_file" ]; then
        print_message "$RED" "Template file not found at: $template_file"
        exit 1
    fi
    
    # Copy and modify template
    sudo cp "$template_file" "$config_file"
    sudo sed -i "s/{{DOMAIN}}/$domain/g" "$config_file"
    sudo sed -i "s/{{PORT}}/$port/g" "$config_file"
    
    # Test nginx configuration
    print_message "$YELLOW" "Testing Nginx configuration..."
    if ! sudo nginx -t; then
        print_message "$RED" "Nginx configuration test failed. Please check the configuration."
        exit 1
    fi
}

# Function to create Apache configuration
create_apache_config() {
    local app_name=$1
    local domain=$2
    local port=$3
    
    local config_file="/etc/apache2/sites-available/$app_name.conf"
    local template_file="$SCRIPT_DIR/templates/apache/site-template.conf"
    
    # Check if template exists
    if [ ! -f "$template_file" ]; then
        print_message "$RED" "Template file not found at: $template_file"
        exit 1
    fi
    
    # Copy and modify template
    sudo cp "$template_file" "$config_file"
    sudo sed -i "s/{{DOMAIN}}/$domain/g" "$config_file"
    sudo sed -i "s/{{PORT}}/$port/g" "$config_file"
    
    sudo a2ensite "$app_name"
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
else
    # Check if existing web server is running properly
    if ! check_service_status $web_server; then
        print_message "$RED" "Existing $web_server installation is not working properly. Attempting to fix..."
        install_web_server "$pkg_manager" "$web_server"
    fi
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
print_message "$YELLOW" "Reloading $web_server..."
if ! sudo systemctl reload $web_server; then
    print_message "$RED" "Failed to reload $web_server. Attempting to restart..."
    if ! sudo systemctl restart $web_server; then
        print_message "$RED" "Failed to restart $web_server. Please check the configuration and try again."
        exit 1
    fi
fi

# Install SSL certificates
for domain in "${domains[@]}"; do
    print_message "$YELLOW" "Installing SSL certificate for $domain"
    if ! sudo certbot --"$web_server" -d "$domain" --non-interactive --agree-tos --email "admin@${domain}" --redirect; then
        print_message "$RED" "Failed to install SSL certificate for $domain"
        exit 1
    fi
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