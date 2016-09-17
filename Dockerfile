FROM nginx:1.11-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY build/foobarium/ /www

CMD ["nginx", "-g", "daemon off;"]
