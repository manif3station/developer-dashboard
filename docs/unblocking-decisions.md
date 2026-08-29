# Getting a blocked decision answered

Some work stops on a judgement that is not the agent's to make: a push to
`master`, a contradiction between two rules, whether a card should be split.
This page is about how that question reaches the person who can answer it, and
why the place you put it decides whether it gets answered at all.

## Ask on the card, never in chat

```bash
d2 tira.question.ask  --ref DD-NNN --text TEXT --reason TEXT --option A --option B
d2 tira.question.list --ref DD-NNN            # read the answer
d2 tira.question.mark --id Q-NNN --mark ok    # settle it
```

A question on a card is a durable record with an owner, an answer and a mark. It
is swept: when the owner answers and nobody has read it, that becomes a finding
in its own right, on the grounds that *an answer nobody acts on is the same to
him as no answer*.

A question in chat is none of those things. Nothing sweeps it, nothing escalates
it, and nothing records that it was ever asked. It is indistinguishable, later,
from a question nobody had.

**This is not a style preference; it is the difference between an answer and
silence.** Measured on this project on one morning, with two agent sessions
working the same board: the session that asked its blocking questions on the
cards had three answered within about four minutes of the owner picking up his
phone. The other reported "waiting on your word" in chat and in session text, and
sat on a fully verified fix for hours while `master` stayed broken into a ninth
day. Same owner, same phone, same morning. The only variable was where the
question was put.

## What makes a question answerable

The owner is usually on a phone. A question he can answer in one tap gets
answered; one that needs a paragraph of reply waits.

- **`--reason`** — why this cannot be decided without him. Include what you have
  already established, so he is not asked to redo your work.
- **`--option`** — two to four concrete choices, each of which you could act on
  immediately. Not "what should I do?"
- **State the cost of each option** where they differ. If one trades a rule
  against losing a check, say so; that is exactly the part only he can weigh.
- **Say what is already true.** "Everything is verified, this needs your word"
  is a different question from "I am stuck."

## After the answer

1. **Read it promptly.** The sweep exists because an unread answer is a stalled
   one.
2. **Act on it**, then **fold the decision into a card FIELD.** A comment is not
   folding it in — the rule that checks this compares the mark against the newest
   *field* write, and it wants the field write to come **after** the mark.
3. **Mark it** `ok` when it settles the matter. If it does not, `--mark not-ok`
   **and ask a new question** — a cross on its own settles nothing.

## Two failure modes worth naming

**An ambiguous answer acted on privately.** An answer that says "one of you
stands down" without naming which is answered *twice*, once by each reader, and
they can both be wrong in opposite directions: both continue, or both stop. When
an answer does not fully determine your action, **write your reading on the card
and invite correction before acting**, rather than acting on the most convenient
interpretation.

**Narrating instead of asking.** Reporting "blocked on you" in a status update
feels like raising it. It is not asking; it produces no record, and it converts a
decision that takes ninety seconds into an open-ended wait. If the answer changes
what happens to a card, it belongs on the card — and then get on with something
else while you wait.
