# -*- mode: ruby -*-
# vim: set ft=ruby :
require 'fileutils'

SCAP_DIR = File.expand_path('../scap', __FILE__)
FileUtils.mkdir SCAP_DIR unless File.exist?(SCAP_DIR)

Vagrant.configure(2) do |config|
  config.vm.box = 'debian/jessie64'

  config.vm.provider 'virtualbox'
  config.vm.provision :shell, path: 'setup.sh', args: [ ENV['VAGRANT_LOG'] ].compact
  config.vm.synced_folder SCAP_DIR, '/scap'
end

