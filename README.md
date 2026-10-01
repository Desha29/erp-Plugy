# PLUGY EV — production web build

This repository contains the compiled Flutter web application. Serve this directory using an HTTPS static web host. The relative base URL supports both a domain root and a repository subpath; use a trailing slash for the application URL.

Build configuration: release mode, APP_ENV=production, Supabase project https://orbovqzenjlyshhiuofx.supabase.co. Only the public Supabase publishable key is included in the browser bundle.

## Backend prerequisites

Uploading these files does not apply database migrations or verify the live backend. Before activating this release, confirm the compatible operations/finance foundations and the additive migrations through 20261018_salesperson_commission.sql are deployed and verified. This includes unified transactions, setup checks, treasury account locations, security hardening, expense assets, product stock editing, opening costs and salesperson commissions. Follow the deployment guides in the source workspace. Never run fresh setup on an existing database.

## Validation

The Flutter production web build completed successfully. Five focused Supabase configuration and salesperson permission tests passed. Static entrypoint and asset checks passed before upload. Live authentication and business transactions were not tested.

## cPanel deployment

The repository-root `.cpanel.yml` deploys only the web application files into the cPanel account's `$HOME/public_html/`. Keep the Git checkout outside `public_html`, for example `$HOME/repositories/erp-Plugy`.

In cPanel, open Git Version Control, manage this repository, and choose Pull or Deploy → Update from Remote → Deploy HEAD Commit. Pull deployment from GitHub is manual; a GitHub push alone does not trigger it. For another domain's document root, adjust DEPLOYPATH in `.cpanel.yml`.

Deployment overwrites matching application files but does not delete unrelated files or copy repository metadata. If another application already occupies the document root, use a dedicated document root instead. No Flutter build is required on the hosting server.
