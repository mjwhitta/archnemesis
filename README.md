# ArchNemesis

<a href="https://www.buymeacoffee.com/mjwhitta">🍪 Buy me a cookie</a>

I like Arch. So much so, I created my own custom PT/RT install using
it. Can I call this a distro?

## Quick start

Run one of the following shortcuts if you just want to use the default
configurations.

**Note:** Default credentials: `nemesis:nemesis`

### Nemesis

From an Arch Installation ISO:

```
$ curl -kLs "https://nemesis.archnemesis.ninja" | bash
```

### CLI only

From an Arch Installation ISO:

```
$ curl -kLs "https://cli.archnemesis.ninja" | bash
```

### Post-install

```
$ curl -kLs "https://post-install.archnemesis.ninja" | bash
```

## Installation (from scratch)

### Preperation

1. Download the install script

    ```
    $ curl -kL -o install.sh -s "https://install.archmemesis.ninja"
    $ chmod 700 install.sh
    ```

2. Inspect the script to make sure you feel it's safe

3. Generate a config file by running the script

    ```
    $ ./install.sh >nemesis.json
    ```

4. Modify the json file as needed

    - Add authorized_keys
    - Add users
    - Change session
    - Change ssh port
    - Modify packages

### Installing

1. Get an Arch installation ISO from the [Arch Linux Downloads] page
    - Currently tested with archlinux-2020.03.01-x86_64.iso

2. Boot it up and wait for the shell prompt

3. Find a way to get `authorized_keys` and/or the config onto the
   install machine (or prep on this machine)

    a) On a remote machine:

    ```
    $ ruby -r un -e httpd . -p 8080
    ```

    b) On the install machine:

    ```
    $ curl -s "http://remote_machine:8080/authorized_keys"
    ```

4. Download the install script (unless you prep'd on same machine)

    ```
    $ curl -kL -o install.sh -s "https://install.archmemesis.ninja"
    $ chmod 700 install.sh
    ```

5. Run the script using the config

    ```
    $ ./install.sh -c nemesis.json /dev/DEVICE
    ```

## Installation (post-install)

If you have an existing Arch Linux install, you can use the following
steps to convert to ArchNemesis (mileage may vary). This will simply
skip most of the configuration and just install any missing packages.

1. Download the install script

    ```
    $ curl -kL -o install.sh -s "https://install.archmemesis.ninja"
    $ chmod 700 install.sh
    ```

2. Inspect the script to make sure you feel it's safe

3. Run the script (you can generate a config and use it if you want)

    ```
    $ ./install.sh --post-install
    ```

## TODO

- Lots of things
    - Store progress
        - Continue from where you left off, if error encountered
    - dm-crypt +/- LUKS

[Arch Linux Downloads]: https://www.archlinux.org/download/
