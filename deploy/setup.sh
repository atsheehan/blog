sudo mkdir -p /var/www
sudo tar zxf /tmp/site.tar.gz -C /var/www
sudo rm /tmp/site.tar.gz
sudo chown -R www-data:www-data /var/www/foobarium
sudo find /var/www/foobarium -type f -exec chmod 0444 {} \;
sudo find /var/www/foobarium -type d -exec chmod 0555 {} \;

sudo apt-get update
sudo apt-get -y install nginx

sudo mv /tmp/foobarium.nginx.conf /etc/nginx/sites-available
sudo ln -sf /etc/nginx/sites-available/foobarium.nginx.conf /etc/nginx/sites-enabled/foobarium.nginx.conf
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -s reload
