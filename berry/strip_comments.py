#!/usr/bin/env python3
"""Removes Berry comments (# ... / #- ... -#) from a .be file for the .tapp
build, without treating a '#'/'"' inside a double-quoted string literal as a
comment. Only intended for the language subset actually used in gplug_ha.be
(strings exclusively in double quotes, escapes via backslash) - not a full
Berry parser.

Usage: strip_comments.py <file.be>   (result on stdout)
"""
import sys


def strip(src):
    out = []
    i = 0
    n = len(src)
    in_string = False
    while i < n:
        c = src[i]
        if in_string:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(src[i + 1])
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
            continue
        if c == '"':
            in_string = True
            out.append(c)
            i += 1
            continue
        if c == "#":
            if i + 1 < n and src[i + 1] == "-":
                j = src.find("-#", i + 2)
                end = j + 2 if j != -1 else n
                out.append("\n" * src.count("\n", i, end))
                i = end
                continue
            j = src.find("\n", i)
            i = j if j != -1 else n
            continue
        out.append(c)
        i += 1
    return "".join(out)


def main():
    with open(sys.argv[1], encoding="utf-8") as f:
        stripped = strip(f.read())

    lines = [ln.rstrip() for ln in stripped.split("\n")]
    result = []
    prev_blank = False
    for ln in lines:
        blank = ln.strip() == ""
        if blank and prev_blank:
            continue
        result.append(ln)
        prev_blank = blank

    sys.stdout.write("\n".join(result).strip("\n") + "\n")


if __name__ == "__main__":
    main()
