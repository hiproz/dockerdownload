#!/bin/bash

# 设置清理操作
trap 'ssh-agent -k >/dev/null 2>&1' EXIT

# 常量定义
SSH_IP="xxx"
SSH_PORT=22
SSH_USER="root"
SSH_KEY_PATH="demokey"
SSH_TIMEOUT=10  # SSH连接超时时间（秒）

# 默认路径
REMOTE_SAVE_PATH="/data/dockremote"
LOCAL_SAVE_PATH="/data/docklocal"
SKIP_PULL=false

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-pull)
            SKIP_PULL=true
            shift
            ;;
        *)
            break
            ;;
    esac
done

# 检查参数数量
if [ $# -lt 1 ] || [ $# -gt 3 ]; then
    echo "用法: $0 [--skip-pull] <docker镜像地址> [远程导出路径] [本地接收路径]"
    echo "示例: $0 gitblit/gitblit /data/dockremote /data/docklocal"
    echo "示例: $0 --skip-pull gitblit/gitblit /data/dockremote /data/docklocal"
    exit 1
fi

DOCKER_IMAGE=$1
if [ $# -ge 2 ]; then
    REMOTE_SAVE_PATH=$2
fi
if [ $# -ge 3 ]; then
    LOCAL_SAVE_PATH=$3
fi

# 从镜像地址中提取镜像名称
IMAGE_NAME=$(basename "$DOCKER_IMAGE")
TAR_FILE="$IMAGE_NAME.tar"

# 初始化ssh-agent并添加密钥
echo "初始化ssh-agent..."
eval $(ssh-agent -s) >/dev/null 2>&1
ssh-add "$SSH_KEY_PATH"
if [ $? -ne 0 ]; then
    echo "错误: 无法添加SSH密钥"
    exit 1
fi

# 函数：测试SSH连接
test_ssh_connection() {
    echo "测试SSH连接..."
    timeout $SSH_TIMEOUT ssh -o StrictHostKeyChecking=no -o ConnectTimeout=$SSH_TIMEOUT "$SSH_USER@$SSH_IP" "echo 'SSH连接测试成功'"
    return $?
}

# 函数：执行远程命令
execute_remote() {
    local cmd=$1
    echo "正在执行远程命令: $cmd"
    timeout $SSH_TIMEOUT ssh -o StrictHostKeyChecking=no -o ConnectTimeout=$SSH_TIMEOUT "$SSH_USER@$SSH_IP" "$cmd"
    return $?
}

# 函数：从远程复制文件
scp_from_remote() {
    local remote_file=$1
    local local_file=$2
    echo "正在从远程复制文件: $remote_file 到 $local_file"
    
    # 首先获取远程文件大小
    local remote_size=$(execute_remote "stat -f %z '$remote_file' 2>/dev/null || stat -c %s '$remote_file'")
    if [ -z "$remote_size" ]; then
        echo "错误: 无法获取远程文件大小"
        return 1
    fi
    echo "远程文件大小: $remote_size 字节"
    
    # 使用rsync替代scp，显示进度
    rsync -av --progress -e "ssh -o StrictHostKeyChecking=no" "$SSH_USER@$SSH_IP:$remote_file" "$local_file"
    return $?
}

# 检查必要参数
if [ -z "$SSH_IP" ]; then
    read -p "请输入远程服务器IP: " SSH_IP
fi

if [ ! -f "$SSH_KEY_PATH" ]; then
    echo "错误: SSH密钥文件不存在: $SSH_KEY_PATH"
    exit 1
fi

# 测试SSH连接
if ! test_ssh_connection; then
    echo "错误: SSH连接测试失败"
    echo "请检查以下内容："
    echo "1. SSH密钥文件 ($SSH_KEY_PATH) 是否存在且有正确的权限"
    echo "2. 远程服务器 ($SSH_IP) 是否可访问"
    echo "3. 防火墙设置是否允许SSH连接"
    exit 1
fi

# 创建本地目录
mkdir -p "$LOCAL_SAVE_PATH"

# 远程操作
echo "开始在远程服务器上操作..."

# 1. 创建远程目录
echo "创建远程目录: $REMOTE_SAVE_PATH"
if ! execute_remote "mkdir -p $REMOTE_SAVE_PATH"; then
    echo "错误: 无法创建远程目录"
    echo "正在检查远程目录权限..."
    execute_remote "ls -la /data"
    exit 1
fi
echo "远程目录创建成功"

# 2. 拉取Docker镜像（如果未跳过）
if [ "$SKIP_PULL" = false ]; then
    echo "正在拉取Docker镜像..."
    echo "执行命令: docker pull $DOCKER_IMAGE"
    pull_output=$(execute_remote "cd $REMOTE_SAVE_PATH && docker pull $DOCKER_IMAGE")
    echo "$pull_output"

    # 检查是否拉取成功
    if ! echo "$pull_output" | grep -q "Downloaded newer image" && ! echo "$pull_output" | grep -q "Image is up to date" && ! echo "$pull_output" | grep -q "Pull complete"; then
        echo "错误: Docker镜像拉取失败"
        
        # 添加详细的诊断信息
        echo "正在收集诊断信息..."
        
        # 检查Docker服务状态
        echo "执行命令: systemctl status docker"
        execute_remote "systemctl status docker | cat"
        
        # 检查Docker磁盘空间
        echo "执行命令: df -h"
        execute_remote "df -h | cat"
        
        # 检查Docker信息
        echo "执行命令: docker info"
        execute_remote "docker info | cat"
        
        # 检查网络连接
        echo "执行命令: ping -c 4 docker.io"
        execute_remote "ping -c 4 docker.io | cat"
        
        # 检查Docker日志
        echo "执行命令: journalctl -u docker --no-pager | tail -n 50"
        execute_remote "journalctl -u docker --no-pager | tail -n 50 | cat"
        
        # 尝试列出本地镜像
        echo "执行命令: docker images"
        execute_remote "docker images | cat"
        
        exit 1
    fi
else
    echo "跳过拉取Docker镜像步骤..."
fi

# 3. 检查镜像是否存在
echo "执行命令: docker images $DOCKER_IMAGE"
images_output=$(execute_remote "docker images $DOCKER_IMAGE")
if ! echo "$images_output" | grep -q "$IMAGE_NAME"; then
    echo "错误: Docker镜像不存在"
    exit 1
fi

# 4. 保存镜像为tar文件
echo "正在将镜像保存为tar文件..."
echo "执行命令: docker save -o $TAR_FILE $DOCKER_IMAGE"
save_output=$(execute_remote "cd $REMOTE_SAVE_PATH && docker save -o $TAR_FILE $DOCKER_IMAGE")
if [ $? -ne 0 ]; then
    echo "错误: 镜像保存失败"
    echo "$save_output"
    exit 1
fi

# 等待文件生成完成
echo "等待文件生成..."
sleep 2

# 检查文件是否存在和大小
file_check=$(execute_remote "ls -lh $REMOTE_SAVE_PATH/$TAR_FILE")
echo "远程文件状态: $file_check"

# 5. 将tar文件从远程复制到本地
echo "正在将镜像文件从远程复制到本地..."
if ! scp_from_remote "$REMOTE_SAVE_PATH/$TAR_FILE" "$LOCAL_SAVE_PATH/$TAR_FILE"; then
    echo "错误: 文件复制失败"
    exit 1
fi

# 6. 在本地加载镜像
echo "正在在本地加载Docker镜像..."
load_output=$(docker load -i "$LOCAL_SAVE_PATH/$TAR_FILE")
echo "$load_output"

# 7. 检查镜像是否加载成功
if echo "$load_output" | grep -q "Loaded image"; then
    echo "Docker镜像加载成功!"
else
    echo "错误: Docker镜像加载失败"
    exit 1
fi

echo "操作成功完成!"
