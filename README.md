# ArchNemesis

[![Yum](https://img.shields.io/badge/-Buy%20me%20a%20cookie-blue?labelColor=grey&logo=cookiecutter&style=for-the-badge)](https://www.buymeacoffee.com/mjwhitta)

I like Arch. So much so, I created my own custom Red Team "distro"
based on it.

## Quick start

From an [Arch Installation ISO]:

```
$ curl -Ls get.archnemesis.ninja | bash
$ cd archnemesis
$ vim ./nemesis.cfg
```

Modify `nemesis.cfg` as needed:

- Change hostname
- Change keyboard layout
- Change pacman mirrors location
- Change session
- Change ssh port
- Change theme
- Change timezone
- Change user
    - Add authorized key
    - Change password
    - Change username

**Note:** You can alternatively modify the `nemesis.cfg` elsewhere and
just use `curl` to grab it before installing.

```
$ ./install -h # READ
$ ./install [/dev/DEVICE]
$ reboot
```

**Note:** Default password: `nemesis`

## TODO

- Store progress
    - Continue from where you left off, if error encountered
- dm-crypt +/- LUKS

[Arch Installation ISO]: https://www.archlinux.org/download
