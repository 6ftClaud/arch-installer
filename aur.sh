#!/bin/bash
git clone https://aur.archlinux.org/pacaur.git
cd pacaur/
makepkg -si
pacaur -Syyuu sublime-text-3 sublime-merge google-chrome