FROM alpine:latest

RUN apk add --no-cache \
	bash \
	ca-certificates \
	coreutils \
	curl \
	ip6tables \
	iptables \
	jq \
	openssl \
	wireguard-tools

ENV LOCAL_NETWORK= \
	FIREWALL=true \
	WG_USERSPACE=false \
	PORT_FORWARDING=false \
	MAX_LATENCY= \
	PIA_USER= \
	PIA_PASS=

# Modify wg-quick so it doesn't die without --privileged
# Set net.ipv4.conf.all.src_valid_mark=1 on container creation using --sysctl if required instead
RUN sed -i 's/cmd sysctl.*/set +e \&\& sysctl -q net.ipv4.conf.all.src_valid_mark=1 \&\& set -e/' /usr/bin/wg-quick

# Install wireguard-go as a fallback if wireguard is not supported by the host OS or Linux kernel
RUN apk add --no-cache --repository=http://dl-cdn.alpinelinux.org/alpine/edge/testing wireguard-go

# Install uncomplicated firewall
RUN apk add --no-cache --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community ufw

# Get the PIA CA cert
ADD https://raw.githubusercontent.com/pia-foss/manual-connections/master/ca.rsa.4096.crt /etc/wireguard/ca.rsa.4096.crt

# Copy root
COPY root/ /
RUN chmod 755 /scripts/*

# Store stuff that might be shared with another container here (eg forwarded port)
VOLUME /shared

WORKDIR /scripts

CMD ["/scripts/start.sh"]
