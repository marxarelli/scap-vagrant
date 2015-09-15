#!/bin/bash
#
# Sets up an environment with multiple LXC containers for testing deployment
# tooling. See the README for details.
#

set -e

[ "$1" == 'debug' ] && set -o xtrace

PACKAGES=(
  apache2
  apache2-utils
  bridge-utils
  btrfs-tools
  git
  libvirt-bin
  lxc
  uidmap
  vim
)

SCAP_PACKAGES=(
  git
  python
  python-jinja2
  python-netifaces
  python-psutil
  python-requests
  python-yaml
  sudo
)

SCAP_REPO=https://gerrit.wikimedia.org/r/p/mediawiki/tools/scap

CONTAINER_PREFIX=scap-target
BASE_CONTAINER=$CONTAINER_PREFIX-base
PASSWORD=vagrant

DEPLOY_DIR=/srv/deployment/mockbase/deploy

# Function for doing stuff to our base container
lxc() {
  local cmd=$1
  shift 1

  lxc-$cmd -n $BASE_CONTAINER "$@"

  return $?
}

lxc_wait_for_ip() {
  echo "Waiting for $1 to get an IP"
  timeout 30s bash <<-end
	while [ -z "\$(lxc-info -i -n '$1')" ]; do
	  sleep 0.2
	done
	end
}

lxc_wait_for_ssh() {
  lxc_wait_for_ip $1

  echo "Waiting for SSH on $1"
  timeout 30s bash <<-end
	while ! nc -z $1 22; do
	  sleep 0.2
	done
	end
}

# Set up apt cache and install packages
if ! [ -f /etc/apt/apt.conf.d/20shared-cache ]; then
  mkdir -p /vagrant/cache/apt
  echo 'Dir::Cache::archives "/vagrant/cache/apt";' > /etc/apt/apt.conf.d/20shared-cache
fi

apt-get -y update
apt-get -y install "${PACKAGES[@]}" "${SCAP_PACKAGES[@]}"

# Create bridge interface
if ! virsh net-list | grep -q default; then
  virsh net-start default
  virsh net-autostart default
fi

# Clone scap into /scap if it's not already cloned
if ! [ -d /scap/.git ]; then
  echo "Cloning $SCAP_REPO to /scap"
  git clone -q "$SCAP_REPO" /scap
fi

# Add scap project directory to our PATH
echo 'PATH=/vagrant/scap/bin:"$PATH"' > /etc/profile.d/scap.sh

# Create deployment environment
if ! [ -d /srv/deployment ]; then
  mkdir -p /srv/deployment
  chown vagrant:vagrant /srv/deployment
fi

# Set up Apache to host it
if ! cmp -s {/etc/apache2/sites-available,/vagrant/files/apache}/deployment.conf; then
  echo 'Setting up Apache vhost for deployment git repos'
  install -o root -m 0644 /vagrant/files/apache/deployment.conf /etc/apache2/sites-available/
  a2ensite deployment
  service apache2 reload
fi

# Prepare central mockbase repo
if ! [ -d /var/lib/git/mockbase ]; then
  echo 'Preparing central mockbase repo'
  sudo -su vagrant git config --global user.name vagrant
  sudo -su vagrant git config --global user.email vagrant@localhost

  dir="$(mktemp -d)"
  rsync --exclude=*.swp --exclude=.git --delete -qa /vagrant/files/mockbase/ "$dir/"

  pushd "$dir"
  sudo -su vagrant git init ./
  sudo -su vagrant git add --all :/
  sudo -su vagrant git commit -m 'initial commit'
  popd

  git clone -q --bare "$dir" /var/lib/git/mockbase
  pushd /var/lib/git/mockbase
  git update-server-info
  popd
  rm -rf "$dir"
fi

# Prepare deploy repo
if ! [ -d "$DEPLOY_DIR" ]; then
  echo 'Cloning git repos into the deployment directory'
  sudo -su vagrant mkdir -p "$DEPLOY_DIR"
  sudo -su vagrant rsync --exclude=*.swp --exclude=.git --delete -qr /vagrant/files/deploy/ "$DEPLOY_DIR/"
fi

if ! [ -d "$DEPLOY_DIR/.git" ]; then
  pushd "$DEPLOY_DIR"
  sudo -su vagrant git init ./
  sudo -su vagrant git add --all :/
  sudo -su vagrant git submodule -q add http://192.168.122.1/git/mockbase
  sudo -su vagrant git commit -m 'initial commit'
  popd
fi

# Create an SSH key for the vagrant user (authorized on each container later)
if ! [ -f /home/vagrant/.ssh/id_rsa ]; then
  sudo -u vagrant ssh-keygen -t rsa -f /home/vagrant/.ssh/id_rsa -N ''
fi

# Allow networked containers
cat > /etc/lxc/default.conf <<-end
	lxc.network.type = veth
	lxc.network.flags = up
	lxc.network.link = virbr0
	lxc.network.hwaddr = 00:FF:AA:00:00:xx
	lxc.network.ipv4 = 0.0.0.0/24
	end

# Move /var/lib/lxc to a btrfs mount so we can do snapshots
if [ -z "$(awk '/^[^#]/ && $2 == "/var/lib/lxc" { print $2 }' /etc/fstab)" ]; then
  truncate -s 3G /var/local/lxc.img
  dev=$(losetup --show -f /var/local/lxc.img)
  mkfs.btrfs $dev
  sync
  losetup -d $dev
  echo '/var/local/lxc.img /var/lib/lxc btrfs loop 0 0' >> /etc/fstab
fi

# Make sure /var/lib/lxc is mounted
if ! mountpoint -q /var/lib/lxc; then
  mount /var/lib/lxc
fi

# Restore the LXC download cache if there is one
if [ -d /vagrant/cache/lxc/download ]; then
  rsync -qrlt /vagrant/cache/lxc/download/ /var/cache/lxc/download/
fi

# Set up base LXC container that we'll use as a template for clones
if [ -z "$(lxc-ls -1 $BASE_CONTAINER)" ]; then
  lxc create -t download -B btrfs -- -d debian -r jessie -a amd64

  echo 'Updating LXC download cache'
  mkdir -p /vagrant/cache/lxc/download
  rsync -qrlt /var/cache/lxc/download/ /vagrant/cache/lxc/download/

  mkdir -p /var/lib/lxc/$BASE_CONTAINER/rootfs/srv/deployment/scap/scap

  echo 'Setting up mockbase in base container'
  mkdir -p /var/lib/lxc/$BASE_CONTAINER/rootfs/$DEPLOY_DIR
  chown vagrant:vagrant /var/lib/lxc/$BASE_CONTAINER/rootfs/$DEPLOY_DIR
  mkdir -p /var/lib/lxc/$BASE_CONTAINER/rootfs/etc/mockbase
  cp /vagrant/files/mockbase/mockbase.service /var/lib/lxc/$BASE_CONTAINER/rootfs/etc/mockbase/
  cat > /var/lib/lxc/$BASE_CONTAINER/rootfs/etc/mockbase/config-vars.yaml <<-end
	---
	foo: bar
	end

  echo 'Starting base container'
  lxc start -d
  lxc wait -s RUNNING

  # Wait for the network to come up
  lxc_wait_for_ip $BASE_CONTAINER

  echo 'Installing scap dependencies into base container'
  lxc attach -- apt-get -y update
  lxc attach -- apt-get -y --force-yes install apt-utils
  lxc attach -- apt-get -y --force-yes install openssh-server "${SCAP_PACKAGES[@]}"

  echo 'Setting up base container users'
  lxc attach -- groupadd -g 1000 vagrant
  lxc attach -- useradd -u 1000 -Ng 1000 -d /home/vagrant -m -s /bin/bash vagrant
  for user in root vagrant; do echo "$user:$PASSWORD"; done | lxc attach -- chpasswd
  lxc attach -- sudo -su vagrant mkdir -m 0700 /home/vagrant/.ssh
  cat /home/vagrant/.ssh/id_rsa.pub \
    | lxc attach -- sudo -u vagrant sh -c 'cat > /home/vagrant/.ssh/authorized_keys'
  lxc attach -- sudo -su vagrant chmod 0600 /home/vagrant/.ssh/authorized_keys

  echo 'Enabling mockbase systemd service in base container'
  lxc attach -q -- systemctl -q enable /etc/mockbase/mockbase.service

  echo 'Authorizing sudo for vagrant on base container'
  cat /vagrant/files/sudoers | lxc attach -- sh -c 'cat > /etc/sudoers.d/mockbase'

  echo 'Stopping base container'
  lxc stop
fi

# Clone base container and add clones to the mockbase target group
if [ -z "$(lxc-ls $CONTAINER_PREFIX-[0-9])" ]; then
  mkdir -p /etc/dsh/group
  truncate -s 0 /etc/dsh/group/mockbase

  for i in {1..10}; do
    clone=$CONTAINER_PREFIX-$(printf '%02d' $i)

    lxc-clone -s $BASE_CONTAINER $clone

    cat >> /var/lib/lxc/$clone/config <<-end
	lxc.start.auto = 1
	lxc.group = onboot
	lxc.mount.entry=/scap /var/lib/lxc/$clone/rootfs/srv/deployment/scap/scap ro bind 0 0
	end

    # Add clone to mockbase target group
    echo $clone >> /etc/dsh/group/mockbase
  done
fi

# Start any stopped clone containers
stopped=($(lxc-ls --stopped $CONTAINER_PREFIX-[0-9]))

for container in "${stopped[@]}"; do
  echo "Starting container $container"
  lxc-start -n $container -d
done

# Wait until SSH is up on each container then authorize its host key
for container in "${stopped[@]}"; do
  lxc_wait_for_ssh $container

  echo "Authorizing host key for $container"
  if [ -f /etc/ssh/ssh_known_hosts ]; then
    ssh-keygen -R $container -f /etc/ssh/ssh_known_hosts 2> /dev/null
    # Fix permissions after running ssh-keygen
    chmod 0644 /etc/ssh/ssh_known_hosts
  fi

  ssh-keyscan -H -t ecdsa $container >> /etc/ssh/ssh_known_hosts 2> /dev/null
done

# Configure host DNS to resolve from dnsmasq first
if ! cmp -s {/vagrant/files/dhcp,/etc/dhcp/dhclient-enter-hooks.d}/prefer-local-nameserver; then
  echo 'Configuring host DNS to resolve local container names'
  install -o root -m 0755 /vagrant/files/dhcp/prefer-local-nameserver /etc/dhcp/dhclient-enter-hooks.d/
  service networking reload
fi
