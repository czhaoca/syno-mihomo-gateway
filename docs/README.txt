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
3. Pick a language (1 English / 2 Chinese) the first time you run it.
4. Choose "1) Deploy the gateway", then follow the prompts.
5. From ANOTHER device, open the dashboard at http://<NAS-IP>:<WEB_UI_PORT>,
   and point a test client's gateway and DNS at <MIHOMO_IP> to route it.

Language
--------
The first time you run install.sh it asks for a language:

      1) English   2) Chinese

The whole installer then runs in that language. Your choice is saved (as
INSTALLER_LANG in .env), so later runs go straight to the menu.

The installer menu
------------------
After the language step, install.sh opens an interactive menu:

  1) Deploy the gateway (first run, end-to-end)
  2) Redeploy (reuse saved settings; fix a conflicting IP)
  3) Set up automatic updates (cron)
  4) Modify an existing deployment
  5) Quit

You can press Ctrl-D at any prompt or menu to quit the installer cleanly.

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

Read-only health check:  sudo sh scripts/doctor.sh --egress
