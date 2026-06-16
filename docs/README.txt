Mihomo Gateway for Synology NAS
===============================

What this is
------------
A transparent proxy gateway you run on your Synology NAS. It is made of two
containers:

  * mihomo      - the proxy engine that routes your LAN traffic
  * metacubexd  - a web dashboard for managing the proxy

Clients on your home network can route their traffic through the gateway by
pointing their gateway and DNS at the gateway's static LAN IP. You manage
everything from a browser using the dashboard.

How it runs (important concept)
-------------------------------
The gateway attaches to your LAN using a "macvlan" network. This gives the
gateway its own LAN IP address that looks like a separate device.

A side effect of macvlan: the NAS host itself CANNOT reach the gateway's own
LAN IP. So always test the proxy and open per-client settings from a DIFFERENT
device on the LAN, never from the NAS itself.

  * The DASHBOARD is published on the NAS and IS reachable from the NAS:
        http://<NAS-IP>:<WEB_UI_PORT>     (default port 8080)

  * The GATEWAY IP (MIHOMO_IP) is only reachable from OTHER LAN devices.

Quick start (5 lines)
---------------------
1. Place this folder inside your Docker shared folder (typically
   /volume1/docker; your volume number may differ).
2. Open a terminal there and run:   sudo sh ./install.sh
3. Choose "1) Deploy the gateway", then follow the prompts.
4. From ANOTHER device, open the dashboard at http://<NAS-IP>:<WEB_UI_PORT>.
5. Point a test client's gateway and DNS at <MIHOMO_IP> to route it.

The installer menu
------------------
Running install.sh opens an interactive menu:

  1) Deploy the gateway (end-to-end)
  2) Set up automatic updates (cron)
  3) Modify an existing deployment
  4) Quit

Before you start
----------------
  * The folder MUST live under the Docker shared folder. The installer checks
    this first and prints exact move instructions if it is somewhere else.
  * Deployment needs root. If you are not root, re-run with:
        sudo sh ./install.sh
  * In mainland China the big public container registries are usually blocked.
    The default image source ("acr" mode) pulls from your own private image
    mirror. You provide the registry host, namespace, username, and password
    once during deploy.

After deploying
---------------
  * Open the dashboard at http://<NAS-IP>:<WEB_UI_PORT> from another device.
  * Add a backend in the dashboard with:
        Host   = <MIHOMO_IP>
        Port   = <CONTROLLER_PORT>     (default 9090)
        Secret = <CONTROLLER_SECRET>   (if you set one)
  * Route any client by setting that client's gateway and DNS to <MIHOMO_IP>.

Where to read next
------------------
  * INSTALL.txt          - detailed step-by-step install
  * CONFIGURE.txt        - the .env settings reference
  * AUTO-UPDATE.txt      - scheduling automatic updates
  * TROUBLESHOOTING.txt  - symptoms and fixes

Logs are written under the logs/ folder (an install log and, once scheduled,
an auto-update log).
