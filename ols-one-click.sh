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

# 检查并修复 libcrypt.so.1 缺失问题
fix_libcrypt() {
    echo "检查 libcrypt.so.1 是否存在..."
    if ! ldconfig -p | grep -q libcrypt.so.1; then
        echo "libcrypt.so.1 缺失，尝试修复..."

        # 安装兼容包
        $INSTALL_CMD libxcrypt-compat || echo "libxcrypt-compat 安装失败或不可用，继续尝试手动修复..."

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
        echo "libcrypt.so.1 已存在。"
    fi
}

# 开放端口
open_ports() {
    echo "配置防火墙..."
    if [ "$PACKAGE_MANAGER" = "apt" ]; then
        sudo ufw status | grep -q inactive && sudo ufw enable
        $FIREWALL_CMD allow 22
        $FIREWALL_CMD allow 80
        $FIREWALL_CMD allow 443
    else
        sudo systemctl start firewalld
        sudo systemctl enable firewalld

         # 在修改防火墙规则之前，临时允许 SSH 端口（22）
        sudo firewall-cmd --zone=public --add-port=22/tcp --permanent
        sudo firewall-cmd --reload
        $FIREWALL_CMD --permanent --add-port=80/tcp
        $FIREWALL_CMD --permanent --add-port=443/tcp
        $FIREWALL_CMD --reload
    fi
}

# 部署函数
deploy() {
    echo "🚀 开始部署..."

    # 更新系统
    echo "更新系统..."
    if [ "$PACKAGE_MANAGER" = "apt" ]; then
        sudo apt update && sudo apt upgrade -y
    else
        sudo yum update -y
    fi

    # 安装必要工具
    echo "安装基础工具..."
    $INSTALL_CMD wget unzip tar curl openssl

    # 修复 libcrypt 问题
    fix_libcrypt

    # 安装 OpenLiteSpeed
    echo "安装 OpenLiteSpeed..."
    bash <( curl -k https://raw.githubusercontent.com/litespeedtech/ols1clk/master/ols1clk.sh )
    # 安装数据库
    echo "安装数据库..."
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

    echo "创建数据库和用户..."
    sudo mysql -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"
    sudo mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';"
    sudo mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
    sudo mysql -e "FLUSH PRIVILEGES;"

    # # 安装 lsphp 和相关扩展
    # echo "安装 lsphp 和 PHP 扩展..."
    # bash <(curl -s https://get.litespeedtech.com/lsphp/installer.sh)  # 安装 OpenLiteSpeed 的 PHP
    # $INSTALL_CMD lsphp lsphp-mysql lsphp-curl lsphp-gd lsphp-mbstring lsphp-xml lsphp-soap lsphp-intl lsphp-zip

    # 下载 WordPress
    echo "下载并配置 WordPress..."
    wget -q https://wordpress.org/latest.tar.gz
    tar -xzf latest.tar.gz
    rm -f latest.tar.gz

    sudo rm -rf /var/www/html/wordpress
    sudo mv wordpress /var/www/html/
    sudo chown -R $WEBSERVER_USER:$WEBSERVER_USER /var/www/html/wordpress

    sudo cp /var/www/html/wordpress/wp-config-sample.php /var/www/html/wordpress/wp-config.php
    sudo sed -i "s/database_name_here/$DB_NAME/" /var/www/html/wordpress/wp-config.php
    sudo sed -i "s/username_here/$DB_USER/" /var/www/html/wordpress/wp-config.php
    sudo sed -i "s/password_here/$DB_PASSWORD/" /var/www/html/wordpress/wp-config.php

    # 设置虚拟主机路径
    echo "配置 OpenLiteSpeed 虚拟主机路径..."
    sudo sed -i "s|/usr/local/lsws/DEFAULT|/var/www/html/wordpress|g" /usr/local/lsws/conf/httpd_config.conf
    sudo systemctl restart lsws

    # 安装 LiteSpeed 缓存插件
    echo "安装 LiteSpeed 缓存插件..."
    PLUGIN_DIR="/var/www/html/wordpress/wp-content/plugins"
    mkdir -p "$PLUGIN_DIR"
    wget -q -O "$PLUGIN_DIR/litespeed-cache.zip" https://downloads.wordpress.org/plugin/litespeed-cache.4.4.1.zip
    sudo unzip "$PLUGIN_DIR/litespeed-cache.zip" -d "$PLUGIN_DIR"
    sudo chown -R $WEBSERVER_USER:$WEBSERVER_USER "$PLUGIN_DIR/litespeed-cache"
    rm -f "$PLUGIN_DIR/litespeed-cache.zip"

    # 配置防火墙
    open_ports

    echo -e "\n✅ 部署完成！"
    echo "数据库名: $DB_NAME"
    echo "数据库用户: $DB_USER"
    echo "数据库密码: $DB_PASSWORD"
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

    sudo rm -rf /var/www/html/wordpress

    # 防火墙清理
    echo "关闭防火墙端口..."
    if [ "$PACKAGE_MANAGER" = "apt" ]; then
        $FIREWALL_CMD delete allow 22
        $FIREWALL_CMD delete allow 80
        $FIREWALL_CMD delete allow 443
    else
        $FIREWALL_CMD --permanent --remove-port=22/tcp
        $FIREWALL_CMD --permanent --remove-port=80/tcp
        $FIREWALL_CMD --permanent --remove-port=443/tcp
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
