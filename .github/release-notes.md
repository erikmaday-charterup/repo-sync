## First install

1. Download the `.zip` below and unzip it.
2. Drag **Repo Sync** into your Applications folder and open it.
3. macOS will say it can't verify the app. Click **Done**, then open **System Settings**, **Privacy & Security**, scroll down and click **Open Anyway** next to Repo Sync, and confirm.

You only do this once. After that, Repo Sync updates itself from the menu bar.

## What it needs

Repo Sync uses git and GitHub's `gh` tool, signed in to GitHub. Setup checks for both and shows what to run if something's missing:

```bash
brew install gh      # or download it from https://cli.github.com
gh auth login        # sign gh in to GitHub
gh auth setup-git    # let git use gh's login
```
