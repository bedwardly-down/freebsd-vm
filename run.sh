#!/usr/bin/env bash

set -e

export PATH=$PATH:/Library/Frameworks/Python.framework/Versions/Current/bin

_script="$0"
_script_home="$(dirname "$_script")"


_oldPWD="$PWD"
#everytime we cd to the script home
cd "$_script_home"



#find the release number
if [ -z "$VM_RELEASE" ]; then
  if [ ! -e "conf/default.release.conf" ]; then
    echo "The VM_RELEASE is empty,  but the conf/default.release.conf is not found. something wrong."
    exit 1
  fi
  . "conf/default.release.conf"
  VM_RELEASE=$DEFAULT_RELEASE
fi

#set arbitrary guestname with Github Runner
export VM_GUESTNAME

export VM_RELEASE


#load the release conf
if [ ! -e "conf/$VM_RELEASE.conf" ]; then
  echo "Can not find release conf: conf/$VM_RELEASE.conf"
  echo "The supported release conf: "
  ls conf/*
  exit 1
fi


. conf/$VM_RELEASE.conf


#load the vm conf
_conf_filename="$(echo "$CONF_LINK" | rev  | cut -d / -f 1 | rev)"
echo "Config file: $_conf_filename"

if [ ! -e "$_conf_filename" ]; then
  wget -q "$CONF_LINK"
fi

. $_conf_filename

export VM_ISO_LINK
export VM_OS_NAME
export VM_RELEASE
export VM_INSTALL_CMD
export VM_SSHFS_PKG
export VM_LOGIN_TAG
export VM_OCR
export VM_DISK
export VM_ARCH
export VM_RSYNC

##########################################################


vmsh="$VM_VBOX"

if [ ! -e "$vmsh" ]; then
  echo "Downloading vbox ${SEC_VBOX:-$VM_VBOX_LINK} to: $PWD"
  wget -O $vmsh "${SEC_VBOX:-$VM_VBOX_LINK}"
fi



osname="$VM_OS_NAME"
ostype="$VM_OS_TYPE"
sshport=$VM_SSH_PORT

ovafile="$osname-$VM_RELEASE.qcow2.xz"

_idfile='~/.ssh/host.id_rsa'

importVM() {

  bash $vmsh setup

  if [ ! -e "$ovafile" ]; then
    echo "Downloading $OVA_LINK"
    axel -n 8 -o "$ovafile" -q "$OVA_LINK"
    echo "Download finished, extract"
    xz -d $ovafile
    echo "Extract finished"
  fi

  if [ ! -e "id_rsa.pub" ]; then
    echo "Downloading $VM_PUBID_LINK"
    wget -O "id_rsa.pub" -q "$VM_PUBID_LINK"
  fi

  if [ ! -e "host.id_rsa" ]; then
    echo "Downloading $HOST_ID_LINK"
    wget -O "host.id_rsa" -q "$HOST_ID_LINK"
  fi

  ls -lah

  bash $vmsh addSSHAuthorizedKeys id_rsa.pub
  cat host.id_rsa >$HOME/.ssh/host.id_rsa
  chmod 600 $HOME/.ssh/host.id_rsa

  bash $vmsh importVM $VM_GUESTNAME $ostype "$osname-$VM_RELEASE.qcow2"

  if [ "$DEBUG" ]; then
    bash $vmsh startWeb $VM_GUESTNAME
  fi

}



waitForVMReady() {
  bash $vmsh waitForVMReady "$VM_GUESTNAME"
}


#using the default ksh
execSSH() {
  exec ssh "$VM_GUESTNAME"
}

#using the sh 
execSSHSH() {
  exec ssh "$VM_GUESTNAME" sh
}


addNAT() {
  _prot="$1"
  _hostport="$2"
  _vmport="$3"
  _vmip=$(bash $vmsh getVMIP "$VM_GUESTNAME")
  echo "vm ip: $_vmip"
  if ! command -v socat; then
    echo "installing socat"
    if bash $vmsh isLinux; then
      sudo apt-get install -y socat
    else
      brew install socat
    fi
  fi

  if [ "$_prot" == "udp" ]; then
    sudo socat UDP4-RECVFROM:$_hostport,fork UDP4-SENDTO:$_vmip:$_vmport >/dev/null 2>&1 &
  else
    sudo socat TCP-LISTEN:$_hostport,fork TCP:$_vmip:$_vmport >/dev/null 2>&1 &
  fi

}

setMemory() {
  bash $vmsh setMemory "$VM_GUESTNAME" "$@"
}

setCPU() {
  bash $vmsh setCPU "$VM_GUESTNAME" "$@"
}

startVM() {
  bash $vmsh startVM "$VM_GUESTNAME"
}



rsyncToVM() {
  _pwd="$PWD"
  cd "$_oldPWD"
  rsync -avrtopg -e 'ssh -o MACs=umac-64-etm@openssh.com' --exclude _actions --exclude _PipelineMapping  $HOME/work/  $VM_GUESTNAME:work
  cd "$_pwd"
}


rsyncBackFromVM() {
  _pwd="$PWD"
  cd "$_oldPWD"
  rsync -vrtopg   -e 'ssh -o MACs=umac-64-etm@openssh.com' $VM_GUESTNAME:work/ $HOME/work $VM_RSYNC
  cd "$_pwd"
}


installRsyncInVM() {
  ssh "$VM_GUESTNAME" sh <<EOF
if ! command -v rsync; then
$VM_INSTALL_CMD $VM_RSYNC_PKG
fi
EOF

}

runSSHFSInVM() {

  if [ -e "hooks/onRunSSHFS.sh" ] && ssh "$VM_GUESTNAME" sh <hooks/onRunSSHFS.sh; then
    echo "OK";
  elif [ "$VM_SSHFS_PKG" ]; then
    echo "Installing $VM_SSHFS_PKG"
    ssh "$VM_GUESTNAME" sh <<EOF
if ! command -v sshfs ; then
$VM_INSTALL_CMD $VM_SSHFS_PKG
fi
EOF
    echo "Run sshfs"
    ssh "$VM_GUESTNAME" sh <<EOF

if sshfs -o reconnect,ServerAliveCountMax=2,allow_other,default_permissions host:work $HOME/work ; then
  echo "run sshfs in vm is OK, show mount:"
  /sbin/mount
  if [ "$VM_GUESTNAME" = "netbsd" ]; then
    tree $HOME/work
  fi
else
  echo "error run sshfs in vm."
  exit 1
fi

EOF

  fi


}


#run in the vm, just as soon as the vm is up
onStarted() {
  bash $vmsh addSSHHost $VM_GUESTNAME "$_idfile"
  #just touch the file, so that the user can access this file in the VM
  echo "" >>${GITHUB_ENV}
  if [ -e "hooks/onStarted.sh" ]; then
    ssh "$VM_GUESTNAME" sh <hooks/onStarted.sh
  fi
}


#run in the vm, just after the files are initialized
onInitialized() {
  if [ -e "hooks/onInitialized.sh" ]; then
    ssh "$VM_GUESTNAME" sh <hooks/onInitialized.sh
  fi
}


onBeforeStartVM() {
  #run in the host machine, the VM is imported, but not booted yet.
  if [ -e "hooks/onBeforeStartVM.sh" ]; then
    echo "Run hooks/onBeforeStartVM.sh"
    . hooks/onBeforeStartVM.sh
  else
    echo "Skip hooks/onBeforeStartVM.sh"
  fi
}


showDebugInfo() {
  echo "==================Debug Info===================="
  pwd && ls -lah && sudo ps aux
  bash -c 'pwd && ls -lah ~/.ssh/'
  if [ -e "$HOME/.ssh/config" ]; then
    cat "$HOME/.ssh/config"
  fi
  cat $_conf_filename

  echo "===================Debug Info in VM============="
  ssh "$VM_GUESTNAME" sh <<EOF
pwd
ls -lah
whoami
tree .

EOF
  echo "================================================"

}

"$@"
















