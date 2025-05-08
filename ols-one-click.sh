#!/bin/bash

# 检查系统发行版
if [ -f /etc/debian_version ]; then
    PACKAGE_MANAGER="apt"
    INSTALL_CMD="sudo apt install -y"
    REMOVE_CMD="sudo apt purge -y"
    AUTOREMOVE_CMD="sudo apt autoremove -y"
    FIREWALL_CMD="sudo ufw"
    WEBSERVER_USER="www-data"
elif [ -f /etc/redhat-release ]; then
    PACKAGE_MANAGER="yum"
    INSTALL_CMD="sudo yum install -y"
    REMOVE_CMD="sudo yum remove -y"
    AUTOREMOVE_CMD="echo 'YUM 无 autoremove 命令，跳过自动清理'"
    FIREWALL_CMD="sudo firewall-cmd"
    WEBSERVER_USER="nobody"
else
    echo "不支持的系统发行版。"
    exit 1
fi

SERVER_IP=$(hostname -I | awk '{print $1}')

# 创建相关目录
WEB_ROOT="/var/www/html"
if [ ! -d "$WEB_ROOT" ]; then
    sudo mkdir -p $WEB_ROOT
fi
# 检查并修复 libcrypt.so.1 缺失问题
fix_libcrypt() {
    echo "Check libcrypt.so.1 Exists..."
    if ! ldconfig -p | grep -q libcrypt.so.1; then
        echo "libcrypt.so.1 not found,try repair..."

        # 安装兼容包
        $INSTALL_CMD libxcrypt-compat || echo "libxcrypt-compat fail intall，reapir shoudong..."

        # 手动修复路径和链接
        if [ ! -d /usr/lib64 ]; then
            sudo mkdir -p /usr/lib64
        fi

        if [ -f /usr/lib/x86_64-linux-gnu/libcrypt.so.1 ] && [ ! -f /usr/lib64/libcrypt.so.1 ]; then
            sudo ln -s /usr/lib/x86_64-linux-gnu/libcrypt.so.1 /usr/lib64/libcrypt.so.1
        elif [ -f /usr/lib/libcrypt.so.1 ] && [ ! -f /usr/lib64/libcrypt.so.1 ]; then
            sudo ln -s /usr/lib/libcrypt.so.1 /usr/lib64/libcrypt.so.1
        fi
    else
        echo "libcrypt.so.1 exits。"
    fi
}

# 开放端口
open_ports() {
    echo "Config Firewall..."
    if [ "$PACKAGE_MANAGER" = "apt" ]; then
        sudo ufw status | grep -q inactive && sudo ufw enable
        $FIREWALL_CMD allow 22
        $FIREWALL_CMD allow 80
        $FIREWALL_CMD allow 443
        $FIREWALL_CMD allow 7080
        $FIREWALL_CMD allow 8081
    else
        sudo systemctl start firewalld
        sudo systemctl enable firewalld

        # 在修改防火墙规则之前，临时允许 SSH 端口（22）
        sudo firewall-cmd --zone=public --add-port=22/tcp --permanent
        sudo firewall-cmd --reload
        $FIREWALL_CMD --permanent --add-port=80/tcp
        $FIREWALL_CMD --permanent --add-port=443/tcp
        $FIREWALL_CMD --permanent --add-port=7080/tcp
        $FIREWALL_CMD --permanent --add-port=8081/tcp
        $FIREWALL_CMD --reload
    fi
}

# 安装 OpenLiteSpeed
install_openlitespeed() {
    echo "Install OpenLiteSpeed..."

    # 使用 OpenLiteSpeed 官方安装脚本
    if [ "$PACKAGE_MANAGER" = "apt" ]; then
        wget -qO - https://rpms.litespeedtech.com/debian/enable_openlitespeed_repository.sh | sudo bash
        sudo apt update
        sudo apt install openlitespeed -y
    elif [ "$PACKAGE_MANAGER" = "yum" ]; then
        wget -qO - https://rpms.litespeedtech.com/centos/enable_openlitespeed_repository.sh | sudo bash
        sudo yum install openlitespeed -y
    fi

    # 启动 OpenLiteSpeed
    sudo systemctl enable lsws
    sudo systemctl start lsws

    # 配置防火墙
    echo "Config firewall..."
    open_ports

    echo "OpenLiteSpeed Install success And Start working。"
}


# 部署函数
deploy() {
    echo "Start Deploying..."

    # 更新系统
    echo "Updating..."
    if [ "$PACKAGE_MANAGER" = "apt" ]; then
        sudo apt update && sudo apt upgrade -y
    else
        sudo yum update -y
    fi

    
    # 安装必要工具
    echo "Install base tools..."
    $INSTALL_CMD wget unzip tar curl openssl

    # 修复 libcrypt 问题
    fix_libcrypt

    # 安装文件管理
    install_filebrowser

    # 安装 OpenLiteSpeed
    install_openlitespeed

    # 安装数据库
    echo "Install database..."
    if [ "$PACKAGE_MANAGER" = "apt" ]; then
        $INSTALL_CMD mysql-server
        sudo systemctl enable mysql
        sudo systemctl start mysql
        sudo mysql_secure_installation
    else
        $INSTALL_CMD mariadb-server
        sudo systemctl enable mariadb
        sudo systemctl start mariadb
        sudo mysql_secure_installation
    fi

    # 创建数据库和用户
    DB_NAME="wordpress_db"
    DB_USER="wordpress_user"
    DB_PASSWORD=$(openssl rand -base64 12)

    echo "Create Database And User..."
    sudo mysql -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"
    sudo mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';"
    sudo mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
    sudo mysql -e "FLUSH PRIVILEGES;"

    # 下载 WordPress
    echo "Downing And Install WordPress..."
    wget -q https://wordpress.org/latest.tar.gz
    tar -xzf latest.tar.gz
    rm -f latest.tar.gz

    sudo rm -rf $WEB_ROOT/wordpress
    sudo mv wordpress $WEB_ROOT
    sudo chown -R $WEBSERVER_USER:$WEBSERVER_USER $WEB_ROOT/wordpress

    sudo cp $WEB_ROOT/wordpress/wp-config-sample.php $WEB_ROOT/wordpress/wp-config.php
    sudo sed -i "s/database_name_here/$DB_NAME/" $WEB_ROOT//html/wordpress/wp-config.php
    sudo sed -i "s/username_here/$DB_USER/" $WEB_ROOT/html/wordpress/wp-config.php
    sudo sed -i "s/password_here/$DB_PASSWORD/"$WEB_ROOT/html/wordpress/wp-config.php

    # 设置虚拟主机路径
    echo "Config OpenLiteSpeed Vhost Path..."
    sudo sed -i "s|/usr/local/lsws/DEFAULT|$WEB_ROOT/wordpress|g" /usr/local/lsws/conf/httpd_config.conf
    sudo systemctl restart lsws

    # 安装 LiteSpeed 缓存插件
    echo "Install LiteSpeed Cache Plugin..."
    PLUGIN_DIR="$WEB_ROOT/wordpress/wp-content/plugins"
    mkdir -p "$PLUGIN_DIR"
    wget -q -O "$PLUGIN_DIR/litespeed-cache.zip" https://downloads.wordpress.org/plugin/litespeed-cache.4.4.1.zip
    sudo unzip "$PLUGIN_DIR/litespeed-cache.zip" -d "$PLUGIN_DIR"
    sudo chown -R $WEBSERVER_USER:$WEBSERVER_USER "$PLUGIN_DIR/litespeed-cache"
    rm -f "$PLUGIN_DIR/litespeed-cache.zip"

    # 配置防火墙
    open_ports

    echo -e "\n✅ Deploy Success！"

    show_info
}

show_info(){
    # 输出部署信息总结
    echo -e "\n==================== Infomation ===================="
    echo -e "✅ WordPress site path:        $WEB_ROOT/wordpress"
    echo -e "🌐 wordpre home: http://$SERVER_IP or https://$SERVER_IP"
    echo -e "🔐 database name:                $DB_NAME"
    echo -e "👤 database user:                $DB_USER"
    echo -e "🔑 datebase pwd :                $DB_PASSWORD"
    echo -e "📁 Filebrowser file manage:    http://$SERVER_IP:8081"
    echo -e "👤 Filebrowser account  :      admin"
    echo -e "🔑 Filebrowser pwd      :      admin"
    echo -e "🧱 开放端口:                  22, 80, 443, 7080, 8081"
    echo -e "🚀 OpenLiteSpeed panel url:   https://$SERVER_IP:7080 (default: admin，renew pwd firt login)"
    echo -e "⚙️ LiteSpeed cache plugin:   $WEB_ROOT/wordpress/wp-content/plugins/litespeed-cache"
    echo -e "===================================================\n"
}

install_filebrowser() {
    echo "Install Filebrowser File Manage..."
    curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
    sudo mkdir -p /etc/filebrowser

    # filebrowser -r /var/www/html/ -p 8081 -d /etc/filebrowser/filebrowser.db &

    # 可选：设置为 systemd 服务（增强稳定性）
    sudo tee /etc/systemd/system/filebrowser.service > /dev/null <<EOF
[Unit]
Description=Filebrowser
After=network.target

[Service]
ExecStart=/usr/local/bin/filebrowser -r $WEB_ROOT/ -p 8081 -d /etc/filebrowser/filebrowser.db
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reexec
    sudo systemctl enable filebrowser
    sudo systemctl start filebrowser
}


# 卸载函数
uninstall() {
    echo "🗑️ 开始卸载..."

    sudo systemctl stop lsws
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

    sudo rm -rf $WEB_ROOT/wordpress

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

    echo "✅ 卸载完成！"
}

# 主程序入口
case "$1" in
    deploy)
        deploy
        ;;
    uninstall)
        uninstall
        ;;
    *)
        echo "用法: $0 {deploy|uninstall}"
        ;;
esac
