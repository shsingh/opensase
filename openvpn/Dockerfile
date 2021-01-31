# Build a docker image for openvpn
FROM centos:latest

MAINTAINER Sebastian Weitzel <sebastian.weitzel@gmail.com>

WORKDIR /tmp

RUN yum --quiet --assumeyes update && \
  yum --quiet --assumeyes install epel-release && \
  yum --quiet --assumeyes --setopt=tsflags=nodocs install openvpn openssl iproute iptables sudo && \
  rm -rf /tmp/* /var/tmp/* /var/log/*

# Needed by scripts
ENV VPNCONFIG="/data-priv"
ENV RANDFILE="/data-priv/.rnd"
ENV EASYRSA="/usr/local/share/easy-rsa"
ENV EASYRSA_PKI="/data-priv/pki"
ENV EASYRSA_ALGO="ec"
ENV EASYRSA_CURVE="secp521r1"

# VPN server instance details
ENV VPN_SERVER_URI="udp://vpn.f5labs.dev"
ENV CLIENT_CN="vpn.f5labs.dev"

ADD ./bin /usr/local/bin
ADD ./easyrsa3 /usr/local/share/easy-rsa
COPY ./vpn/ /data-priv/

RUN chmod a+x /usr/local/bin/*

# Internally uses port 1194, remap using docker
EXPOSE 1194/udp

ENTRYPOINT ["/usr/local/bin/ovpn_run.sh"]
