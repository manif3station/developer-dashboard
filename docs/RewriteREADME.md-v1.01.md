# RewriteREADME.md-v1.01

## Goal

Make the project README useful as a first stop for people who want to understand,
install, configure, and use Developer Dashboard. Keep it in UK English and describe
the product as an independent developer tool. Mention implementation languages
only where they help someone install, extend, or embed it.

## Review findings

- The README is generated from the POD in `lib/Developer/Dashboard.pm`; edits to
  the generated README alone would be lost on the next sync.
- The opening overview mixes the product description with deployment details,
  platform workarounds, watchdog behaviour, private helper staging, and
  performance claims. This buries the basic purpose and repeats detail explained
  in later chapters.
- The document opens with feature and implementation internals before reaching
  installation and first-run instructions. Readers have to scan a long technical
  introduction before finding a practical starting point.
- Many paragraphs exceed 100 words. Some combine several independent behaviours;
  others are release-gate history, benchmark notes, or implementation rationale
  better grouped in advanced or maintainer material.
- Examples are sometimes embedded in prose or run together. Commands, config
  fragments, and explanatory text need distinct blocks.
- Project terminology, command names, paths, defaults, access rules, and platform
  claims must be checked against the current source before being retained. The
  existing README includes historical versioned measurements and internal gate
  results that are not stable product instructions.

## Rewrite decisions

- Lead with the independent product name and its uses; keep implementation
  language details in installation and embedding guidance.
- Replace the implementation-heavy opening with a short overview, a six-item
  capability map, and direct links to installation and first run.
- Put the practical manual before the feature reference and API namespace
  material, so readers can reach setup without scanning advanced topics first.
- Split 52 long POD paragraphs into shorter paragraphs. The remaining long
  rendered blocks are command examples or bullet lists, which are already
  visually structured.
- Keep detailed feature and platform behaviour in its relevant reference
  section rather than repeating it in the product overview.
- Move the historical Problem 48 verification record under maintainer guidance
  and label it as an archived 6.03 record so its run-specific measurements are
  not mistaken for current performance or test status.

## Proposed reader order

1. Product overview and a short capability map.
2. User guide: installation and first run, followed by pages, collectors,
   browser access, container workflows, and other everyday tasks.
3. Feature reference for detailed browser and runtime behaviour.
4. API/module reference and FAQ.
5. Embedding and maintainer guidance, including development and verification.

Use short paragraphs, descriptive subheadings, and lists where they make choices
or steps easier to scan. Keep detailed technical reference available, but move
implementation history and narrow benchmark reports out of the primary reader
path. Regenerate `README.md` from the POD after source edits.

## Alignment review

- Verified the documented default web bind (`0.0.0.0:7890`) against
  `Developer::Dashboard::Web::Server` and the loopback/helper trust split against
  `Developer::Dashboard::Auth`.
- Confirmed the README version (`6.04`) matches the main POD, version module,
  and `dist.ini` in the current worktree.
- Corrected the `Installation` cross-reference so it targets this README rather
  than an unrelated MetaCPAN page.
- Removed implementation-status detail from the opening overview and grouped
  contributor instructions under a maintainer heading.
