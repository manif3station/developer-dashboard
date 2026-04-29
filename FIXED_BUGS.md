# Fixed Bugs

## 3.19 - Optional browser workspace extraction from core

- Fixed the core/runtime boundary so the default Developer Dashboard
  distribution no longer claims, seeds, or ships an optional browser workspace
  that has been moved out of core.
- Fixed the shipped manuals, release metadata, and test guides so they now
  describe only the browser pages and verification paths that still belong to
  the core distribution.

## 3.19 - Container restart and stop listener ownership

- Fixed `dashboard stop` and `dashboard restart` so they can still find and
  terminate the real serving pid after the managed web process renames itself
  into the underlying `starman master` listener shape.
- Fixed container lifecycle control so saved web-state listener ports are used
  to recover the active listener pid, preventing Docker runs from leaving the
  web listener behind or losing restart ownership after startup.
