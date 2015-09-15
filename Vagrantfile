# -*- mode: ruby -*-
# vim: set ft=ruby :
require 'fileutils'

SCAP_DIR = File.expand_path('../scap', __FILE__)
FileUtils.mkdir SCAP_DIR unless File.exist?(SCAP_DIR)

Vagrant.configure(2) do |config|
  memory = 1024

  config.vm.provider 'virtualbox' do |vb, config|
    config.vm.box = 'debian/jessie64'
    vb.memory = memory
  end

  config.vm.provider 'parallels' do |prl, config|
    config.vm.box = 'parallels/debian-8.1'
    prl.memory = memory
  end

  config.vm.provision :shell, path: 'setup.sh', args: [ ENV['VAGRANT_LOG'] ].compact
  config.vm.synced_folder SCAP_DIR, '/scap'
end

