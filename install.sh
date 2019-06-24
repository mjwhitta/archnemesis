#!/usr/bin/env bash

### Helpers begin
check_deps() {
    local missing
    for d in "${deps[@]}"; do
        if [[ -z $(command -v "$d") ]]; then
            # Force absolute path
            if [[ ! -f "/$d" ]]; then
                err "$d was not found"
                missing="true"
            fi
        fi
    done; unset d
    [[ -z $missing ]] || exit 128
}
err() { echo -e "${color:+\e[31m}[!] $*\e[0m"; }
errx() { err "${*:2}"; exit "$1"; }
good() { echo -e "${color:+\e[32m}[+] $*\e[0m"; }
info() { echo -e "${color:+\e[37m}[*] $*\e[0m"; }
long_opt() {
    local arg shift="0"
    case "$1" in
        "--"*"="*) arg="${1#*=}"; [[ -n $arg ]] || usage 127 ;;
        *) shift="1"; shift; [[ $# -gt 0 ]] || usage 127; arg="$1" ;;
    esac
    echo "$arg"
    return $shift
}
subinfo() { echo -e "${color:+\e[36m}[=] $*\e[0m"; }
warn() { echo -e "${color:+\e[33m}[-] $*\e[0m"; }
### Helpers end

## Installer functions

array() { json_get "$1[]"; }

boolean() {
    local var="$1"

    # If it doesn't start with a "." then it should be a "var"
    [[ -n $(echo "$1" | grep -Ps "^\.") ]] || var=".vars.$1"

    # I can only anticipate so much here
    case "$(json_get "$var")" in
        "enable"|"Enable"|"ENABLE") echo "true" ;;
        "on"|"On"|"ON") echo "true" ;;
        "true"|"True"|"TRUE") echo "true" ;;
        "y"|"Y"|"yes"|"Yes"|"YES") echo "true" ;;
    esac
}

# Exit if bad return status
check_if_fail() {
    [[ $1 -eq 0 ]] || errx "$1" "Something went wrong"
}

# Get value from json and replace placeholders with variable values
json_get() {
    while read -r line; do
        [[ $line != "null" ]] || continue

        while read -r replace; do
            local new="${replace#\{\{\{}"
            new="${new%\}\}\}}"
            new="$(var "$new")"
            line="${line//$replace/$new}"
        done < <(echo "$line" | grep -oPs "\{\{\{[^}]+\}\}\}")
        unset replace

        echo "$line"
    done < <(jq -cMrS "$1" 2>/dev/null "$config"); unset line
}

# Get a list of keys for a hash
hash_keys() { json_get "$1|keys[]"; }

# Run the command in the chroot
run_in_chroot() {
    cat >/mnt/chroot_cmd <<EOF
#!/usr/bin/env bash
$@
exit \$?
EOF
    check_if_fail $?

    chmod 700 /mnt/chroot_cmd
    check_if_fail $?

    arch-chroot /mnt /chroot_cmd
    check_if_fail $?

    rm -f /mnt/chroot_cmd
    check_if_fail $?
}

# Get one of the variables
var() { json_get ".vars.$1"; }

## Configuration functions

add_users_to_groups() {
    # Loop thru users and add to specified group
    local entry groups username
    while read -r entry; do
        groups="${entry#*:}"
        username="${entry%%:*}"
        run_in_chroot "usermod -aG \"$groups\" $username"
    done < <(array ".users.groups"); unset entry
}

configure_enable_networking() {
    # Configure dhcp
    array ".network.dhcp_network" \
        >/mnt/etc/systemd/network/dhcp.network
    check_if_fail $?

    # Symlink /etc/resolv.conf
    ln -sf ../run/systemd/resolve/resolv.conf /mnt/etc/
    check_if_fail $?

    # Enable services
    run_in_chroot "systemctl enable systemd-networkd.service"
    run_in_chroot "systemctl enable systemd-resolved.service"
}

create_users() {
    # Loop thru users and create them
    local configs creds crypt password username
    while read -r creds; do
        password="${creds#*:}"
        username="${creds%%:*}"
        crypt="$(perl -e "print crypt(\"$password\", \"$RANDOM\")")"
        run_in_chroot "useradd -mp \"$crypt\" -U $username"

        # Autostart tint2 for openbox sessions
        if [[ -n $(boolean "gui") ]]; then
            case "$(var "session")" in
                "openbox")
                    configs="/mnt/home/$username/.config"
                    mkdir -p "$configs/openbox"
                    echo "tint2 &" >"$configs/openbox/autostart"
                    run_in_chroot \
                        "chown -R $username:$username ${configs#/mnt}"
                    ;;
            esac
        fi
    done < <(array ".users.create"); unset creds
}

customize() {
    echo "Recommended actions include:"
    echo "    - Create new users"
    echo "    - Set user passwords (if authorized_keys not provided)"
    echo "    - Change the preferred shell (maybe to zsh)"
    echo "    - Install additional packages"
    echo "    - Modify config files"

    local ans
    while :; do
        read -p "Drop into a shell? (y/N) " -r ans
        case "$ans" in
            "y"|"Y"|"yes"|"Yes") arch-chroot /mnt; break ;;
            ""|"n"|"N"|"no"|"No") break ;;
        esac
    done
}

enable_multilib() {
    # Return if already uncommented
    [[ -n $(grep -Ps "#\[multilib\]" "$1") ]] || return

    # Uncomment out the multilib line
    local inc="/etc/pacman.d/mirrorlist"
    sed -i -r \
        -e "s/^#(\[multilib\]).*/\\1/" \
        -e "/^\[multilib\]/!b;n;cInclude = $inc" "$1"
    check_if_fail $?

    # Update pacman database
    case "$action" in
        "install") run_in_chroot "pacman -Syy" ;;
        "postinstall") sudo pacman -Syy ;;
    esac
}

install_configure_enable_iptables() {
    # Install iptables
    run_in_chroot "pacman --needed --noconfirm -S iptables"

    # Create rules files
    local fw
    for fw in iptables ip6tables; do
        array ".iptables.${fw}_rules" >/mnt/etc/iptables/${fw}.rules
        check_if_fail $?
    done; unset fw

    # Fix permissions
    chmod 644 /mnt/etc/iptables/{iptables,ip6tables}.rules
    check_if_fail $?

    # Enable services
    if [[ -n $(boolean ".iptables.enable") ]]; then
        run_in_chroot "systemctl enable {iptables,ip6tables}.service"
    fi
}

install_configure_enable_lxdm() {
    # Install LXDM
    run_in_chroot "pacman --needed --noconfirm -S lxdm"

    # Update lxdm.conf
    local key val
    while read -r key; do
        val="$(json_get ".lxdm.lxdm_conf.$key")"
        [[ -n $val ]] || continue
        sed -i -r "s|^#? ?($key)=.*|\\1=$val|" /mnt/etc/lxdm/lxdm.conf
        check_if_fail $?
    done < <(hash_keys ".lxdm.lxdm_conf"); unset key

    # Enable service
    if [[ -n $(boolean ".lxdm.enable") ]]; then
        run_in_chroot "systemctl enable lxdm.service"
    fi
}

install_configure_enable_networkmanager() {
    # Install NetworkManager
    local -a pkgs=(
        "network-manager-applet"
        "networkmanager"
        "networkmanager-openconnect"
        "networkmanager-openvpn"
    )
    run_in_chroot "pacman --needed --noconfirm -S ${pkgs[*]}"

    # Enable service
    run_in_chroot "systemctl enable NetworkManager.service"
}

install_configure_enable_ssh() {
    # Install SSH
    run_in_chroot "pacman --needed --noconfirm -S openssh"

    # Update sshd_config
    local key val
    while read -r key; do
        val="$(json_get ".ssh.sshd_config.$key")"
        [[ -n $val ]] || continue
        sed -i -r "s|^#?($key) .*|\\1 $val|" /mnt/etc/ssh/sshd_config
        check_if_fail $?
    done < <(hash_keys ".ssh.sshd_config"); unset key

    # Enable service
    if [[ -n $(boolean ".ssh.enable") ]]; then
        run_in_chroot "systemctl enable sshd.service"
    fi

    # Configure initial ~/.ssh/authorized_keys
    local homedir
    while read -r key; do
        case "$key" in
            "root") homedir="/mnt/root" ;;
            *) homedir="/mnt/home/$key" ;;
        esac

        mkdir -p "$homedir/.ssh"
        check_if_fail $?

        array ".ssh.authorized_keys.$key" \
            >"$homedir/.ssh/authorized_keys"
        check_if_fail $?

        chmod -R go-rwx "$homedir/.ssh"
        check_if_fail $?

        run_in_chroot "chown -R $key:$key \"${homedir#/mnt}/.ssh\""
        check_if_fail $?
    done < <(hash_keys ".ssh.authorized_keys"); unset key

    # Configure initial ~/.ssh/config
    local hostname="$(var "hostname")"
    while read -r key; do
        case "$key" in
            "root") homedir="/mnt/root" ;;
            *) homedir="/mnt/home/$key" ;;
        esac

        mkdir -p "$homedir/.ssh"
        check_if_fail $?

        ssh-keygen -f "$homedir/.ssh/$hostname" -N "" -q -t ed25519
        check_if_fail $?

        array ".ssh.config.$key" >"$homedir/.ssh/config"
        check_if_fail $?

        chmod -R go-rwx "$homedir/.ssh"
        check_if_fail $?

        run_in_chroot "chown -R $key:$key \"${homedir#/mnt}/.ssh\""
        check_if_fail $?
    done < <(hash_keys ".ssh.config"); unset key
}

install_configure_enable_grub() {
    # Install grub
    run_in_chroot "pacman --needed --noconfirm -S grub"

    # Update /etc/default/grub
    local key val
    while read -r key; do
        val="$(json_get ".grub.grub.$key")"
        [[ -n $val ]] || continue
        sed -i -r "s|^($key)\\=[0-9]+|\\1=$val|" /mnt/etc/default/grub
        check_if_fail $?
    done < <(hash_keys ".grub.grub"); unset key

    # Install bootloader
    case "$boot_mode" in
        "BIOS") run_in_chroot "grub-install --target=i386-pc $1" ;;
        "UEFI")
            run_in_chroot "pacman --needed --noconfirm -S efibootmgr"
            local -a cmd=(
                "grub-install --target=x86_64-efi"
                "--efi-directory=/boot --bootloader-id=grub"
            )
            run_in_chroot "${cmd[@]}"
            ;;
    esac

    # Configure grub
    run_in_chroot "grub-mkconfig -o /boot/grub/grub.cfg"
}

install_packages() {
    # Install packages with pacman
    local pkg
    local -a pkgs
    while read -r pkg; do
        case "$pkg" in
            "gcc")
                [[ -n $(boolean "nemesis_tools") ]] || pkgs+=("$pkg")
                ;;
            "vim") [[ -n $(boolean "gui") ]] || pkgs+=("$pkg") ;;
            *) pkgs+=("$pkg") ;;
        esac
    done < <(array ".packages.default"); unset pkg

    if [[ -n $(boolean "gui") ]]; then
        while read -r pkg; do
            pkgs+=("$pkg")
        done < <(array ".packages.gui"); unset pkg
    fi

    if [[ -n $(boolean "nemesis_tools") ]]; then
        while read -r pkg; do
            pkgs+=("$pkg")
        done < <(array ".packages.nemesis_tools"); unset pkg
    fi

    case "$action" in
        "install")
            if [[ ${#pkgs[@]} -gt 0 ]]; then
                run_in_chroot \
                    "pacman --needed --noconfirm -S ${pkgs[*]}"
            fi
            ;;
        "postinstall")
            if [[ ${#pkgs[@]} -gt 0 ]]; then
                sudo pacman --needed --noconfirm -S "${pkgs[@]}"
            fi
            ;;
    esac

    # Install RuAUR ruby gem
    local -a env=(
        "GEM_HOME=/root/.gem/ruby"
        "GEM_PATH=/root/.gem/ruby/gems"
    )
    local gem="gem install --no-format-executable --no-user-install"
    case "$action" in
        "install")
            run_in_chroot "pacman --needed --noconfirm -S ruby"
            run_in_chroot "mkdir -p /root/.gem/ruby/gems"
            local null=">/dev/null 2>&1"
            run_in_chroot "${env[*]} $gem rdoc $null || echo -n"
            run_in_chroot "${env[*]} $gem rdoc ruaur"
            ;;
        "postinstall")
            export GEM_HOME="$HOME/.gem/ruby"
            export GEM_PATH="$HOME/.gem/ruby/gems"

            mkdir -p "$HOME/.gem/ruby/gems"
            sudo pacman --needed --noconfirm -S ruby
            check_if_fail $?

            $gem rdoc >/dev/null 2>&1
            $gem rdoc ruaur
            check_if_fail $?
            ;;
    esac

    # Reset
    unset pkgs

    # Install AUR packages with RuAUR
    while read -r pkg; do
        pkgs+=("$pkg")
    done < <(array ".packages.aur.default"); unset pkg

    if [[ -n $(boolean "gui") ]]; then
        while read -r pkg; do
            pkgs+=("$pkg")
        done < <(array ".packages.aur.gui"); unset pkg
    fi

    if [[ -n $(boolean "nemesis_tools") ]]; then
        while read -r pkg; do
            pkgs+=("$pkg")
        done < <(array ".packages.aur.nemesis_tools"); unset pkg
    fi

    case "$action" in
        "install")
            local ruaur="/root/.gem/ruby/bin/ruaur --noconfirm"
            if [[ ${#pkgs[@]} -gt 0 ]]; then
                run_in_chroot "${env[*]} $ruaur -S ${pkgs[*]}"
            fi
            ;;
        "postinstall")
            local ruaur="$HOME/.gem/ruby/bin/ruaur --noconfirm"
            if [[ ${#pkgs[@]} -gt 0 ]]; then
                $ruaur -S "${pkgs[@]}"
            fi
            check_if_fail $?
            ;;
    esac
}

partition_and_format_disk_bios() {
    # Wipe all signatures
    local part
    while read -r part; do
        wipefs --all --force "$part"
        check_if_fail $?
    done < <(lsblk -lp "$1" | awk '!/NAME/ {print $1}' | sort -r)
    unset part

    # Single bootable partition (ext4)
    case "$1" in
        "/dev/nvme"*)
            sed -e "s/\s*\([\+0-9a-zA-Z]*\).*/\1/" <<EOF | fdisk "$1"
                g  # clear the in memory partition table
                n  # new partition
                1  # partition 1
                   # default - start at beginning of disk
                   # default - extend partition to end of disk
                p  # print the in-memory partition table
                w  # write the partition table and exit
EOF
            check_if_fail $?

            mkfs.ext4 "${1}p1"
            check_if_fail $?
            ;;
        *)
            sed -e "s/\s*\([\+0-9a-zA-Z]*\).*/\1/" <<EOF | fdisk "$1"
                o  # clear the in memory partition table
                n  # new partition
                p  # primary partition
                1  # partition 1
                   # default - start at beginning of disk
                   # default - extend partition to end of disk
                a  # make a partition bootable
                p  # print the in-memory partition table
                w  # write the partition table and exit
EOF
            check_if_fail $?

            mkfs.ext4 "${1}1"
            check_if_fail $?
            ;;
    esac
}

partition_and_format_disk_uefi() {
    # Wipe all signatures
    local part
    while read -r part; do
        wipefs --all --force "$part"
        check_if_fail $?
    done < <(lsblk -lp "$1" | awk '!/NAME/ {print $1}' | sort -r)
    unset part

    # A small, bootable partition (EFI) and a larger partition (ext4)
    case "$1" in
        "/dev/nvme"*)
            sed -e "s/\s*\([\+0-9a-zA-Z]*\).*/\1/" <<EOF | fdisk "$1"
                g     # clear the in memory partition table
                n     # new partition
                1     # partition 1
                      # default - start at beginning of disk
                +256M # 256M UEFI partition
                t     # change partition type
                1     # EFI system
                n     # new partition
                2     # partition 2
                      # default - start after UEFI partition
                      # default - extend partition to end of disk
                p     # print the in-memory partition table
                w     # write the partition table and exit
EOF
            check_if_fail $?

            mkfs.fat "${1}p1"
            check_if_fail $?

            mkfs.ext4 "${1}p2"
            check_if_fail $?
            ;;
        *)
            sed -e "s/\s*\([\+0-9a-zA-Z]*\).*/\1/" <<EOF | fdisk "$1"
                o     # clear the in memory partition table
                n     # new partition
                p     # primary partition
                1     # partition 1
                      # default - start at beginning of disk
                +256M # 256M UEFI partition
                t     # change partition type
                ef    # EFI system
                n     # new partition
                p     # primary partition
                2     # partition 2
                      # default - start after UEFI partition
                      # default - extend partition to end of disk
                a     # make a partition bootable
                1     # partition 1
                p     # print the in-memory partition table
                w     # write the partition table and exit
EOF
            check_if_fail $?

            mkfs.ext4 "${1}1"
            check_if_fail $?

            mkfs.ext4 "${1}2"
            check_if_fail $?
            ;;
    esac
}

select_locale() {
    local locale="$(var "locale")"

    # Uncomment preferred locale
    sed -i -r "s/^#$locale/$locale/" /mnt/etc/locale.gen
    check_if_fail $?

    # Configure locale
    run_in_chroot "locale-gen"
    echo "LANG=$locale.UTF-8" >/mnt/etc/locale.conf
    check_if_fail $?
}

select_mirrors() {
    # Get preferred mirrors
    grep -A 1 "$(var "mirrors")" /etc/pacman.d/mirrorlist | \
        grep -v "\-\-" >/etc/pacman.d/mirrorlist.keep
    check_if_fail $?

    # Replace mirrors with preferred mirrors
    mv -f /etc/pacman.d/mirrorlist.keep /etc/pacman.d/mirrorlist
    check_if_fail $?
}

usage() {
    cat <<EOF
Usage: ${0##*/} [OPTIONS] [dev]

If no config is specified, it will print out the default config. If a
config is specified, it will install ArchNemesis with the options
specified in the config. Setting "nemesis_tools" to "false" or empty
means you only want to install Arch Linux (and OpenBox if "gui" is
true).

Options:
    -c, --config=CONFIG    Use specified json config
    -h, --help             Display this help message
    --no-color             Disable colorized output
    -p, --post-install     Only install missing packages

EOF
    exit "$1"
}

declare -a args deps
unset config dev help postinstall
action="print"
color="true"
deps+=("perl")

# Check for missing dependencies
check_deps

# Parse command line options
while [[ $# -gt 0 ]]; do
    case "$1" in
        "--") shift && args+=("$@") && break ;;
        "-c"|"--config"*)
            config="$(long_opt "$@")" || shift
            [[ $action == "postinstall" ]] || action="install"
            ;;
        "-h"|"--help") help="true" ;;
        "--no-color") unset color ;;
        "-p"|"--post-install") action="postinstall" ;;
        *) args+=("$1") ;;
    esac
    shift
done
[[ ${#args[@]} -eq 0 ]] || set -- "${args[@]}"

# Check for valid params
[[ -z $help ]] || usage 0
case "$action" in
    "install")
        [[ $# -le 1 ]] || usage 1
        [[ -n $config ]] || usage 2
        [[ $# -eq 0 ]] || dev="$1"
        if [[ -z $dev ]]; then
            declare -a devs
            while read -r dev; do
                devs+=("$dev")
            done < <(lsblk -lp | awk '!/NAME/ {print $1}'); unset dev
            while :; do
                clear && lsblk -lp && echo
                read -p "Please enter target device: " -r dev
                [[ -n $dev ]] || continue
                valid="$(echo " ${devs[*]} " | grep -Ps "\s$dev\s")"
                [[ -z $valid ]] || break
            done
        fi
        ;;
    "postinstall")
        [[ $# -eq 0 ]] || usage 1
        [[ -n $config ]] || usage 2
        ;;
    "print") [[ $# -eq 0 ]] || usage 1 ;;
esac

# Default json
cat >/tmp/archnemesis.json <<EOF
{
  "vars": {
    "gui": "true",
    "hostname": "nemesis",
    "loadkeys": "us",
    "locale": "en_US",
    "mirrors": "United States",
    "nemesis_tools": "true",
    "primary_user": "nemesis",
    "session": "openbox",
    "ssh_port": "22",
    "timezone": "America/Indiana/Indianapolis"
  },
  "grub": {
    "grub": {"GRUB_TIMEOUT": "1"}
  },
  "iptables": {
    "enable": "true",
    "iptables_rules": [
      "*filter",
      ":INPUT DROP [0:0]",
      ":FORWARD DROP [0:0]",
      ":OUTPUT ACCEPT [0:0]",
      ":TCP - [0:0]",
      ":UDP - [0:0]",
      "# Allow established",
      "-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT",
      "# Allow loopback",
      "-A INPUT -i lo -j ACCEPT",
      "# Drop invalid",
      "-A INPUT -m conntrack --ctstate INVALID -j DROP",
      "# Allow ping",
      "-A INPUT -p icmp -m icmp --icmp-type 8 -m conntrack --ctstate NEW -j ACCEPT",
      "# Jump to TCP table for new tcp",
      "-A INPUT -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -m conntrack --ctstate NEW -j TCP",
      "# Otherwise reject tcp",
      "-A INPUT -p tcp -j REJECT --reject-with tcp-reset",
      "# Jump to UDP table for new udp",
      "-A INPUT -p udp -m conntrack --ctstate NEW -j UDP",
      "# Otherwise reject udp",
      "-A INPUT -p udp -j REJECT --reject-with icmp-port-unreachable",
      "# Reject everything else",
      "-A INPUT -j REJECT --reject-with icmp-proto-unreachable",
      "# Allow SSH with brute-force protection",
      "-A TCP -p tcp -m multiport --dports {{{ssh_port}}} -m limit --limit 16/min --limit-burst 32 -j ACCEPT",
      "COMMIT",
      "*nat",
      ":PREROUTING ACCEPT [0:0]",
      ":INPUT ACCEPT [0:0]",
      ":OUTPUT ACCEPT [0:0]",
      ":POSTROUTING ACCEPT [0:0]",
      "COMMIT",
      "*raw",
      ":PREROUTING ACCEPT [0:0]",
      ":OUTPUT ACCEPT [19:2500]",
      "-A PREROUTING -m rpfilter -j ACCEPT",
      "-A PREROUTING -j DROP",
      "COMMIT"
    ],
    "ip6tables_rules": [
      "*filter",
      ":INPUT DROP [0:0]",
      ":FORWARD DROP [0:0]",
      ":OUTPUT ACCEPT [0:0]",
      ":TCP - [0:0]",
      ":UDP - [0:0]",
      "# Allow established",
      "-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT",
      "# Allow loopback",
      "-A INPUT -i lo -j ACCEPT",
      "# Drop invalid",
      "-A INPUT -m conntrack --ctstate INVALID -j DROP",
      "# Allow ping",
      "-A INPUT -p ipv6-icmp -m icmp6 --icmpv6-type 128 -m conntrack --ctstate NEW -j ACCEPT",
      "# Allow IPv6 ICMP for router advertisements (add needed subnets)",
      "-A INPUT -s fe80::/10 -p ipv6-icmp -j ACCEPT",
      "# Jump to TCP table for new tcp",
      "-A INPUT -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -m conntrack --ctstate NEW -j TCP",
      "# Otherwise reject tcp",
      "-A INPUT -p tcp -j REJECT --reject-with tcp-reset",
      "# Jump to UDP table for new udp",
      "-A INPUT -p udp -m conntrack --ctstate NEW -j UDP",
      "# Otherwise reject udp",
      "-A INPUT -p udp -j REJECT --reject-with icmp6-port-unreachable",
      "# Reject everything else",
      "-A INPUT -j REJECT --reject-with icmp6-port-unreachable",
      "# Allow DHCPv6 (add needed subnets)",
      "-A UDP -s fe80::/10 -p udp -m udp --dport 546 -m state --state NEW -j ACCEPT",
      "COMMIT",
      "*raw",
      ":PREROUTING ACCEPT [0:0]",
      ":OUTPUT ACCEPT [0:0]",
      "-A PREROUTING -m rpfilter -j ACCEPT",
      "-A PREROUTING -j DROP",
      "COMMIT"
    ]
  },
  "lxdm": {
    "enable": "{{{gui}}}",
    "lxdm_conf": {
      "autologin": "{{{primary_user}}}",
      "numlock": "1",
      "session": "/usr/bin/{{{session}}}-session",
      "theme": "IndustrialArch"
    }
  },
  "network": {
    "dhcp_network": [
      "[Match]",
      "Name=enp*",
      "",
      "[Network]",
      "DHCP=ipv4"
    ]
  },
  "packages": {
    "aur": {
      "default": [
        "urlview",
        "zsh-history-substring-search"
      ],
      "gui": [
        "lxdm-themes",
        "obmenu-generator",
        "pa-applet-git"
      ],
      "ignore": [
        "burpsuite",
        "nessus",
        "samdump2",
        "xprobe2"
      ],
      "nemesis_tools": [
        "amap-bin",
        "dirb",
        "dirbuster",
        "httprint",
        "isic",
        "maltego",
        "rockyou",
        "vncrack"
      ]
    },
    "default": [
      "aspell",
      "bind-tools",
      "bzip2",
      "cifs-utils",
      "cpio",
      "cronie",
      "ctags",
      "curl",
      "exfat-utils",
      "gcc",
      "gdb",
      "git",
      "git-crypt",
      "go",
      "gzip",
      "htop",
      "iproute2",
      "jdk-openjdk",
      "jq",
      "lua",
      "mlocate",
      "moreutils",
      "mutt",
      "ncdu",
      "ncurses",
      "nfs-utils",
      "numlockx",
      "openconnect",
      "p7zip",
      "par2cmdline",
      "parallel",
      "perl-file-mimeinfo",
      "putty",
      "pygmentize",
      "python",
      "python-pip",
      "python2",
      "python2-pip",
      "ranger",
      "ripgrep",
      "rsync",
      "ruby",
      "socat",
      "tcl",
      "the_silver_searcher",
      "tmux",
      "unrar",
      "unzip",
      "vim",
      "weechat",
      "wget",
      "wpa_supplicant",
      "xz",
      "zip",
      "zsh",
      "zsh-completions",
      "zsh-syntax-highlighting"
    ],
    "gui": [
      "alsa-firmware",
      "alsa-tools",
      "alsa-utils",
      "blueman",
      "chromium",
      "clusterssh",
      "compton",
      "dunst",
      "flameshot",
      "gtk2-perl",
      "gvim",
      "mupdf",
      "nitrogen",
      "noto-fonts",
      "oblogout",
      "openbox",
      "pamixer",
      "pavucontrol",
      "pcmanfm",
      "pulseaudio",
      "pulseaudio-bluetooth",
      "rofi",
      "tilda",
      "tilix",
      "tint2",
      "ttf-dejavu",
      "viewnior",
      "wmctrl",
      "x11-ssh-askpass",
      "x11vnc",
      "xclip",
      "xdg-user-dirs",
      "xdotool",
      "xf86-input-keyboard",
      "xf86-input-mouse",
      "xf86-input-synaptics",
      "xf86-video-ati",
      "xf86-video-intel",
      "xf86-video-vesa",
      "xorg-server",
      "xorg-xinput",
      "xorg-xkill",
      "xorg-xmodmap",
      "xorg-xrandr",
      "xorg-xrdb",
      "xscreensaver",
      "xsel",
      "xterm"
    ],
    "nemesis_tools": [
      "aircrack-ng",
      "binwalk",
      "clamav",
      "cowpatty",
      "dnsmasq",
      "expect",
      "fcrackzip",
      "firejail",
      "foremost",
      "gcc-multilib",
      "gnu-netcat",
      "hashcat",
      "hashcat-utils",
      "hping",
      "hydra",
      "impacket",
      "john",
      "masscan",
      "metasploit",
      "ncrack",
      "net-snmp",
      "nikto",
      "nmap",
      "openvas-libraries",
      "openvas-manager",
      "openvas-scanner",
      "ophcrack",
      "pyrit",
      "radare2",
      "sqlmap",
      "tcpdump",
      "wireshark-qt",
      "zaproxy",
      "zmap"
    ]
  },
  "ssh": {
    "authorized_keys": {
      "nemesis": [],
      "root": []
    },
    "config": {
      "nemesis": [
        "# No agent or X11 forwarding",
        "Host *",
        "    ForwardAgent no",
        "    ForwardX11 no",
        "    HashKnownHosts yes",
        "    IdentityFile ~/.ssh/{{{hostname}}}",
        "    LogLevel Error"
      ],
      "root": []
    },
    "enable": "true",
    "sshd_config": {
      "PasswordAuthentication": "yes",
      "PermitRootLogin": "without-password",
      "Port": "{{{ssh_port}}}",
      "PrintLastLog": "no",
      "PrintMotd": "no",
      "UseDNS": "no",
      "X11Forwarding": "no"
    }
  },
  "users": {
    "create": [
      "nemesis:nemesis"
    ],
    "groups": [
      "nemesis:users,wireshark"
    ]
  }
}
EOF

# Main

case "$action" in
    *"install")
        info "Checking internet connection..."
        tmp="$(ping -c 1 8.8.8.8 | grep -s "0% packet loss")"
        [[ -n $tmp ]] || errx 3 "No internet"
        info "Success"

        if [[ -z $(command -v jq) ]]; then
            depsurl="https://deps.archnemesis.ninja"
            curl -kLO "$depsurl/jq-1.6-2-x86_64.pkg.tar.xz"
            curl -kLO "$depsurl/oniguruma-6.9.2-1-x86_64.pkg.tar.xz"
            sudo pacman --needed --noconfirm -U -- *.pkg.tar.xz
            check_if_fail $?
        fi

        info "Validating json config..."
        jq -cMrS "." >/dev/null "$config"
        check_if_fail $?
        info "Success"
        ;;
esac

case "$action" in
    "install")
        mounted="$(mount | grep -oPs "${dev}[0-9p]*")"
        [[ -z $mounted ]] || umount -R /mnt
        mounted="$(mount | grep -oPs "${dev}[0-9p]*")"
        [[ -z $mounted ]] || errx 4 "Device already mounted"

        boot_mode="BIOS"
        [[ ! -d /sys/firmware/efi/efivars ]] || boot_mode="UEFI"

        info "Selecting keyboard layout"
        loadkeys="$(var "loadkeys")"
        loadkeys "$loadkeys"
        check_if_fail $?

        info "Updating system clock"
        timedatectl set-ntp true
        check_if_fail $?

        case "$boot_mode" in
            "BIOS")
                info "Partitioning and formatting disk"
                partition_and_format_disk_bios "$dev"

                info "Mounting file system"
                case "$dev" in
                    "/dev/nvme"*) mount "${dev}p1" /mnt ;;
                    *) mount "${dev}1" /mnt ;;
                esac
                check_if_fail $?
                ;;
            "UEFI")
                info "Partitioning and formatting disk"
                partition_and_format_disk_uefi "$dev"

                info "Mounting file systems"
                case "$dev" in
                    "/dev/nvme"*)
                        mount "${dev}p2" /mnt
                        mkdir -p /mnt/boot
                        mount "${dev}p1" /mnt/boot
                        ;;
                    *)
                        mount "${dev}2" /mnt
                        mkdir -p /mnt/boot
                        mount "${dev}1" /mnt/boot
                        ;;
                esac
                check_if_fail $?
                ;;
        esac

        info "Selecting mirrors"
        select_mirrors

        info "Installing base packages"
        pacstrap /mnt base base-devel
        check_if_fail $?

        info "Configuring the system"

        info "Generating fstab"
        genfstab -U /mnt >>/mnt/etc/fstab
        check_if_fail $?

        info "chroot tasks"

        info "Selecting the time zone"
        tz="$(var "timezone")"
        run_in_chroot "ln -sf /usr/share/zoneinfo/$tz /etc/localtime"
        run_in_chroot "hwclock --systohc"

        info "Selecting locale"
        select_locale

        info "Saving the keyboard layout"
        echo "KEYMAP=$loadkeys" >/mnt/etc/vconsole.conf
        check_if_fail $?

        info "Saving hostname"
        var "hostname" >/mnt/etc/hostname
        check_if_fail $?

        if [[ -n $(var "nemesis_tools") ]]; then
            info "Enabling multilib in pacman.conf"
            enable_multilib /mnt/etc/pacman.conf
        fi

        info "Installing and configuring GRUB"
        install_configure_enable_grub "$dev"

        info "Configuring and enabling networking"
        configure_enable_networking

        info "Installing/Configuring/Enabling iptables"
        install_configure_enable_iptables

        info "Creating users"
        create_users

        info "Installing/Configuring/Enabling SSH"
        install_configure_enable_ssh

        if [[ -n $(var "gui") ]]; then
            info "Installing/Configuring/Enabling NetworkManager"
            install_configure_enable_networkmanager

            info "Installing/Configuring/Enabling LXDM"
            install_configure_enable_lxdm
        fi

        info "Installing user requested packages"
        install_packages

        info "Adding users to requested groups"
        add_users_to_groups

        info "User customizations"
        customize

        info "Unmounting"
        umount -R /mnt
        check_if_fail $?

        info "You can now reboot (remove installation media)"
        ;;
    "postinstall")
        if [[ -n $(var "nemesis_tools") ]]; then
            info "Enabling multilib in pacman.conf"
            enable_multilib /etc/pacman.conf
        fi

        info "Installing missing packages"
        install_packages
        ;;
    "print") cat /tmp/archnemesis.json ;;
esac
