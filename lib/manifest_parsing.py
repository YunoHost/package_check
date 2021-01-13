#!/usr/bin/python3

import sys
import json

def argument_for_question(question, all_choices=False):
    question_type = question.get("type")

    if question_type is None and question.get("choices"):
        question_type = "boolean"
    elif question_type is None and question.get("default"):
        question_type = "with_default"
    elif question_type is None and question["name"] == "admin":
        question_type = "user"
    elif question_type is None and question["name"] == "domain":
        question_type = "domain"

    if question_type == "domain":
        return (question["name"], "ynh.local")
    elif question_type == "path":
        if all_choices:
            return (question["name"], question["default"], "/")
        else:
            return (question["name"], question["default"])
    elif question_type == "with_default":
        return (question["name"], question["default"])
    elif question_type == "boolean":
        if not all_choices:
            if isinstance(question["default"], bool):
                if question["default"]:
                    question["default"] = "1"
                else:
                    question["default"] = "0"

            return (question["name"], question["default"])
        else:
            if isinstance(question["default"], bool) :
                return (question["name"], "1", "0")

            if question.get("choices"):
                return (question["name"],) + tuple(question["choices"])

            return (question["name"], question["default"])
    elif question_type == "password":
        return (question["name"], "ynh")
    elif question_type == "user":
        return (question["name"], "johndoe")
    else:
        raise Exception("Unknow question type: %s\n" % question_type, question)

if __name__ == '__main__':
    manifest_path = sys.argv[1:][0]
    manifest = json.load(open(manifest_path, "r"))

    for question in manifest["arguments"]["install"]:
        print(":".join(argument_for_question(question, all_choices=True)))
