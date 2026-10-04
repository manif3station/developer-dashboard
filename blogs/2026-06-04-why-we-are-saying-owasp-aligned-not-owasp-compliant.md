# Why We Are Saying OWASP-Aligned, Not OWASP-Compliant

There is a tempting sentence every project wants to write once its security work starts to feel serious:

> We are now OWASP compliant.

We are not going to say that about Developer Dashboard.

Not because the project is soft on security.

Not because the project only did a token checklist pass.

And not because the recent work was small.

We are not saying it because the sentence is too broad, too easy to misunderstand, and too easy to overclaim.

What we can say now is more precise, and in practice much more useful:

Developer Dashboard now has a full OWASP-aligned security gate.

That is a real change.

## The Important Distinction

“OWASP compliant” sounds like one clean badge.

But OWASP is not one single universal pass/fail stamp for local developer tools. In real use, teams usually mean one of these:

- aligned to OWASP Top 10 threat categories
- assessed against OWASP ASVS at a stated level
- reviewed with OWASP testing ideas in mind
- externally audited against a documented scope

Those are not the same thing.

If we said “OWASP compliant” without qualification, it would imply a stronger and more formal claim than the project can honestly make today.

That is exactly the kind of language good security work should avoid.

So the project is taking the stricter route:

- no vague compliance wording
- explicit OWASP scope
- explicit gate criteria
- executable tests for the gate itself

## What Actually Changed

The recent work did not just add a sentence to a document.

It turned OWASP alignment into a repo-level delivery rule.

### 1. OWASP is now a full gate, not a baseline nod

Developer Dashboard now treats OWASP as a hard release and verification gate.

That gate now explicitly covers:

- OWASP ASVS 5.x chapter coverage from `V1` through `V14`
- OWASP Top 10 2021 threat mapping from `A01` through `A10`
- Level 2 rigor as the default floor
- Level 3 review for higher-trust changes such as auth, sessions, cryptographic handling, release-signing paths, and externally callable API routes

That is a much more serious posture than “we thought about OWASP while coding.”

## 2. The gate is now executable

This is the part that matters most.

A lot of projects have security language.

Far fewer have security language that breaks the build when it drifts.

Developer Dashboard now has a dedicated regression test for the OWASP gate itself.

That test checks that the repository still carries:

- the full ASVS chapter span
- the full Top 10 span
- the Level 2 and Level 3 policy split
- the required audit commands
- the expected security-sensitive runtime invariants around redirects, cookies, headers, auth ownership, and traversal coverage

That means the project is no longer relying on memory or good intentions to preserve the security gate.

## 3. The runtime checks behind the words are visible

The gate is not just “mention OWASP somewhere.”

It points at concrete repo-side evidence:

- forbidden-library scans
- auth and session checks
- redirect-sanitization checks
- traversal-focused checks
- raw-SQL grep checks
- focused web and SSL regression tests

That is important because security drift often starts in the gap between policy text and what people actually verify.

This work narrowed that gap.

## 4. The claim is stronger because it is narrower

There is a useful paradox here:

by refusing to say “OWASP compliant,” the project can make a stronger technical claim.

We can now say that Developer Dashboard is:

- OWASP-aligned
- ASVS-gated
- Top-10-mapped
- regression-tested at the repo gate level

That is more believable than a vague compliance slogan, because it tells you what the project is actually doing.

## What This Does Not Mean

This does not mean:

- every security question is solved forever
- the runtime has no future hardening left
- the project has a formal third-party certification
- every deployment context has been externally assessed

It also does not mean the project should stop improving.

One obvious example is content security policy hardening. The project already sets security headers, but there is still a difference between “present and useful” and “as locked down as possible.” Enterprise posture is a moving target, not one commit.

## Why This Matters

Developer Dashboard is not trying to become a toy that looks secure in screenshots.

It is trying to become a local platform that can be trusted more seriously:

- by one operator on one laptop
- by layered project runtimes
- by browser-facing helper flows
- by machine-driven Ajax routes
- by release and packaging workflows

That requires security language that is accurate enough to survive scrutiny.

So the project is choosing the sentence that can be defended:

Developer Dashboard now enforces a full OWASP-aligned security gate.

That is not marketing inflation.

That is the beginning of a security posture the project can keep proving every time the repository changes.
