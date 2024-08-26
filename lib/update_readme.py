#! /usr/bin/env python3

import os 
from pathlib import Path

BASEDIR = os.path.realpath(os.path.dirname(os.path.realpath(__file__)) + "/..")
README = Path(BASEDIR) / "README.md"
SCRIPT = Path(BASEDIR) / "package_check.sh"

with open(SCRIPT) as f:
    content = f.read()
    help = content.split("#STARTHELP")[1].split("#ENDHELP")[0]
    # Remove first 2 lines
    help = "\n".join(help.split("\n")[2:])
    # Remove last 3 lines
    help = "\n".join(help.split("\n")[:-3])

with open(README) as f:
    content = f.read()
    start = content.split("<!--STARTHELP-->")[0]
    end = content.split("<!--ENDHELP-->")[1]

readme_content = start \
    + "<!--STARTHELP-->\n\n" \
    + "```text\n" \
    + "> ./package_check.sh --help\n" \
    + help \
    + "\n```\n\n<!--ENDHELP-->" \
    + end

with open(README, "w") as f:
    f.write(readme_content)
