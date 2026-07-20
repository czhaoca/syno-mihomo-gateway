Synology NAS 上的 Mihomo 网关
=============================

这是什么
--------
一个运行在群晖（Synology）NAS 上的透明代理网关。它由两个容器组成：

  * mihomo      - 负责转发局域网流量的代理引擎
  * metacubexd  - 用于管理代理的网页面板

家庭网络中的客户端只需把网关和 DNS 指向本网关的静态局域网 IP，即可让流量
经由网关转发。日常管理通过浏览器在面板中完成。

它是如何运行的（重要概念）
--------------------------
网关通过 "macvlan" 网络接入你的局域网，从而拥有一个独立的局域网 IP，看起来
就像一台独立的设备。

macvlan 有一个副作用：NAS 主机本身无法访问网关自己的局域网 IP。因此，请始终
在局域网中的另一台设备上测试代理、设置各客户端，绝不要在 NAS 上进行。

  * 面板发布在 NAS 上，可以从 NAS 访问：
        http://<NAS-IP>:<WEB_UI_PORT>     （默认端口 8080）

  * 网关 IP（MIHOMO_IP）只能从局域网中的其他设备访问。

快速开始（5 步）
----------------
不在群晖 NAS 上？网关也可以运行在任何能运行 Docker 的 Linux 主机
（amd64/arm64）或树莓派上——在 Linux 发布包中，请运行
sudo sh ./install-linux.sh（树莓派上运行 sudo sh ./install-pi.sh），
并改读 INSTALL-LINUX.zh.txt。下面的步骤是群晖路径。

1. 把本文件夹放入 Docker 共享文件夹（通常为 /volume1/docker；你的卷号可能
   不同）。
2. 在该目录下打开终端并运行：   sudo sh ./install.sh
3. 首次运行时选择语言（1 英文 / 2 中文）。
4. 选择 "1) 部署网关"，然后按提示操作。
5. 在另一台设备上打开面板 http://<NAS-IP>:<WEB_UI_PORT>，并把一台测试客户端
   的网关和 DNS 指向 <MIHOMO_IP>，即可将其接入代理。

语言
----
首次运行 install.sh 时会询问语言：

      1) English（英文）   2) 中文

随后整个安装程序都以该语言运行。你的选择会被保存（即 .env 中的
INSTALLER_LANG），因此以后运行会直接进入菜单。

安装程序菜单
------------
选择语言之后，install.sh 会打开一个交互式菜单：

  1) 部署网关（首次运行，端到端）
  2) 使用已保存的 .env 部署（可编辑设置或按原样部署）
  3) 设置自动更新（cron）
  4) 修改现有部署
  5) 状态 / 诊断
  6) 退出

菜单上方会显示一行实时状态：尚未部署 / 不完整 / 运行中（运行时含网关 IP 与面板地址）。
第 5 项为只读：一份状态概览，外加可选的一次 doctor 诊断。

在任意提问或菜单处，你都可以按 Ctrl-D 干净地退出安装程序。

开始之前
--------
  * 文件夹必须位于 Docker 共享文件夹之下。安装程序会首先检查这一点，若位置
    不对会打印准确的移动指引。
  * 部署需要 root 权限。如果你不是 root，请改用：
        sudo sh ./install.sh
  * 在中国大陆，主流的公共容器镜像仓库通常无法访问。默认的镜像来源
    （"acr" 模式）会从你自己的私有镜像源拉取。部署时你只需提供一次仓库地址、
    命名空间、用户名和密码。

部署完成之后
------------
  * 在另一台设备上打开面板 http://<NAS-IP>:<WEB_UI_PORT>。
  * 在面板中添加一个后端：
        主机（Host）   = <MIHOMO_IP>
        端口（Port）   = <CONTROLLER_PORT>     （默认 9090）
        密钥（Secret） = <CONTROLLER_SECRET>   （如已设置）
  * 把任意客户端的网关和 DNS 设为 <MIHOMO_IP>，即可让其走代理。

接下来阅读
----------
  * INSTALL.zh.txt          - 详细的分步安装
  * INSTALL-LINUX.zh.txt    - 通用 Linux / 树莓派安装（仅 Linux 发布包）
  * CONFIGURE.zh.txt        - .env 设置参考
  * AUTO-UPDATE.zh.txt      - 设置自动更新
  * TROUBLESHOOTING.zh.txt  - 故障现象与解决办法
  * CLI.zh.txt              - gateway.sh 命令行参考

日志写入 ../syno-mihomo-gateway-data/logs/（与本文件夹同级，会自动创建）：
一份安装日志；设置计划任务后还有一份自动更新日志。

只读健康检查：sudo sh scripts/doctor.sh --egress
