# Repo rules

- Never add Claude (or any AI) as author or co-author in commits or pull requests. No `Co-Authored-By`, `Claude-Session`, or "Generated with Claude" lines.

## Workflow

- Never commit directly to `main`. Every change goes on a branch (`feature/<short-name>` or `fix/<short-name>`), then a pull request into `main`.
- Merging into `main` publishes a release (see `.github/workflows/release.yml`), so only merge after the change has been tried in SketchUp. Merging is the user's call.
- A PR that changes the extension (`print_prep.rb` or `print_prep/`) bumps `ext.version` in `print_prep.rb`: patch for fixes, minor for features. Without a bump, the existing release's file is silently replaced.
- PR descriptions say what changed and list what to check by hand in SketchUp.
