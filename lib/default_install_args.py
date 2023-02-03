#!/usr/bin/python3

import sys
import json
import toml

def get_default_values_for_questions(manifest, raise_if_no_default=True):

    base_default_value_per_arg_type = {
        ("domain", "domain"): "domain.tld",
        ("path", "path"): "/" + manifest["id"],
        ("user", "admin"): "package_checker",
        ("group", "init_main_permission"): "visitors",
        ("group", "init_admin_permission"): "admins",
        ("password", "password"): "MySuperComplexPassword"
    }

    if manifest.get("packaging_format", 1) <= 1:
        questions = {q["name"]:q for q in manifest["arguments"]["install"]}
    else:
        questions = manifest["install"]

    for name, question in questions.items():
        type_and_name = (question["type"], name)
        base_default = base_default_value_per_arg_type.get(type_and_name)
        if base_default:
            yield (name, base_default)
        elif question.get("default"):
            if isinstance(question.get("default"), bool):
                yield (name, str(int(question.get("default"))))
            else:
                yield (name, str(question.get("default")))
        elif question["type"] == "boolean":
            yield (name, "1")
        elif question.get("choices"):
            if isinstance(question["choices"]):
                choices = str(question["choices"])
            else:
                choices = list(question["choices"].keys())
            yield (name, choices[0])
        else:
            if raise_if_no_default:
                raise Exception("No default value could be computed for arg " + name)

if __name__ == '__main__':
    manifest_path = sys.argv[1:][0]

    if manifest_path.endswith(".json"):
        manifest = json.load(open(manifest_path, "r"))
    else:
        manifest = toml.load(open(manifest_path, "r"))

    querystring = '&'.join([k + "=" + v for k, v in get_default_values_for_questions(manifest)])
    print(querystring)
