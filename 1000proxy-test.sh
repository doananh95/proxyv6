#!/bin/sh
# Auto-install and configure 3proxy with 1000 proxies, NO authentication
# Each proxy listens on the server's IPv4 and uses a unique IPv6 for outgoing

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

install_3proxy() {
    echo "installing 3proxy"
    URL="https://github.com/z3APA3A/3proxy/archive/refs/tags/0.8.13.tar.gz"
    wget -qO- $URL | tar -xzf-
    cd 3proxy-0.8.13 || exit 1
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cd $WORKDIR || exit 1
}

# Generate 3proxy cfg with NO auth; each proxy uses -6 to support IPv6 outgoing
gen_3proxy() {
    cat <<EOF
daemon
maxconn 4000
nserver 1.1.1.1
nserver 8.8.4.4
nserver 2001:4860:4860::8888
nserver 2001:4860:4860::8844
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
stacksize 6291456
flush
auth none

# generated proxy entries (no user/pass)
$(awk -F "/" '{print "allow *\nproxy -6 -n -p" $2 " -i" $1 " -e" $3 "\nflush\n"}' ${WORKDATA})
EOF
}

# Create proxy list file containing IPv4:port lines (the endpoints to connect to)
gen_proxy_file() {
    cat >proxy.txt <<EOF
$(awk -F "/" '{print $1 ":" $2 }' ${WORKDATA})
EOF
}

# data format per-line: IP4/PORT/IP6
gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
        echo "$IP4/$port/$(gen64 $IP6)"
    done
}

gen_ifconfig() {
    cat <<EOF
$(awk -F "/" '{print "ifconfig eth0 inet6 add " $3 "/64"}' ${WORKDATA})
EOF
}

# --------------------
# main
# --------------------

echo "installing apps"

install_3proxy

echo "working folder = /home/bkns"
WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $WORKDIR || exit 1

# Detect IPs
IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

if [ -z "$IP4" ] || [ -z "$IP6" ]; then
    echo "Cannot detect IPv4 or IPv6. Make sure this server has both IPv4 and IPv6 connectivity."
    exit 1
fi

echo "Internal IP = ${IP4}. External sub for IP6 = ${IP6}"

# Configure ports for 1000 proxies: 22000..22999 (1000 ports)
FIRST_PORT=22000
LAST_PORT=22999

# generate data and supporting files

gen_data >${WORKDATA}

# create script that adds all IPv6 addresses to the interface
gen_ifconfig >${WORKDIR}/boot_ifconfig.sh
chmod +x ${WORKDIR}/boot_ifconfig.sh

# generate 3proxy config and proxy list

gen_3proxy >/usr/local/etc/3proxy/3proxy.cfg

gen_proxy_file

# ensure rc.local exists and will run on systemd systems
if [ ! -f /etc/rc.d/rc.local ]; then
    echo "#!/bin/sh -e" > /etc/rc.d/rc.local
    chmod +x /etc/rc.d/rc.local
fi

# append startup commands (idempotent append)
grep -F "# 3proxy boot" /etc/rc.d/rc.local >/dev/null 2>&1 || cat >>/etc/rc.d/rc.local <<EOF
# 3proxy boot
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 10048
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
EOF

chmod +x /etc/rc.d/rc.local
systemctl enable rc-local 2>/dev/null || true
systemctl start rc-local 2>/dev/null || true

# run once now
bash /etc/rc.d/rc.local || true

echo "Proxy setup finished. Created ${WORKDATA} and ${WORKDIR}/proxy.txt"
echo "proxy endpoints (connect to):"
awk -F"/" '{print $1":"$2}' ${WORKDATA} | head -n 20

echo "... (total lines: $(wc -l < ${WORKDATA}))"

# cleanup optional
# rm -rf /root/setup.sh
# rm -rf /root/3proxy-3proxy-0.8.6

echo "Done."
