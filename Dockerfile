FROM php:8-apache

# Which git ref to build from. Defaults to the v1.9.19 tag; MCP support
# (and mcp-loader.php) has existed since v1.9.14, so this tag's git tree
# is complete — unlike the v1.9.19 *release zip*, whose packaging manifest
# apparently missed that file. Use "master" for the latest dev code instead.
ARG WEBCALENDAR_REF=v1.9.19

# --- System packages + PHP extensions -----------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        libsqlite3-dev \
        libzip-dev \
        libpng-dev \
        libjpeg62-turbo-dev \
        libfreetype6-dev \
        libicu-dev \
        libonig-dev \
        libxml2-dev \
    && rm -rf /var/lib/apt/lists/* \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    # Install standard extensions
    && docker-php-ext-install -j"$(nproc)" gd \
    && docker-php-ext-install -j"$(nproc)" zip \
    && docker-php-ext-install -j"$(nproc)" intl \
    && docker-php-ext-install -j"$(nproc)" mbstring \
    # OPcache is built into the PHP core as of PHP 8.5.
    # We check if it's already loaded (as "Zend OPcache") before trying to install it.
    && (php -m | grep -qi "Zend OPcache" || docker-php-ext-install -j"$(nproc)" opcache) \
    # Conditionally install SQLite extensions if they aren't already loaded
    && (php -m | grep -qix pdo_sqlite || docker-php-ext-install pdo_sqlite) \
    && (php -m | grep -qix sqlite3 || docker-php-ext-install sqlite3) \
    && a2enmod rewrite

# --- Clone WebCalendar directly from git ---------------------------------
# Sidesteps the release-zip packaging gap (missing includes/mcp-loader.php
# in the 1.9.19 zip) since the git tree for this tag is complete.
RUN cd / \
    && rm -rf /var/www/html \
    && git clone --depth 1 --branch "${WEBCALENDAR_REF}" \
        https://github.com/craigk5n/webcalendar.git /var/www/html \
    && rm -rf /var/www/html/.git

WORKDIR /var/www/html

# --- Classic installer setup (matches the project's own Dockerfile-php8) -
# Create an empty, world-writable settings.php so the browser-based
# install wizard can write your chosen DB settings (sqlite3 path, admin
# password, etc.) into it on first visit.
RUN mkdir -p data \
    && touch includes/settings.php \
    && chmod 777 includes/settings.php \
    && chown -R www-data:www-data /var/www/html

# --- Seed empty bind-mounts on startup -----------------------------------
# 1. Backup the cloned includes directory to a safe place inside the image
RUN cp -a /var/www/html/includes /opt/includes-backup

# 2. Create an entrypoint script that runs before Apache starts
# Using printf ensures we get clean Unix line endings (\n) and avoids heredoc issues.
RUN printf '#!/bin/bash\nset -e\n\n# If init.php is missing, the host bind-mount is empty.\nif [ ! -f /var/www/html/includes/init.php ]; then\n    echo "Seeding includes directory from image backup..."\n    cp -a /opt/includes-backup/. /var/www/html/includes/\n    chown -R www-data:www-data /var/www/html/includes\nfi\n\n# Execute the main command (apache2-foreground)\nexec "$@"\n' > /usr/local/bin/docker-entrypoint.sh

# 3. Make the script executable and set it as the entrypoint
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["apache2-foreground"]

EXPOSE 80

# Persist the sqlite db file (data/) and the generated settings.php
# (includes/) across rebuilds — see docker-compose.yml.
VOLUME ["/var/www/html/data", "/var/www/html/includes"]