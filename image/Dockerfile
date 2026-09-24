# Sylius (Sylius-Standard project) on the official PHP-FPM Alpine image. The
# code, vendor/ and the built assets are immutable in the image; setup copies
# public/ to a volume Caddy serves (uploads are in their own volume).
ARG PHP_VERSION=8.5
ARG NODE_VERSION=22

FROM php:${PHP_VERSION}-fpm-alpine AS php
# PHP extensions required by Sylius 2 (ctype, dom, fileinfo, iconv, json,
# mbstring, openssl, pdo, simplexml, tokenizer and xml are in the base image;
# opcache is built into PHP since 8.5).
RUN set -eux; \
    # icu-data-full: locale data for intl (Alpine ships English only: es_CL
    # amounts would read "CLP 9,990" instead of "$9.990").
    apk add --no-cache su-exec icu-data-full; \
    apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS freetype-dev icu-dev libjpeg-turbo-dev libpng-dev \
        libwebp-dev libzip-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install -j"$(nproc)" exif gd intl pdo_mysql zip; \
    pecl install apcu; \
    docker-php-ext-enable apcu; \
    runDeps="$( \
        scanelf --needed --nobanner --format '%n#p' --recursive /usr/local/lib/php/extensions \
            | tr ',' '\n' | sort -u \
            | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )"; \
    apk add --no-cache --virtual .sylius-rundeps $runDeps; \
    apk del --no-network .build-deps; \
    php -m | grep -qi -e '^gd$' -e '^intl$' -e '^apcu$'
COPY opcache.ini /usr/local/etc/php/conf.d/opcache-recommended.ini

# The project: Sylius-Standard (the official project template) with the
# Sylius core pinned, production dependencies only.
FROM php AS build
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
ARG SYLIUS_STANDARD_VERSION=2.2.4
ARG SYLIUS_VERSION=2.2.9
ENV APP_ENV=prod APP_DEBUG=0 COMPOSER_ALLOW_SUPERUSER=1
RUN set -eux; \
    composer create-project --no-install --no-scripts --no-interaction \
        "sylius/sylius-standard:${SYLIUS_STANDARD_VERSION}" /app; \
    cd /app; \
    composer require --no-update --no-scripts --no-interaction "sylius/sylius:${SYLIUS_VERSION}"
# The stack's additions: configuration from the environment and the setup
# command (app:stack-setup).
COPY overlay/ /app/
# The application's default locale: products and other translatable data
# need a translation in it, and it must be one of the store's locales, so
# it's the store's locale (compiled into the container: a build argument).
ARG SYLIUS_LOCALE=es_CL
RUN set -eux; \
    cd /app; \
    sed -i "s/^    locale: .*/    locale: ${SYLIUS_LOCALE}/" config/parameters.yaml; \
    grep -q "locale: ${SYLIUS_LOCALE}\$" config/parameters.yaml; \
    # Some Sylius-Standard releases ship a composer.lock (with another core
    # version), some don't: update the core and what it needs, keeping the
    # rest of the lock file, or resolve everything without one.
    if [ -f composer.lock ]; then packages="sylius/sylius --with-all-dependencies"; else packages=""; fi; \
    composer update ${packages} --no-dev --no-interaction --prefer-dist --optimize-autoloader --no-scripts; \
    composer show sylius/sylius | grep -q "^versions : \* v${SYLIUS_VERSION}\$"; \
    composer clear-cache

# Assets (Webpack Encore): need the vendor bundles' sources.
FROM node:${NODE_VERSION}-alpine AS assets
WORKDIR /app
COPY --from=build /app /app
RUN yarn install --non-interactive && yarn build:prod

FROM php
ARG SYLIUS_STANDARD_VERSION=2.2.4
ARG SYLIUS_VERSION=2.2.9
ENV APP_ENV=prod APP_DEBUG=0 PHP_OPCACHE_VALIDATE_TIMESTAMPS=0 \
    SYLIUS_VERSION=${SYLIUS_VERSION}
WORKDIR /app
COPY --from=build --chown=www-data:www-data /app /app
COPY --from=assets --chown=www-data:www-data /app/public/build /app/public/build
RUN set -eux; \
    rm -rf node_modules var/cache/* var/log/*; \
    su -s /bin/sh www-data -c 'php -d memory_limit=-1 bin/console assets:install public --no-interaction \
        && php -d memory_limit=-1 bin/console cache:warmup'; \
    # Build id: setup copies public/ to Caddy's volume when it changes.
    printf '%s %s\n' "${SYLIUS_VERSION}" "$(date -u +%Y%m%dT%H%M%SZ)" > /app/public/.build
