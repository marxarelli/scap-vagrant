#!/bin/bash
#
# Sets up an environment with multiple LXC containers for testing deployment
# tooling.
#

PACKAGES=(
  bridge-utils
  git
  libvirt-bin
  lxc
  uidmap
)

SCAP_PACKAGES=(
  python3
  python3-jinja2
  python3-netifaces
  python3-psutil
  python3-requests
  python3-yaml
)

CONTAINER=scap-target-base
PASSWORD=vagrant

# Function for doing stuff to our base container
lxc() {
  local cmd=$1
  shift 1

  sudo lxc-$cmd -n $CONTAINER "$@"

  return $?
}

sudo apt-get -y update
sudo apt-get -y install "${PACKAGES[@]}" "${SCAP_PACKAGES[@]}"

# Clone scap into /scap if it's not already cloned
if ! [ -d /scap/.git ]; then
  git clone https://gerrit.wikimedia.org/r/p/mediawiki/tools/scap /scap
fi

# Create bridge interface
if ! sudo virsh net-list | grep -q default; then
  sudo virsh net-start default
  sudo virsh net-autostart default
fi

# Allow networked containers
sudo sh -c 'cat > /etc/lxc/default.conf' <<-end
	lxc.network.type = veth
	lxc.network.flags = up
	lxc.network.link = virbr0
	lxc.network.hwaddr = 00:FF:AA:00:00:xx
	lxc.network.ipv4 = 0.0.0.0/24

	lxc.mount.entry=/scap /var/lib/lxc/$CONTAINER/rootfs/scap ro bind 0 0
	end

# Restore the LXC download cache if there is one
if [ -d /vagrant/cache/lxc/download ]; then
  echo 'Using cached LXC download'
  sudo rsync -rlt /vagrant/cache/lxc/download/ /var/cache/lxc/download/
fi

# Create base LXC image
if [ -z "$(lxc-ls -1 $CONTAINER)" ]; then
  lxc create -t download -- -d debian -r jessie -a amd64

  echo 'Updating LXC download cache'
  mkdir -p /vagrant/cache/lxc/download
  sudo rsync -rlt /var/cache/lxc/download/ /vagrant/cache/lxc/download/

  sudo mkdir /var/lib/lxc/$CONTAINER/rootfs/scap

  echo 'Starting base container'
  lxc start -d
  lxc wait -s RUNNING

  echo 'Setting up base container users'
  lxc attach -- groupadd -g 1000 vagrant
  lxc attach -- useradd -u 1000 -Ng 1000 -d /home/vagrant -m -s /bin/bash vagrant

  for user in root vagrant; do echo "$user:$PASSWORD"; done | lxc attach -- chpasswd

  # Wait for the network to come up
  echo 'Waiting for base container network'
  timeout 30s bash <<-end
	while ! sudo lxc-attach -n $CONTAINER -- ifconfig eth0 | grep -q 'inet:[0-9]'; do
	  sleep 0.2
	done
	end

  echo 'Installing scap dependencies into base container'
  lxc attach -- apt-get -y update
  lxc attach -- apt-get -y --force-yes install apt-utils
  lxc attach -- apt-get -y --force-yes install openssh-server "${SCAP_PACKAGES[@]}"

  lxc stop
fi
