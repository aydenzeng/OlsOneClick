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
LSWSCCTRL="sudo /usr/local/lsws/bin/lswsctrl"
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
        sudo apt update && sudo apt upgrade -y && sudo apt install ufw -y
    else
        sudo yum update -y
    fi

    $INSTALL_CMD wget unzip tar curl openssl
    fix_libcrypt
}

setup_dashboard_homepage() {
    local HTML_PATH="/usr/local/lsws/Example/html"
    local VHOST_CONF="/usr/local/lsws/conf/vhosts/Example/vhconf.conf"
    local LITESPEED_CTRL="/usr/local/lsws/bin/lswsctrl"
    local SERVER_IP=$(hostname -I | awk '{print $1}')

    echo "🔧 Writing custom index.html..."

    cat > "$HTML_PATH/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Server Dashboard</title>
  <style>
    body { font-family: Arial, sans-serif; background: #f7f7f7; text-align: center; padding: 50px; }
    h1 { margin-bottom: 40px; }
    .nav { display: flex; flex-direction: column; align-items: center; gap: 20px; }
    a { display: block; width: 300px; padding: 15px; background: #007bff; color: white; text-decoration: none; border-radius: 8px; font-size: 18px; transition: background 0.3s; }
    a:hover { background: #0056b3; }
  </style>
</head>
<body>
  <h1>🚀 Server Dashboard</h1>
  <div class="nav">
    <a href="http://localhost:7080" target="_blank">LiteSpeed 管理面板</a>
    <a href="/phpmyadmin/" target="_blank">phpMyAdmin 数据库管理</a>
    <a href="/filemanage/" target="_blank">Tinyfilemanager文件管理器</a>
  </div>
</body>
</html>
EOF

    echo "✅ Homepage created at $HTML_PATH/index.html"

    echo "🔍 Ensuring vhconf.conf has index.html..."

    if ! grep -q "indexFiles.*index.html" "$VHOST_CONF"; then
        echo "🔧 Adding index.html to indexFiles..."
        sed -i '/indexFiles/s/$/ index.html/' "$VHOST_CONF"
    else
        echo "✅ index.html already present in indexFiles."
    fi

    echo "🔄 Restarting OpenLiteSpeed..."
    $LITESPEED_CTRL restart

    echo "🎉 首页部署完成！请访问: http://$SERVER_IP:8088/"
}


# === 函数：编译并安装 OpenSSH ===
install_openssh() {
  set -e
  local VERSION="9.7p1"
  local WORKDIR="/usr/local/src"
  local PREFIX="/usr"
  local SYSCONFDIR="/etc/ssh"

  echo "📦 安装构建依赖..."
  yum install -y gcc make pam-devel zlib-devel openssl-devel wget tar

  echo "⬇️ 下载 OpenSSH $VERSION..."
  cd "$WORKDIR"
  wget -O openssh.tar.gz "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${VERSION}.tar.gz"
  tar -xf openssh.tar.gz
  cd "openssh-${VERSION}"

  echo "🛡️ 备份 sshd 配置..."
  cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak_$(date +%F_%T) || true

  echo "⚙️ 开始配置..."
  ./configure \
    --prefix="$PREFIX" \
    --sysconfdir="$SYSCONFDIR" \
    --with-pam \
    --with-md5-passwords \
    --with-ssl-dir=/usr

  echo "🔨 编译..."
  make -j"$(nproc)"

  echo "📥 安装..."
  make install

  echo "🔁 重启 sshd 服务..."
  chmod 600 /etc/ssh/ssh_host_* 2>/dev/null || true
  systemctl daemon-reexec
  if systemctl is-active --quiet sshd; then
    systemctl restart sshd
  else
    systemctl start sshd
  fi

  echo "✅ OpenSSH $VERSION 安装完成"
  ssh -V
}


install_phpmyadmin(){
    local PMA_VERSION="5.1.3"  # 可以根据需要修改版本
    local downUrl="https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}/phpMyAdmin-${PMA_VERSION}-all-languages.zip"
    local VHCONF="/usr/local/lsws/conf/vhosts/Example/vhconf.conf"
    local CONTEXT_BLOCK=$(cat <<EOF
context /phpmyadmin {
  location                \$VH_ROOT/html/phpmyadmin/
  indexFiles              index.php
  allowBrowse             1
  addDefaultCharset       off
  phpIniOverride  {

  }
}
EOF
)
    cd /usr/local/lsws/Example/html
    rm -rf phpmyadmin
    wget -q $downUrl
    # 解压和安装
    unzip phpMyAdmin-${PMA_VERSION}-all-languages.zip
    rm phpMyAdmin-${PMA_VERSION}-all-languages.zip
    rm -rf phpmyadmin
    mv phpMyAdmin-*-all-languages phpmyadmin
    mv phpmyadmin/config.sample.inc.php phpmyadmin/config.inc.php
    chown -R $WEBSERVER_USER:$WEBSERVER_USER /usr/local/lsws/Example/html/phpmyadmin
    chmod -R 755 /usr/local/lsws/Example/html/phpmyadmin

    echo "🔧 Modifying LiteSpeed virtual host config..."

    if grep -q "context /phpmyadmin" "$VHCONF"; then
        echo "⚠️  Context '/phpmyadmin' already exists, skipping."
    else
        echo "🔧 Adding context '/phpmyadmin' to $VHCONF"
        echo "" >> "$VHCONF"
        echo "$CONTEXT_BLOCK" >> "$VHCONF"
        echo "✅ Context added."
    fi

    echo "🔄 Restarting LiteSpeed..."
    $LSWSCCTRL restart

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

    install_package "libatomic1 rcs lsphp81 lsphp81-common" 
    if [ "$PACKAGE_MANAGER" = "apt" ]; then
        install_package "lsphp81-mysql"
    else
        install_package "lsphp81-mysqlnd"
    fi

    # 创建 OpenLiteSpeed 用户和组
    if ! id -u "$WEBSERVER_USER" &>/dev/null; then
        echo "👤 Creating web server user: $WEBSERVER_USER"
        sudo useradd -r -s /bin/false "$WEBSERVER_USER"
    fi
    # 设置 OpenLiteSpeed 的用户和组
    sudo sed -i "s/^user\s.*/user $WEBSERVER_USER/" /usr/local/lsws/conf/httpd_config.conf
    sudo sed -i "s/^group\s.*/group $WEBSERVER_USER/" /usr/local/lsws/conf/httpd_config.conf


    # sudo systemctl enable lsws --now || { echo "❌ Failed to enable/start OpenLiteSpeed service"; exit 1; }
    $LSWSCCTRL start || { echo "❌ Failed to enable/start OpenLiteSpeed service"; exit 1; }

    open_ports 22 80 443 7080 8081 8088 3306

    sudo mkdir -p /tmp/lshttpd
    sudo chown -R "$WEBSERVER_USER":"$WEBSERVER_USER" /tmp/lshttpd
    sudo chmod 755 /tmp/lshttpd

    echo "✅ OpenLiteSpeed installation completed"

    setup_dashboard_homepage
}

create_database_and_user() {
    local ROOT_PASS="$1"
    local DB_NAME="$2"
    local DB_USER="$3"
    local DB_PASS="$4"

    # 生成创建数据库和用户的 SQL
    local SQL=$(cat <<-EOSQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOSQL
    )

    echo "Creating database '$DB_NAME' and user '$DB_USER'..."
    echo "$SQL" | sudo mysql -uroot -p"$ROOT_PASS"
    if [ $? -eq 0 ]; then
        echo "✅ Database and user created successfully."
    else
        echo "❌ Failed to create database or user."
        exit 1
    fi
}
set_root_password() {
    local ROOT_PASS="$1"

    echo "🔍 Detecting MariaDB version..."

    VERSION_FULL=$(sudo mysql -u root -s --skip-column-names -e "SELECT VERSION();" 2>/dev/null)
    VERSION_MAJOR=$(echo "$VERSION_FULL" | cut -d. -f1)
    VERSION_MINOR=$(echo "$VERSION_FULL" | cut -d. -f2)

    echo "➡️ MariaDB version detected: $VERSION_FULL"

    echo "🔐 Setting MySQL root password..."

    if (( VERSION_MAJOR >= 10 && VERSION_MINOR >= 4 )); then
        echo "✅ Using MariaDB >= 10.4 logic: updating auth plugin + password"

        sudo mysql -u root <<-EOSQL
        ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${ROOT_PASS}');
        FLUSH PRIVILEGES;
EOSQL

    else
        echo "✅ Using MariaDB < 10.4 logic: direct password update"

        sudo mysql -u root <<-EOSQL
        ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PASS}';
        FLUSH PRIVILEGES;
EOSQL
    fi

    echo "✅ Root password set successfully."
}

install_database() {
    echo "🗄️ Installing database service..."
    # local MYSQL_ROOT_PASSWORD="123123"
    $INSTALL_CMD mariadb-server

    echo "🚀 Starting MariaDB service..."
    sudo /etc/init.d/mariadb start

    echo "⏳ Waiting for MariaDB to be ready..."
    # 等待 MariaDB 启动（最长等待30秒）
    for i in {1..30}; do
        if sudo mysqladmin ping &>/dev/null; then
            echo "✅ MariaDB is up!"
            break
        fi
        echo "⏳ MariaDB not ready yet... ($i)"
        sleep 1
    done

    if ! sudo mysqladmin ping &>/dev/null; then
        echo "❌ MariaDB failed to start or not ready after 30 seconds."
        exit 1
    fi

    echo "🔧 Generating a random root password for MySQL..."
    echo "Generated MySQL root password: $MYSQL_ROOT_PASSWORD"

    echo "🔧 Securing database installation..."
    # 使用示例：
    set_root_password "$MYSQL_ROOT_PASSWORD"

    echo "🧰 Creating database and user..."

    create_database_and_user "$MYSQL_ROOT_PASSWORD" "$DB_NAME" "$DB_USER" "$DB_PASSWORD"

    echo "✅ Database installation and initialization complete."
    echo "🔐 Save your MySQL root password: $MYSQL_ROOT_PASSWORD"
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

    $LSWSCCTRL restart || {
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

    # 尝试优雅地关闭 mariadb
    sudo systemctl stop mariadb || true
    sudo systemctl stop mysql || true
    # 确保进程终止
    if pgrep mariadbd > /dev/null; then
        echo "⚠️  MariaDB process still running. Forcing kill..."
        sudo pkill -9 mariadbd
    fi

    $REMOVE_CMD openlitespeed
    
    $REMOVE_CMD lsphp81 lsphp81-common lsphp81-mysqlnd
    sudo rm -rf /usr/local/lsws

    if [ "$PACKAGE_MANAGER" = "apt" ]; then
        $REMOVE_CMD mariadb-server mariadb-client mariadb-common
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
check_mysql_running() {
    # 检查 MariaDB 状态（不依赖 systemctl）    
    # 方法1：检查 mariadbd 进程是否存在
    if pgrep -x "mariadbd" >/dev/null; then
        PROCESS_RUNNING=true
    else
        PROCESS_RUNNING=false
    fi
    
    # 方法2：检查 3306 端口是否被监听（MariaDB 默认端口）
    if ss -tulpn | grep -q ":3306"; then
        PORT_LISTENING=true
    else
        PORT_LISTENING=false
    fi
    
    # 综合判断服务状态
    if [ "$PROCESS_RUNNING" = true ] && [ "$PORT_LISTENING" = true ]; then
        echo "✅ Database service (mariadb) is running."
    else
        echo "❌ Database service (mariadb) is not running."
        
        # 输出额外诊断信息（调试用）
        echo "--- Debug Information ---"
        echo "Process check: $(pgrep -x "mariadbd" >/dev/null && echo "Running" || echo "Not running")"
        echo "Port check: $(ss -tulpn | grep -q ":3306" && echo "Port 3306 is open" || echo "Port 3306 is closed")"
        echo "-------------------------"
    fi
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
        $LSWSCCTRL status || echo "❌ Failed to get OpenLiteSpeed status."
        check_mysql_running
        ;;
    resetAdminPass)
        sudo /usr/local/lsws/admin/misc/admpass.sh
        ;;
    installMariaDB)
        echo "🗄️ Installing MariaDB..."
        install_database
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
    installOpenSSH)
        install_openssh
        ;;
    installPhpMyAdmin)
        install_phpmyadmin
        ;;
    logs)
        tail -f /usr/local/lsws/logs/error.log
        ;;
    customHomePage)
        setup_dashboard_homepage
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
        echo "Usage: $0 {install|uninstall|resetAdminPass|status|update|installWithWp|version|openPorts|logs|installPhpMyAdmin|createDbUser|installOpenSSH|customHomePage}"
        ;;
esac
