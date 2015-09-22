#!/usr/bin/env bash
# Helpful shell aliases and functions to make deployment easier

export LS_OPTIONS='--color=auto'
alias ll="ls $LS_OPTIONS -l"
alias l="ls $LS_OPTIONS -lA"

# update the suders file on all running targets
update-sudoers() {
    sudo -v

    for container in $(sudo lxc-ls -1 --running); do
        sudo cat /vagrant/files/sudoers | \
            sudo lxc-attach -n "$container" -- sh -c 'cat > /etc/sudoers.d/mockbase'
    done
}

# Run a command on all running targets
targets() {
    sudo -v

    local cmd="$@"

    for container in $(sudo lxc-ls -1 --running); do
        printf "\n${container}:\n"
        sudo lxc-attach -n "$container" -- sh -c "$cmd"
    done
}
