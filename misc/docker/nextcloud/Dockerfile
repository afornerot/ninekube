FROM nextcloud:stable

USER root

# Create directories for plugins
RUN mkdir -p /var/www/html/apps /var/www/html/custom_apps \
    && chown -R www-data:www-data /var/www/html/apps /var/www/html/custom_apps

# Install apps in /usr/src/nextcloud/ (entrypoint copies from there to the volume)
RUN mkdir -p /usr/src/nextcloud/custom_apps

# Install calendar plugin
RUN curl -sL "https://github.com/nextcloud-releases/calendar/releases/download/v6.5.1/calendar-v6.5.1.tar.gz" \
    | tar -xz -C /usr/src/nextcloud/custom_apps/

# Install richdocuments (Collabora connector)
RUN curl -sL "https://github.com/nextcloud-releases/richdocuments/releases/download/v8.6.8/richdocuments-v8.6.8.tar.gz" \
    | tar -xz -C /usr/src/nextcloud/custom_apps/ || true

# Install oidc_login plugin
RUN curl -sL "https://github.com/pulsejet/nextcloud-oidc-login/releases/download/v3.3.1/oidc_login.tar.gz" \
    | tar -xz -C /usr/src/nextcloud/custom_apps/

# Install groupfolders plugin
RUN curl -sL "https://github.com/nextcloud-releases/groupfolders/releases/download/v22.0.3/groupfolders-v22.0.3.tar.gz" \
    | tar -xz -C /usr/src/nextcloud/custom_apps/ || true

# Install contacts plugin
RUN curl -sL "https://github.com/nextcloud-releases/contacts/releases/download/v6.1.3/contacts-v6.1.3.tar.gz" \
    | tar -xz -C /usr/src/nextcloud/custom_apps/ || true

# Install deck plugin
RUN curl -sL "https://github.com/nextcloud-releases/deck/releases/download/v1.14.3/deck-v1.14.3.tar.gz" \
    | tar -xz -C /usr/src/nextcloud/custom_apps/ || true

# Install notes plugin
RUN curl -sL "https://github.com/nextcloud-releases/notes/releases/download/v4.12.1/notes-v4.12.1.tar.gz" \
    | tar -xz -C /usr/src/nextcloud/custom_apps/ || true

# user_ldap is already included in base Nextcloud image
# Custom PHP configuration
RUN echo "memory_limit = 512M" > /usr/local/etc/php/conf.d/zzz-custom.ini \
    && echo "upload_max_filesize = 16M" >> /usr/local/etc/php/conf.d/zzz-custom.ini \
    && echo "post_max_size = 16M" >> /usr/local/etc/php/conf.d/zzz-custom.ini \
    && echo "max_execution_time = 3600" >> /usr/local/etc/php/conf.d/zzz-custom.ini \
    && echo "max_input_time = 3600" >> /usr/local/etc/php/conf.d/zzz-custom.ini \
    && chown -R www-data:www-data /usr/local/etc/php/conf.d/

# Fix permissions
RUN chown -R www-data:www-data /var/www/html/apps /usr/src/nextcloud/custom_apps

USER www-data
