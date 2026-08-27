# Projects/ — your code repositories

Each code project you work on lives here as its **own** git repo (its own remote), listed in
`setup/project-repos.txt` so every machine's bootstrap clones it. Keeping them under this one tree means a
single clone carries all your code + its context. This directory is git-ignored in the memory repo (the
project repos version themselves) — see `.gitignore`.

Its resume context lives in `code/<name>/PROJECT.md` (in the memory repo), not here.
