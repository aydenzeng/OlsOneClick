#!/bin/bash

#================= Configuration Variables =================
DB_NAME="wordpress_db"
DB_USER="wordpress_user"
DB_PASSWORD=$(openssl rand -base64 12)
WEB_ROOT="/var/www/html"
INFO_FILE="deploy_info.txt"
WEBSERVER_USER="www"
#=============== Check System Distribution ===============
if [ -f /etc/debian_version ]; then
    PACKAGE_MANAGER="apt"
    INSTALL_CMD="sudo apt install -y"
    REMOVE_CMD="sudo apt purge -y"
    AUTOREMOVE_CMD="sudo apt autoremove -y"
    FIREWALL_CMD="sudo ufw"
elif [ -f /etc/redhat-release ]; then
    PACKAGE_MANAGER="yum"
    INSTALL_CMD="sudo yum install -y"
    REMOVE_CMD="sudo yum remove -y"
    AUTOREMOVE_CMD="echo 'YUM does not support autoremove, skipping cleanup'"
    FIREWALL_CMD="sudo firewall-cmd"
else
    echo "❌ Unsupported system distribution."
    exit 1
fi

SERVER_IP=$(hostname -I | awk '{print $1}')

#================== Function Definitions ==================

fix_libcrypt() {
    echo "🔧 Checking libcrypt.so.1..."
    if ! ldconfig -p | grep -q libcrypt.so.1; then
        echo "🧩 libcrypt.so.1 missing, attempting to fix..."
        $INSTALL_CMD libxcrypt-compat || echo "❌ Failed to install libxcrypt-compat. Please fix manually."

        if [ ! -d /usr/lib64 ]; then sudo mkdir -p /usr/lib64; fi
        if [ -f /usr/lib/x86_64-linux-gnu/libcrypt.so.1 ] && [ ! -f /usr/lib64/libcrypt.so.1 ]; then
            sudo ln -s /usr/lib/x86_64-linux-gnu/libcrypt.so.1 /usr/lib64/libcrypt.so.1
        elif [ -f /usr/lib/libcrypt.so.1 ] && [ ! -f /usr/lib64/libcrypt.so.1 ]; then
            sudo ln -s /usr/lib/libcrypt.so.1 /usr/lib64/libcrypt.so.1
        fi
    else
        echo "✅ libcrypt.so.1 found"
    fi
}

open_ports() {
    echo "🌐 Configuring firewall..."
    if [ "$PACKAGE_MANAGER" = "apt" ]; then
        sudo ufw status | grep -q inactive && sudo ufw enable
        for port in 22 80 443 7080 8081; do $FIREWALL_CMD allow $port; done
    else
        sudo systemctl enable firewalld --now
        for port in 22 80 443 7080 8081; do $FIREWALL_CMD --permanent --add-port=${port}/tcp; done
        $FIREWALL_CMD --reload
    fi
}

update_sys_tools() {
    echo "⬆️ Updating system and base tools..."
    if [ "$PACKAGE_MANAGER" = "apt" ]; then
        sudo apt update && sudo apt upgrade -y
    else
        sudo yum update -y
    fi

    $INSTALL_CMD wget unzip tar curl openssl
    fix_libcrypt
}

install_openlitespeed() {
    echo "📦 Installing OpenLiteSpeed..."

    # 添加 LiteSpeed 源
    add_litespeed_repo() {
        wget -qO - https://repo.litespeed.sh | sudo bash
    }

    # 统一安装命令并检测错误
    install_package() {
        local pkg="$1"
        $INSTALL_CMD $pkg || { echo "❌ Failed to install $pkg"; exit 1; }
    }

    add_litespeed_repo || { echo "❌ Failed to add LiteSpeed repository"; exit 1; }

    if [ "$PACKAGE_MANAGER" = "apt" ]; then
        sudo apt update || { echo "❌ apt update failed"; exit 1; }
    fi

    # 安装 OpenLiteSpeed 和 PHP 81 相关模块
    install_package "openlitespeed"

    install_package "lsphp81 lsphp81-common lsphp81-mysqlnd"

    sudo systemctl enable lsws --now || { echo "❌ Failed to enable/start OpenLiteSpeed service"; exit 1; }

    open_ports

    echo "✅ OpenLiteSpeed installation completed"
}



install_database() {
    echo "🗄️ Installing database service..."
    if [ "$PACKAGE_MANAGER" = "apt" ]; then
        $INSTALL_CMD mysql-server
        sudo systemctl enable mysql --now
        sudo mysql_secure_installation
    else
        $INSTALL_CMD mariadb-server
        sudo systemctl enable mariadb --now
        sudo mysql_secure_installation
    fi

    echo "🧰 Creating database and user..."
    sudo mysql <<EOF
CREATE DATABASE IF NOT EXISTS $DB_NAME;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
}

install_wordpress() {
    echo "⬇️ Downloading and configuring WordPress..."
    wget -q https://wordpress.org/latest.tar.gz
    tar -xzf latest.tar.gz && rm -f latest.tar.gz

    sudo rm -rf $WEB_ROOT/wordpress
    sudo mv wordpress $WEB_ROOT
    sudo chown -R $WEBSERVER_USER:$WEBSERVER_USER $WEB_ROOT/wordpress
    sudo find $WEB_ROOT/wordpress -type d -exec chmod 755 {} \;
    sudo find $WEB_ROOT/wordpress -type f -exec chmod 644 {} \;

    sudo cp $WEB_ROOT/wordpress/wp-config-sample.php $WEB_ROOT/wordpress/wp-config.php
    sudo sed -i "s/database_name_here/$DB_NAME/" $WEB_ROOT/wordpress/wp-config.php
    sudo sed -i "s/username_here/$DB_USER/" $WEB_ROOT/wordpress/wp-config.php
    sudo sed -i "s/password_here/$DB_PASSWORD/" $WEB_ROOT/wordpress/wp-config.php

    create_wordpress_vhost  # 这里调用创建虚拟主机

    echo "📦 Installing LiteSpeed Cache plugin..."
    PLUGIN_DIR="$WEB_ROOT/wordpress/wp-content/plugins"
    mkdir -p "$PLUGIN_DIR"
    wget -q -O "$PLUGIN_DIR/litespeed-cache.zip" https://downloads.wordpress.org/plugin/litespeed-cache.4.4.1.zip
    sudo unzip "$PLUGIN_DIR/litespeed-cache.zip" -d "$PLUGIN_DIR"
    sudo chown -R $WEBSERVER_USER:$WEBSERVER_USER "$PLUGIN_DIR/litespeed-cache"
    rm -f "$PLUGIN_DIR/litespeed-cache.zip"
}

generate_vhost_config() {
    local doc_root="$1"
    local vhost_conf="$2"
    local vhost_root="$3"

    sudo tee "$vhost_conf" > /dev/null <<EOF
docRoot                   $doc_root
vhRoot                    $vhost_root
allowSymbolLink           1
enableScript              1
restrained                0
index  {
  useServer               0
  indexFiles              index.php, index.html
}
extProcessor php {
  type                    lsapi
  address                 uds:///tmp/lshttpd/lsphp.sock
  maxConns                35
  env                     PHP_LSAPI_MAX_REQUESTS=500
  initTimeout             60
  retryTimeout            0
  persistConn             1
  respBuffer              0
  autoStart               1
  path                    /usr/local/lsws/lsphp81/bin/lsphp
  backlog                 100
  instances               1
  priority                0
  memSoftLimit            2047M
  memHardLimit            2047M
  procSoftLimit           400
  procHardLimit           500
  cpuSoftLimit            30
  cpuHardLimit            60
}
scriptHandler {
  add                     lsapi:php
}
security {
  allowBrowse             1
}
errorHandler 404 {
  url                     /index.php
  override                1
}
accessControl {
  allow                   ALL
}
EOF
}

add_listener_port() {
    local site_name="$1"
    local site_port="$2"
    local httpd_conf="/usr/local/lsws/conf/httpd_config.conf"

    if grep -q "listener WordPress_$site_port" "$httpd_conf"; then
        echo "ℹ️ Listener WordPress_$site_port 已存在，跳过添加"
        return
    fi

    echo "📌 添加 Listener WordPress_$site_port 到 httpd_config.conf"
    sudo tee -a "$httpd_conf" > /dev/null <<EOF

listener WordPress_$site_port {
  address                 *:$site_port
  secure                  0
  vhList                  $site_name
}
EOF
}


create_wordpress_vhost() {
    echo "⚙️ Create OpenLiteSpeed WordPress Vhost Config..."
    SITE_NAME="$1"
    SITE_PORT="$2"
    # 虚拟主机配置文件路径
    DOC_ROOT="$WEB_ROOT/$SITE_NAME"
    VHOST_ROOT="/usr/local/lsws/conf/vhosts/$SITE_NAME"
    VHOST_CONF="$VHOST_ROOT/vhost.conf"

    if [ -f "$VHOST_CONF" ]; then
    echo "⚠️ 检测到已有虚拟主机配置，是否覆盖？(y/n)"
    read -r CONFIRM
    [ "$CONFIRM" != "y" ] && return
    fi
    # 创建虚拟主机目录（如果不存在）
    sudo mkdir -p "$(dirname "$VHOST_CONF")"

    generate_vhost_config "$DOC_ROOT" "$VHOST_CONF" "$VHOST_ROOT"

    # 添加监听端口
    add_listener_port "$SITE_NAME" "$SITE_PORT"

    /usr/local/lsws/bin/lswsctrl restart || {
        echo "❌ OpenLiteSpeed 配置错误，重启失败，请检查 vhost.conf"
        exit 1
    }
    # 重启服务应用配置
    sudo systemctl restart lsws

    echo "✅ WordPress 虚拟主机配置完成：$SITE_NAME"
    echo "🌐 访问地址：http://$SERVER_IP:$SITE_PORT"
}


install_filebrowser() {
    FILEBROWSER_DB_DIR="/etc/filebrowser"
    FILEBROWSER_DB_FILE="$FILEBROWSER_DB_DIR/filebrowser.db"
    FILEBROWSER_PORT=8081

    echo "📁 Installing Filebrowser..."
    curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
    
    echo "📂 Creating Filebrowser config directory and setting permissions..."
    sudo mkdir -p "$FILEBROWSER_DB_DIR"
    sudo chown -R "$WEBSERVER_USER":"$WEBSERVER_USER" "$FILEBROWSER_DB_DIR"
    sudo chmod 700 "$FILEBROWSER_DB_DIR"

    echo "📂 Setting permissions for WEB_ROOT ($WEB_ROOT)..."
    sudo chown -R "$WEBSERVER_USER":"$WEBSERVER_USER" "$WEB_ROOT"
    sudo chmod -R 755 "$WEB_ROOT"

    echo "⚙️ Creating systemd service file for Filebrowser..."
    sudo tee /etc/systemd/system/filebrowser.service > /dev/null <<EOF
[Unit]
Description=Filebrowser
After=network.target

[Service]
ExecStart=/usr/local/bin/filebrowser -r $WEB_ROOT -p $FILEBROWSER_PORT --address 0.0.0.0 -d $FILEBROWSER_DB_FILE
Restart=always
User=$WEBSERVER_USER
Group=$WEBSERVER_USER

[Install]
WantedBy=multi-user.target
EOF

    echo "🔄 Reloading systemd daemon..."
    sudo systemctl daemon-reload

    echo "🚀 Enabling and starting Filebrowser service..."
    sudo systemctl enable filebrowser --now
}

show_info() {
    echo -e "\n📄 Writing deployment info..."
    cat <<EOF | tee $INFO_FILE

==================== Deployment Summary ====================
✅ Site Root Path:            $WEB_ROOT
🌐 Access URL:                http://$SERVER_IP or https://$SERVER_IP
🔐 Database Name:             $DB_NAME
👤 Database User:             $DB_USER
🔑 Database Password:         $DB_PASSWORD
📁 Filebrowser URL:           http://$SERVER_IP:8081
👤 Filebrowser Username:      admin
🔑 Filebrowser Password:      admin
🧱 Opened Ports:              22, 80, 443, 7080, 8081
🚀 OLS Admin Panel:           https://$SERVER_IP:7080 (Default user: admin. Set password at first login.)
⚙️ LiteSpeed Cache Plugin:    $WEB_ROOT/wordpress/wp-content/plugins/litespeed-cache
============================================================
EOF
}

deploy() {
    echo "🚀 Starting deployment..."
    update_sys_tools
    install_filebrowser
    install_openlitespeed
    install_database
    open_ports
    show_info
    echo -e "\n✅ Deployment completed successfully! Info saved to $INFO_FILE"
}
# 卸载函数
uninstall() {
    echo "🗑️ Start Uninstall..."

    sudo systemctl stop lsws
    $REMOVE_CMD openlitespeed
    $REMOVE_CMD filebrowser
    $REMOVE_CMD lsphp81 lsphp81-common lsphp81-mysqlnd
    sudo rm -rf /usr/local/lsws

    if [ "$PACKAGE_MANAGER" = "apt" ]; then
        $REMOVE_CMD mysql-server mysql-client mysql-common
        eval "$AUTOREMOVE_CMD"
        sudo rm -rf /var/lib/mysql /etc/mysql
    else
        $REMOVE_CMD mariadb-server
        eval "$AUTOREMOVE_CMD"
        sudo rm -rf /var/lib/mysql /etc/my.cnf
    fi

    $REMOVE_CMD lsphp*
    eval "$AUTOREMOVE_CMD"

    sudo rm -rf /var/www/html/wordpress

    # 防火墙清理
    echo "关闭防火墙端口..."
    if [ "$PACKAGE_MANAGER" = "apt" ]; then
        $FIREWALL_CMD delete allow 80
        $FIREWALL_CMD delete allow 443
        $FIREWALL_CMD delete allow 8081
        $FIREWALL_CMD delete allow 7080
    else
        $FIREWALL_CMD --permanent --remove-port=80/tcp
        $FIREWALL_CMD --permanent --remove-port=443/tcp
        $FIREWALL_CMD --permanent --remove-port=7080/tcp
        $FIREWALL_CMD --permanent --remove-port=8081/tcp
        $FIREWALL_CMD --reload
    fi

    echo "✅ uninstall completed successfully!"
}
updateScript() {
    echo "🔄 Updating script..."
    #备份当前脚本
    cp -f ./ols-one-click.sh ./ols-one-click.sh.bak
    #下载最新脚本
    curl -O https://raw.githubusercontent.com/aydenzeng/OlsOneClick/main/ols-one-click.sh || wget https://raw.githubusercontent.com/aydenzeng/OlsOneClick/main/ols-one-click.sh && chmod +x ./ols-one-click.sh
    echo "✅ Script updated successfully!"
}
#================== Execute Deployment ==================
# 主程序入口
case "$1" in
    update)
        echo "🔄 Updating system and tools..."
        updateScript
        ;;
    status)
        #检查lsws服务状态
        if systemctl is-active --quiet lsws; then
            echo "✅ OpenLiteSpeed is running."
        else
            echo "❌ OpenLiteSpeed is not running."
        fi
        #检查Filebrowser服务状态
        if systemctl is-active --quiet filebrowser; then
            echo "✅ Filebrowser is running."
        else
            echo "❌ Filebrowser is not running."
        fi
        #检查数据库服务状态
        if systemctl is-active --quiet mysql; then
            echo "✅ Database service is running."
        else
            echo "❌ Database service is not running."
        fi
        ;;
    resetAdminPass)
        sudo /usr/local/lsws/admin/misc/admpass.sh
        ;;
    installWithWp)
        SITENAME="$2"
        SITEPORT="$3"
        if [ -z "$SITENAME" ]; then
            read -rp "Input Site Name (eg. mysite): " SITENAME
        fi
        if [ -z "$SITEPORT" ]; then
            read -rp "Input Site Port (eg. 8080): " SITEPORT
        fi
        echo "🚀 Starting deployment with WordPress: $SITENAME on port $SITEPORT..."
        install_wordpress "$SITENAME" "$SITEPORT"
        ;;
    install)
        deploy
        ;;
    uninstall)
        uninstall
        ;;
    *)
        echo "Usage: $0 {install|uninstall|resetAdminPass|status|update|installWithWp}"
        ;;
esac
