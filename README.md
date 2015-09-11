# scap-vagrant

A quick and dirty Vagrant based environment for testing [scap][], a MediaWiki
deployment tool.

## Requirements

- [VirtualBox](https://www.virtualbox.org/)
- [Vagrant](https://www.vagrantup.com/)

## Setup

    $ vagrant up

And relax. No, really, *relax*. This will take a while depending on your
connection.

## What that does

  1. Creates a Debian jessie VirtualBox VM
  2. Clones scap into `./scap` and mounts it at `/scap` in the VM
  3. Installs scap dependencies
  4. Initializes a test deploy repo with scap configuration at
     `/srv/deployment/mockbase/deploy`
  5. Uses LXC to create 10 cloned system containers within the VM to act as
     deployment targets
  6. Each container:
     1. Is networked via a bridge interface on the VM and accessible over SSH
        at an IP address in the range `192.168.122.0/24`
     2. Bind mounts `/scap` as read-only for access to local deployment scripts
     3. Contains a `mockbase` service script listening on `127.0.0.1:1134` that can be
        used to test service restarts and post-deploy checks
  7. Exposes `/srv/deployment/mockbase/deploy/mockbase` as an HTTP git repo
     accessible at `192.168.122.1` from containers
  8. Writes a list of container host names to `/etc/dsh/group/mockbase`

## How to deploy

    $ vagrant ssh
    vagrant@vm $ cd /srv/deployment/mockbase/deploy
    vagrant@vm $ deploy

[scap]: https://www.mediawiki.org/wiki/Deployment_tooling/Notes/What_does_scap_do
