#!/usr/bin/env python3
"""Compose the spoken script for one Tira question.

Kept as its own file rather than inlined in a shell heredoc, because a question's
text, reason and options are arbitrary prose: quotes, dollars and backslashes all
appear in them, and every one of those breaks a heredoc that the shell expands.
The first version of the caller did exactly that and failed in a way that looked
like Tira refusing the recording.

Prints the script on stdout. Exits 1 when there is no such question, so the caller
can tell "not found" from "found but empty".
"""

import glob
import json
import sys

WORDS = ["One", "Two", "Three", "Four", "Five", "Six"]


def find(qid, root):
    """Purpose: locate one question anywhere on the board.
    Input:   question reference, board root.
    Output:  (card ref, question dict) or (None, None).
    """
    for path in glob.glob(root + "/*/*/*.json"):
        try:
            record = json.load(open(path))
        except Exception:
            continue
        for question in record.get("questions") or []:
            if question.get("id") == qid:
                return record.get("ref"), question
    return None, None


def compose(qid, card, question):
    """Purpose: turn a question into words meant to be heard, not read.
    Input:   reference, card reference, question dict.
    Output:  one string.

    The card reference is spaced out ("D D 511") because a speech engine reads
    "DD-511" as a word rather than as letters.
    """
    number = qid.split("-")[1].lstrip("0") or qid
    spoken = ["Question %s on card %s." % (number, (card or "").replace("DD-", "D D "))]
    spoken.append(question.get("text") or "")
    if question.get("reason"):
        spoken.append("Why I am asking. " + question["reason"])
    options = question.get("options") or []
    if options:
        spoken.append("Your choices are.")
        for index, option in enumerate(options):
            label = WORDS[index] if index < len(WORDS) else str(index + 1)
            spoken.append("%s. %s." % (label, option))
    answer = (question.get("answer") or {}).get("text")
    if answer:
        spoken.append("This one has already been answered.")
    return " ".join(part.strip() for part in spoken if part).strip()


def main():
    if len(sys.argv) != 3:
        print("usage: question-speech.py Q-NNN TIRA_ROOT", file=sys.stderr)
        return 2
    qid, root = sys.argv[1], sys.argv[2]
    card, question = find(qid, root)
    if question is None:
        print("no question %s under %s" % (qid, root), file=sys.stderr)
        return 1
    print(compose(qid, card, question))
    return 0


if __name__ == "__main__":
    sys.exit(main())
