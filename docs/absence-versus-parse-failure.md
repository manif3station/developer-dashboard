# A checker that reports absence must be able to tell absence from a parse failure

When a guard looks for a declaration and does not find one, it knows exactly one
thing: **its own pattern did not match.** That is not the same as the declaration
being absent, and a message that says "nothing was declared" has stated a
conclusion the check never reached.

The two states call for opposite responses, which is why collapsing them is
expensive:

| state | what is true | what the reader should do |
|---|---|---|
| **absent** | nobody declared anything | write the declaration |
| **unparsed** | somebody declared something, in a form the pattern rejects | fix the *form*, or widen the pattern deliberately |

Told "you did not declare a trigger", a reader who *did* declare one has been
sent to do something they have already done. They will either write a second
declaration beside the first, or conclude the checker is broken and stop reading
it — and a checker its own users have learned to disbelieve is worse than no
checker, because it still occupies the place where a working one would go.

## The shape, concretely

`.claude/tools/decline-watch` parses a decline's reason for the trigger it has
declared for itself:

```perl
return $1 if $reason =~ /RE-DECLARE\s+TRIGGER:\s*([A-Za-z0-9_-]+)/;
return undef;
```

The colon is mandatory. A reason that writes `RE-DECLARE TRIGGER - <prose>`, or
puts a name the character class rejects after the colon, returns `undef` — and
`undef` is the same value the function returns for a reason that never mentions
a trigger at all. One value, two meanings, and the message picks the wrong one:

> `<rule>` is declined with no re-declare trigger declared

The parse is **not** the defect. Being strict is right here: the prose after a
dash is three conditions rather than a name, so accepting it would turn an
honest parse failure into a silent wrong parse — a strictly worse outcome, since
the tool would then evaluate the wrong thing while looking correct. **What needs
fixing is the sentence, not the regex.**

## The fix is a second, laxer pattern used only for the message

Detect the *attempt* separately from the *value*:

- the **strict** pattern extracts the trigger name, and stays exactly as strict
  as it is;
- a **lax** pattern asks only "did somebody try to declare a trigger here?";
- strict-fails-and-lax-matches is a third finding with its own wording, naming
  the form that was found and the form that is required.

The lax pattern must never feed the evaluator. Its only consumer is the message,
which is what keeps a widened *detector* from becoming a widened *parser*.

## This vocabulary already exists in this repository — use it

Three tools here already separate these states, each having learned it
separately:

- `.claude/tools/schedule-health` reports a crontab line with no log redirect as
  *"freshness cannot be checked - cannot-look, not clean"*;
- `.claude/tools/question-speech.py` documents its exit 1 so *"the caller can
  tell 'not found' from 'found but empty'"*;
- `.claude/tools/policy-sweep` **dies** when the policy catalogue has no
  recognisable section — *"so its format has changed"* — rather than reporting
  zero rules and exiting clean.

That last one is the sharpest, because a changed format is precisely the case
where a pattern silently matches nothing, and reporting "no rules" would have
been catastrophic and quiet.

So this is not a new principle for this project. It is one the project applies
in three places and omits in a fourth — which is the ordinary way a convention
decays, and the reason a guard is worth auditing against its own siblings rather
than against first principles.

## The general test

For any checker that reports something is missing, ask:

- **What did the check actually establish?** Almost always "my pattern did not
  match", which is a fact about the pattern. Word the message as that fact when
  the two cannot be distinguished, or add the detector that distinguishes them.
- **What would a reader who HAS done the thing conclude?** If the answer is
  "that the tool is wrong", the message is training its audience to skim.
- **Does one return value carry two meanings?** `undef`, empty list, zero and
  `False` are all routinely made to mean both "none" and "could not tell".
  That collapse in the *function* is what forces the collapse in the *message*.

Related: [[reporting-a-judgement-you-did-not-make]] — the same failure across a
producer/reporter pair, where a judgement the producer made is dropped by the
tool people actually read, and which likewise ends in three states rather than
two. [[assertions-that-cannot-fail]] — a check whose subject is empty reports
success for the same underlying reason.
