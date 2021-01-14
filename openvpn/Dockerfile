# Build a docker image for openvpn
FROM centos:latest

MAINTAINER Sebastian Weitzel <sebastian.weitzel@gmail.com>

WORKDIR /tmp

RUN yum --quiet --assumeyes update && \
  yum --quiet --assumeyes install epel-release && \
  yum --quiet --assumeyes --setopt=tsflags=nodocs install openvpn openssl iproute iptables sudo && \
  rm -rf /tmp/* /var/tmp/* /var/log/*

# etc just with default config, copied to /usr/local/openvpn/etc on startup
ADD ./bin /usr/local/bin
ADD ./easyrsa3 /usr/local/share/easy-rsa
ADD ./etc /etc

RUN chmod a+x /usr/local/bin/*
# Needed by scripts
ENV VPNCONFIG=/data-priv 
ENV RANDFILE=/data-priv/.rnd 
ENV EASYRSA="/usr/local/share/easy-rsa" 
ENV EASYRSA_PKI="/data-priv/pki" 
ENV EASYRSA_ALGO="ec" 
ENV EASYRSA_CURVE="secp521r1"

# Internally uses port 1194, remap using docker
EXPOSE 1194/udp

ENTRYPOINT ["/usr/local/bin/ovpn_run.sh"]
