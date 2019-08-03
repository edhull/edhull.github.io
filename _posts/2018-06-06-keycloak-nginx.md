---
layout: post
title:  "Securing Nginx with Keycloak"
author: "Ed Hull"
categories: nginx keycloak security openresty homelab
tags: nginx keycloak docker container virtualization openresty security authentication homelab openidc openid-connect oauth2
published: true
---
<br/>

I have a large number of services exposed on my network. Most of these services are available for the benefit of anyone who happens to frequent my WLAN to allow them to do things such as controlling lights and browsing media.

There are a small number of sensitive services that I use to maintain and monitor other services (think ELK, Zabbix, etc.) which I would prefer are locked down. Using good ol' `htpasswd` to require nginx to prompt for basic authentication "works", but it's not very scalable. And honestly, with an attitude like that we'd be stuck with the horse and cart rather than the car. 

I was recently introduced to [Keycloak](https://www.keycloak.org/) through my day job as a devops / platform engineer. Keycloak acts as a Single Sign-On (SSO) authentication _service provider_ which plugs in to many _identity providers_ such as Google, Twitter, Facebook, as well as having out-of-the-box support for LDAP and Active Directory. Keycloak can also act as a stand-alone identity provider with its own list of users and groups. 

A typical use-case of Keycloak (and the RedHat version, _RedHat SSO_) is to append an [_adapter_](https://www.keycloak.org/docs/3.1/securing_apps/topics/overview/supported-platforms.html) (what everyone else calls a library) to your web application that provides the ability for your application to authenticate against Keycloak. Keycloak supports OpenID-Connect and SAML easily, but it's worth checking the adapter for your language as I've personally found it to be touch-and-go. The adapter provides the capability for your application to do things such as retrieve an authenticated user's name and e-mail address.

When I first started playing with Keycloak my eyes started to glaze over with the excitement of knowing I might have a new personal project to start working on. _Hmm_, I began to wonder. 

<br />
![keycloak-master-realm](/images/blog/kc1.png)

I run an nginx reverse proxy which facades my services. Could I somehow utilise Keycloak to authenticate my services and turn nginx into an authentication layer? _Without_ needing to modify those services? 

Yes. This post is a journey on how I transitioned from `htpasswd` to Keycloak for Nginx authentication. Hopefully you may find it interesting. 

<br />
**OpenResty**

After a few hours of researching whether this would be possible, my sights fixed on to [lua-resty-openidc](https://github.com/zmartzone/lua-resty-openidc). Lua-resty-openidc is a library which extends Lua with support for OpenID Connect - which Keycloak supports. By using this library it should be as simple as adding a small code snippet to an nginx listener block to enable Keycloak authentication. 

I cloned my existing Ubuntu nginx LXC container and began using it as a testbed. I immediately ran into trouble. As hard as I tried, I could not get nginx to cleanly compile with the required Lua libraries needed to support lua-resty-openidc. After the 8 hour mark I conceeded and switched to [OpenResty](https://openresty.org/en/). OpenResty is functionally identical to Nginx with the addition of Lua out of the box. Why didn't I do this straight away? Partly stubbornness, partly I don't like the idea of not being able to deploy the latest nginx updates and needing to wait for them to trickle through the OpenResty release cycle.

<br />
**Keycloak Setup**

<br />
![keycloak](/images/blog/keycloak.png)


I needed a Keycloak server to authenticate against. I went with Docker-Compose to stand up a postgres-backed Keycloak container (modify the user credentials to your liking):

```
version: '2.1'
services:
  keycloak_postgres:
    hostname: keycloak-db
    restart: always
    image: postgres
    volumes:
      - ./keycloak_postgres_data:/var/lib/postgresql
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: password
    dns:
      - 8.8.8.8
  keycloak:
    hostname: keycloak
    restart: always
    image: jboss/keycloak:3.4.3.Final
    environment:
      POSTGRES_PORT_5432_TCP_ADDR: keycloak_postgres
      POSTGRES_DATABASE: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: password
      KEYCLOAK_USER: admin
      KEYCLOAK_PASSWORD: password
      PROXY_ADDRESS_FORWARDING: "true"
#    volumes:
#      - ./keycloak_data/themes:/opt/jboss/keycloak/themes
    ports:
      - 8080:8080
    depends_on:
      - keycloak_postgres
    dns:
      - 8.8.8.8
    links:
      - keycloak_postgres
```
<br />
I won't cover certificates, but I'm going to assume you are using a reverse proxy in front of Keycloak which will handle SSL termination. 

With Keycloak stood up, I created a set of new _realms_. In Keycloak a realm is the scope of what a set of credentials are valid. A realm is composed of _clients_ - where a _client_ is an application that is consuming the credentials. In my scenario, each client is equal to one nginx `listener` block.

To begin with, I created a new realm for internal applications and a new realm for external applications (as they may use different users). I created a client within the internal applications realm called 'elk' as my acceptance criteria for this experiment is to have an authentication layer provided by Keycloak in front of my ELK stack. 
<br />
<br />
![keycloak-elk-img](/images/blog/kc2.jpeg)
<br />
I configured the client _Access Type_ to confidential (meaning a Secret is required from OpenResty), I set the _Root URL_ to my ELK domain (I've substituted the URLS in the screenshots), and allowed a wildcard for valid redirects. Finally I set the _Web Origins_ to '\*'. 

From here, moving to the _Installation_ tab and selecting _OIDC JSON_ from the dropdown list will provide you with a set of values which we will use with OpenResty later. Keep a note.
<br />
![keycloak-installation-img](/images/blog/kc3.jpeg)
<br />
Next, I created a new test user within the internal applications realm. I created a user 'test', and then went back to edit the user to set a password. By default a user will be prompted to set their password the first time they login, but we can ignore that step.

From this point you can tweak Keycloak for things such as DDOS protection, although I won't cover fine-tuning here.

<br />
**OpenResty Setup**
<br />
I came up with the following steps to stand up OpenResty with support for OpenID-Connect auth. These are the commands I put together for Ubuntu, although it's not a big jump to make them work for Centos/RHEL. 

```
apt-get update \
&& apt-get install -y libc6-dev libgd-dev libgeoip-dev libpcre3-dev liblua5.3-dev lua5.3 lua-cjson curl libssl1.0.0 unzip apt-utils autoconf automake build-essential git libgeoip-dev liblmdb-dev libpcre++-dev libtool libxml2-dev libyajl-dev pkgconf wget zlib1g-dev liblua5.2-dev

cd /usr/src && \
wget http://keplerproject.github.io/luarocks/releases/luarocks-2.2.2.tar.gz && \
tar xvf luarocks-2.2.2.tar.gz && \
cd luarocks-2.2.2 && \
./configure && make build && make install

luarocks install lua-resty-jwt
luarocks install lua-resty-session
luarocks install lua-resty-jwt
luarocks install lua-resty-http
luarocks install lua-resty-openidc
luarocks install luacrypto

cd /usr/src && \
wget -O openresty.tar.gz https://openresty.org/download/openresty-1.13.6.2.tar.gz && \
mkdir /usr/src/openresty && \
tar -zxf openresty.tar.gz -C /usr/src/openresty --strip-components=1

# Compile OpenResty - tweak to your liking!
cd /usr/src/openresty && \
ldconfig && \
./configure --prefix=/usr/local --user=www-data --group=www-data --with-stream --with-http_ssl_module --without-mail_pop3_module --without-mail_imap_module --without-mail_smtp_module --with-compat --with-debug --with-pcre-jit --with-http_stub_status_module --with-http_realip_module --with-http_auth_request_module --with-http_addition_module --with-http_dav_module --with-http_geoip_module --with-http_gunzip_module --with-http_gzip_static_module --with-http_image_filter_module --with-http_v2_module --with-http_sub_module --with-stream --with-stream_ssl_module --with-threads -j2 && \
make -j2 && \
make install

# I had a bug with Lua's Crypto module not being picked up. The nasty way I found around this was to manually copy the crypto library to a location it could be found. 
mkdir -p /usr/local/lib/lua/5.1/
cp /usr/local/lib/lua/5.3/crypto.so /usr/local/lib/lua/5.1/crypto.so
```
<br />
I also created a new service for starting OpenResty at `/lib/systemd/system/openresty.service`:
```
[Service]
Type=forking
ExecStartPre=/usr/local/nginx/sbin/nginx -t -c /usr/local/nginx/conf/nginx.conf
ExecStart=/usr/local/nginx/sbin/nginx -c /usr/local/nginx/conf/nginx.conf
ExecReload=/usr/local/nginx/sbin/nginx -s reload
KillStop=/usr/local/nginx/sbin/nginx -s stop

KillMode=process
Restart=on-failure
RestartSec=42s

PrivateTmp=true
LimitNOFILE=200000

[Install]
WantedBy=multi-user.target

```
<br />
Finally, we need to modify the nginx configuration to utilise Keycloak. This is an abstraction of the nginx configuration I use:
```
worker_processes 2;
error_log /var/log/nginx/error.log;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
    use epoll;
    multi_accept on;
}

http {
   include       mime.types;
   default_type  application/octet-stream;
   keepalive_timeout 65;
   keepalive_requests 100000;
   tcp_nopush on;
   tcp_nodelay on;

   lua_package_path '/usr/local/share/lua/5.3/?.lua;;';
   lua_shared_dict discovery 1m;
   lua_shared_dict jwks 1m;
   lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;

   variables_hash_max_size 2048;
   server_names_hash_bucket_size 128;
   server_tokens off;

   resolver 8.8.8.8 valid=30s ipv6=off;
   resolver_timeout 11s;

   log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';
   
   upstream upstream_server {
        server 10.100.4.200:1010       max_fails=3 fail_timeout=30s;
   }

   server {
        listen       80;
        listen       443  ssl;
        server_name  mydomain.co.uk;
        proxy_intercept_errors off;
        ssl_certificate /etc/letsencrypt/live/mydomain.co.uk/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/mydomain.co.uk/privkey.pem;
        server_tokens             off;

        access_log  logs/mydomain.log;
        error_log  logs/mydomain.error.log;

        root   /var/www/html;

        lua_code_cache off;
        #There is a bug I found with sessions not sticking properly and causing spontaneous 403's
	#For now, set the session secret hard-coded
        set $session_secret 723p4hR234t36VsCD8g565325IC0022G;

        access_by_lua '
          local opts = {
            redirect_uri_path = "/redirect_uri",
            accept_none_alg = true,
            discovery = "https://keycloak_endpoint/auth/realms/internal_applications/.well-known/openid-configuration",
            client_id = "elk",
            client_secret = "!!! Set this to the secret from the JSON !!! ",
            ssl_verify = "no",
            redirect_uri_scheme = "https",
            logout_path = "/logout",
            redirect_after_logout_uri = "https://keycloak_endpoint/auth/realms/internal_applications/protocol/openid-connect/logout",
            redirect_after_logout_with_id_token_hint = false,
            session_contents = {id_token=true}
          }
          local res, err = require("resty.openidc").authenticate(opts)

          if err then
            ngx.status = 403
            ngx.say(err)
            ngx.exit(ngx.HTTP_FORBIDDEN)
          end
       ';

        location / {
           proxy_pass http://upstream_server;
 	}
   }   
}  

```
<br />
This configuration will protect all context paths of `mydomain.co.uk` by redirecting users to the `keycloak_endpoint` to authenticate. Once authenticated, the user will be redirected back to the application (based on the client base URL created in Keycloak) with an authentication token which lua_resty_openidc will receive. If the user is authenticated, then the normal nginx `proxy_pass` redirect will apply as normal.  

<br />
![keycloak-login-img](/images/blog/kc4.jpeg)

<br />
<br />
**Theming Keycloak**
<br />
It's straight forward to apply a new theme to Keycloak - the hardest part seems to be finding themes to apply in the first place. I downloaded a theme I found online and reverse engineered the hell out of it to create my own formal-but-kinda-intimidating authentication prompt. You can uncomment my volume mount in the Docker compose file to provide your own themes to the container.
<br />
![keycloak-themed-img](/images/blog/kc5.jpeg)

<br />
<br />
**Round Up**
<br />
I spent far too much time trying to get Nginx to natively work with the Lua libraries only to go with OpenResty. This use-case isn't necessarily the best for Keycloak as the user's credentials are not being consumed by the services being protected, but that doesn't mean I can't use it anyway! Hopefully this has been informative and sparked some ideas of your own.

<br/>


Useful Links:

[https://aboullaite.me/secure-kibana-keycloak/](https://aboullaite.me/secure-kibana-keycloak/) <br />
[https://eclipsesource.com/de/blogs/2018/01/11/authenticating-reverse-proxy-with-keycloak/](https://eclipsesource.com/de/blogs/2018/01/11/authenticating-reverse-proxy-with-keycloak/) <br />
[https://github.com/zmartzone/lua-resty-openidc](https://github.com/zmartzone/lua-resty-openidc) <br />

