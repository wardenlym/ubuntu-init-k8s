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

apt_update() {
  apt update
}

apt_install_base_util() {
  apt install -y git wget curl zsh jq ansible \
                    net-tools bridge-utils traceroute \
                    ntp ipvsadm
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

#apt_update
#apt_install_base_util
#remove_docker
#apt_install_docker
apt_install_kubeadm_kubectl
