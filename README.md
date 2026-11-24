# Publish theme to DataSide

This GitHub Action publishes a built WordPress theme to a DataSide site. It uploads the theme, waits while the site restarts with it, and reports whether the site accepted it. If the site rejects the theme, the site keeps its previous theme version and the run fails with the reason.

For the full setup steps, read [Maintaining your DataSide WordPress theme from GitHub](docs/customer-theme-guide.md). This README covers only the action.

## Workflow file

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
          bind-code: ${{ inputs.bind-code }}
```

The job needs `permissions: id-token: write`. The action proves your repository and branch to DataSide with the run's GitHub OIDC token, and an action cannot grant itself that permission. The action needs no secrets.

To pin an exact version, replace `@v1` with the full commit SHA of a release. The `v1` tag moves to each new `v1.x.y` release.

## Inputs

| Input | Required | Meaning |
|---|---|---|
| `site` | yes | The site's address, for example `wordpress-prod.123456789012.app.dataside.cloud`. It must end in `.app.dataside.cloud`. |
| `path` | yes | The directory that holds the built theme, relative to the workspace. It must have `style.css` at its top level. |
| `bind-code` | no | The code from the DataSide email. Enter it only in the one manual run that links the repository to the site. |

## Outputs

| Output | Meaning |
|---|---|
| `publish-id` | The publish ID of the theme version that this run published. Empty if the run did not publish. |
| `status` | `good` if the site accepted the theme version, `rejected` if it did not. Empty if the run stopped before a result. |

## Linking the repository to a site

Each site accepts themes from one repository and one branch. You link them once per site:

1. In the repository's **Actions** tab, choose **Run workflow** on the publishing branch, with the `bind-code` box empty. The run fails with "Binding requested", and your DataSide account email receives a code.
2. Choose **Run workflow** again on the same branch, and paste the code into the `bind-code` box. This run links the repository to the site and publishes the theme.

The code is valid for one use within 24 hours. After the link exists, every push to the publishing branch publishes. Do not put the code in the workflow file or in a repository secret; enter it only as the manual-run input.

## Failure messages

| Message | Meaning and what to do |
|---|---|
| Add `permissions: id-token: write` to the job. | The job cannot request an OIDC token. Add the permission to the job, as in the sample. |
| This runner has no `jq` (or `curl`, `tar`). | A self-hosted runner lacks the tool. Install it, or use a GitHub-hosted runner. |
| The site must be a DataSide host ending in .app.dataside.cloud | The `site` input is wrong. Use the site address from DataSide. |
| The path '...' is not a directory. / has no style.css at its top level. | The `path` input does not point at the built theme. Check your build's output directory. |
| The theme holds a symbolic link, which DataSide refuses | Replace the named link with a regular file or directory. |
| The packed theme is ..., over the 50 MB limit. | Remove files the theme does not need at run time, for example source files and `node_modules`. |
| Binding requested. DataSide has emailed a code... | The site has no link to a repository yet. Run the workflow again by hand with the code, as in "Linking the repository to a site". |
| No binding request matches this code. | The site has no link, and no code request exists for this repository and branch. The code may come from a run on another branch. Run the workflow by hand without `bind-code` to request a new code. |
| The theme API refused the binding code: ... | The code is wrong, expired, or was tried too many times. The message says which. Request a new code. |
| The theme API refused the publish: ... | The site refused the theme. The message gives the reason, for example that the site is linked to another repository or branch. |
| The theme API refused the publish for 20 minutes: ... | An earlier theme version stayed on trial for the whole time. The message gives the reason. Check the site, then run the workflow again. |
| S3 refused the upload: HTTP ... | The upload failed. Run the workflow again. If it fails again, contact DataSide support. |
| DataSide rejected theme version ...: *reason* | The site checked the theme and refused it, for example `php-lint` for a PHP syntax error. The run annotates the file and line when known. The annotation points at the built theme, which is your source file only when the theme needs no build. Fix the cause and push again. |
| No result after 20 minutes. | The site did not report a result in time. Check the site, then run the workflow again. |

If a run fails for another reason, contact DataSide support with the link to the failed workflow run.

## Licence

MIT. See [LICENSE](LICENSE).
