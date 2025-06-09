### Openlitespeed 一键安装包
#### 安装
```bash
curl -O https://raw.githubusercontent.com/aydenzeng/OlsOneClick/main/ols-one-click.sh || wget https://raw.githubusercontent.com/aydenzeng/OlsOneClick/main/ols-one-click.sh && chmod +x ./ols-one-click.sh && sudo ./ols-one-click.sh install

```
#### 卸载
```bash
sudo ./ols-one-click.sh uninstall
```

### 本地docker 启动
#### 启动容器：
```bash
docker-compose up -d
```

#### 进入容器：
```bash
docker-compose exec ols-deploy bash
```

#### 执行脚本：
在容器内运行你的脚本命令：
```bash
# 完整部署（包括安装 MySQL）
ols-one-click.sh install

# 安装 WordPress 站点
ols-one-click.sh installWithWp mysite 8081

# 查看部署信息
cat /deploy_info/deploy_info.txt
```

#### 验证服务：
* OpenLiteSpeed 管理面板：http://localhost:7080
* WordPress 站点：http://localhost:8081
* phpMyAdmin：http://localhost:8088
