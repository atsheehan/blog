FROM nginx:1.9

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY build/foobarium/ /www

CMD ["nginx", "-g", "daemon off;"]
