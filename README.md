Package checker for YunoHost
==================

[YunoHost project](https://yunohost.org/#/)

Set of unit tests to check YunoHost packages.
The `package_check.sh` script perform a series of tests on a package for verify its capability to be installed and removed in different situation.
The test results are printed directly in the terminal and stored in the log file Test_results.log

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
                                devbaseimgs.yunohost.org automatically)
    -h, --help                  Display this help
```

## Deploying package_check

First you need to install the system dependencies.

Package check is based on the LXD/LXC ecosystem. Be careful that
**LXD can conflict with other installed virtualization technologies such as
libvirt or vanilla LXCs**, especially because they all require a daemon based
on DNSmasq which may list on port 53.

On a Debian-based system (regular Debian, Ubuntu, Mint ...), LXD can be
installed using `snapd`. On other systems like Archlinux, you will probably also
be able to install `snapd` using the system package manager (or even
`lxd` directly).

```bash
apt install git snapd lynx jq
sudo snap install core
sudo snap install lxd

# Adding lxc/lxd to /usr/local/bin to make sure we can use them easily even
# with sudo for which the PATH is defined in /etc/sudoers and probably doesn't
# include /snap/bin
sudo ln -s /snap/bin/lxc /usr/local/bin/lxc
sudo ln -s /snap/bin/lxd /usr/local/bin/lxd
```

NB. : you should **make sure that your user is in the `lxd` group** so that it's
able to run `lxc` commands without sudo... You can check this with the command
`groups` where you should see `lxd`. Otherwise, add your user to this group
(don't forget that you may need to reload your entire graphical session for this
to propagate (sigh))

Then you shall initialize LXD which will ask you a bunch of question. Usually
answering the default (just pressing enter) to all questions is fine. Just pay
attention to :

- the storage backend driver. Possibly `zfs` is the best, but requires a kernel >= 5.x
  and corresponding kernel module loaded. You can fallback to the `dir` driver.
- the size of the default storage it'll create (the default is 5G but you may
  want 10G for heavy usage ?) (if you're using the 'dir' driver, this won't be asked)

```bash
lxd init
```

The base images for tests are centralized on `devbaseimgs.yunohost.org` and we'll download them from there to speed things up:

```bash
lxc remote add yunohost https://devbaseimgs.yunohost.org --public
```

(At the time this README is written, fingerprint is d9ae6e76c374e3c58c3c20a881cffe7435809adb3b222ec393805f5bd01bb522 )

Then you can install package check :

```
git clone https://github.com/YunoHost/package_check
cd package_check
```

Then test your packages :

```
./package_check.sh your_app_ynh
```

## Run package check in a VirtualBox VM via Vagrant

We add script to run package check in a VirtualBox. More information here:

* [vagrant/README.md](https://github.com/YunoHost/package_check/tree/master/vagrant)


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
