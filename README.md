# Open Secure Access Service Edge

The purpose of this project is to build SASE components using OSS tools for testing.

It will currently build Docker containers for OpenVPN and transparent Proxy (Squid+C-ICAP+ClamAV)

OpenSASE creates several containers to server as VPN server with explicit and transparent proxy capability.
The OpenVPN container will forward all HTTP (Port 80) / HTTPS (Port 443) traffic to the Squid container. All other VPN traffic will be SNAT'd.
Squid is configured to scan all traffic via ClamAV for Virii and against Google Safebrowsing database. Additionally the Shallalist blacklist is configured.
Dnsmasq has been recently added to the landscape to ensure Squid and VPN clients will use the same DNS server, and furthermore it allows resolution of Docker network hostnames.

> It has been tested on Windows OpenVPN client as well as IOS 11

```
+----------------------------------------------------------------------------+
|                                                                            |
|                                     3128/tcp                               |
|   +-------------+ 80/tcp            3129/tcp TPROXY http  +------------+   |
|   |             | 443/tcp           3130/tcp TPROXY https |            |   |
|   |   openvpn   +----------------------------------------->   squid    |   |
|   |             |                                         |            |   |
|   +------^------+                                         +------+-----+   |
|          | 1194/udp                                              |         |
|          |                                                       |         |
|          |                                              1344/tcp |         |
|          |       +------------+                           +------v-----+   |
|          |       |            |                           |            |   |
|          |       |   clamav   <---------------------------+   cicap    |   |
|          |       |            | 3310/tcp                  |            |   |
|          |       +------------+                           +------------+   |
|          |                                                                 |
|          | 5443/udp                                                        |
+-------------------------------------------------------------- Docker-host -+
           |
           |
  +-----------------------------------------------------------------------+
  |        |                                                              |
  |        |                                                              |
  |  +-----+------+                                                       |
  |  | VPN client |                                                       |
  |  +------------+                                                       |
  |                                                                       |
  |                                                                       |
  +-------------------------------------------------------------Internet--+
```

## Quick Start

> Requires [Docker](https://docs.docker.com/) 17.06 or later, and [Docker Compose](https://docs.docker.com/compose/) 1.13.0 or later

### Build containers

* Obtain the GIT structure (as [.zip](https://github.com/shsingh/opensase/archive/master.zip) or use [GIT](https://github.com/shsingh/opensase.git))
* Change to the opensase directory, then build:
```bash
docker-compose -p opensase build
```

### Start containers

* Start service once, to build volumes, networks
```bash
docker-compose -p opensase up
```

> Note: Make sure to read the output, and if everything went well, the containers keep running

## Setting up Clients

* Ensure DNS entry for vpn.f5labs.dev for localhost (testing)

* Start OpenVPN client
```bash
sudo openvpn openvpn/client.f5labs.dev.ovpn
```

## Configure Explicit Proxy
* Configuring proxy explicitly is definetly recommended. Squid bump works generally more reliable with explicit configured proxy.
* Hint: Use Foxyproxy (Firefox) or similar Proxy switcher utility, to simply turn Proxy on when VPN is enabled.
    * Proxy: IP 192.168.50.5:3128

### Windows VPN client

* OpenVPN on Windows is easy to use. Just copy the *.ovpn file over to C:\Program Files\OpenVPN\config (adjust if needed)
* Start OpenVPN, you will probably Admin permissions or else the Tunnel will not be properly created.
* Import Squid CA into Certificate Stores
    - create file squidCA.crt with content you saved
    - double click the file (info window should be presented)
    - click "Install Certificate"
    - pick local user as install destination
    - select "Trusted Root Certification Authorities" as store
    - verify in Internet Explorer that e.g. on https://www.google.com no certificate error is popping up anymore
      (Note: Google Chrome is using also the Windows store)
    - Firefox uses its own Cert store (Settings -> Extended -> Certificates)

### IOS

* Application & VPN Profile
    - Install on your device [OpenVPN Connect](https://itunes.apple.com/de/app/openvpn-connect/id590379981)
    - Use Itunes put the *.ovpn file in the OpenVPN Connect files. The application will then offer to import the profile 
* Squid CA to prevent SSL errors
    - Store CA as PEM (.crt) in Dropbox or Icloud and open the file. There should be a popup presenting the possibility to import the certificate and set it to trusted. 
    - Alternatively install the iPhone Configuration Utility on [MacOS](https://itunes.apple.com/us/app/apple-configurator/id434433123?mt=12) / [Windows](http://download.cnet.com/iPhone-Configuration-Utility-for-Windows/3000-20432_4-10969175.html)
        * Create a profile and add the Squid CA to the certificate store. Then assign the profile to your device.

### Verification on Client

After the tunnel has been established, make sure it is working:

* Ping the VPN server:
```bash
ping 10.128.81.1
```
* Check Transparent Proxy is working by downloading a (harmless) [Eicar Test Virus](http://www.eicar.org/85-0-Download.html)
    > Note: Try the different variants, SSL should also work. If it works you will see a message from Squid/ClamAV, and not from your local Virus Scanner.

## Miscellaneous

### Choice for CentOS

* I decided to use CentOS whenver flexibility is required (image size ~350MB)
* Atomic Linux is used for Dnsmasq (image size ~5MB)

### Security Aspects

* Each application has its own container, thus high isolation
* Applications run non-root
* VPN CA is kept in a separate Docker Volume. Password should be kept at a secure location
* VPN is using TLS 1.2 with Elliptic Curve certificates, DHE and tls-crypt channel.
* Keys for OpenVPN and squid are stored in their respective directly --> *DO NOT USE THIS IN PRODUCTION*

### Blacklist
* The blacklists can be configured by adjusting the Squid containers ENV var SQUIDGUARD_FILTER (list of space separated categories)
    * Check a list of supported [Shallalist Categories](http://www.shallalist.de/categories.html)

### Skipping SSL Bump
* SSL bump (man in the middle) can be disabled for defined sites by modifying /data/squid/nobump.txt.
    * The file is located on the Docker 'opensase_data' volume

### Cleanup
* In case you want to remove the Docker containers, networks and volumes, the following steps can be used after stopping the services:
```bash
docker rm opensase_clamav_1 opensase_squid_1 opensase_cicap_1 opensase_openvpn_1 opensase_dnsmasq_1 ; \
docker rmi opensase_clamav opensase_squid opensase_cicap opensase_openvpn opensase_dnsmasq ; \
docker volume rm opensase_squid_priv ; docker volume rm opensase_openvpn_priv ; docker volume rm opensase_data ; \
docker network rm opensase_main ; \
docker image prune
```

--

### Credits: 
The initial build for this was inspired from the work done by [@sweitzel](https://github.com/sweitzel) on the [docker-vpnbox](https://github.com/sweitzel/docker-vpnbox) project
