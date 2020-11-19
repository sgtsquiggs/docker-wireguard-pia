#!/bin/bash
# Copyright (C) 2020 Private Internet Access, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.


# Check if the mandatory environment variables are set.
if [[ ! $WG_SERVER_IP ]]; then
  echo "WG_SERVER_IP was not set!"
  exit 1
elif [[ ! $WG_HOSTNAME ]]; then
  echo "WG_HOSTNAME was not set!"
  exit 1
elif [[ ! $PIA_TOKEN ]]; then
  echo "PIA_TOKEN was not set!"
  exit 1
fi

if [ "$WG_USERSPACE" == "true" ]; then
  export WG_QUICK_USERSPACE_IMPLEMENTATION=wireguard-go
fi

# Create ephemeral wireguard keys, that we don't need to save to disk.
privKey="$(wg genkey)"
export privKey
pubKey="$( echo "$privKey" | wg pubkey)"
export pubKey

# Authenticate via the PIA WireGuard RESTful API.
# This will return a JSON with data required for authentication.
# The certificate is required to verify the identity of the VPN server.
# In case you didn't clone the entire repo, get the certificate from:
# https://github.com/pia-foss/manual-connections/blob/master/ca.rsa.4096.crt
# In case you want to troubleshoot the script, replace -s with -v.
echo "Trying to connect to the PIA WireGuard API on $WG_SERVER_IP..."
wireguard_json="$(curl -s -G \
  --connect-to "$WG_HOSTNAME::$WG_SERVER_IP:" \
  --cacert "/etc/wireguard/ca.rsa.4096.crt" \
  --data-urlencode "pt=${PIA_TOKEN}" \
  --data-urlencode "pubkey=$pubKey" \
  "https://${WG_HOSTNAME}:1337/addKey" )"
export wireguard_json

# Check if the API returned OK and stop this script if it didn't.
if [ "$(echo "$wireguard_json" | jq -r '.status')" != "OK" ]; then
  >&2 echo "Server did not return OK. Stopping now."
  exit 1
fi

# Create the WireGuard config based on the JSON received from the API
# In case you want this section to also add the DNS setting, please
# start the script with PIA_DNS=true.
# This uses a PersistentKeepalive of 25 seconds to keep the NAT active
# on firewalls. You can remove that line if your network does not
# require it.
echo -n "Trying to write /etc/wireguard/pia.conf... "
mkdir -p /etc/wireguard
if [ "$PIA_DNS" == true ]; then
  dnsServer="$(echo "$wireguard_json" | jq -r '.dns_servers[0]')"
  echo "Trying to set up DNS to $dnsServer. In case you do not have resolvconf,"
  echo "this operation will fail and you will not get a VPN. If you have issues,"
  echo "start this script without PIA_DNS."
  dnsSettingForVPN="DNS = $dnsServer"
fi
echo "
[Interface]
Address = $(echo "$wireguard_json" | jq -r '.peer_ip')
PrivateKey = $privKey
$dnsSettingForVPN
[Peer]
PersistentKeepalive = 25
PublicKey = $(echo "$wireguard_json" | jq -r '.server_key')
AllowedIPs = 0.0.0.0/0
Endpoint = ${WG_SERVER_IP}:$(echo "$wireguard_json" | jq -r '.server_port')
" > /etc/wireguard/pia.conf || exit 1
echo OK!

# Start the WireGuard interface.
# If something failed, stop this script.
# If you get DNS errors because you miss some packages,
# just hardcode /etc/resolv.conf to "nameserver 10.0.0.242".
echo
echo Trying to create the wireguard interface...
wg-quick up pia || exit 1

echo -n "
Waiting for wireguard to connect"
for i in {5..1}; do
  printf "...%s" "$i"
  sleep 1
done
echo
echo

if [ "$FIREWALL" == "true" ]; then
  iptables -F OUTPUT
  iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT
  iptables -F INPUT
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A INPUT -i lo -j ACCEPT

  # Allow docker network input/output
  docker_network="$(ip -o addr show dev eth0 | awk '$3 == "inet" {print $4}')"
  iptables -A OUTPUT -o eth0 --destination $docker_network -j ACCEPT
  iptables -A INPUT -i eth0 --source $docker_network -j ACCEPT

  # Allow WG stuff
  iptables -A OUTPUT -o pia -j ACCEPT
  iptables -I OUTPUT -m mark --mark $(wg show pia fwmark) -j ACCEPT

  echo "Firewall enabled"
  echo
  iptables -L
fi

sleep infinity

# Set env var LOCAL_NETWORK=192.168.1.0/24 to allow LAN input/output
if [ -n "$LOCAL_NETWORK" ]; then
  for range in $LOCAL_NETWORK; do
    if [[ $FIREWALL == "true" ]]; then
      echo "Allowing network access to $range"
      iptables -A OUTPUT -o eth0 --destination $range -j ACCEPT
      iptables -A INPUT -i eth0 --source $range -j ACCEPT
    fi
    echo "Adding route to $range"
    ip route add $range via $(ip route show 0.0.0.0/0 dev eth0 | cut -d\  -f3)
  done
fi

# This section will stop the script if PIA_PF is not set to "true".
if [ "$PIA_PF" != true ]; then
  while true; do
    sleep 900
  done
fi

exec env PIA_TOKEN=$PIA_TOKEN \
  PF_GATEWAY="$(echo "$wireguard_json" | jq -r '.server_vip')" \
  PF_HOSTNAME="$WG_HOSTNAME" \
  FIREWALL="$FIREWALL" \
  ./port_forwarding.sh
