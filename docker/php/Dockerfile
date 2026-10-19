FROM php:8.3-fpm-alpine

RUN apk add --no-cache --virtual .build-deps $PHPIZE_DEPS \
 && docker-php-ext-install pdo_mysql opcache \
 && pecl install redis-6.1.0 \
 && docker-php-ext-enable redis \
 && apk del .build-deps \
 && rm -rf /tmp/pear

COPY php.ini /usr/local/etc/php/conf.d/zz-app.ini
COPY www.conf /usr/local/etc/php-fpm.d/zz-www.conf

WORKDIR /var/www/app
