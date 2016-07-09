# Merci a Bram pour ce code python.
# https://github.com/YunoHost/ci

import sys
import json

from default_args import argument_for_question


if __name__ == '__main__':
    manifest_path = sys.argv[1:][0]
    manifest = json.load(open(manifest_path, "r"))

    for question in manifest["arguments"]["install"]:
        print ":".join(argument_for_question(question, all_choices=True))
