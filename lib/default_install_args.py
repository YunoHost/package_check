#!/usr/bin/python3

import argparse
import json
from pathlib import Path

import toml


def get_default_value(app_name: str, name: str, question: dict, raise_if_no_default: bool = True) -> str:
    base_default_value_per_arg_type = {
        ("domain", "domain"): "domain.tld",
        ("path", "path"): "/" + app_name,
        ("user", "admin"): "package_checker",
        ("group", "init_main_permission"): "visitors",
        ("group", "init_admin_permission"): "admins",
        ("password", "password"): "MySuperComplexPassword"
    }

    type_and_name = (question["type"], name)

    if value := base_default_value_per_arg_type.get(type_and_name):
        return value

    if value := question.get("default"):
        if isinstance(value, bool):
            # Convert bool to "0", "1"
            value = str(int(value))
        return value

    if question["type"] == "boolean":
        return "1"

    if question["type"] == "password":
        return "SomeSuperStrongPassword1234"

    if choices := question.get("choices"):
        return list(choices)[0]

    if raise_if_no_default:
        raise RuntimeError("No default value could be computed for arg " + name)
    return ""


def get_default_values_for_questions(manifest: dict, raise_if_no_default=True) -> dict[str, str]:
    app_name = manifest["id"]

    if manifest.get("packaging_format", 1) <= 1:
        questions = {q["name"]: q for q in manifest["arguments"]["install"]}
    else:
        questions = manifest["install"]

    args = {
        name: get_default_value(app_name, name, question, raise_if_no_default)
        for name, question in questions.items()
    }
    return args


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest_path", type=Path, help="Path to the app directory")
    args = parser.parse_args()

    if args.manifest_path.name.endswith(".json"):
        manifest = json.load(args.manifest_path.open())
    else:
        manifest = toml.load(args.manifest_path.open())

    query_string = "&".join([f"{name}={value}" for name, value in get_default_values_for_questions(manifest).items()])
    print(query_string)


if __name__ == "__main__":
    main()
