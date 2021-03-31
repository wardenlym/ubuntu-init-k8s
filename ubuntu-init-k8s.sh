#!/usr/bin/env bash

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-f] -p param_value arg1 [arg2...]
Script description here.
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
-f, --flag      Some flag description
-p, --param     Some param description
EOF
  exit
}

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
}

setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

parse_params() {
  # default values of variables set from params
  flag=0
  param=''

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    -f | --flag) flag=1 ;; # example flag
    -p | --param) # example named parameter
      param="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  # check required params and arguments
  [[ -z "${param-}" ]] && die "Missing required parameter: param"
  [[ ${#args[@]} -eq 0 ]] && die "Missing script arguments"

  return 0
}

parse_params "$@"
setup_colors

# script logic here

msg "${RED}Read parameters:${NOFORMAT}"
msg "- flag: ${flag}"
msg "- param: ${param}"
msg "- arguments: ${args[*]-}"


set_localtime() {
  ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
}

apt_install_base_util() {
  apt update && apt install -y \
    apt-transport-https \
    ca-certificates \
    git \
    wget \
    curl \
    bash-completion \
    zsh \
    jq \
    ansible \
    unzip \
    sysstat \
    dnsutils \
    tcpdump \
    telnet \
    lsof \
    htop \
    net-tools \
    bridge-utils \
    traceroute \
    conntrack \
    ntp \
    ipvsadm \
    ipset 
}

remove_docker() {
  #TODO: how to ensure docker cmd is exist
  set +e
  docker container stop $(docker container ls -aq)
  docker system prune -f -a --volumes
  apt remove -y docker
  apt remove -y docker-engine
  apt remove -y docker.io
  apt remove -y containerd
  apt remove -y runc
  apt remove -y docker-ce
  apt remove -y docker-ce-cli
  apt purge -y docker-ce
  apt purge -y docker-ce-cli 
  apt autoremove -y
  set -e
}

apt_install_docker() {
  apt update
  apt install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --yes --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo \
  "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt update
  apt install -y docker-ce=5:19.03.15~3-0~ubuntu-focal docker-ce-cli=5:19.03.15~3-0~ubuntu-focal containerd.io
  apt-mark hold docker-ce docker-ce-cli containerd.io
  usermod -aG docker $USER

  mkdir -p /data/docker
  bash -c 'cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": [
      "https://registry.docker-cn.com",
      "http://hub-mirror.c.163.com",
      "https://v2qkv589.mirror.aliyuncs.com",
      "https://mirror.ccs.tencentyun.com",
      "https://docker.mirrors.ustc.edu.cn",
      "http://f1361db2.m.daocloud.io"
  ],
  "live-restore": true ,
  "max-concurrent-downloads": 10,
  "log-driver": "json-file",
  "log-level": "warn",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "data-root": "/data/docker",
  "exec-opts": ["native.cgroupdriver=systemd"]
}
EOF'

  systemctl restart docker.service
}

apt_install_kubeadm_kubectl() {
  echo 'deb https://mirrors.aliyun.com/kubernetes/apt/ kubernetes-xenial main' > /etc/apt/sources.list.d/kubernetes.list
  gpg --keyserver keyserver.ubuntu.com --recv-keys 836F4BEB
  gpg --export --armor 836F4BEB | sudo apt-key add -
  apt update
  apt install -y kubelet=1.19.7-00 kubeadm=1.19.7-00 kubectl=1.19.7-00
}

disable_swap() {
  swapoff -a && sysctl -w vm.swappiness=0
  sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

  # 两种写法都可以
  #sed -ri '/^[^#]*swap/s@^@#@' /etc/fstab
}

load_module_rke_checks() {
  rm -f /etc/modules-load.d/rke.conf
  for module in br_netfilter ip6_udp_tunnel ip_set ip_set_hash_ip ip_set_hash_net iptable_filter iptable_nat iptable_mangle iptable_raw nf_conntrack_netlink nf_conntrack nf_defrag_ipv4 nf_nat nfnetlink udp_tunnel veth vxlan x_tables xt_addrtype xt_conntrack xt_comment xt_mark xt_multiport xt_nat xt_recent xt_set  xt_statistic xt_tcpudp;
  do
    modprobe $module
    /sbin/modinfo -F filename $module |& grep -qv ERROR && modprobe -- $module && echo $module >> /etc/modules-load.d/rke.conf || :
  done
  systemctl daemon-reload
  systemctl enable --now systemd-modules-load.service
}

load_module_ipvs() {
  module=(
  ip_vs
  ip_vs_rr
  ip_vs_wrr
  ip_vs_sh
  nf_conntrack
  br_netfilter
    )
  rm -f /etc/modules-load.d/ipvs.conf
  for kernel_module in ${module[@]};do
      /sbin/modinfo -F filename $kernel_module |& grep -qv ERROR && modprobe -- $kernel_module && echo $kernel_module >> /etc/modules-load.d/ipvs.conf || :
  done

  systemctl daemon-reload
  systemctl enable --now systemd-modules-load.service

  # add this if systemd-modules-load report a error
#   cat>>/usr/lib/systemd/system/systemd-modules-load.service<<EOF
# [Install]
# WantedBy=multi-user.target
# EOF

}

load_k8s_sysctl() {
  cat << EOF | tee /etc/sysctl.d/k8s.conf
# 需要禁止ipv6可以打开
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1
# net.ipv6.conf.lo.disable_ipv6 = 1

net.ipv4.neigh.default.gc_stale_time = 120

# ubuntu20.04默认是2 calico需要是1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.lo.arp_announce = 2
net.ipv4.conf.all.arp_announce = 2
net.ipv4.ip_forward = 1
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 1024
net.ipv4.tcp_synack_retries = 2

# 要求iptables不对bridge的数据进行处理
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-arptables = 1

net.netfilter.nf_conntrack_max = 2310720
fs.inotify.max_user_watches=89100
fs.file-max = 52706963
fs.nr_open = 52706963
vm.overcommit_memory=1
vm.panic_on_oom=0

vm.swappiness=0
EOF
  sysctl -p /etc/sysctl.d/k8s.conf
  sysctl --system
}


set_localtime

apt_install_base_util
#remove_docker
apt_install_docker
apt_install_kubeadm_kubectl

disable_swap
load_module_rke_checks
load_module_ipvs
load_k8s_sysctl

