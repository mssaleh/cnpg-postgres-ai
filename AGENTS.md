# Repository instructions

## Git workflow (mandatory)

- This is a single-branch repository. `main` is the only allowed local or
  remote branch.
- Never create, push, or retain any other branch.
- Never open or use pull requests for this repository.
- Make commits directly on `main` and push them directly to `origin/main`.
- If a non-`main` branch is discovered, first verify that any intended changes
  are already present on `main`, then delete the extra local and remote refs.
- Build and publish release images only from commits on `main`.
