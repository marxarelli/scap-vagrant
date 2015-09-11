#!/bin/bash
#
# Sets up an environment with multiple LXC containers for testing deployment
# tooling. See the README for details.
#

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
)

SCAP_PACKAGES=(
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
	while [ -z "$(lxc-info -i -n "$1")" ]; do
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

apt-get -y update
apt-get -y install "${PACKAGES[@]}" "${SCAP_PACKAGES[@]}"

# Clone scap into /scap if it's not already cloned
if ! [ -d /scap/.git ]; then
  echo "Cloning $SCAP_REPO to /scap"
  git clone -q "$SCAP_REPO" /scap
fi

# Add scap project directory to our PATH
echo 'PATH=/vagrant/scap/bin:"$PATH"' > /etc/profile.d/scap.sh

# Prepare mockbase and deploy/mockbase git repos. XXX what a mess
if ! [ -d /var/lib/git/mockbase.git ]; then
  echo 'Preparing mockbase and deploy/mockbase git repos'
  sudo -su vagrant git config --global user.name vagrant
  sudo -su vagrant git config --global user.email vagrant@localhost

  mkdir -p /srv/deployment
  chown vagrant:vagrant /srv/deployment

  sudo -su vagrant mkdir -p $DEPLOY_DIR
  rsync --exclude=*.swp --exclude=.git --delete -qa /vagrant/deploy/ $DEPLOY_DIR/

  pushd $DEPLOY_DIR/mockbase
  sudo -su vagrant git init ./
  sudo -su vagrant git add --all :/ && git commit -m "commit at $(date)"
  mockbase_commit=$(git rev-parse HEAD)
  popd

  git clone -q --bare $DEPLOY_DIR/mockbase /var/lib/git/mockbase.git

  pushd $DEPLOY_DIR
  rm -rf mockbase
  sudo -su vagrant git init ./
  sudo -su vagrant git add --all :/
  sudo -su vagrant git commit -m "commit at $(date)"
  popd

  git clone -q --bare $DEPLOY_DIR /var/lib/git/mockbase-deploy.git

  rm -rf $DEPLOY_DIR
  sudo -su vagrant git clone -q /var/lib/git/mockbase-deploy.git $DEPLOY_DIR
  pushd $DEPLOY_DIR
  sudo -su vagrant git submodule -q add ../mockbase.git
  sudo -su vagrant git commit -m "submodule commit at $(date)"
  popd
fi

# Create an SSH key for the vagrant user (authorized on each container later)
if ! [ -f /home/vagrant/.ssh/id_rsa ]; then
  sudo -u vagrant ssh-keygen -t rsa -f /home/vagrant/.ssh/id_rsa -N ''
fi

# Create bridge interface
if ! virsh net-list | grep -q default; then
  virsh net-start default
  virsh net-autostart default
fi

# Allow networked containers
cat > /etc/lxc/default.conf <<-end
	lxc.network.type = veth
	lxc.network.flags = up
	lxc.network.link = virbr0
	lxc.network.hwaddr = 00:FF:AA:00:00:xx
	lxc.network.ipv4 = 0.0.0.0/24
	end

# Configure host DNS to resolve from dnsmasq first
sed -i '1i nameserver 192.168.122.1' /etc/resolv.conf

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
  cp /vagrant/deploy/mockbase/mockbase.service /var/lib/lxc/$BASE_CONTAINER/rootfs/etc/mockbase/
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

# Start any stopped slave containers
lxc-ls --stopped $CONTAINER_PREFIX-[0-9] | while read container; do
  echo "Starting container $container"
  lxc-start -n $container -d
done

# Wait until SSH is up on each container then authorize its host key
lxc-ls $CONTAINER_PREFIX-[0-9] | while read container; do
  lxc_wait_for_ssh $container

  echo "Authorizing host key for $container"
  if [ -f /etc/ssh/ssh_known_hosts ]; then
    ssh-keygen -R $container -f /etc/ssh/ssh_known_hosts 2> /dev/null
    # Fix permissions after running ssh-keygen
    chmod 0644 /etc/ssh/ssh_known_hosts
  fi

  ssh-keyscan -H -t ecdsa $container >> /etc/ssh/ssh_known_hosts 2> /dev/null
done
