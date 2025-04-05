# dockerdownload
解决国内hub.docker 无法访问的问题，通过海外 docker 节点下载image，然后打包传到国内

## 使用方法
dockerdownload [--skip-pull] <docker镜像地址> [远程导出路径] [本地接收路径]

示例: `dockerdownload gitblit/gitblit /data/dockremote /data/dockremote`

示例: `dockerdownload --skip-pull gitblit/gitblit /data/dockremote /data/docklocal`

## 可选参数
--skip-pull：如果远端已经 pull 成功，则可以通过这个参数跳过 docker pull 流程

## 脚本工作流程
1. 解析命令行参数，支持--skip-pull选项
2. 初始化ssh-agent并添加SSH密钥
3. 测试SSH连接
4. 创建远程目录
5. 根据--skip-pull选项决定是否拉取Docker镜像
6. 检查镜像是否存在
7. 将镜像保存为tar文件
8. 将tar文件从远程复制到本地
9. 在本地加载Docker镜像
10. 检查镜像是否加载成功
