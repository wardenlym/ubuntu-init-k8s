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
    ipvsadm \
    ipset 
}

set_localtime() {
  ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
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

  mkdir -p /etc/docker /data/docker
  # 注意修改data-root
  bash -c 'cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": [
      "https://registry.docker-cn.com",
      "http://hub-mirror.c.163.com",
      "https://fz5yth0r.mirror.aliyuncs.com",
      "https://mirror.ccs.tencentyun.com",
      "https://docker.mirrors.ustc.edu.cn",
      "http://f1361db2.m.daocloud.io"
      "https://dockerhub.mirrors.nwafu.edu.cn/",
      "https://reg-mirror.qiniu.com",
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

# 这段还不完全理解，没有使用。暂时先记录下来。
# 防止FORWARD的DROP策略影响转发,给docker daemon添加下列参数修正，当然暴力点也可以iptables -P FORWARD ACCEPT
# mkdir -p /etc/systemd/system/docker.service.d/
# cat>/etc/systemd/system/docker.service.d/10-docker.conf<<EOF
# [Service]
# ExecStartPost=/sbin/iptables --wait -I FORWARD -s 0.0.0.0/0 -j ACCEPT
# ExecStopPost=/bin/bash -c '/sbin/iptables --wait -D FORWARD -s 0.0.0.0/0 -j ACCEPT &> /dev/null || :'
# ExecStartPost=/sbin/iptables --wait -I INPUT -i cni0 -j ACCEPT
# ExecStopPost=/bin/bash -c '/sbin/iptables --wait -D INPUT -i cni0 -j ACCEPT &> /dev/null || :'
# EOF

  systemctl restart docker.service
  systemctl enable --now docker
}

apt_install_kubeadm_kubectl() {
  # 直接指定key的方法
  # echo 'deb https://mirrors.aliyun.com/kubernetes/apt/ kubernetes-xenial main' > /etc/apt/sources.list.d/kubernetes.list
  # gpg --keyserver keyserver.ubuntu.com --recv-keys 836F4BEB
  # gpg --export --armor 836F4BEB | sudo apt-key add -

  curl https://mirrors.aliyun.com/kubernetes/apt/doc/apt-key.gpg | apt-key add -
  cat>/etc/apt/sources.list.d/kubernetes.list<<EOF
deb https://mirrors.aliyun.com/kubernetes/apt/ kubernetes-xenial main
EOF
  apt update
  apt install -y kubelet=1.19.7-00 kubeadm=1.19.7-00 kubectl=1.19.7-00
  systemctl enable kubelet
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
  cat << EOF | tee /etc/sysctl.d/k8s.conf > /dev/null
# 需要禁止ipv6可以打开
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1
# net.ipv6.conf.lo.disable_ipv6 = 1

# 修复ipvs模式下长连接timeout问题 小于900即可
# https://github.com/moby/moby/issues/31208
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 10

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

setting_limit() {
  cat>/etc/security/limits.d/kubernetes.conf<<EOF
*       soft    nproc   131072
*       hard    nproc   131072
*       soft    nofile  131072
*       hard    nofile  131072
root    soft    nproc   131072
root    hard    nproc   131072
root    soft    nofile  131072
root    hard    nofile  131072
EOF
}

gen_kubeadm_config() {
  cat>kubeadm-initconfig.yaml<<EOF
apiVersion: kubeadm.k8s.io/v1beta2
kind: InitConfiguration
bootstrapTokens:
- groups:
  - system:bootstrappers:kubeadm:default-node-token
  token: abcdef.0123456789abcdef
  ttl: 24h0m0s
  usages:
  - signing
  - authentication
localAPIEndpoint:
  advertiseAddress: 172.29.50.31                          # 本节点宣告ip地址
  bindPort: 6443
nodeRegistration:
  criSocket: /var/run/dockershim.sock
  name: master-01
  taints:
  - effect: NoSchedule
    key: node-role.kubernetes.io/master
---
apiVersion: kubeadm.k8s.io/v1beta2
kind: ClusterConfiguration
clusterName: kubernetes
certificatesDir: /etc/kubernetes/pki
imageRepository: registry.aliyuncs.com/google_containers  # 修改国内镜像源
controlPlaneEndpoint: "172.29.50.30:6443"                 # apiserver负载均衡地址和端口
kubernetesVersion: v1.19.7                                # 选择k8s版本
networking:
  dnsDomain: cluster.local
  serviceSubnet: 10.96.0.0/12
  podSubnet: "10.44.0.0/16"                               # 修改子网地址
apiServer:
  timeoutForControlPlane: 4m0s
  extraArgs:
    authorization-mode: "Node,RBAC"
    enable-admission-plugins: "NamespaceLifecycle,LimitRanger,ServiceAccount,PersistentVolumeClaimResize,DefaultStorageClass,DefaultTolerationSeconds,NodeRestriction,MutatingAdmissionWebhook,ValidatingAdmissionWebhook,ResourceQuota,Priority,PodPreset"
    runtime-config: api/all=true
    storage-backend: etcd3
    etcd-servers: https://172.19.0.2:2379,https://172.19.0.3:2379,https://172.19.0.4:2379
controllerManager:
  extraArgs:
    bind-address: "0.0.0.0"
    experimental-cluster-signing-duration: 87600h        # 证书过期时间修改为10年
  extraVolumes:
  - hostPath: /etc/localtime
    mountPath: /etc/localtime
    name: localtime
    readOnly: true
scheduler:
  extraArgs:
    bind-address: "0.0.0.0"
  extraVolumes:
  - hostPath: /etc/localtime
    mountPath: /etc/localtime
    name: localtime
    readOnly: true
dns:
  type: CoreDNS
etcd:
  local:
    imageRepository: quay.io/coreos #如果不单独指定，默认会去找aliyun的imageRepository
    imageTag: v3.4.13
    dataDir: /var/lib/etcd
    extraArgs: # 暂时没有extraVolumes
      auto-compaction-retention: "1h"
      max-request-bytes: "33554432"
      quota-backend-bytes: "8589934592"
      enable-v2: "false"                                  # disable etcd v2 api
  # external: //外部etcd的时候这样配置 https://godoc.org/k8s.io/kubernetes/cmd/kubeadm/app/apis/kubeadm/v1beta2#Etcd
    # endpoints:
    # - "https://172.19.0.2:2379"
    # - "https://172.19.0.3:2379"
    # - "https://172.19.0.4:2379"
    # caFile: "/etc/kubernetes/pki/etcd/ca.crt"
    # certFile: "/etc/kubernetes/pki/etcd/etcd.crt"
    # keyFile: "/etc/kubernetes/pki/etcd/etcd.key"
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration # https://godoc.org/k8s.io/kube-proxy/config/v1alpha1#KubeProxyConfiguration
mode: ipvs
featureGates:
  SupportIPVSProxyMode: true                              # 开启ipvs模式
metricsBindAddress: "0.0.0.0:10249"                       # 开启默认监听metrics地址
ipvs:
  excludeCIDRs: null
  minSyncPeriod: 0s
  scheduler: "rr"                                         # 调度算法
  syncPeriod: 15s
iptables:
  masqueradeAll: true
  masqueradeBit: 14
  minSyncPeriod: 0s
  syncPeriod: 30s
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration # https://godoc.org/k8s.io/kubelet/config/v1beta1#KubeletConfiguration
cgroupDriver: systemd
failSwapOn: true # 如果开启swap则设置为false
EOF
}

#apt_install_base_util
#set_localtime

#remove_docker
#apt_install_docker
#apt_install_kubeadm_kubectl

#disable_swap
#load_module_rke_checks
#load_module_ipvs
#load_k8s_sysctl

#setting_limit

gen_kubeadm_config



