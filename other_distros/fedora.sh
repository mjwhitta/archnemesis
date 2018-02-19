#!/usr/bin/env bash

err() {
    ret="$1" && shift
    echo -e "\e[31m[-] $@\e[0m"
    exit $ret
}

info() {
    echo -e "\e[37m[+] $@\e[0m"
    sleep 1
}

install_packages() {
    # Install packages
    declare -a pkgs

    pkgs+=("aspell")
    pkgs+=("bind-utils")
    pkgs+=("bzip2")
    pkgs+=("cifs-utils")
    pkgs+=("cpio")
    pkgs+=("cronie")
    pkgs+=("ctags")
    pkgs+=("curl")
    #pkgs+=("exfat-utils")
    [[ -n $nemesis ]] || pkgs+=("gcc")
    pkgs+=("gdb")
    pkgs+=("git")
    pkgs+=("gzip")
    pkgs+=("htop")
    pkgs+=("iproute")
    pkgs+=("iptables")
    pkgs+=("java-1.8.0-openjdk-devel")
    pkgs+=("jq")
    pkgs+=("lua")
    pkgs+=("mlocate")
    pkgs+=("mutt")
    pkgs+=("ncdu")
    pkgs+=("ncurses")
    pkgs+=("ncurses-devel")
    pkgs+=("ncurses-libs")
    pkgs+=("nfs-utils")
    pkgs+=("numlockx")
    pkgs+=("openconnect")
    pkgs+=("p7zip")
    pkgs+=("par2cmdline")
    pkgs+=("python2")
    pkgs+=("python2-pip")
    pkgs+=("python3")
    pkgs+=("python3-pip")
    pkgs+=("python3-pygments")
    pkgs+=("ranger")
    pkgs+=("redhat-rpm-config")
    #pkgs+=("ripgrep")
    pkgs+=("rsync")
    pkgs+=("ruby")
    pkgs+=("ruby-devel")
    pkgs+=("ruby-irb")
    pkgs+=("tcl")
    pkgs+=("the_silver_searcher")
    pkgs+=("tmux")
    #pkgs+=("unrar")
    pkgs+=("unzip")
    [[ -n $gui ]] || pkgs+=("vim-enhanced")
    pkgs+=("weechat")
    pkgs+=("wpa_supplicant")
    pkgs+=("xz")
    pkgs+=("zsh")
    #pkgs+=("zsh-completions")
    pkgs+=("zsh-syntax-highlighting")
    if [[ -n $gui ]]; then
        pkgs+=("alsa-firmware")
        pkgs+=("alsa-tools")
        pkgs+=("alsa-utils")
        pkgs+=("chromium")
        pkgs+=("clusterssh")
        #pkgs+=("compton")
        pkgs+=("dunst")
        pkgs+=("google-noto-fonts-common")
        pkgs+=("lxdm")
        pkgs+=("mupdf")
        pkgs+=("network-manager-applet")
        pkgs+=("NetworkManager")
        pkgs+=("NetworkManager-openconnect")
        pkgs+=("NetworkManager-openvpn")
        pkgs+=("nitrogen")
        #pkgs+=("oblogout")
        pkgs+=("obconf")
        pkgs+=("obmenu")
        pkgs+=("openbox")
        #pkgs+=("pamixer")
        pkgs+=("pavucontrol")
        pkgs+=("pcmanfm")
        pkgs+=("pulseaudio")
        #pkgs+=("rofi")
        pkgs+=("terminator")
        # pkgs+=("termite")
        pkgs+=("tilda")
        pkgs+=("tint2")
        #pkgs+=("ttf-croscore")
        #pkgs+=("ttf-dejavu")
        #pkgs+=("ttf-droid")
        #pkgs+=("ttf-freefont")
        #pkgs+=("ttf-liberation")
        #pkgs+=("ttf-linux-libertine")
        #pkgs+=("ttf-ubuntu-font-family")
        pkgs+=("viewnior")
        pkgs+=("vim-X11")
        pkgs+=("wmctrl")
        pkgs+=("x11vnc")
        pkgs+=("xclip")
        pkgs+=("xdg-user-dirs")
        pkgs+=("xdotool")
        pkgs+=("xorg-x11-drv-ati")
        pkgs+=("xorg-x11-drv-intel")
        pkgs+=("xorg-x11-drv-libinput")
        pkgs+=("xorg-x11-drv-vesa")
        pkgs+=("xorg-x11-drv-synaptics-devel")
        pkgs+=("xorg-x11-server-Xorg")
        pkgs+=("xorg-x11-server-utils")
        pkgs+=("xsel")
        pkgs+=("xterm")
    fi
    if [[ -n $nemesis ]]; then
        pkgs+=("aircrack-ng")
        pkgs+=("binwalk")
        pkgs+=("cowpatty")
        pkgs+=("dnsmasq")
        pkgs+=("expect")
        #pkgs+=("fcrackzip")
        #pkgs+=("firejail")
        pkgs+=("foremost")
        pkgs+=("gcc") #pkgs+=("gcc-multilib")
        #pkgs+=("hashcat")
        #pkgs+=("hashcat-utils")
        pkgs+=("hping3")
        pkgs+=("hydra")
        pkgs+=("john")
        pkgs+=("masscan")
        #pkgs+=("metasploit")
        pkgs+=("ncrack")
        pkgs+=("net-snmp")
        pkgs+=("nikto")
        pkgs+=("nmap")
        pkgs+=("nmap-ncat")
        pkgs+=("openvas-cli")
        pkgs+=("openvas-libraries")
        pkgs+=("openvas-manager")
        pkgs+=("openvas-scanner")
        pkgs+=("ophcrack")
        pkgs+=("pyrit")
        #pkgs+=("radare2")
        pkgs+=("socat")
        #pkgs+=("sqlmap")
        pkgs+=("tcpdump")
        #pkgs+=("zaproxy")
        pkgs+=("zmap")
    fi

    yes | sudo dnf install ${pkgs[@]}
}

usage() {
    echo "Usage: ${0/*\//} [OPTIONS]"
    echo "Options:"
    echo "    -g, --gui"
    echo "        Install gui packages"
    echo "    -h, --help"
    echo "        Display this help message"
    echo "    -n, --nemesis"
    echo "        Install security-testing related packages"
    echo
    exit $1
}

declare -a args
unset gui nemesis

while [[ $# -gt 0 ]]; do
    case "$1" in
        "--") shift && args+=("$@") && break ;;
        "-g"|"--gui") gui="true" ;;
        "-h"|"--help") usage 0 ;;
        "-n"|"--nemesis") nemesis="true" ;;
        *) args+=("$1") ;;
    esac
    shift
done
[[ -z ${args[@]} ]] || set -- "${args[@]}"

[[ $# -eq 0 ]] || usage 2

info "Checking internet connection..."
tmp="$(ping -c 1 8.8.8.8 | \grep "0% packet loss")"
[[ -n $tmp ]] || err 3 "No internet"
info "Success!"

info "Installing missing packages"
install_packages
