FROM nextcloud:stable

USER root

# Install calendar plugin
RUN curl -sL "https://github.com/nextcloud-releases/calendar/releases/download/v6.5.1/calendar-v6.5.1.tar.gz" \
    | tar -xz -C /var/www/html/apps/

# Install oidc_login plugin
RUN curl -sL "https://github.com/pulsejet/nextcloud-oidc-login/releases/download/v3.3.1/oidc_login.tar.gz" \
    | tar -xz -C /var/www/html/custom_apps/

# Install groupfolders plugin
RUN curl -sL "https://github.com/nextcloud-releases/groupfolders/releases/download/v22.0.3/groupfolders-v22.0.3.tar.gz" \
    | tar -xz -C /var/www/html/custom_apps/ || true

# Install richdocuments (Collabora connector)
RUN curl -sL "https://github.com/nextcloud-releases/richdocuments/releases/download/v8.6.8/richdocuments-v8.6.8.tar.gz" \
    | tar -xz -C /var/www/html/custom_apps/ || true

# Fix permissions
RUN chown -R www-data:www-data /var/www/html/apps /var/www/html/custom_apps

USER www-data
