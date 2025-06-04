#!/bin/bash
VERSION="1.1.2"
#================= Configuration Variables =================
DB_NAME="wordpress_db"
DB_USER="wordpress_user"
DB_PASSWORD=$(openssl rand -base64 12)
MYSQL_ROOT_PASSWORD=$(openssl rand -base64 12) # 随机生成 MySQL root 密码
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
# 创建 OpenLiteSpeed 用户和组
if ! id -u "$WEBSERVER_USER" &>/dev/null; then
    echo "👤 Creating web server user: $WEBSERVER_USER"
    sudo useradd -r -s /bin/false "$WEBSERVER_USER"
fi

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
    local ports=("$@")  # 获取所有传入的端口参数

    if [ "$PACKAGE_MANAGER" = "apt" ]; then
        sudo ufw status | grep -q inactive && sudo ufw --force enable
        for port in "${ports[@]}"; do
            sudo ufw allow "$port"
        done
    else
        sudo systemctl enable firewalld --now
        for port in "${ports[@]}"; do
            sudo firewall-cmd --permanent --add-port="${port}/tcp"
        done
        sudo firewall-cmd --reload
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

install_phpmyadmin(){
    local downUrl="https://files.phpmyadmin.net/snapshots/phpMyAdmin-6.0+snapshot-all-languages.zip"
    cd /usr/local/lsws/Example/html
    rm -rf phpmyadmin
    wget -q $downUrl
    unzip phpMyAdmin-6.0+snapshot-all-languages.zip
    rm phpMyAdmin-6.0+snapshot-all-languages.zip
    mv phpMyAdmin-*-all-languages phpmyadmin
    mv phpmyadmin/config.sample.inc.php phpmyadmin/config.inc.php
    echo "Success installed phpMyAdmin..."
    echo "http://$SERVER_IP:8088/phpmyadmin/index.php"
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

    # 创建 OpenLiteSpeed 用户和组
    if ! id -u "$WEBSERVER_USER" &>/dev/null; then
        echo "👤 Creating web server user: $WEBSERVER_USER"
        sudo useradd -r -s /bin/false "$WEBSERVER_USER"
    fi
    # 设置 OpenLiteSpeed 的用户和组
    sudo sed -i "s/^user\s.*/user $WEBSERVER_USER/" /usr/local/lsws/conf/httpd_config.conf
    sudo sed -i "s/^group\s.*/group $WEBSERVER_USER/" /usr/local/lsws/conf/httpd_config.conf


    sudo systemctl enable lsws --now || { echo "❌ Failed to enable/start OpenLiteSpeed service"; exit 1; }

    open_ports 22 80 443 7080 8081 8088

    sudo mkdir -p /tmp/lshttpd
    sudo chown -R "$WEBSERVER_USER":"$WEBSERVER_USER" /tmp/lshttpd
    sudo chmod 755 /tmp/lshttpd

    echo "✅ OpenLiteSpeed installation completed"
}

install_database() {
    echo "🗄️ Installing database service..."

    if [ "$PACKAGE_MANAGER" = "apt" ]; then
        $INSTALL_CMD mysql-server
        sudo systemctl enable mysql --now
        SERVICE_NAME="mysql"
    else
        $INSTALL_CMD mariadb-server
        sudo systemctl enable mariadb --now
        SERVICE_NAME="mariadb"
    fi

    echo "🔧 Generating a random root password for MySQL..."

    echo "Generated MySQL root password: $MYSQL_ROOT_PASSWORD"

    echo "🔧 Securing database installation (no interaction)..."

    SECURE_SQL=$(cat <<-EOSQL
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOSQL
    )

    sudo mysql -e "$SECURE_SQL"

    echo "🧰 Creating database and user..."

    CREATE_USER_SQL=$(cat <<-EOSQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOSQL
    )

    sudo mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "$CREATE_USER_SQL"

    echo "✅ Database installation and initialization complete."
    echo "🔐 Remember to save your MySQL root password: $MYSQL_ROOT_PASSWORD"
}


create_mariadb_user() {
  read -p "Enter database name: " dbname
  read -p "Enter username: " dbuser
  read -s -p "Enter password: " dbpass
  echo
  read -s -p "Confirm password: " dbpass_confirm
  echo

  if [ "$dbpass" != "$dbpass_confirm" ]; then
    echo "❌ Passwords do not match. Aborting."
    return 1
  fi

  # 使用 sudo 检查数据库是否存在（无需密码）
  db_exists=$(sudo mysql -N -e "SELECT COUNT(*) FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = '${dbname}'" 2>/dev/null)

  if [ "$db_exists" -eq 0 ]; then
    # 数据库不存在，创建它
    sudo mysql <<EOF
CREATE DATABASE IF NOT EXISTS \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${dbuser}'@'localhost' IDENTIFIED BY '${dbpass}';
GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'localhost';
FLUSH PRIVILEGES;
EOF
    if [ $? -eq 0 ]; then
      echo "✅ Database '${dbname}' and user '${dbuser}' created and granted privileges successfully."
    else
      echo "❌ Operation failed. Please check if MariaDB is running and your sudo privileges are correct."
      return 1
    fi
  else
    # 数据库已存在，只创建用户
    sudo mysql <<EOF
CREATE USER IF NOT EXISTS '${dbuser}'@'localhost' IDENTIFIED BY '${dbpass}';
GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'localhost';
FLUSH PRIVILEGES;
EOF
    if [ $? -eq 0 ]; then
      echo "✅ User '${dbuser}' created and granted privileges to '${dbname}' successfully."
    else
      echo "❌ Operation failed. Please check if MariaDB is running and your sudo privileges are correct."
      return 1
    fi
  fi
}


install_wordpress() {
    local SITE_NAME="$1"     # WordPress 站点目录名，例如 blog1
    local PORT="$2"          # 虚拟主机端口，例如 8081

    # 自动生成数据库信息
    local DB_NAME="wp_${SITE_NAME}"
    local DB_USER="user_${SITE_NAME}"
    local DB_PASSWORD=$(openssl rand -hex 8)  # 随机密码

    local SITE_DIR="$WEB_ROOT/$SITE_NAME"

    echo "⬇️ Downloading and configuring WordPress..."
    wget -q https://wordpress.org/latest.tar.gz
    tar -xzf latest.tar.gz && rm -f latest.tar.gz

    sudo rm -rf "$SITE_DIR"
    sudo mv wordpress "$SITE_DIR"
    sudo chown -R "$WEBSERVER_USER:$WEBSERVER_USER" "$SITE_DIR"
    sudo find "$SITE_DIR" -type d -exec chmod 755 {} \;
    sudo find "$SITE_DIR" -type f -exec chmod 644 {} \;

    sudo cp "$SITE_DIR/wp-config-sample.php" "$SITE_DIR/wp-config.php"
    sudo sed -i "s/database_name_here/$DB_NAME/" "$SITE_DIR/wp-config.php"
    sudo sed -i "s/username_here/$DB_USER/" "$SITE_DIR/wp-config.php"
    sudo sed -i "s/password_here/$DB_PASSWORD/" "$SITE_DIR/wp-config.php"

    sudo chown "$WEBSERVER_USER:$WEBSERVER_USER" "$SITE_DIR/wp-config.php"

    create_wordpress_vhost "$SITE_NAME" "$PORT" # 这里调用创建虚拟主机

    echo "📦 Installing LiteSpeed Cache plugin for $SITE_NAME..."
    PLUGIN_DIR="$SITE_DIR/wp-content/plugins"
    mkdir -p "$PLUGIN_DIR"
    wget -q -O "$PLUGIN_DIR/litespeed-cache.zip" https://downloads.wordpress.org/plugin/litespeed-cache.4.4.1.zip
    sudo unzip "$PLUGIN_DIR/litespeed-cache.zip" -d "$PLUGIN_DIR"
    sudo chown -R "$WEBSERVER_USER:$WEBSERVER_USER" "$PLUGIN_DIR/litespeed-cache"
    rm -f "$PLUGIN_DIR/litespeed-cache.zip"

    echo "✅ WordPress installed for $SITE_NAME"
    echo "🔐 Database: $DB_NAME"
    echo "👤 DB User: $DB_USER"
    echo "🔑 DB Pass: $DB_PASSWORD"
}

register_virtual_host() {
    local site_name="$1"
    local vhost_root="$2"
    local vhost_conf="$3"
    local doc_root="$WEB_ROOT/$site_name"

    # 添加到主配置文件（如果尚未存在）
    local httpd_conf="/usr/local/lsws/conf/httpd_config.conf"
    if ! grep -q "vhRoot.*$site_name" "$httpd_conf"; then
        echo "📌 添加虚拟主机 $site_name 到主配置文件"
        sudo tee -a "$httpd_conf" > /dev/null <<EOF

virtualHost $site_name {
  vhRoot                  $doc_root
  configFile              $vhost_conf
  allowSymbolLink         1
  enableScript            1
}
EOF
    fi

    echo "🔄 重启 OpenLiteSpeed 服务以应用配置..."
    sudo systemctl restart lsws
    echo "✅ 虚拟主机 $site_name 配置完成。访问地址：http://$SERVER_IP:$SITE_PORT"
}


generate_vhost_config() {
    local doc_root="$1"
    local vhost_conf="$2"
    local vhost_root="$3"

    sudo tee "$vhost_conf" > /dev/null <<EOF
docRoot                   $doc_root
vhDomain                  $SERVER_IP
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
# 修改vhost_root目录下的所有文件为 lsadm:www
sudo chown -R "lsadm":"$WEBSERVER_USER" "$vhost_root"
sudo chmod -R 755 "$vhost_root"

}

add_listener_port() {
    local site_name="$1"
    local site_port="$2"
    local httpd_conf="/usr/local/lsws/conf/httpd_config.conf"
    local domain="*"

    if grep -q "listener WordPress_$site_port" "$httpd_conf"; then
        echo "ℹ️ Listener WordPress_$site_port 已存在，跳过添加"
        return
    fi

    echo "📌 添加 Listener WordPress_$site_port 到 httpd_config.conf"
    sudo tee -a "$httpd_conf" > /dev/null <<EOF

listener WordPress_$site_port {
  address                 *:$site_port
  secure                  0
  map                     $site_name $domain
}
EOF
    echo "✅ Listener 已添加，端口: $site_port"
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

    register_virtual_host "$SITE_NAME" "$VHOST_ROOT" "$VHOST_CONF"

    # 添加监听端口
    add_listener_port "$SITE_NAME" "$SITE_PORT"

    /usr/local/lsws/bin/lswsctrl restart || {
        echo "❌ OpenLiteSpeed 配置错误，重启失败，请检查 vhost.conf"
        exit 1
    }
    # 重启服务应用配置
    sudo systemctl restart lsws

    # 打开必要的端口
    open_ports "$SITE_PORT"

    echo "✅ WordPress 虚拟主机配置完成：$SITE_NAME"
    echo "🌐 访问地址：http://$SERVER_IP:$SITE_PORT"
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
🔑 Database Root Password:    $MYSQL_ROOT_PASSWORD
🧱 Opened Ports:              22, 80, 443, 7080
🚀 OLS Admin Panel:           https://$SERVER_IP:7080 (Default user: admin. Set password at first login.)
⚙️ LiteSpeed Cache Plugin:    $WEB_ROOT/wordpress/wp-content/plugins/litespeed-cache
============================================================
EOF
}

deploy() {
    echo "🚀 Starting deployment..."
    update_sys_tools
    install_openlitespeed
    install_database
    open_ports 22 80 443 7080 8088
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
version(){
    echo "$VERSION"
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
    createDbUser)
        create_mariadb_user
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
    installPhpMyAdmin)
        install_phpmyadmin
        ;;
    logs)
        tail -f /usr/local/lsws/logs/error.log
        ;;
    openPorts)
        ports="$2"
        if [ -z "$SITENAME" ]; then
            read -rp "Input Site Name (eg. 80 8888 8889): " SITENAME
        fi
        open_ports $ports
        echo "🌐 Opened ports: $ports"
        ;;
    version)
        version
        ;;
    uninstall)
        uninstall
        ;;
    *)
        echo "Usage: $0 {install|uninstall|resetAdminPass|status|update|installWithWp|version|openPorts|logs|installPhpMyAdmin|createDbUser}"
        ;;
esac
