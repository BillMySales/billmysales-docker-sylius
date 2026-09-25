Sylius Docker stack
===================

Docker Compose stack for [Sylius](https://sylius.com) (open source e-commerce
framework on Symfony: shop, admin panel, Shop and Admin APIs), usable for
local development and for simple production deployments (a single server).
Maintained by [BillMySales](https://www.billmysales.com).

| Component   | Image                                        | Default version              |
|-------------|----------------------------------------------|------------------------------|
| Web server  | `caddy:<ver>-alpine`                         | 2.11                         |
| Sylius      | own image (`image/`) on `php:<ver>-fpm-alpine` | 2.2.9 (Sylius-Standard 2.2.4, PHP 8.5) |
| Database    | `mariadb:<ver>`                              | 11.4 (LTS)                   |
| Mailpit     | `axllent/mailpit` (optional, dev)            | v1.31                        |

Sylius is distributed as a Composer project to build a shop with
(Sylius-Standard), not as a production image: the only official image
(`ghcr.io/sylius/sylius-php`) is a PHP base, and Sylius-Standard's own
compose file is for development (bind mounts, Xdebug, Node). So
`image/Dockerfile` builds one (about 3 minutes, image ~390 MB, amd64 and
arm64; tested on arm64):

1. `composer create-project sylius/sylius-standard` at
   `SYLIUS_STANDARD_VERSION`, with `sylius/sylius` pinned to
   `SYLIUS_VERSION`, plus a small overlay (`image/overlay`: stack settings, a
   setup command, Spanish email texts).
2. A Node stage builds the shop and admin assets (`yarn build:prod`,
   Webpack Encore).
3. The final stage on `php:8.5-fpm-alpine` (PHP 8.5: tested by Sylius's CI)
   with the required extensions (exif gd intl pdo_mysql zip, apcu; OPcache is
   built into PHP 8.5), `icu-data-full` (Alpine's ICU only has English: CLP
   prices showed as `CLP 9,990` instead of `$9.990`), assets installed and the
   Symfony cache warmed up.

MariaDB 11.4 is the version Sylius's CI tests with.

Requirements
------------

- Docker Engine 24+ with the Compose v2 plugin (`docker compose`, 2.20+).
- About 1 GB of disk for the images; 512 MB of RAM for the stack.
- Development: ports 8112, 8412 and 8025 free on the host.
- Production: a server with ports 80 and 443 reachable, and a DNS record for
  the site's domain pointing to it.

Quick start (development)
-------------------------

```shell
cp .env.dev.example .env
docker compose up -d --build   # builds the image the first time (~3 minutes)
docker compose logs -f setup   # wait for "==> Done"
```

- Shop: http://localhost:8112 (redirects to `/es_CL/`).
- Admin: http://localhost:8112/admin (user `admin@example.com`, password
  `admin12345`).
- APIs: http://localhost:8112/api/v2/docs (Shop and Admin API).
- Mailpit (every email Sylius sends): http://localhost:8025

Production
----------

```shell
cp .env.prod.example .env
# Fill in SYLIUS_URL, SITE_ADDRESS, APP_SECRET, JWT_PASSPHRASE, DB_PASSWORD,
# DB_ROOT_PASSWORD, SYLIUS_ADMIN_EMAIL, SYLIUS_ADMIN_PASSWORD and the SMTP_*
# values.
docker compose up -d --build
```

- With `SITE_ADDRESS` set to the domain, Caddy gets a Let's Encrypt certificate
  and renews it automatically (certificates live in the `caddy_data` volume).
- Behind another TLS-terminating proxy, use `SITE_ADDRESS=:80`.
- Compose refuses to start while a required value is missing.
- The `backup` profile is enabled by default in the production template.
- Behind an existing Traefik (no host ports), use `overrides/traefik.yaml`
  (see [Overrides](#overrides)).
- The image is built on the server (or build it elsewhere, push it to a
  registry and set `SYLIUS_IMAGE`).

Services
--------

| Service   | Profile   | Role                                                              |
|-----------|-----------|-------------------------------------------------------------------|
| `db`      |           | MariaDB, data in the `db_data` volume.                            |
| `setup`   |           | One-shot job (`scripts/setup.sh`), runs on every `up`.            |
| `php`     |           | PHP-FPM with Sylius (internal port 9000).                         |
| `worker`  |           | Symfony Messenger worker (asynchronous messages, e.g. catalog promotions). |
| `cron`    |           | `sylius:cancel-unpaid-orders` and `sylius:remove-expired-carts` every `CRON_INTERVAL`. |
| `caddy`   |           | TLS, static files, the only published ports (80, 443).            |
| `console` | `tools`   | Sylius's console (`bin/console`), as `www-data`.                  |
| `backup`  | `backup`  | Database dump + uploads + keys on a schedule.                     |
| `mailpit` | `mailpit` | Development SMTP server that catches all mail.                    |

The code lives in the image (immutable). Caddy serves the static files from
the `public` volume (a copy of the image's `public/`, refreshed by `setup`
when the image changes) and the uploads from the `media` volume; everything
else goes to `index.php` (PHP-FPM). No PHP file other than `index.php` runs.

### What `setup` does

- Keys, generated once in the `keys` volume: the JWT key pair of the APIs
  (protected by `JWT_PASSPHRASE`) and the payment encryption key (Sylius
  encrypts the payment gateways' credentials with it). **Back them up**: the
  `backup` service includes them.
- Empty database: `sylius:install:database` (schema and migrations, no sample
  data). Otherwise: pending Doctrine migrations (a new version).
- `app:stack-setup` (`image/overlay/src/Command/StackSetupCommand.php`):
  - the admin user (`SYLIUS_ADMIN_EMAIL`, `SYLIUS_ADMIN_PASSWORD`, with Admin
    API access), if missing;
  - each one created only if missing (then kept as edited in the admin):
    locale `es_CL`, currency CLP, country Chile and its zone, tax category
    "Afecto" with IVA 19% included in prices, the `default` channel using
    them, a free "Despacho" shipping method and a "Transferencia bancaria"
    (offline) payment method, so checkout works.
- Copies the image's public files to Caddy's volume when the image's build id
  changes.

Common commands
---------------

```shell
docker compose ps                        # status: every service "healthy", setup "Exited (0)"
docker compose logs -f php worker        # logs (Sylius logs to stderr)
docker compose exec db mariadb -usylius -p sylius   # SQL shell
docker compose run --rm console          # Sylius commands (profile "tools")
docker compose run --rm console sylius:admin-user:change-password
docker compose down                      # stop, keep data
docker compose down -v                   # stop and DELETE all data
```

Store and locale
----------------

- The store's locale (`SYLIUS_LOCALE`, `es_CL`) is also Sylius's `locale`
  parameter, set **in the image at build time**: Sylius requires product
  translations in it (with the default `en_US`, products created through the
  API without an English name are rejected). The image tag includes it; set
  it before the first install.
- Prices are integers in the currency's minor unit: CLP has none, so `9990`
  is $9.990. With IVA included in prices, Sylius computes the tax inside them.
- Sylius translates its shop and admin to Spanish (`es`); the 31 email texts
  missing upstream are in `image/overlay/translations/messages.es.yaml`.
- The channel has no hostname (like Sylius's installer): it answers on any
  address, and links in emails use `SYLIUS_URL`. With a hostname, Sylius
  builds links as `https://<hostname>`, without a port.
- A product enabled without variants makes the shop's product lists fail
  (HTTP 500, "Product has no variants"): Sylius's behavior; products created
  in the admin always get one.

Emails
------

Sylius sends them itself (Symfony Mailer): order and shipment confirmations,
account verification, password resets (shop and admin), contact form.
SMTP comes from `SMTP_*` (`SMTP_SECURE`: empty or `tls` = STARTTLS when the
server offers it, `ssl` = SMTPS, `none` = never TLS); without `SMTP_HOST`
emails are discarded. The sender is `SMTP_FROM` / `SMTP_FROM_NAME`.

Payments
--------

Sylius-Standard includes the official Adyen, Mollie and PayPal plugins (kept
as upstream ships them). The shop pages load Adyen's and Mollie's JavaScript
from their CDNs even when no such payment method is configured. Removing a
plugin means customizing the image (see below).

Backups
-------

With the `backup` profile, the `backup` service writes `<timestamp>-db.sql.gz`
and `<timestamp>-files.tar.gz` (uploads and keys) to the `backups` volume (or
`./data/backups` with `overrides/local-dirs.yaml`) at start and then every
`BACKUP_INTERVAL_HOURS`, and deletes files older than `BACKUP_KEEP_DAYS`.
Files are readable by their owner only (they contain the keys).

```shell
docker compose run --rm --no-deps backup now                  # back up now
docker compose run --rm --no-deps backup list                 # list timestamps
docker compose stop php worker cron                 # stop the app first
docker compose run --rm --no-deps backup restore <timestamp>  # database, uploads and keys
docker compose up -d
```

`--no-deps` keeps the command from starting `setup` first (with damaged
data `setup` fails and the restore would never run); the database must
be running (`docker compose up -d db` if the stack is down).

A restore drops every table first, so nothing created after the backup
remains.

Upgrades
--------

Back up first, read Sylius's `UPGRADE-2.x.md` for a new minor version, then
change `SYLIUS_VERSION` (and `SYLIUS_STANDARD_VERSION` when a newer
Sylius-Standard is out) in `.env` and run `docker compose up -d --build`: the
image is rebuilt on the new version and `setup` runs the migrations and
refreshes the public files before PHP-FPM starts. Rebuild regularly
(`docker compose build --pull`) for PHP and Alpine security fixes.

Composer 2.9 refuses to install versions with known security advisories:
old Sylius versions (e.g. 2.2.0) no longer build, which is intended.

Customizing the image
---------------------

The image is a Sylius-Standard project: plugins are Composer packages
(`composer require` in `image/Dockerfile`, then registered in
`config/bundles.php` through `image/overlay`), and themes, templates,
translations and services go in `image/overlay`, copied over the project
before `composer update`. Then `docker compose up -d --build`. A BillMySales
integration would be a Sylius plugin (a listener of the order's state
machine) or a client of the Admin API.

Overrides
---------

Optional compose files in `overrides/`, enabled with `COMPOSE_FILE` in `.env`
(several are combined with `:`). Each file documents its variables.

```shell
COMPOSE_FILE=compose.yaml:overrides/traefik.yaml:overrides/local-dirs.yaml
```

| File                        | Purpose                                                            |
|-----------------------------|--------------------------------------------------------------------|
| `overrides/traefik.yaml`    | Publish through an existing Traefik on a shared external network:  |
|                             | no host ports, Traefik terminates TLS (`TRAEFIK_HOST`, ...).       |
| `overrides/local-dirs.yaml` | Database, keys, uploads, public files, Caddy and backups in local  |
|                             | directories (`DATA_DIR`, default `./data`) instead of volumes.     |

A local `compose.override.yaml` (gitignored) is also loaded automatically by
Docker Compose, for changes specific to one machine.

Configuration
-------------

Every variable is documented in `.env.prod.example`. Main groups:

- **Site and network**: `SYLIUS_URL`, `SITE_ADDRESS`, `HTTP_BIND`,
  `HTTP_PORT`, `HTTPS_PORT`, `TIMEZONE`.
- **Credentials**: `APP_SECRET`, `JWT_PASSPHRASE`, `DB_PASSWORD`,
  `DB_ROOT_PASSWORD`, `SYLIUS_ADMIN_EMAIL`, `SYLIUS_ADMIN_PASSWORD`
  (required).
- **Store** (created if missing): `SYLIUS_STORE_NAME`, `SYLIUS_CURRENCY`,
  `SYLIUS_COUNTRY`, `SYLIUS_ZONE_NAME`, `SYLIUS_TAX_*`,
  `SYLIUS_PRICES_INCLUDE_TAX`, `SYLIUS_SHIPPING_NAME`, `SYLIUS_PAYMENT_NAME`.
- **Versions**: `SYLIUS_VERSION`, `SYLIUS_STANDARD_VERSION`, `SYLIUS_LOCALE`,
  `PHP_VERSION`, `MARIADB_VERSION`, `CADDY_VERSION`, ...
- **Mail**: `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURE`, `SMTP_USER`,
  `SMTP_PASSWORD`, `SMTP_FROM`, `SMTP_FROM_NAME`.
- **PHP, resources and logs**: `PHP_*`, `PHP_FPM_*`, `*_MEMORY_LIMIT` per
  service, `UPLOAD_MAX_SIZE`, `CRON_INTERVAL`, `LOG_MAX_SIZE`, `LOG_MAX_FILE`.

Notes:

- Production settings: `APP_ENV=prod`, debug off, PHP errors logged (never
  displayed unless `PHP_DISPLAY_ERRORS=On`), OPcache without file checks.
  Sylius's logs go to stderr (`docker compose logs`) instead of files inside
  the container; deprecation notices are dropped.
- Symfony trusts `X-Forwarded-*` from its direct peer, Caddy
  (`SYMFONY_TRUSTED_PROXIES=REMOTE_ADDR`), which sends the real client IP
  and scheme and never passes what a client sent (it drops
  `X-Forwarded-Port`): links and secure cookies follow the public
  `https://` address behind Caddy and Traefik, also for public client IPs
  (with `private_ranges`, the admin redirected to `http://` for them).
- The Shop and Admin APIs are enabled (Sylius-Standard enables them only in
  development). Admin API: `POST /api/v2/admin/administrators/token` with the
  admin's email and password returns a JWT.
- From inside the containers, the host machine is reachable as
  `host.docker.internal`.

Security
--------

- Client IP headers: PHP gets only the real client IP (as Caddy sees it) in
  `REMOTE_ADDR`, `X-Forwarded-For` and `X-Real-IP`, and no `Client-Ip`,
  `Cf-Connecting-Ip` or `X-Forwarded-Port` (a client could forge them), so
  Symfony can trust Caddy's headers as they come; set like in the other PHP
  stacks.
- No default secrets: compose fails if the required passwords and secrets are
  missing. The development template uses public values; never use it on a
  server.
- PHP runs as `www-data`; only Caddy (and Mailpit in development) publishes
  ports; PHP-FPM and MariaDB are internal. `HTTP_BIND` defaults to
  `127.0.0.1`.
- Caddy only runs `index.php`, blocks dotfiles and serves nothing else from
  the project (code, `.env`, keys are outside the web root). Security headers
  are added when Sylius doesn't send them; PHP's version is not exposed.
- The keys volume is private (mode 700, `www-data`).
- Not included: a web application firewall or off-site backup copies.

Validation
----------

What was checked for this stack (2026-09-24):

- Clean start (`down -v` + `up -d`, image built) in about 35 s: every service `healthy`,
  `setup` `Exited (0)`; a second run makes no changes.
- Shop (`/es_CL/`, in Spanish) and admin (login form with CSRF, dashboard,
  orders, products, channels, customers, tax rates) with all their CSS, JS and
  fonts; Admin API with a JWT, Shop API.
- A full checkout through the Shop API: product in CLP, cart, address,
  shipping, bank transfer, order: 2 × $9.990 = $19.980 with IVA included;
  amounts shown as `$19.980` in the admin.
- Emails through SMTP to Mailpit in Spanish (order confirmation, account
  verification), with links to `SYLIUS_URL`.
- Product image upload; thumbnails generated by Sylius, then served by Caddy.
- Backup and restore (data created after the backup is gone; uploads and
  keys back).
- Upgrade 2.2.0 → 2.2.9 with data: 15 migrations, products and customers
  kept, public files refreshed, a new order afterwards.
- HTTPS with `SITE_ADDRESS=localhost` (links, emails and cookies `Secure` on
  `https://localhost:8412`); overrides: Traefik v3.6 routing with no host
  ports (client IP kept), local directories (fresh install, owners `82`).
- Not tested: issuing a real Let's Encrypt certificate (needs a public
  domain), SMTPS/STARTTLS with a real provider, Adyen/Mollie/PayPal.

Resource usage
--------------

Idle, after a few requests: PHP-FPM ~140 MiB, worker ~110 MiB, MariaDB
~135 MiB, Caddy ~16 MiB, cron ~6 MiB (about 400 MiB in total). Image ~390 MB.

License
-------

[MIT](LICENSE).
