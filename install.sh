#!/usr/bin/env bash

### Helpers begin
check_deps() {
    local missing
    for d in "${deps[@]}"; do
        if [[ -z $(command -v "$d") ]]; then
            # Force absolute path
            if [[ ! -e "/$d" ]]; then
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
        "--"*"="*) arg="${1#*=}"; [[ -n $arg ]] || return 127 ;;
        *) shift="1"; shift; [[ $# -gt 0 ]] || return 127; arg="$1" ;;
    esac
    echo "$arg"
    return $shift
}
subinfo() { echo -e "${color:+\e[36m}[=] $*\e[0m"; }
warn() { echo -e "${color:+\e[33m}[-] $*\e[0m"; }
### Helpers end

## Installer functions

# Return an array line by line
array() { json_get "$1[]"; }

# Return true or empty string
boolean() {
    local var

    # If it doesn't start with a "." then it should be a "var"
    case "$1" in
        "."*) var="$1" ;;
        *) var=".vars.$1" ;;
    esac

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

# Run dconf commands as the specified user
dconf_as() {
    local -a env
    local run="/run/user/\$(id -u $1)"

    env+=("DBUS_SESSION_BUS_ADDRESS=unix:path=$run/bus")
    case "$1" in
        "root") env+=("HOME=/root") ;;
        *) env+=("HOME=/home/$1") ;;
    esac
    env+=("USER=$1")
    env+=("XDG_RUNTIME_DIR=$run")

    run_in_chroot "mkdir -p $run"
    run_in_chroot "chown -R $1:$1 $run"
    run_in_chroot "chmod -R go-rwx $run"
    run_in_chroot "${env[*]} dbus-launch $2" "$1"
}

# Get value from json and replace placeholders with variable values
json_get() {
    local new

    while read -r line; do
        [[ $line != "null" ]] || continue

        while read -r replace; do
            new="${replace#\{\{\{}"
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
$1
exit \$?
EOF
    check_if_fail $?

    chmod 777 /mnt/chroot_cmd
    check_if_fail $?

    arch-chroot ${2:+-u $2} /mnt /chroot_cmd
    check_if_fail $?

    rm -f /mnt/chroot_cmd
    check_if_fail $?
}

# Get one of the variables
var() { json_get ".vars.$1"; }

## Configuration functions

beginners_guide() {
    local loadkeys tz

    info "Selecting keyboard layout"
    loadkeys="$(var "loadkeys")"
    loadkeys "$loadkeys"
    check_if_fail $?

    info "Updating system clock"
    timedatectl set-ntp true
    check_if_fail $?

    case "$boot_mode" in
        "BIOS") partition_and_format_disk_bios "$dev" ;;
        "UEFI") partition_and_format_disk_uefi "$dev" ;;
    esac

    info "Mounting file systems"
    case "$boot_mode" in
        "BIOS")
            case "$dev" in
                "/dev/nvme"*)
                    subinfo "Mounting ${dev}p1 as /"
                    mount "${dev}p1" /mnt
                    ;;
                *)
                    subinfo "Mounting ${dev}1 as /"
                    mount "${dev}1" /mnt
                    ;;
            esac
            check_if_fail $?
            ;;
        "UEFI")
            case "$dev" in
                "/dev/nvme"*)
                    subinfo "Mounting ${dev}p2 as /"
                    mount "${dev}p2" /mnt

                    subinfo "Mounting ${dev}p1 as /boot"
                    mkdir -p /mnt/boot
                    mount "${dev}p1" /mnt/boot
                    ;;
                *)
                    subinfo "Mounting ${dev}2 as /"
                    mount "${dev}2" /mnt

                    subinfo "Mounting ${dev}1 as /boot"
                    mkdir -p /mnt/boot
                    mount "${dev}1" /mnt/boot
                    ;;
            esac
            check_if_fail $?
            ;;
    esac

    info "Configuring mirrors"
    select_mirrors
    check_if_fail $?

    info "Installing base packages and kernel"
    pacstrap /mnt base base-devel linux linux-firmware
    check_if_fail $?

    info "Configuring the system"

    info "Generating fstab"
    genfstab -U /mnt >>/mnt/etc/fstab
    check_if_fail $?

    info "Selecting the time zone"
    tz="$(var "timezone")"
    run_in_chroot "ln -fs /usr/share/zoneinfo/$tz /etc/localtime"
    run_in_chroot "hwclock --systohc"

    select_locale

    info "Saving the keyboard layout"
    echo "KEYMAP=$loadkeys" >/mnt/etc/vconsole.conf
    check_if_fail $?

    info "Saving hostname"
    var "hostname" >/mnt/etc/hostname
    check_if_fail $?

    configure_enable_networking
    install_configure_enable_grub "$dev"
}

configure_archnemesis() {
    local bin gl idx name ucfg uhome

    info "Finalizing ArchNemesis"

    # ArTTY
    gl="https://gitlab.com"
    bin="$(
        curl -s "$gl/api/v4/projects/3236088/releases" | \
        jq -cMrS ".[0].description" | \
        grep -ioPs "linux.+upx.+\Kuploads.+arTTY"
    )"
    curl -kLo /mnt/usr/local/bin/arTTY -s "$gl/mjwhitta/artty/$bin"
    chmod 755 /mnt/usr/local/bin/arTTY

    # Install htop
    subinfo "Installing htop"
    run_in_chroot "pacman --needed --noconfirm -S htop"

    if [[ -n $(boolean "gui") ]]; then
        # Install rofi and tilix
        subinfo "Installing rofi and tilix"
        run_in_chroot "pacman --needed --noconfirm -S rofi tilix"

        # Setup alfred script
        cp -f /tmp/scripts/bin/alfred /mnt/usr/local/bin/
        chmod 755 /mnt/usr/local/bin/alfred

        # Setup snapwin script
        cp -f /tmp/scripts/bin/snapwin /mnt/usr/local/bin/
        chmod 755 /mnt/usr/local/bin/snapwin

        # Setup default terminal emulator
        subinfo "Creating symlink to tilix"
        run_in_chroot "ln -fs /usr/bin/tilix /usr/local/bin/term"

        # Wallpapers
        subinfo "Installing Linux wallpapers"
        rm -fr /mnt/usr/share/lnxpcs /mnt/usr/share/lnxpcs-master
        tar -C /mnt/usr/share -f /tmp/lnxpcs-master.tar.gz -xz \
            lnxpcs-master/wallpapers
        check_if_fail $?

        mv -f /mnt/usr/share/lnxpcs-master /mnt/usr/share/lnxpcs
        check_if_fail $?
    fi

    # Loop thru users and setup configs
    for idx in $(seq 1 "$(json_get ".users|length")"); do
        ((idx -= 1)) # 0-indexed

        name="$(json_get ".users[$idx].name")"
        [[ -n $name ]] || continue

        case "$name" in
            "root") uhome="/mnt/root" ;;
            *) uhome="/mnt/home/$name" ;;
        esac
        ucfg="$uhome/.config"

        # arTTY
        run_in_chroot "/usr/local/bin/arTTY -u" "$name"
        run_in_chroot "/usr/local/bin/arTTY --save linux-arch" "$name"

        # bash/zsh
        cat >"$uhome/.bashrc" <<EOF
# If not running interactively, don't do anything
[[ \$- == *i* ]] || return

# Find dirs that should be in PATH
unset PTH
for dir in \
    "\$HOME/bin" \
    "\$HOME/.local/bin" \
    /usr/local/bin \
    /usr/local/sbin \
    /usr/bin \
    /usr/sbin \
    /bin \
    /sbin \
    /usr/bin/core_perl \
    /usr/bin/vendor_perl
do
    [[ ! -d \$dir ]] || PTH="\${PTH:+\$PTH:}\$dir"
done; unset dir

# Find missing from PATH
while read -r dir; do
    [[ ! -d \$dir ]] || PTH="\${PTH:+\$PTH:}\$dir"
done < <(echo "\${PATH//:/\\n}" | grep -Psv "\${PTH//:/|}")
unset dir

# Set PATH
[[ -z \$PTH ]] || export PATH="\$PTH"
unset PTH

# Aliases
alias cp="\\cp -i"
alias f="sudo"
alias la="ls -A"
alias ll="ls -hl"
alias lla="ll -A"
alias ls="\\ls --color=auto -F"
alias mine="sudo chown -R \\\$(id -nu):\\\$(id -gn)"
alias mv="\\mv -i"
alias q="exit"
alias sume="sudo -Es"
alias which="command -v"

# Functions
function simplehttp() {
    case "\$1" in
        "busybox")
            if [[ -n \$(command -v busybox) ]]; then
                busybox httpd -f -p "\${2:-8080}"
            else
                echo "busybox is not installed"
            fi
            ;;
        "perl")
            if [[ -n \$(command -v plackup) ]]; then
                plackup -MPlack::App::Directory \
                    -e 'Plack::App::Directory->new(root=>".");' \
                    -p "\${2:-8080}"
            else
                echo "Please run: cpan Plack"
            fi
            ;;
        "php")
            if [[ -n \$(command -v php) ]]; then
                php -S 0.0.0.0:"\${2:-8080}"
            else
                echo "php is not installed"
            fi
            ;;
        "python2")
            if [[ -n \$(command -v python2) ]]; then
                python2 -m SimpleHTTPServer "\${2:-8080}"
            else
                echo "python2 is not installed"
            fi
            ;;
        "python3")
            if [[ -n \$(command -v python3) ]]; then
                python3 -m http.server "\${2:-8080}"
            else
                echo "python3 is not installed"
            fi
            ;;
        "ruby")
            if [[ -n \$(command -v ruby) ]]; then
                ruby -e httpd -r un -- -p "\${2:-8080}" .
            else
                echo "ruby is not installed"
            fi
            ;;
        "twisted")
            if [[ -n \$(command -v twistd) ]]; then
                twistd -n web --listen tcp:"\${2:-8080}" --path .
            else
                echo "Please run: python3 -m pip install twisted"
            fi
            ;;
        *)
            echo "Usage: simplehttp <lang> [port]"
            echo
            echo "DESCRIPTION"
            echo -n "    Start an HTTP server using the specified "
            echo "language and port (default: 8080)."
            echo
            echo "OPTIONS"
            echo "    -h, --help    Display this help message"
            echo
            echo "LANGUAGES"
            [[ -z \$(command -v busybox) ]] || echo "    busybox"
            [[ -z \$(command -v perl) ]] || echo "    perl"
            [[ -z \$(command -v php) ]] || echo "    php"
            [[ -z \$(command -v python2) ]] || echo "    python2"
            [[ -z \$(command -v python3) ]] || echo "    python3"
            [[ -z \$(command -v ruby) ]] || echo "    ruby"
            [[ -z \$(command -v python3) ]] || echo "    twisted"
            ;;
    esac
}

# Prompt
case "\$SHELL\$BASH" in
    *"bash") export PS1="[\u@\h \W]\$ " ;;
    *"zsh") export PS1="[%n@%m %~]%# " ;;
esac

[[ -z \$(command -v arTTY) ]] || arTTY
EOF
        ln -fs .bashrc "$uhome/.zshrc"

        cat >"$uhome/.bash_profile" <<EOF
# If not running interactively, don't do anything
[[ \$- == *i* ]] || return

[[ -z \$BASH ]] || [[ ! -f \$HOME/.bashrc ]] || . "\$HOME/.bashrc"
EOF
        ln -fs .bash_profile "$uhome/.zprofile"

        # htop
        subinfo "Configuring htop for $name"
        mkdir -p "$ucfg/htop"
        cp -f /tmp/configs/htop/htoprc "$ucfg/htop/"

        # snapwin
        subinfo "Configuring snapwin for $name"
        mkdir -p "$ucfg/snapwin"
        cat >"$ucfg/snapwin/rc" <<EOF
{
  "frame": 20,
  "offset": 30,
  "padding": 15
}
EOF

        # top
        subinfo "Configuring top for $name"
        cp -f /tmp/configs/top/toprc "$uhome/.toprc"

        if [[ -n $(boolean "gui") ]]; then
            # LXQT
            case "$(var "session")" in
                "lxqt")
                    subinfo "Configuring lxqt for $name"
                    mkdir -p "$ucfg/lxqt"
                    cp -f /tmp/configs/lxqt/*.conf "$ucfg/lxqt/"
                    ;;
            esac

            # openbox
            subinfo "Configuring openbox for $name"
            mkdir -p "$ucfg/openbox"
            cp -f /tmp/configs/lxqt/lxqt-rc.xml "$ucfg/openbox/rc.xml"

            # pcmanfm-qt
            subinfo "Configuring pcmanfm-qt for $name"
            mkdir -p "$ucfg"
            cp -r /tmp/configs/pcmanfm-qt "$ucfg/"
            ln -fs default "$ucfg/pcmanfm-qt/lxqt"

            # rofi
            subinfo "Configuring rofi for $name"
            mkdir -p "$ucfg/rofi"
            cp -f /tmp/configs/rofi/config "$ucfg/rofi/"
            cp -f /tmp/configs/rofi/glue_pro_blue.rasi \
                "$ucfg/rofi/theme.rasi"

            # tilix
            subinfo "Configuring tilix for $name"
            run_in_chroot "chown -R $name:$name ${ucfg#/mnt}"
            cp -f /tmp/configs/tilix/milesrc.conf /mnt/var/tmp/an.conf
            dconf_as "$name" \
                "dconf load /com/gexperts/Tilix/ </var/tmp/an.conf"
            rm -f /mnt/var/tmp/an.conf

            # xpofile
            subinfo "Configuring xprofile for $name"
            cp -f /tmp/configs/lxqt/xprofile "$uhome/.xprofile"

            # xscreensaver
            subinfo "Configuring xscreensaver for $name"
            cp -f /tmp/configs/x11/xscreensaver "$uhome/.xscreensaver"
        fi
    done; unset idx

    fix_permissions
}

configure_enable_networking() {
    info "Configuring and enabling networking"

    # Configure dhcp
    array ".network.dhcp_network" \
        >/mnt/etc/systemd/network/dhcp.network
    check_if_fail $?

    # Symlink /etc/resolv.conf
    ln -fs ../run/systemd/resolve/resolv.conf /mnt/etc/
    check_if_fail $?

    # Enable services
    run_in_chroot "systemctl enable systemd-networkd"
    run_in_chroot "systemctl enable systemd-resolved"
}

create_and_configure_users() {
    local crypt group groups idx name password uhome

    info "Creating and configuring users"

    # Loop thru users and create them
    for idx in $(seq 1 "$(json_get ".users|length")"); do
        ((idx -= 1)) # 0-indexed

        groups="$(json_get ".users[$idx].groups")"
        name="$(json_get ".users[$idx].name")"
        password="$(json_get ".users[$idx].password")"
        shell="$(json_get ".users[$idx].shell")"

        [[ -n $name ]] || continue

        # Create user
        crypt="$(perl -e "print crypt(\"$password\", \"$RANDOM\")")"
        case "$name" in
            "root")
                uhome="/mnt/root"
                if [[ -n $password ]]; then
                    subinfo "Updating root password"
                    run_in_chroot "usermod -p \"$crypt\" $name"
                fi
                ;;
            *)
                uhome="/mnt/home/$name"
                if [[ -n $password ]]; then
                    subinfo "Creating new user: $name"
                    run_in_chroot "useradd -mp \"$crypt\" -U $name"
                fi
                ;;
        esac

        # Add user to groups
        if [[ -n $groups ]]; then
            while read -r group; do
                subinfo "Creating new group: $group"
                run_in_chroot "groupadd -f $group"
            done < <(echo -e "${groups//,/\\n}"); unset group

            subinfo "Adding $name to groups: $groups"
            run_in_chroot "usermod -aG \"$groups\" $name"
        fi

        # Configure shell
        if [[ -n $shell ]]; then
            run_in_chroot "usermod -s $shell $name"
        fi

        # Configure initial ~/.ssh
        subinfo "Configuring ssh for $name"
        mkdir -p "$uhome/.ssh"
        check_if_fail $?

        # authorized_keys
        array ".users[$idx].authorized_keys" \
            >"$uhome/.ssh/authorized_keys"
        check_if_fail $?

        # config
        array ".users[$idx].ssh_config" >"$uhome/.ssh/config"
        check_if_fail $?

        # SSH key
        hostname="$(var "hostname")"
        ssh-keygen -C "$hostname" -f "$uhome/.ssh/$hostname" -N "" \
            -q -t ed25519
        check_if_fail $?
    done; unset idx

    fix_permissions
}

customize() {
    local ans

    info "User customizations"

    while :; do
        read -p "Open shell for final customizations? (y/N) " -r ans
        case "$ans" in
            "y"|"Y"|"yes"|"Yes") arch-chroot /mnt; break ;;
            ""|"n"|"N"|"no"|"No") break ;;
        esac
    done
}

enable_multilib() {
    local inc

    info "Enabling multilib in pacman.conf"

    # Return if already uncommented
    [[ -n $(grep -Ps "#\[multilib\]" "$1") ]] || return

    # Uncomment out the multilib line
    inc="/etc/pacman.d/mirrorlist"
    sed -i -r \
        -e "s/^#(\[multilib\]).*/\\1/" \
        -e "/^\[multilib\]/!b;n;cInclude = $inc" "$1"
    check_if_fail $?

    # Update pacman database
    subinfo "Refreshing pacman db"
    case "$action" in
        "install") run_in_chroot "pacman -Syy" ;;
        "postinstall") sudo pacman -Syy ;;
    esac
}

enable_services() {
    local service

    info "Enabling services"

    # Loop thru services
    while read -r service; do
        subinfo "Enabling $service"
        run_in_chroot "systemctl enable $service"
    done < <(array ".services"); unset service
}

enable_sudo_for_wheel() {
    info "Enabling sudo for wheel group"
    sed -i -r "s/^# (%wheel ALL\=\(ALL\) ALL)/\1/g" /mnt/etc/sudoers
}

fetch_tarballs() {
    local gitlab="https://gitlab.com/mjwhitta"
    local tar

    info "Fetching ArchNemesis deps"

    cd /tmp

    # Configs
    subinfo "Fetching configs tarball"
    rm -fr configs-master
    tar="configs/-/archive/master/configs-master.tar.gz"
    curl -kLO "$gitlab/$tar"
    check_if_fail $?

    tar -xzf configs-master.tar.gz
    check_if_fail $?
    mv configs-master configs

    # Scripts
    subinfo "Fetching scripts tarball"
    rm -fr scripts-master
    tar="scripts/-/archive/master/scripts-master.tar.gz"
    curl -kLO "$gitlab/$tar"
    check_if_fail $?

    tar -xzf scripts-master.tar.gz
    check_if_fail $?
    mv scripts-master scripts

    # Wallpapers
    subinfo "Fetching wallpapers tarball"
    tar="lnxpcs/-/archive/master/lnxpcs-master.tar.gz"
    curl -kLO "$gitlab/$tar"
    check_if_fail $?

    cd
}

fix_permissions() {
    local idx uhome name

    info "Fixing home directory permissions"

    # Loop thru users and fix permissions
    for idx in $(seq 1 "$(json_get ".users|length")"); do
        ((idx -= 1)) # 0-indexed

        name="$(json_get ".users[$idx].name")"
        [[ -n $name ]] || continue

        subinfo "Fixing permissions for $name"

        case "$name" in
            "root") uhome="/mnt/root" ;;
            *) uhome="/mnt/home/$name" ;;
        esac

        chmod -R go-rwx "$uhome"
        check_if_fail $?
        run_in_chroot "chown -R $name:$name \"${uhome#/mnt}\""
        check_if_fail $?
    done; unset idx
}

install_configure_enable_iptables() {
    local fw

    # Install iptables
    info "Installing iptables"
    run_in_chroot "pacman --needed --noconfirm -S iptables"

    # Create rules files
    subinfo "Configuring iptables"
    for fw in iptables ip6tables; do
        array ".iptables.${fw}_rules" >/mnt/etc/iptables/${fw}.rules
        check_if_fail $?
    done; unset fw

    # Fix permissions
    chmod 644 /mnt/etc/iptables/{iptables,ip6tables}.rules
    check_if_fail $?

    # Enable services
    if [[ -n $(boolean ".iptables.enable") ]]; then
        subinfo "Enabling iptables"
        run_in_chroot "systemctl enable {ip6tables,iptables}"
    fi
}

install_configure_enable_lxdm() {
    local key val

    if [[ -n $(boolean ".lxdm.enable") ]]; then
        # Install LXDM
        info "Installing LXDM"
        run_in_chroot "pacman --needed --noconfirm -S lxdm"

        # Update lxdm.conf
        subinfo "Configuring LXDM"
        while read -r key; do
            val="$(json_get ".lxdm.lxdm_conf.$key")"
            [[ -n $val ]] || continue
            sed -i -r "s|^#? ?($key)=.*|\\1=$val|" \
                /mnt/etc/lxdm/lxdm.conf
            check_if_fail $?
        done < <(hash_keys ".lxdm.lxdm_conf"); unset key

        # Enable service
        subinfo "Enabling LXDM"
        run_in_chroot "systemctl enable lxdm"
    fi
}

install_configure_enable_sddm() {
    if [[ -n $(boolean ".sddm.enable") ]]; then
        # Install SDDM
        info "Installing SDDM"
        run_in_chroot "pacman --needed --noconfirm -S sddm"

        # Configure SDDM
        subinfo "Configuring SDDM"
        mkdir -p /mnt/etc/sddm.conf.d
        array ".sddm.sddm_conf" >/mnt/etc/sddm.conf.d/default.conf

        # Enable service
        subinfo "Enabling SDDM"
        run_in_chroot "systemctl enable sddm"
    fi
}

install_configure_enable_ssh() {
    local hostname key val

    # Install SSH
    info "Installing openssh"
    run_in_chroot "pacman --needed --noconfirm -S openssh"

    # Update sshd_config
    subinfo "Configuring sshd"
    while read -r key; do
        val="$(json_get ".ssh.sshd_config.$key")"
        [[ -n $val ]] || continue
        sed -i -r "s|^#?($key) .*|\\1 $val|" /mnt/etc/ssh/sshd_config
        check_if_fail $?
    done < <(hash_keys ".ssh.sshd_config"); unset key

    # Enable service
    if [[ -n $(boolean ".ssh.enable") ]]; then
        subinfo "Enabling sshd"
        run_in_chroot "systemctl enable sshd"
    fi
}

install_configure_enable_grub() {
    local -a cmd
    local key val

    # Install grub
    info "Installing grub"
    run_in_chroot "pacman --needed --noconfirm -S grub"

    # Update /etc/default/grub
    subinfo "Updating /etc/default/grub"
    while read -r key; do
        val="$(json_get ".grub.grub.$key")"
        [[ -n $val ]] || continue
        sed -i -r "s|^($key)\\=.*|\\1=$val|" /mnt/etc/default/grub
        check_if_fail $?
    done < <(hash_keys ".grub.grub"); unset key

    # Install bootloader
    case "$boot_mode" in
        "BIOS")
            subinfo "Installing bootloader for $boot_mode"
            run_in_chroot "grub-install --target=i386-pc $1"
            ;;
        "UEFI")
            info "Installing efibootmgr"
            run_in_chroot "pacman --needed --noconfirm -S efibootmgr"

            subinfo "Installing bootloader for $boot_mode"
            cmd=(
                "grub-install"
                "--efi-directory=/boot"
                "--removable"
                "--target=x86_64-efi"
            )
            run_in_chroot "${cmd[*]}"
            ;;
    esac

    # Configure grub
    subinfo "Generating GRUB config"
    run_in_chroot "grub-mkconfig -o /boot/grub/grub.cfg"
}

install_enable_networkmanager() {
    local -a pkgs

    # Install NetworkManager
    info "Installing NetworkManager"
    pkgs=(
        "network-manager-applet"
        "networkmanager"
        "networkmanager-openconnect"
        "networkmanager-openvpn"
    )
    run_in_chroot "pacman --needed --noconfirm -S ${pkgs[*]}"

    # Enable service
    subinfo "Enabling NetworkManager"
    run_in_chroot "systemctl enable NetworkManager"
}

install_packages() {
    local gem pkg ruaur
    local -a env pkgs

    info "Installing user requested packages"

    # Install packages with pacman
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
                sudo pacman --needed --noconfirm -S "${pkgs[*]}"
            fi
            ;;
    esac

    # Install RuAUR ruby gem
    env=(
        "GEM_HOME=/root/.gem/ruby"
        "GEM_PATH=/root/.gem/ruby/gems"
    )
    gem="gem install --no-format-executable --no-user-install"
    case "$action" in
        "install")
            subinfo "Installing ruby"
            run_in_chroot "pacman --needed --noconfirm -S ruby"

            subinfo "Installing RuAUR ruby gem for AUR pkgs"
            run_in_chroot "mkdir -p /root/.gem/ruby/gems"
            run_in_chroot \
                "${env[*]} $gem rdoc >/dev/null 2>&1 || echo -n"
            run_in_chroot "${env[*]} $gem rdoc ruaur"
            ;;
        "postinstall")
            export GEM_HOME="$HOME/.gem/ruby"
            export GEM_PATH="$HOME/.gem/ruby/gems"
            mkdir -p "$GEM_PATH"

            subinfo "Installing ruby"
            sudo pacman --needed --noconfirm -S ruby
            check_if_fail $?

            subinfo "Installing RuAUR ruby gem for AUR pkgs"
            $gem rdoc >/dev/null 2>&1
            $gem rdoc ruaur
            check_if_fail $?
            ;;
    esac

    # Reset
    unset pkgs

    info "Installing user requested AUR packages"

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
            ruaur="/root/.gem/ruby/bin/ruaur --noconfirm"
            if [[ ${#pkgs[@]} -gt 0 ]]; then
                run_in_chroot "${env[*]} $ruaur -S ${pkgs[*]}"
            fi
            ;;
        "postinstall")
            ruaur="$HOME/.gem/ruby/bin/ruaur --noconfirm"
            if [[ ${#pkgs[@]} -gt 0 ]]; then
                $ruaur -S "${pkgs[*]}"
            fi
            check_if_fail $?
            ;;
    esac
}

partition_and_format_disk_bios() {
    local part

    info "Partitioning and formatting disk for BIOS"

    # Wipe all signatures
    while read -r part; do
        subinfo "Wiping signatures for $part"
        wipefs --all --force "$part"
        check_if_fail $?
    done < <(lsblk -lp "$1" | awk '!/NAME/ {print $1}' | sort -r)
    unset part

    # Single bootable partition (ext4)
    subinfo "Partitioning"
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

    subinfo "Formatting as ext4"
    case "$1" in
        "/dev/nvme"*) mkfs.ext4 "${1}p1" ;;
        *) mkfs.ext4 "${1}1" ;;
    esac
    check_if_fail $?
}

partition_and_format_disk_uefi() {
    local part

    info "Partitioning and formatting disk for UEFI"

    # Wipe all signatures
    while read -r part; do
        subinfo "Wiping signatures for $part"
        wipefs --all --force "$part"
        check_if_fail $?
    done < <(lsblk -lp "$1" | awk '!/NAME/ {print $1}' | sort -r)
    unset part

    # A small, bootable partition (EFI) and a larger partition (ext4)
    subinfo "Partitioning"
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

    subinfo "Formatting as fat32 and ext4"
    case "$1" in
        "/dev/nvme"*)
            mkfs.fat "${1}p1"
            check_if_fail $?

            mkfs.ext4 "${1}p2"
            check_if_fail $?
            ;;
        *)
            mkfs.fat "${1}1"
            check_if_fail $?

            mkfs.ext4 "${1}2"
            check_if_fail $?
            ;;
    esac
}

select_locale() {
    local locale="$(var "locale")"

    info "Selecting $(var "locale") for locale"

    # Uncomment preferred locale
    sed -i -r "s/^#$locale/$locale/" /mnt/etc/locale.gen
    check_if_fail $?

    # Configure locale
    run_in_chroot "locale-gen"
    echo "LANG=$locale.UTF-8" >/mnt/etc/locale.conf
    check_if_fail $?
}

select_mirrors() {
    local mirrors="$(var "mirrors")"
    local url="https://archlinux.org/mirrorlist"

    # Get preferred mirrors
    subinfo "Selecting 5 closest mirrors for ${mirrors^^}"
    curl -s "$url/?country=${mirrors^^}&protocol=https&use_mirror_status=on" | \
        sed -e "s/^#Server/Server/" -e "/^#/d" | \
        rankmirrors -n 5 - | tee /etc/pacman.d/mirrorlist.keep
    check_if_fail $?

    # Replace mirrors with preferred mirrors
    mv -f /etc/pacman.d/mirrorlist.keep /etc/pacman.d/mirrorlist
    check_if_fail $?
}

usage() {
    cat <<EOF
Usage: ${0##*/} [OPTIONS] [dev]

DESCRIPTION
    If no config is specified, it will print out the default config.
    If a config is specified, it will install ArchNemesis with the
    options specified in the config. Setting "nemesis_tools" to
    "false" or empty means you only want to install Arch Linux (and
    LXQT if "gui" is true).

OPTIONS
    -c, --config=CFG      Use specified json config
    -h, --help            Display this help message
        --no-color        Disable colorized output
    -p, --post-install    Only install missing packages

EOF
    exit "$1"
}

declare -a args
unset config dev help postinstall
action="print"
color="true"

# Parse command line options
while [[ $# -gt 0 ]]; do
    case "$1" in
        "--") shift; args+=("$@"); break ;;
        "-c"|"--config"*)
            [[ $action == "postinstall" ]] || action="install"
            config="$(long_opt "$@")"
            ;;
        "-h"|"--help") help="true" ;;
        "--no-color") unset color ;;
        "-p"|"--post-install") action="postinstall" ;;
        *) args+=("$1") ;;
    esac
    case "$?" in
        0) ;;
        1) shift ;;
        *) usage $? ;;
    esac
    shift
done
[[ ${#args[@]} -eq 0 ]] || set -- "${args[@]}"

# Help info
[[ -z $help ]] || usage 0

# Check for missing dependencies
declare -a deps
deps+=("perl")
check_deps

case "$config" in
    "/"*|"") ;;
    *) config="$(pwd)/$config" ;;
esac

# Check for valid params
case "$action" in
    "install")
        [[ $# -le 1 ]] || usage 1

        [[ -n $config ]] || usage 2
        [[ -f $config ]] || usage 3

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
        [[ -f $config ]] || usage 3
        ;;
    "print") [[ $# -eq 0 ]] || usage 1 ;;
esac

# Main

case "$action" in
    *"install")
        info "Checking internet connection..."
        tmp="$(ping -c 1 8.8.8.8 | grep -s "0% packet loss")"
        [[ -n $tmp ]] || errx 5 "No internet"
        info "Success"

        sudo pacman --noconfirm -Syy
        sudo pacman --needed --noconfirm -S jq pacman-contrib

        info "Validating json config..."
        jq "." "$config" >/dev/null 2>&1
        [[ $? -eq 0 ]] || errx 4 "Invalid JSON"
        info "Success"
        ;;
esac

case "$action" in
    "install")
        mounted="$(mount | grep -oPs "${dev}[0-9p]*")"
        [[ -z $mounted ]] || umount -R /mnt
        mounted="$(mount | grep -oPs "${dev}[0-9p]*")"
        [[ -z $mounted ]] || errx 6 "Device already mounted"

        boot_mode="BIOS"
        [[ ! -d /sys/firmware/efi/efivars ]] || boot_mode="UEFI"

        beginners_guide
        install_configure_enable_iptables
        enable_sudo_for_wheel
        install_configure_enable_ssh

        if [[ -n $(boolean "gui") ]]; then
            install_enable_networkmanager
            install_configure_enable_lxdm
            install_configure_enable_sddm
        fi

        if [[ -n $(boolean "nemesis_tools") ]]; then
            enable_multilib /mnt/etc/pacman.conf
        fi

        install_packages
        enable_services
        fetch_tarballs
        create_and_configure_users
        configure_archnemesis
        customize

        info "Unmounting"
        umount -R /mnt
        check_if_fail $?

        info "You can now reboot (remove installation media)"
        ;;
    "postinstall")
        if [[ -n $(boolean "nemesis_tools") ]]; then
            enable_multilib /etc/pacman.conf
        fi

        install_packages
        ;;
    "print")
        # Default json
        cat <<EOF
{
  "vars": {
    "#": "Should AUR packages be installed?",
    "aur": "true",
    "#": "Should this be a graphical install?",
    "gui": "true",
    "hostname": "nemesis",
    "loadkeys": "us",
    "locale": "en_US",
    "mirrors": "us",
    "#": "Should offensive security tools be installed?",
    "nemesis_tools": "true",
    "primary_user": "nemesis",
    "#": "Graphical session of choice (currently LXQT is supported)",
    "session": "lxqt",
    "sshd_port": "22",
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
      ":HARDPASS - [0:0]",
      ":SYNFLOOD - [0:0]",
      ":TCP - [0:0]",
      ":UDP - [0:0]",
      "# Allow loopback",
      "-A INPUT -i lo -j ACCEPT",
      "# Allow established",
      "-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT",
      "# Drop invalid",
      "-A INPUT -m conntrack --ctstate INVALID -j DROP",
      "# Allow ping",
      "-A INPUT -p icmp -m icmp --icmp-type 8 -m conntrack --ctstate NEW -j ACCEPT",
      "# Jump to TCP table for new TCP",
      "-A INPUT -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -m conntrack --ctstate NEW -j TCP",
      "# Jump to UDP table for new UDP",
      "-A INPUT -p udp -m conntrack --ctstate NEW -j UDP",
      "# Otherwise reject",
      "-A INPUT -j HARDPASS",
      "# Allow established",
      "# -A FORWARD -m conntrack --ctstate DNAT,ESTABLISHED,RELATED -j ACCEPT",
      "# Drop invalid",
      "# -A FORWARD -m conntrack --ctstate INVALID -j DROP",
      "# Otherwise reject",
      "#-A FORWARD -j HARDPASS",
      "-A HARDPASS -p tcp -j REJECT --reject-with tcp-reset",
      "-A HARDPASS -p udp -j REJECT --reject-with icmp-port-unreachable",
      "-A HARDPASS -j REJECT --reject-with icmp-proto-unreachable",
      "# Protect from SYN flood",
      "-A SYNFLOOD -m limit --limit 64/min --limit-burst 64 -j RETURN",
      "-A SYNFLOOD -j HARDPASS",
      "# Check for SYN flood",
      "-A TCP -j SYNFLOOD",
      "# Allow:",
      "# - SSH ({{{sshd_port}}})",
      "-A TCP -p tcp -m multiport --dports {{{sshd_port}}} -j ACCEPT",
      "# Allow:",
      "# - WireGuard (443)",
      "# -A UDP -p udp -m multiport --dports 443 -j ACCEPT",
      "COMMIT",
      "*nat",
      ":PREROUTING ACCEPT [0:0]",
      ":INPUT ACCEPT [0:0]",
      ":OUTPUT ACCEPT [0:0]",
      ":POSTROUTING ACCEPT [0:0]",
      "# Masquerade",
      "# -A POSTROUTING -o eth0 -j MASQUERADE",
      "COMMIT",
      "*raw",
      ":PREROUTING ACCEPT [0:0]",
      ":OUTPUT ACCEPT [0:0]",
      "-A PREROUTING -m rpfilter -j ACCEPT",
      "-A PREROUTING -j DROP",
      "COMMIT"
    ],
    "ip6tables_rules": [
      "*filter",
      ":INPUT DROP [0:0]",
      ":FORWARD DROP [0:0]",
      ":OUTPUT ACCEPT [0:0]",
      ":HARDPASS - [0:0]",
      ":SYNFLOOD - [0:0]",
      ":TCP - [0:0]",
      ":UDP - [0:0]",
      "# Allow loopback",
      "-A INPUT -i lo -j ACCEPT",
      "# Allow established",
      "-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT",
      "# Drop invalid",
      "-A INPUT -m conntrack --ctstate INVALID -j DROP",
      "# Allow ping",
      "-A INPUT -p ipv6-icmp -m icmp6 --icmpv6-type 128 -m conntrack --ctstate NEW -j ACCEPT",
      "# Allow IPv6 ICMP for router advertisements (add needed subnets)",
      "-A INPUT -s fe80::/10 -p ipv6-icmp -j ACCEPT",
      "# Jump to tcp table for new tcp",
      "-A INPUT -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -m conntrack --ctstate NEW -j TCP",
      "# Jump to udp table for new udp",
      "-A INPUT -p udp -m conntrack --ctstate NEW -j UDP",
      "# Otherwise reject",
      "-A INPUT -j HARDPASS",
      "# Allow established",
      "# -A FORWARD -m conntrack --ctstate DNAT,ESTABLISHED,RELATED -j ACCEPT",
      "# Drop invalid",
      "# -A FORWARD -m conntrack --ctstate INVALID -j DROP",
      "# Otherwise reject",
      "#-A FORWARD -j HARDPASS",
      "-A HARDPASS -p tcp -j REJECT --reject-with tcp-reset",
      "-A HARDPASS -p udp -j REJECT --reject-with icmp6-port-unreachable",
      "-A HARDPASS -j REJECT --reject-with icmp6-port-unreachable",
      "# Protect from SYN flood",
      "-A SYNFLOOD -m limit --limit 64/min --limit-burst 64 -j RETURN",
      "-A SYNFLOOD -j HARDPASS",
      "# Check for SYN flood",
      "-A TCP -j SYNFLOOD",
      "# Allow:",
      "# - SSH ({{{sshd_port}}})",
      "-A TCP -p tcp -m multiport --dports {{{sshd_port}}} -j ACCEPT",
      "# Allow:",
      "# - WireGuard (443)",
      "# -A UDP -p udp -m multiport --dports 443 -j ACCEPT",
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
    "enable": "false",
    "lxdm_conf": {
      "autologin": "{{{primary_user}}}",
      "numlock": "1",
      "session": "/usr/bin/{{{session}}}-session"
    }
  },
  "sddm": {
    "enable": "{{{gui}}}",
    "sddm_conf": [
      "[Autologin]",
      "User={{{primary_user}}}",
      "Session={{{session}}}.desktop",
      "",
      "[General]",
      "Numlock=on"
    ]
  },
  "network": {
    "dhcp_network": [
      "[Match]",
      "Name=en*",
      "",
      "[Network]",
      "DHCP=ipv4"
    ]
  },
  "packages": {
    "aur": {
      "default": [],
      "gui": [],
      "misc": [
        "burpsuite",
        "maltego",
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
      "dnsmasq",
      "exfat-utils",
      "gcc",
      "gdb",
      "git",
      "git-crypt",
      "go",
      "gzip",
      "inetutils",
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
      "ranger",
      "ripgrep",
      "rsync",
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
      "zsh-history-substring-search",
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
      "flameshot",
      "gvim",
      "keepassxc",
      "leafpad",
      "lxqt",
      "mupdf",
      "noto-fonts",
      "openbox",
      "oxygen-icons",
      "pamixer",
      "pavucontrol-qt",
      "pcmanfm-qt",
      "pulseaudio",
      "pulseaudio-bluetooth",
      "ttf-dejavu",
      "viewnior",
      "wmctrl",
      "x11-ssh-askpass",
      "x11vnc",
      "xclip",
      "xdg-user-dirs",
      "xdotool",
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
    "misc": [
      "dunst",
      "nitrogen",
      "tilda"
    ],
    "nemesis_tools": [
      "aircrack-ng",
      "binwalk",
      "clamav",
      "cowpatty",
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
      "openvas",
      "ophcrack",
      "pyrit",
      "python2",
      "python2-pip",
      "radare2",
      "sqlmap",
      "tcpdump",
      "wireshark-qt",
      "zaproxy",
      "zmap"
    ]
  },
  "services": [],
  "ssh": {
    "enable": "true",
    "sshd_config": {
      "PasswordAuthentication": "yes",
      "PermitRootLogin": "without-password",
      "Port": "{{{sshd_port}}}",
      "PrintLastLog": "no",
      "PrintMotd": "no",
      "UseDNS": "no",
      "X11Forwarding": "no"
    }
  },
  "users": [
    {
      "authorized_keys": [],
      "groups": "users,wheel,wireshark",
      "name": "{{{primary_user}}}",
      "password": "nemesis",
      "shell": "/usr/bin/zsh",
      "ssh_config": [
        "# No agent or X11 forwarding",
        "Host *",
        "    ForwardAgent no",
        "    ForwardX11 no",
        "    HashKnownHosts yes",
        "    IdentityFile ~/.ssh/{{{hostname}}}",
        "    LogLevel Error"
      ]
    },
    {
      "authorized_keys": [],
      "groups": "",
      "name": "root",
      "password": "nemesis",
      "shell": "",
      "ssh_config": []
    }
  ]
}
EOF
        ;;
esac
