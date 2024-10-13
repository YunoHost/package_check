Package checker for YunoHost
==================

[YunoHost project](https://yunohost.org/#/)

Set of integration tests to check YunoHost packages.
The `package_check.sh` script perform a series of tests on a package for verify its capability to be installed and removed in different situation.
The test results are printed directly in the terminal and stored in the log file Test_results.log

## Setup

> [!WARNING]
> We use LXD or Incus, which may conflict with other virtualization technologies. It may conflict with libvirt or LXC due to
> requiring dnsmasq on port 53. It will definitely conflict with Docker, but [some workarounds are documented](https://linuxcontainers.org/incus/docs/main/howto/network_bridge_firewalld/#prevent-connectivity-issues-with-incus-and-docker).

- install basic dependencies: `sudo apt install lynx jq btrfs-progs`
- install [LXD](https://canonical.com/lxd/install) or [Incus](https://linuxcontainers.org/incus/docs/main/installing/)
- make sure your user is in the `lxd` or `incus-admin` group (`sudo usermod -a -G lxd MYUSER`)
- **restart your computer**: this will ensure you have indeed the permissions, and that LXD/Incus can access the BTRFS kernel module
- make sure LXC/Incus is initialized with `lxd init` or `incus admin init --minimal`; in the case of LXD, make sure to use the `btrfs` storage driver unless you know what you are doing
- if using LXD, run this command to add the Yunohost image repository: `lxc remote add yunohost https://repo.yunohost.org/incus --protocol simplestreams --public`; at the time this README is written, fingerprint is `d9ae6e76c374e3c58c3c20a881cffe7435809adb3b222ec393805f5bd01bb522`

<details>
<summary><b>More details about LXD/Incus settings</b></summary>
If you'd like to use non-default settings with Incus, run `incus admin init` without the `--minimal` flag. In most cases,
default settings are just fine, but be aware that the storage backend driver may have a large impact on performance.

Using the `btrfs` or `zfs` driver will provide best performance due to [CoW](https://en.wikipedia.org/wiki/Copy-on-write), but it may
not be available on all systems. In that case, the default storage may not be enough for your needs.
</details>

<details>
<summary><b>Additional steps if you have installed LXD with snap...</b></summary>
<pre><code>
# Adding lxc/lxd to /usr/local/bin to make sure we can use them easily even
# with sudo for which the PATH is defined in /etc/sudoers and probably doesn't
# include /snap/bin
sudo ln -s /snap/bin/lxc /usr/local/bin/lxc
sudo ln -s /snap/bin/lxd /usr/local/bin/lxd
</code></pre>
</details>

You can now setup and use `package_check`:

```bash
git clone https://github.com/YunoHost/package_check
cd package_check
./package_check.sh your_app_ynh
```

## Features

The script is able to perform the following tests:

- [Linter](https://github.com/YunoHost/package_linter)
- Install/remove/reinstall at the root of a domain (`domain.tld/`)
- Install/remove/reinstall in a subpath (`domain.tld/foobar`)
- Install/remove/reinstall with no url (for non-webapps)
- Install with `is_public=0` (private install)
- Install multiple instances (if `multi_instance` is true)
- Upgrade from same version
- Upgrade from previous versions
- Backup/restore
- Changing the installation url (`change_url`)

Package_check script uses a LXC container to manipulate the package in a clean environment without any previous installations.

Usage:
For a package in a directory: `./package_check.sh APP_ynh`
For a package on GitHub: `./package_check.sh https://github.com/YunoHost-Apps/APP_ynh`

The app is expected to contain a `tests.toml` file (see below) to tell package_check what tests to run (though most of it is guessed automagically)

## Usage

```text
> ./package_check.sh --help
 Usage: package_check.sh [OPTION]... PACKAGE_TO_CHECK

    -b, --branch=BRANCH     Specify a branch to check.
    -a, --arch=ARCH
    -d, --dist=DIST
    -y, --ynh-branch=BRANCH
    -i, --interactive           Wait for the user to continue before each remove
    -e, --interactive-on-errors Wait for the user to continue on errors
    -s, --force-stop            Force the stop of running package_check
    -r, --rebuild               (Re)Build the base container
                                (N.B.: you're not supposed to use this option,
                                images are supposed to be fetch from
                                https://repo.yunohost.org/incus automatically)
    -h, --help                  Display this help
```

## You can start a container on a different architecture with some hacks

Install the package `qemu-user-static` and `binfmt-support`, then list of all available images :

```
lxc image list images:debian/bullseye
```

Export the image of the architecture you want to run (for example armhf):

```
lxc image export images:debian/bullseye/armhf
```

This command will create two files.

- rootfs.squashfs
- lxd.tar.xz

We need to change the architecture of the metadata:

```
tar xJf lxd.tar.xz
sed -i '0,/architecture: armhf/s//architecture: amd64/' metadata.yaml
tar cJf lxd.tar.xz metadata.yaml templates
```

And reimport the image:

```
lxc image import lxd.tar.xz rootfs.squashfs --alias test-arm
```

You can now start an armhf image with:

```
lxc launch test-arm
lxc exec inspired-lamprey -- dpkg --print-architecture
```

If the `build_base_lxc.sh` script detects that you are trying a cross container architecture, it will try to perform this hack

## `tests.toml` syntax

```toml
test_format = 1.0

[default]

    # ------------
    # Tests to run
    # ------------

    # NB: the tests to run are automatically deduced by the CI script according to the
    # content of the app's manifest. The declarations below allow to customize which
    # tests are ran, possibly add special test suite to test special args, or
    # declare which commits to test upgrade from.
    #
    # You can also decide (though this is discouraged!) to ban/ignore some tests,

    exclude = ["install.private", "install.multi"]  # NB : you should NOT need this except if you really have a good reason ...

    # For special usecases, sometimes you need to setup other things on the machine
    # prior to installing the app (such as installing another app)
    # (Remove this key entirely if not needed)
    preinstall = """
    sudo yunohost app install foobar
    sudo yunohost user list
    """

    # -------------------------------
    # Default args to use for install
    # -------------------------------

    # By default, the CI will automagically fill the 'standard' args
    # such as domain, path, admin, is_public and password with relevant values
    # and also install args with a "default" provided in the manifest..
    # It should only make sense to declare custom args here for args with no default values

    args.language = "fr_FR"    # NB : you should NOT need those lines unless for custom questions with no obvious/default value
    args.multisite = 0

    # -------------------------------
    # Commits to test upgrade from
    # -------------------------------

    test_upgrade_from.00a1a6e7.name = "Upgrade from 5.4"
    test_upgrade_from.00a1a6e7.args.foo = "bar"

    # -------------------------------
    # Curl tests to validate that the app works
    # -------------------------------
    [default.curl_tests]
    #home.path = "/"
    home.expect_title = "Login - Nextcloud"

    #dash.path = "/"
    dash.logged_on_sso = true
    dash.expect_title = "Tableau de bord - Nextcloud"

    admin.path = "/settings/admin"
    admin.logged_on_sso = true
    admin.expect_title = "Paramètres d'administration - Nextcloud"

    asset.path = "/core/img/logo/logo.svg"

    file.path = "/remote.php/dav/files/__USER__/Readme.md"
    file.logged_on_sso = true
    file.expect_content = "# Welcome to Nextcloud!"

    caldav.base_url = "https://yolo.test"
    caldav.path = "/.well-known/caldav"
    caldav.logged_on_sso = true
    caldav.expect_content = "This is the WebDAV interface."

# This is an additional test suite
[multisite]

    # On additional tests suites, you can decide to run only specific tests

    only = ["install.subdir"]

    args.language = "en_GB"
    args.multisite = 1
```

Note that you can run `python3 lib/parse_tests_toml.py /path/to/your/app/ | jq` to dump what tests will be run by package check


##### Test ids

The test IDs to be used in only/exclude statements are: `install.root`, `install.subdir`, `install.nourl`, `install.multi`, `backup_restore`, `upgrade`, `upgrade.someCommitId` `change_url`
