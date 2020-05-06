#!/usr/bin/env sh

# Write the docker-compose alias to ~/.bash_alias
ALIAS=$'alias docker-compose=\'docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$PWD:$PWD" \
    -w="$PWD" \
    docker/compose\''
echo -e "$ALIAS" >> ~/.bash_alias

# Include ~/.bash_alias in ~/.bashrc
ALIAS_INCLUDE='if [[ -f ~/.bash_alias ]] ; then \n    . ~/.bash_alias \nfi'
echo -e "$ALIAS_INCLUDE" >> ~/.bashrc

. ~/.bashrc
