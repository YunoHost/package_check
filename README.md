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

<!--STARTHELP-->

```text
> ./package_check.sh --help
 Usage: package_check.sh [OPTION]... PACKAGE_TO_CHECK

    -b, --branch=BRANCH         Specify a branch to check.
    -a, --arch=ARCH
    -d, --dist=DIST
    -y, --ynh-branch=BRANCH
    -D, --dry-run               Show a JSON representing which tests are going to be ran (meant for debugging)
    -i, --interactive           Wait for the user to continue before each remove
    -e, --interactive-on-errors Wait for the user to continue on errors
    -s, --force-stop            Force the stop of running package_check
    -r, --rebuild               (Re)Build the base container
                                (N.B.: you're not supposed to use this option,
                                images are supposed to be fetch from
                                devbaseimgs.yunohost.org automatically)
    -S, --storage-dir DIRECTORY Where to store temporary test files like yunohost backups
    -v, --verbose               Prints the complete debug log to screen
    -h, --help                  Display this help

    Pass YNHDEV_BACKEND=incus|lxd to use a specific LXD-compatible backend.
```

<!--ENDHELP-->

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
