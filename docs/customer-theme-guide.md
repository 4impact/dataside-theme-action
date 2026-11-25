# Maintaining your DataSide WordPress theme from GitHub

You keep your WordPress theme in your own GitHub repository. A GitHub Actions workflow in that repository builds the theme and sends it to DataSide. DataSide installs it on your site and reports the result in the same workflow run. Once DataSide has turned on theme publishing for your site, no one at DataSide needs to act when you publish.

**Before you start, you need:**

- DataSide to have turned on theme publishing for each site (ask DataSide support);
- a GitHub repository that holds your theme;
- the address of each DataSide site, for example `wordpress-prod.123456789012.app.dataside.cloud`;
- access to the inbox of your DataSide account email (the address you sign in to the DataSide portal with);
- an administrator login for WordPress admin on each site.

**Time:** about 15 minutes per site. **If something fails:** contact DataSide support with the link to the failed workflow run.

## Set up once per site

1. Copy the DataSide template to `.github/workflows/dataside-theme.yml` in your repository.
2. In that file, set the site address, the publishing branch, the directory that holds your built theme, and `theme`, your theme folder name. For example, the `preprod` branch publishes to the preprod site and `main` publishes to the prod site. To replace a theme that the site already uses, set `theme` to that theme's folder name.
3. In that file, add your build commands (for example `npm ci && npm run build`) before the DataSide publish action, `4impact/dataside-theme-action`. If your theme needs no build, add none.
4. Commit and push the file.
5. In the repository's **Actions** tab, choose **Run workflow** on the publishing branch, with the `bind-code` box empty. The run stops, and your DataSide account email receives a one-time code.
6. Choose **Run workflow** again on the same branch, and paste the code into the `bind-code` box. This run links the repository to the site and publishes your theme for the first time.
7. If the site's active theme already has the name in `theme`, do nothing. Otherwise, in WordPress admin, open **Appearance > Themes** and activate the theme of that name once.

The code is valid for one use within 24 hours. If nobody in your organisation asked for a code, ignore the email.

```mermaid
flowchart LR
    A[Add the workflow file<br/>from the template] --> B[Run workflow<br/>with no code]
    B --> C[DataSide account email<br/>receives a code]
    C --> D[Run workflow again<br/>with the code]
    D --> E[Theme is published;<br/>activate the theme folder you set,<br/>if it is not already active]
```

### Sample workflow file

This sample is for a theme that builds with npm into `dist/theme`. The `preprod` branch publishes to the preprod site, and `main` publishes to the prod site. Your file has your own site addresses, branches, build commands and directory.

```yaml
name: Publish theme to DataSide

on:
  push:
    branches: [main, preprod]           # the publishing branches
  workflow_dispatch:                    # manual runs, used once per site to link it
    inputs:
      bind-code:
        description: Code from the DataSide email
        required: false

jobs:
  publish:
    runs-on: ubuntu-latest
    permissions:
      id-token: write                   # lets DataSide confirm the repository and branch
      contents: read
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false

      # Your build. Leave these two steps out if your theme needs no build.
      - uses: actions/setup-node@v4
        with:
          node-version: 22
      - run: npm ci && npm run build    # writes the built theme to dist/theme

      - uses: 4impact/dataside-theme-action@v1
        with:
          site: >-
            ${{ github.ref_name == 'main'
                && 'wordpress-prod.123456789012.app.dataside.cloud'
                || 'wordpress-preprod.123456789012.app.dataside.cloud' }}
          path: dist/theme
          theme: my-theme                       # your theme folder name
          bind-code: ${{ inputs.bind-code }}
```

## Publish a change

Push to the publishing branch. The workflow run builds the theme, sends it to DataSide, and waits while your site restarts with it. This usually takes 2 to 5 minutes. The result of the run tells you the outcome:

- **Green tick:** DataSide installed the new theme version under your `theme` name. WordPress serves it while that name is the active theme.
- **Red cross:** DataSide rejected the new theme version, and your `theme` name keeps its newest good theme version, if it has one. The run log gives the reason, for example a PHP syntax error with the file and line. Fix the cause and push again.

GitHub emails you when a run you started fails. To roll back a change, revert the commit and push.

```mermaid
flowchart LR
    P[Push to the<br/>publishing branch] --> R[Workflow run:<br/>build, then publish]
    R --> S[Site restarts and<br/>checks the new theme]
    S -->|checks pass| G[Run succeeds:<br/>theme version installed under its name]
    S -->|checks fail| F[Run fails with the reason:<br/>theme name keeps its newest good version]
```

## Change the theme name

Push with a new `theme` name to publish under that name. WordPress keeps using the old name until an administrator activates the new name in **Appearance > Themes**.

A green tick for a name that is not active covers only the file checks. The site's restart checks do not load that theme. Check the site straight after you activate the new name. To fix a fault, push a fixed theme version.

## What your built theme must have

- `style.css` at the top level of the built theme directory, with a `Theme Name:` header.
- PHP files that pass `php -l` (the PHP syntax check) on PHP 8.4.
- Regular files and directories only: no symbolic links.
- No need to write files inside the theme directory while the site runs. The site cannot change installed theme files; store generated files in `wp-content/uploads` instead.
- The `vendor/` directory, if the theme uses Composer packages.
- A size of at most 50 MB once packed, and 200 MB unpacked.
- For a child theme: a parent theme that DataSide provides. Another theme that you publish cannot be the parent.
- A `theme` name of lower-case letters, digits, `-` and `_`, starting with a letter or digit, at most 64 characters.
- No dependency on a WordPress plugin.
