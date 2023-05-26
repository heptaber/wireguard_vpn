#!/bin/bash

: '
wireguard and unbound dns resolver setup script
chmod +x wgsetup.sh
sh /.wgsetup.sh
'


# setting up varibales
LOCAL_ADDRESS="10.0.0.1"
LOCAL_NETWORK="10.0.0.0"
ADR_START="10.0.0."
WG_PORT="51402"

WG_DIR="/etc/wireguard"
WG_CONF="/etc/wireguard/wg0.conf"
CLIENTS_FILES_DIR="/etc/wireguard/clients"

CLIENTS_NUMBER=3
SERVER_IP=$(hostname -I | awk '{print $1}')


case $1 in
  -c)
    if [ $2 == ""]
      then
      echo "Default clients number is " + $CLIENTS_NUMBER
    else
      echo "Set up for " + $2 + " clients..."
      CLIENTS_NUMBER=$2
    fi
    ;;
esac


# check current user is root
if [ "$(id -u)" != 0 ]; then
  echo "No permissions to run the script! Please use: sudo ./wgsetup.sh"
  exit 1
fi


# update the system
apt update && apt upgrade -y
# install wireguard
apt install wireguard -y

# install dnsutils
apt install dnsutils -y

# install firewall
apt install ufw -y

# install net-tools if missing
apt install net-tools -y

# install qrencode to generate QR codes
apt install qrencode -y

# create alias to use the app by 'qr' command
echo "alias qr='qrencode -t ansiutf8 <'" >> ~/.bashrc
source ~/.bashrc

# install cron
apt install cron -y


# ADDING CRON JOBS
# monthly auto-update domains
echo 'curl -o /var/lib/unbound/root.hints https://www.internic.net/domain/named.cache' > /etc/cron.monthly/update_unbound_roots.sh
chmod +x /etc/cron.monthly/update_unbound_roots.sh
# monthly server auto-update and reboot
echo 'apt update && apt upgrade -y && apt autoremove -y && reboot' > /etc/cron.monthly/server_update.sh
chmod +x /etc/cron.monthly/server_update.sh


# enable ip forwarding
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
# enable proxy forwarding
echo "net.ipv4.conf.all.proxy_arp = 1" >> /etc/sysctl.conf


# Wireguard server set up
SERVER_PUBKEY=$(wg genkey | tee $WG_DIR/privatekey | wg pubkey | tee $WG_DIR/publickey)
PK=$(cat $WG_DIR/privatekey)
NETWORK_INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
# another one way to get network interface: route -n | awk '$1 == "0.0.0.0" {print $8}'

cat > $WG_CONF << ENDOFFILE
[Interface]
Address = $LOCAL_ADDRESS/24
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $NETWORK_INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $NETWORK_INTERFACE -j MASQUERADE
ListenPort = $WG_PORT
PrivateKey = $PK
SaveConfig = true
ENDOFFILE

# up wg
wg-quick up wg0
# auto-run on system startup
systemctl enable wg-quick@wg0
# fix sometimes wg startup fails first time
wg-quick down wg0
systemctl start wg-quick@wg0


# Wireguard clients set up (adding peers)
# creating directory for client configs
cd $WG_DIR
if [ ! -d "clients" ]; then
    mkdir clients
fi

# set up clients
START=10
LIMIT=$((CLIENTS_NUMBER+START-1))
for i in $(seq $START $LIMIT);
do
   CLIENT_PUBKEY=$(wg genkey | tee $WG_DIR/client"$i"_privatekey | wg pubkey | tee $WG_DIR/client"$i"_publickey)
   CLIENT_PRIVATEKEY=$(cat $WG_DIR/client"$i"_privatekey)
   CLIENT_LOCAL_IP=$ADR_START"$i"
   wg set wg0 peer $CLIENT_PUBKEY allowed-ips $CLIENT_LOCAL_IP
   cat > $CLIENTS_FILES_DIR/client"$i".conf << ENDOFFILE
[Interface]
Address = $CLIENT_LOCAL_IP/32
PrivateKey = $CLIENT_PRIVATEKEY
DNS = $LOCAL_ADDRESS

[Peer]
PublicKey = $SERVER_PUBKEY
Endpoint = $SERVER_IP:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 20
ENDOFFILE
done

systemctl restart wg-quick@wg0


# set up firewall rules
ufw allow $WG_PORT/udp
ufw allow OpenSSH
ufw disable
ufw enable

# ADDITIONAL
# install iptables
apt install iptables -y

# IPTABLES SET UP
# track VPN connection
iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
# allow incoming VPN traffic on the listening port
iptables -A INPUT -p udp -m udp --dport $WG_PORT -m conntrack --ctstate NEW -j ACCEPT
# allow TCP and UDP recursive DNS traffic
iptables -A INPUT -s $LOCAL_NETWORK/24 -p tcp -m tcp --dport 53 -m conntrack --ctstate NEW -j ACCEPT
iptables -A INPUT -s $LOCAL_NETWORK/24 -p udp -m udp --dport 53 -m conntrack --ctstate NEW -j ACCEPT
# allow forwarding of packets that stay in the VPN tunnel
iptables -A FORWARD -i wg0 -o wg0 -m conntrack --ctstate NEW -j ACCEPT
# set up nat
iptables -t nat -A POSTROUTING -s $LOCAL_NETWORK/24 -o $NETWORK_INTERFACE -j MASQUERADE

# persistent firewall rules
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections

apt install iptables-persistent -y
systemctl enable netfilter-persistent
netfilter-persistent save


# UNBOUND DNS RESOLVER SET UP
apt install unbound unbound-host -y
apt install curl -y
# download list of DNS root servers
curl -o /var/lib/unbound/root.hints https://www.internic.net/domain/named.cache
# access restrictions set
chown unbound:unbound /var/lib/unbound/root.hints

cat > /etc/unbound/unbound.conf << ENDOFFILE
server:
    num-threads: 2

    # enable logs
    verbosity: 1

    # list of Root DNS Server
    root-hints: "/var/lib/unbound/root.hints"

    #Use the root servers key for DNSSEC
    auto-trust-anchor-file: "/var/lib/unbound/root.key"

    # respond to DNS requests on all interfaces
    interface: 0.0.0.0
    max-udp-size: 3072
    
    # IPs authorised to access the DNS Server
    access-control: 0.0.0.0/0                 refuse
    access-control: 127.0.0.1                 allow
    access-control: $LOCAL_NETWORK/24             allow

    # not allowed to be returned for public Internet  names
    private-address: $LOCAL_NETWORK/24

    # hide DNS Server info
    hide-identity: yes
    hide-version: yes

    # limit DNS fraud and use DNSSEC
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-referral-path: yes
    
    # add an unwanted reply threshold to clean the cache and avoid, when possible, DNS poisoning
    unwanted-reply-threshold: 10000000
    
    # have the validator print validation failures to the log
    val-log-level: 1
    
    # minimum lifetime of cache entries in seconds
    cache-min-ttl: 1800
    
    # maximum lifetime of cached entries in seconds
    cache-max-ttl: 14400
    prefetch: yes
    prefetch-key: yes
ENDOFFILE

systemctl disable systemd-resolved
systemctl stop systemd-resolved

systemctl enable unbound
systemctl start unbound

# cat 'DNSStubListener=no' > /etc/systemd/resolved.conf


ifconfig wg0 down
ifconfig wg0 up


# updating hosts
cp /etc/hosts /etc/hosts.default
echo "$LOCAL_ADDRESS    $(hostname)" >> /etc/hosts
