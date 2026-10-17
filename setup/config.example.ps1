# config.example.ps1 - copy this to  config.ps1  and fill in YOUR values.
#
#   Copy-Item setup\config.example.ps1 setup\config.ps1
#
# config.ps1 is git-ignored (it's machine/account-specific). bootstrap.ps1 reads it to know WHICH
# GitHub repo is your memory canon. Nothing here is secret - real credentials never live in the repo.

# The private GitHub repo that IS your memory canon. After you click "Use this template" on
# claude-memory-kit, GitHub makes you a repo - put its clone URL here.
$MemRepoUrl = "https://github.com/<your-account>/<your-memory-repo>.git"

# Your git identity (used for the auto-save commits). Leave blank to use your existing global
# `git config user.name` / `user.email`.
$GitUserName  = ""
$GitUserEmail = ""
