# Repo Sync

A menu bar app that keeps the main branch current in every GitHub repo inside a folder.

On a schedule (hourly by default) it fetches each repo and fast-forwards its default branch when that's safe. It never touches your feature branches, never stashes, and never merges. If the default branch has uncommitted changes or local commits, it skips that repo and tells you why.

## Get the app

1. Download the `.zip` from the [latest release](https://github.com/erikmaday-charterup/repo-sync/releases/latest) and unzip it.
2. Drag **Repo Sync** into your Applications folder and open it.
3. macOS will say it can't verify the app. Click **Done**, then open **System Settings**, go to **Privacy & Security**, scroll down, click **Open Anyway** next to Repo Sync, and confirm.

<!-- Screenshot: System Settings > Privacy & Security > Open Anyway (Erik to add) -->

You only need to do this once. After that, Repo Sync updates itself from the menu bar.

## What setup does

The first time you open it, Repo Sync walks you through setup:

- Offers to move the app into your Applications folder.
- Checks your Mac for git and GitHub's `gh` tool, signed in to GitHub, and shows what to run for anything missing (see GitHub access below).
- Asks which folder your repos live in (`~/Code` by default).
- Lists the repos in your GitHub organizations so you can tick the ones you want. Any you don't have yet are cloned for you.

From then on it keeps the default branch current on a schedule. It never deletes a repo folder, never clones over a folder that already exists, and never touches a branch other than the default branch.

## Build from source

Needs macOS 13 or later and Xcode or its command line tools. Build with Xcode 26 or later to get the Liquid Glass look; the build script uses /Applications/Xcode.app when it's there.

```bash
scripts/build-app.sh
open ~/Applications/Repo\ Sync.app
```

The first time it reads a folder in Desktop or Documents, macOS asks for permission. The build is signed ad hoc, so on another Mac you need the Open Anyway step from "Get the app" above.

## GitHub access

Repo Sync needs git and GitHub's `gh` tool, with `gh` signed in to GitHub. It borrows gh's login (`gh auth token`) each time it lists your organizations' repos or checks for updates, and keeps no token of its own. Cloning and syncing run plain git, so git needs a GitHub login too.

If something's missing, setup shows a checklist with the command to copy:

```bash
xcode-select --install   # git, through Apple's command line tools (setup has an Install git button)
brew install gh          # or download it from https://cli.github.com
gh auth login            # sign gh in to GitHub
gh auth setup-git        # let git use gh's login
```

Repo Sync never changes your git or gh setup; it only tells you what to run. Background syncs never show a password prompt. If gh is later signed out or uninstalled, the panel says what's wrong and which command fixes it, and existing repos keep syncing as long as git can still reach GitHub.

## Command line

```bash
# sync once without the menu bar and print each repo's result
"~/Applications/Repo Sync.app/Contents/MacOS/RepoSync" --sync-once ~/Code
```

The log is at `~/Library/Logs/RepoSync.log`.
