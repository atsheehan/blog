---
layout: "article"
title: "Building a Rails Server"
description: "This article describes setting up an Ubuntu 14.04 server for hosting a Ruby on Rails application. It focuses on what should be installed while explaining some of the design choices and configuration options. Once we know what we'd like our server configuration to look like, it becomes easier to evaluate the different methods of building and automating the deployment process."
published_on: "2016-11-16"
---

This article describes how I would setup an Ubuntu 14.04 server for hosting a Ruby on Rails application. It doesn't cover the deployment process, but focuses on what should be installed and where to put it. Once we know what we'd like our server configuration to look like, it becomes easier to evaluate the different methods of building and automating the deployment process.

### Prerequisites

This article assumes the following:

* We have shell access and sudo privileges to a server with a new install of Ubuntu 14.04. It is assumed that this server will only be used for running the Rails application. For testing I used an AWS EC2 t2.micro instance using base image `ami-c8580bdf`.
* We have a Rails application that is ready to be deployed. The next section will describe a sample application used in this article and the steps taken to prepare it for a production deployment.

## The Sample Ruby on Rails Application

To demonstrate the build process we'll use a [Stack Overflow](https://stackoverflow.com/) clone called [Zero Division](https://github.com/atsheehan/zero). And by clone, I mean a barebones question and answer site without all that additional fluff such as user authentication, fancy styling, or practical value of any kind.

Zero Division is a Rails 4.2.6 application. Apart from the initial app creation with `rails new` and some basic [CRUD actions](https://en.wikipedia.org/wiki/Create,_read,_update_and_delete) for questions and answers, there are a few changes that were made to prepare for deployment. We'll connect to a PostgreSQL database, which in this case will be a local database server for demonstration purposes.

### Logging to stdout

Rather than writing log messages to `log/production.log` within the app directory, we'll send any output to the `stdout` stream. This way we don't have to deal with managing the log file ourselves and we can push this responsibility to the service running our application. For Ubuntu 14.04 we'll be using the default init system **Upstart**, which will capture `stdout` and save it to a file in the `/var/log/upstart` directory. The benefit of this approach is that Upstart will rotate the logs each day, compressing and deleting logs past a certain date.

The `gem "rails_12factor"` will handle this change automatically. If you're using Rails 5, you can log to `stdout` by [setting an environment variable](https://github.com/rails/rails/pull/23734) and you don't need to include the `rails_12factor` gem.

### Load environment variables from file

Some of the application configuration will be set using environment variables, including the database configuration. For example, the `config/database.yml` file now reads all of the production database credentials from the environment.

```
production:
  adapter: postgresql
  encoding: unicode
  pool: 5
  database: <%= ENV["DATABASE_NAME"] %>
  host: <%= ENV["DATABASE_HOST"] %>
  username: <%= ENV["DATABASE_USER"] %>
  password: <%= ENV["DATABASE_PASSWORD"] %>
```

The `dotenv-rails` gem will handle reading credentials from a `.env` file into the environment when the application boots. The benefit of this approach is that by having the application responsible for loading the environment variables, we don't have to worry can launch our application outside the context of a shell that would normally handle setting environment variables from a user profile.

### Web server configuration

We'll use Puma as the web server for our application. [Puma is recommended by Heroku](https://devcenter.heroku.com/articles/rails4#running) and we'll end up copying their [configuration settings](https://devcenter.heroku.com/articles/deploying-rails-applications-with-the-puma-web-server#config).

The one addition to Heroku's puma configuration is to listen using a unix socket rather than listening over TCP. Since our Rails app will be communicating with nginx on the same machine, we can avoid the overhead of the networking stack by having them talk using unix sockets. We'll create the socket file at `tmp/zero.sock`.

```
workers(Integer(ENV["WEB_CONCURRENCY"] || 2))
threads_count = Integer(ENV["RAILS_MAX_THREADS"] || 5)
threads(threads_count, threads_count)

preload_app!

socket_file = File.expand_path(File.join(__dir__, "..", "tmp", "zero.sock"))
bind("unix://#{socket_file}")

rackup(DefaultRackup)
environment(ENV["RACK_ENV"] || "development")

on_worker_boot do
  ActiveRecord::Base.establish_connection
end
```

## Overview

Now that we have a sample application to deploy, let's cover the steps we'll take to configure an Ubuntu 14.04 server.

At a high level, we'll perform the following:

1. Updating any existing software and configure security updates
2. Install Ruby
3. Install application dependencies
4. Configure the application as a service
5. Configure nginx as reverse proxy

The next sections will describe the above steps in more detail.

### Update existing software

When our server starts up, we want to bring it up to speed on what packages are available. The `apt-get update` command will refresh the package lists without installing anything new, so let's run that first.

```
$ sudo apt-get update
```

Even though we haven't added any new packages ourselves, there's already a number of packages that have been preinstalled on the Ubuntu 14.04 image. If we want to install any updates to those packages, we can use the `sudo apt-get upgrade` command.

```
$ sudo apt-get -y upgrade
```

Our packages are now up-to-date, but what about new package updates that are released after we finish this build? We don't necessarily need the latest and greatest versions for each package since our application should already be running, but we do want to ensure that any security vulnerabilities are patched quickly.

The `unattended-upgrades` package can be used to install upgrades routinely. This package is already installed with Ubuntu 14.04 and we can view the configuration at `/etc/apt/apt.conf.d/50unattended-upgrades`. By default, it will only install security upgrades:

```
// Automatically upgrade packages from these (origin:archive) pairs
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}-security";
//      "${distro_id}:${distro_codename}-updates";
//      "${distro_id}:${distro_codename}-proposed";
//      "${distro_id}:${distro_codename}-backports";
};
```

To enable the upgrades to run routinely, we need to create a file in `/etc/apt/apt.conf.d/20auto-upgrades` containing:

```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
```

We can do this automatically by running the following command.

```
$ sudo tee /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
```

More info about configuring the unattended-upgrades package can be found on the [Debian wiki](https://wiki.debian.org/UnattendedUpgrades).

[[aside
### Are automatic upgrades always a good idea?

The `unattended-upgrades` package is useful for ensuring security fixes are applied quickly, but it does open up the possibility that the upgraded packages introduce new bugs or breaks backwards compatibility.

Another consideration is that any long-running services that are **not** managed by `apt-get` (i.e. our web application described below) won't be notified of upgraded packages. If a shared library used in our app was upgraded to fix a security issue, the app will continue using the old library loaded in memory until the process is restarted. Even worse is if the new library breaks our app, we won't find out until days or weeks later when the service is restarted, making it difficult to debug.

I still think the benefits of the security upgrades outweight the costs, but these are just a few edge cases to think about.
aside]]

### Installing Ruby

To run a Ruby on Rails web application, we're going to need Ruby. There are two common methods for installation:

* Install a precompiled version using a package manager (e.g. `apt-get install ruby`)
* Build and install Ruby from the source code

There are a lot of benefits to using packages:

* Faster install without the compilation step
* Smaller footprint since we don't need any build dependencies
* Files and dependencies are controlled by the package manager
* Widely used and tested to ensure it plays nice with other packages

Ignoring all of that, we'll build Ruby from source. The primary reason is that we'll have more control over the specific version of Ruby to use. Package repositories can sometimes lag a version or two behind the latest stable release, and in some instances we may be required to use newer versions (e.g. [Rails 5 requires Ruby 2.2.2+](http://edgeguides.rubyonrails.org/5_0_release_notes.html)).

[[aside
If you want the benefits of package management while also using the latest versions available, another approach would be to build your own Ruby package (or find another repository that has more up-to-date versions available). This requires a bit more work and infrastructure to setup, but could speed up deployment if you have a large number of applications or servers that share the same dependencies.
aside]]

To build Ruby, we'll need to install a compiler and some other development dependencies. We can install these using the package manager.

```
$ sudo apt-get -y install autoconf bison build-essential libssl-dev \
     libreadline-dev zlib1g-dev libgdbm-dev
```

Next we need to get the source code.

```
$ cd $HOME
$ wget https://cache.ruby-lang.org/pub/ruby/2.3/ruby-2.3.2.tar.gz
```

Since we're downloading the source from an external website, we can verify that the file hasn't changed since I first grabbed it using the SHA256 digest.

```
$ echo "8d7f6ca0f16d77e3d242b24da38985b7539f58dc0da177ec633a83d0c8f5b197 ruby-2.3.2.tar.gz" \
    | sha256sum -c -
```

This doesn't guarantee that the code is safe to compile and run, just that it hasn't been modified from when I grabbed the checksum.

Now we can unpack the archive.

```
$ tar zxf ruby-2.3.2.tar.gz
$ cd ruby-2.3.2/
```

Configure and build Ruby. Since we're not using this for development, we probably don't need the documentation.

```
$ ./configure --disable-install-doc
$ make
$ sudo make install
```

This will copy the Ruby binaries over to `/usr/local/bin`, installing Ruby system-wide. We're assuming the server is dedicated to running our web application and we're the only user of Ruby, so we don't need to deal with a Ruby version manager. Once the files are copied to `/usr/local/bin`, we can clean up our build directory.

```
$ cd $HOME
$ rm -rf ruby-2.3.2 ruby-2.3.2.tar.gz
```

We'll install the *bundler* gem so that we can bootstrap the gem installation process for our application. Again, since this is for production we don't need to include the documentation.

```
$ sudo gem install --no-document bundler
```

[[aside
### Why are these libraries necessary?

One tricky part of building Ruby is that during compilation, it will check to see if certain libraries are available for added functionality. If those libraries are missing, Ruby continues building but it leaves out that (sometimes critical) functionality.

For example, we could build Ruby with just a few of the development packages.

```
# Install only the compiler and configuration tools
$ sudo apt-get -y install autoconf bison build-essential
$ ./configure --disable-install-doc
$ make
$ sudo make install
```

During the `make` step you may notice a few failures in the output:

```
Failed to configure dbm. It will not be installed.
Failed to configure gdbm. It will not be installed.
Failed to configure openssl. It will not be installed.
Failed to configure readline. It will not be installed.
Failed to configure tk. It will not be installed.
Failed to configure tk/tkutil. It will not be installed.
Failed to configure zlib. It will not be installed.
```

These are parts of the Ruby standard library that rely on external C libraries. To integrate with these libraries, Ruby needs the development headers found in the `lib*-dev` packages. If they can't be found, Ruby will continue on building but you won't be able to use these libraries in your code.

Some of these libraries are more important than others. The `tk` and `tk/tkutil` libraries are used for building GUI applications, so maybe they're not necessary for a web application. But `zlib` is commonly used for compression, including reading and writing gzip (.gz) files. Without this library, even the `gem` command will fail to work properly:

```
$ sudo gem install --no-document bundler

ERROR:  Loading command: install (LoadError)
    cannot load such file -- zlib
ERROR:  While executing gem ... (NoMethodError)
    undefined method `invoke_with_build_args' for nil:NilClass
```

It's best to include support for this functionality since they are part of the standard library. Even if you don't use them directly in your application, any gems you use may rely on them.
aside]]

### Preparing the Application

With Ruby installed, we can now start preparing our application for running in a production environment.

First we'll need to get the source code for our application on the server. This brings up two questions:

* How to get the source code onto the server?
* Where to store the source code?

For getting the source code, one option is to fetch it directly from a version control system (e.g. `git clone REPO`). This works well with public repositories, but if our source is private then we'll need to authenticate our server with the remote repository. This is often done using *readonly* deploy keys.

[[aside
### Limiting Access to a Remote Repository

Before setting up deploy keys, consider whether we actually need access to the remote repository. Do we plan on updating the source once the server has been built? If we're looking to build an [immutable server](http://chadfowler.com/2013/06/23/immutable-deployments.html), we may only need one copy of the source code. It may be simpler to tar up the source code and copy it to the server rather than authorizing access to the source repository. If the server was ever compromised, removing the connection to the repository means it's one less thing to worry about.
aside]]

Fortunately, the source for our app is hosted publicly, so we can fetch directly from GitHub. Rather than pulling the entire repo, we can download and extract an archive with the latest code directly.

```
# Download and unpack the latest source code for the web app
$ cd $HOME
$ wget https://github.com/atsheehan/zero/archive/master.tar.gz
$ tar zxf master.tar.gz
$ rm master.tar.gz
```

We now have the source code on the server, where should we keep it? According to the [Filesystem Hierarchy Standard](http://www.pathname.com/fhs/pub/fhs-2.3.html#SRVDATAFORSERVICESPROVIDEDBYSYSTEM), the `/srv` directory can be used for services provided by this system.

```
$ sudo mkdir -p /srv
$ sudo mv zero-master /srv/zero
$ sudo chown -R root:root /srv/zero
```

Now that our source code is unpacked, we can install any dependencies our app needs. Some of the gems use C code that requires compilation, and some of these gems need additional development libraries. For this application we'll be using the `pg` gem, which requires the `libpq-dev` library. We'll also install `nodejs` which will be used by `uglifier` when we precompile our assets.

```
$ sudo apt-get install -y libpq-dev nodejs
```

Now we can go ahead and install any gems we need.

```
$ cd /srv/zero
$ sudo bundle install --deployment --without development test
```

The [--deployment](http://bundler.io/v1.11/deploying.html#deploying-your-application) flag will install the gems in the `/srv/zero/vendor/bundle` directory, but more importantly it will require the use of `Gemfile.lock`. If for whatever reason this isn't committed to the repository, it will fail rather than installing arbitrary versions of the gems.

We also want to [precompile our assets](http://guides.rubyonrails.org/asset_pipeline.html#precompiling-assets) at this time.

```
$ sudo RAILS_ENV=production bundle exec rake assets:precompile
```

### Creating a User

Up until this point, we've been running our commands using `sudo`, so everything will be owned by the root user. But we don't want to run our Rails application as root. In the dire event that our [application is compromised](http://blog.codeclimate.com/blog/2013/01/10/rails-remote-code-execution-vulnerability-explained/) or [tricked into doing something unintended](https://en.wikipedia.org/wiki/Confused_deputy_problem), running as the root user means access to everything on the server. To limit the amount of damage possible, we need to limit what the application can do.

Let's first create a new user to run our application. Since our application is called `zero`, we'll create a user with the same name.

```
$ sudo adduser --system --no-create-home --gecos '' zero
```

The `--system` flag will create a user without a shell and logins disabled, the `--gecos ''` option avoids prompting for any personal details, and the `--no-create-home` option avoids creating a `/home/zero` directory.

This new user will be running the Rails application, so it needs to be able to read the source code. But we don't want the user running the application to modify the source code in any way, so we can keep the owner of the files as `root` and just provide read-only access to everyone else.

There are two exceptions to our read-only source tree: the `tmp` and `log` directories need to be writeable by our application user.

We could change the owner of the `/srv/zero/tmp` directory so that it is writable by the application user. An alternative is to have the application write to a directory in `/var/tmp` instead. The `/var/tmp` directory may be better optimized for writing temp files and we can avoid filling up the `/srv` directory.

To use `/var/tmp`, we can first create a new directory for our app and then symlink it to our source tree.

```
# Create our new temp directory
$ sudo mkdir -p /var/tmp/zero
$ sudo chown zero /var/tmp/zero

# Remove the existing temp directory, then replace it with a symlink
$ sudo rm -rf /srv/zero/tmp
$ sudo ln -s /var/tmp/zero/ /srv/zero/tmp
```

The other file that needs to be writeable is `log/production.log`. Even though we're redirecting the output to `stdout`, if Rails can't write to `log/production.log` on boot we'll get the following error message.

```
Rails Error: Unable to access log file. Please ensure that
/srv/zero/log/production.log exists and is writable (ie, make it
writable for user and group: chmod 0664
/srv/zero/log/production.log). The log level has been raised to WARN
and the output directed to STDERR until the problem is fixed.
```

We don't actually want to write anything to `production.log` since Upstart will log the output from `stdout` for us. What we can do is create a link to `/dev/null` so that Rails doesn't complain about the missing file.

```
# Provide a dummy log file. The actual logs will be capture from
# STDOUT and written to /var/log/upstart/zero.log
$ sudo rm /srv/zero/log/production.log
$ sudo ln -s /dev/null /srv/zero/log/production.log
```

### Managing Secrets

Most Rails applications need access to credentials for external services and secret keys used for authentication. These values are typically set through environment variables and are not included in the source code.

Managing these secrets is tricky, and I'm not entirely sure of the best way to handle them. Although the source code for application may be shared throughout the company (or even public), the secrets necessary to run the application in production should be limited to only those who will be deploying and managing the operations. Likewise, minimizing the number of processes that have access to these secrets while running is helpful to minimize the chance of them being exposed if a server is compromised.

Our Rails application will read the database credentials and encryption keys from the environment. We'll use the `dotenv-rails` gem to load the environment variables from a file when the application starts up. We'll put the secrets in `/srv/zero/.env` as a series of `KEY=VALUE` pairs.

At a minimum, we need to set the following variables in the `/srv/zero/.env` file (replace the values with your own credentials):

```
DATABASE_NAME=zero_production
DATABASE_HOST=zero-production.host-name.rds.amazonaws.com
DATABASE_USER=zero
DATABASE_PASSWORD=super_secret_password_goes_here
SECRET_KEY_BASE=really_long_random_string_goes_here
```

Where we can fetch this information from is the hard part. Some managed environments provide a way to set environment variables directly and we wouldn't necessarily need to use `dotenv` (e.g. Heroku and Docker have methods for exposing environment variables to applications). Configuration management tools often have their own way of passing sensitive environment variables during their setup process (e.g. Chef can store sensitive credentials in [encrypted data bags](https://docs.chef.io/data_bags.html#encrypt-a-data-bag-item) that can be used to create the `.env` file). Then there are external tools specific for managing secrets that integrate more tightly with the application, such as [Hashicorp's Vault](https://www.vaultproject.io/).

Since managing secrets is a topic large enough to fill several books and depends on the deployment process, we won't go into much detail here. Instead, we'll take the easy way out, installing a PostgreSQL server locally and generating a random secret key with `rake secret`.

First install PostgreSQL and create the `zero` user.

```
# Use a local PostgreSQL server for demonstration purposes and create
# the "zero" database user.
$ sudo apt-get install -y postgresql
$ sudo su postgres -c "createuser -s zero"
```

Then we can create our `.env` file with the database credentials.

```
$ sudo tee /srv/zero/.env <<EOF
DATABASE_NAME=zero_production
DATABASE_HOST=
DATABASE_USER=zero
DATABASE_PASSWORD=
EOF
```

We also need a random secret key base, which we can generate using the `rake secret` task.

```
$ echo "SECRET_KEY_BASE=$(bundle exec rake secret)" | sudo tee -a /srv/zero/.env
```

Now we can setup our database.

```
$ cd /srv/zero
$ bundle exec rake db:setup
```

### Manually Starting the Server

We have our user, the application source, and any credentials we need, so let's verify that we can run the server. Our application user doesn't have a default shell configured, so when switching users we'll have to specify the shell command explicitly.

```
(ubuntu)$ sudo su zero -s /bin/bash
(zero)$ cd /srv/zero
(zero)$ RAILS_ENV=production bundle exec puma -C config/puma.rb
```

At a minimum, the server should start up without any error messages. We won't be able to connect directly since it's listening on a socket rather than a port until we setup nginx.

Note that these commands can also be used to run one-off tasks, such as `rake db:migrate`.

```
(ubuntu)$ sudo su zero -s /bin/bash
(zero)$ cd /srv/zero
(zero)$ RAILS_ENV=production bundle exec rake db:migrate
```

### Running as a Service

Our application starts successfully, but we don't want to have to manually start the server each time the OS boots. To manage the process, we'll use Upstart, the default init system for Ubuntu 14.04. There are several benefits that come with using an init system:

* Can instruct the application server to start on boot once the networking stack is available
* Restarts the web application if it crashes
* Can be controlled via the `start` and `stop` commands
* Captures and logs `stdout` from the app to the `/var/log/upstart` directory
* Manages log rotation

To setup an Upstart service, we need to create a file in the `/etc/init` directory. We have an [Upstart configuration file](https://github.com/atsheehan/zero/blob/master/deploy/upstart.conf) in the `deploy` directory of our source tree, so we can just copy it over.

```
$ sudo cp /srv/zero/deploy/upstart.conf /etc/init/zero.conf
```

Let's take a look at the contents of `/etc/init/zero.conf`.

```
description "Zero web server"

start on started networking
stop on stopping networking

respawn
respawn limit 10 60

env RAILS_ENV=production
env RACK_ENV=production

setuid zero
chdir /srv/zero
exec bundle exec puma -C config/puma.rb
```

The `start on started networking` line indicates that this process should wait until the init system has finished loading the `networking` job. If the Rails process crashes, we want it to `respawn`. If the server crashes more than 10 times in less than a minute, something is probably wrong so don't keep restarting (via `respawn limit 10 60`). We set some initial, non-sensitive environment variables with `env` so that the process knows to start in production mode (the rest will be loaded from the `/srv/zero/.env` file).

The last few instructions tell Upstart to switch to the `zero` user, change into the `/srv/zero` directory, and then run the `bundle exec puma` command.

To test out our service, we can use the `start` command.

```
$ sudo start zero
```

We configured our Rails application to log to `stdout`, which Upstart will collect and write to `/var/log/zero.log`. We can check this file to verify everything is working correctly.

```
$ sudo tail /var/log/upstart/zero.log

[16808] Puma starting in cluster mode...
[16808] * Version 3.4.0 (ruby 2.3.1-p112), codename: Owl Bowl Brawl
[16808] * Min threads: 5, max threads: 5
[16808] * Environment: production
[16808] * Process workers: 2
[16808] * Preloading application
[16808] * Listening on unix:///srv/zero/tmp/zero.sock
[16808] Use Ctrl-C to stop
[16808] - Worker 0 (pid: 16811) booted, phase: 0
[16808] - Worker 1 (pid: 16813) booted, phase: 0
```

Notice how the server is not actually listening on a port but rather a unix socket file:

```
[16808] * Listening on unix:///srv/zero/tmp/zero.sock
```

We'll use this file to communicate between our application server and web server.

### nginx

The last step to completing our build is to setup a web server to listen on port 80 and forward requests to our application server. For this we'll use nginx.

[[aside
### nginx vs. puma

Given that puma is already a web server, why do we need nginx? Why not let puma listen on port 80?

I don't have any concrete reasons as to why puma shouldn't run directly on port 80, but I assume it has to do with how capable they are of handling internet traffic. Port 80 is exposed to the world, so it needs to be able to handle whatever the world throws at it. In addition to the normal HTTP traffic, there's a multitude of ways to send malformed requests that may eat up a lot of resources or otherwise crash the server. Having been around for a while and thoroughly battle-tested, nginx seems like an extra layer of security and performance before the request reaches our Ruby application server.
aside]]

Before we install nginx, lets take a look at the package available in the default repositories.

```
$ apt-cache show nginx

Package: nginx
...
Version: 1.4.6-1ubuntu3.5
...
```

nginx 1.4.6 was released in [early 2014](https://nginx.org/2014.html). It still receives security updates, but there have been several new minor versions released since then (currently 1.10.2 stable). Since nginx is the first point of contact for our application and is directly exposed to the outside world, let's see if we can find a more up-to-date version to install than the one in our current repositories.

The [nginx documentation](https://nginx.org/en/linux_packages.html) describes how we can install one of the official nginx packages by adding another repository to apt. The apt package manager configuration can be found in `/etc/apt`, with `/etc/apt/sources.list` containing the list of existing repositories. To add the new repository containing the updated nginx packages, we can add a file to the `/etc/apt/sources.list.d` directory.

```
$ sudo tee /etc/apt/sources.list.d/nginx.list <<EOF
deb http://nginx.org/packages/ubuntu/ trusty nginx
deb-src http://nginx.org/packages/ubuntu/ trusty nginx
EOF
```

To verify the integrity of the packages, we need to add the signing key from nginx. We can include the key directly in our setup script since it's a public value.

```
# First write the key to a temp file
$ cat <<EOF > /tmp/nginx_repo.key
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: GnuPG v2.0.22 (GNU/Linux)

mQENBE5OMmIBCAD+FPYKGriGGf7NqwKfWC83cBV01gabgVWQmZbMcFzeW+hMsgxH
W6iimD0RsfZ9oEbfJCPG0CRSZ7ppq5pKamYs2+EJ8Q2ysOFHHwpGrA2C8zyNAs4I
QxnZZIbETgcSwFtDun0XiqPwPZgyuXVm9PAbLZRbfBzm8wR/3SWygqZBBLdQk5TE
fDR+Eny/M1RVR4xClECONF9UBB2ejFdI1LD45APbP2hsN/piFByU1t7yK2gpFyRt
97WzGHn9MV5/TL7AmRPM4pcr3JacmtCnxXeCZ8nLqedoSuHFuhwyDnlAbu8I16O5
XRrfzhrHRJFM1JnIiGmzZi6zBvH0ItfyX6ttABEBAAG0KW5naW54IHNpZ25pbmcg
a2V5IDxzaWduaW5nLWtleUBuZ2lueC5jb20+iQE+BBMBAgAoAhsDBgsJCAcDAgYV
CAIJCgsEFgIDAQIeAQIXgAUCV2K1+AUJGB4fQQAKCRCr9b2Ce9m/YloaB/9XGrol
kocm7l/tsVjaBQCteXKuwsm4XhCuAQ6YAwA1L1UheGOG/aa2xJvrXE8X32tgcTjr
KoYoXWcdxaFjlXGTt6jV85qRguUzvMOxxSEM2Dn115etN9piPl0Zz+4rkx8+2vJG
F+eMlruPXg/zd88NvyLq5gGHEsFRBMVufYmHtNfcp4okC1klWiRIRSdp4QY1wdrN
1O+/oCTl8Bzy6hcHjLIq3aoumcLxMjtBoclc/5OTioLDwSDfVx7rWyfRhcBzVbwD
oe/PD08AoAA6fxXvWjSxy+dGhEaXoTHjkCbz/l6NxrK3JFyauDgU4K4MytsZ1HDi
MgMW8hZXxszoICTTiQEcBBABAgAGBQJOTkelAAoJEKZP1bF62zmo79oH/1XDb29S
YtWp+MTJTPFEwlWRiyRuDXy3wBd/BpwBRIWfWzMs1gnCjNjk0EVBVGa2grvy9Jtx
JKMd6l/PWXVucSt+U/+GO8rBkw14SdhqxaS2l14v6gyMeUrSbY3XfToGfwHC4sa/
Thn8X4jFaQ2XN5dAIzJGU1s5JA0tjEzUwCnmrKmyMlXZaoQVrmORGjCuH0I0aAFk
RS0UtnB9HPpxhGVbs24xXZQnZDNbUQeulFxS4uP3OLDBAeCHl+v4t/uotIad8v6J
SO93vc1evIje6lguE81HHmJn9noxPItvOvSMb2yPsE8mH4cJHRTFNSEhPW6ghmlf
Wa9ZwiVX5igxcvaIRgQQEQIABgUCTk5b0gAKCRDs8OkLLBcgg1G+AKCnacLb/+W6
cflirUIExgZdUJqoogCeNPVwXiHEIVqithAM1pdY/gcaQZmIRgQQEQIABgUCTk5f
YQAKCRCpN2E5pSTFPnNWAJ9gUozyiS+9jf2rJvqmJSeWuCgVRwCcCUFhXRCpQO2Y
Va3l3WuB+rgKjsQ=
=EWWI
-----END PGP PUBLIC KEY BLOCK-----
EOF

# Then register it with apt
$ sudo apt-key add /tmp/nginx_repo.key
```

Now with the new repository added, we need to update our package list.

```
$ sudo apt-get update
```

At this point we should be able to install nginx 1.10.2.

```
$ sudo apt-get install -y nginx
```

Once nginx is installed, we can update the configuration so that it directs traffic coming in on port 80 to our Rails process listening on a socket at `/srv/zero/tmp/zero.sock`. nginx configuration is stored in `/etc/nginx`. nginx is capable of hosting several web sites at once, with the generic configuration found in `/etc/nginx/nginx.conf`, and each site with their own configuration file usually stored in `/etc/nginx/conf.d/site.conf`. We'll remove the default site configuration and replace it with our own.

```
$ sudo rm /etc/nginx/conf.d/default.conf
$ sudo cp /srv/zero/deploy/nginx.conf /etc/nginx/conf.d/zero.conf
```

Let's look at the configuration file in `/etc/nginx/conf.d/zero.conf`.

```
server {
    listen *:80;
    root /srv/zero/public;

    error_page 404 /404.html;
    error_page 500 502 503 504 /500.html;

    keepalive_timeout 10s;
    server_tokens off;

    location / {
        try_files $uri @app;
    }

    location @app {
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_pass http://unix:/srv/zero/tmp/zero.sock;
    }

    location /assets {
        expires max;
        add_header Cache-Control public;
        gzip on;
        gzip_types text/css application/javascript;
    }
}
```

We're defining our web app as a virtual host in a `server` block. We'll listen for requests from any IP on port 80 and serve static files directly out of `/srv/zero/public`. If nginx generates a 404 or 50x error before hitting our Rails app, the `error_page` directives let us use the Rails error pages found in `/srv/zero/public/404.html` and `/srv/zero/public/500.html` rather than the default nginx views. The `keepalive_timeout` closes open connections after 10 seconds, and the `server_tokens off` directive excludes the nginx version information from the HTTP response headers.

The `location /` block with `try_files $uri @app` will first try to find a static file in the `/srv/zero/public` directory to fulfill the HTTP request before passing it along to the Rails application. For example, if we received a `GET /robots.txt` request, nginx will check for `/srv/zero/public/robots.txt` first, and since it exists, respond with the `robots.txt` contents without having to pass the request along to Rails. But if we received `GET /questions`, since there is no `/srv/zero/public/questions` file, the request is then forwarded along to the `@app` location block.

The `location @app` block will forward requests to the Rails web app listening on the Unix socket via `proxy_pass http://unix:/srv/zero/tmp/zero.sock`. The `proxy_set_header` directives ensure that nginx passes along relevant HTTP headers sent from the original requestor to the app.

The `location /assets` block will handle any requests where the path starts with `/assets`. These are the precompiled asset files generated by `rake assets:precompile`, which include the hash of the contents in the filename (e.g. `application-1f10c408f1e20bc8316f6a089f9d199edde353503bad437471ffab6e631ce2aa.css`). The benefit of including the hashed value in the filename is that we can cache this file indefinitely, and if the contents of `application.css` ever change, it will have a different hash signature and a different filename. The `expires max` and `Cache-Control public` header instruct browsers to cache these files locally so we don't have to send them with each request. The Rails Asset Pipeline also generates a gzipped version of the assets that we can use too. The `gzip on` and `gzip_types` directive will first look for corresponding asset files ending in `.gz` and send those if available.

With our nginx config in place, we restart the server.

```
$ sudo service nginx restart
```

And with that running, we should be able to access our Rails application.

```
$ curl -i localhost

HTTP/1.1 200 OK
Server: nginx
...

<!DOCTYPE html>
<html>
  <head>
    <title>Zero</title>
    <link rel="stylesheet" media="all" href="/assets/application-1f10c408f1e20bc8316f6a089f9d199edde353503bad437471ffab6e631ce2aa.css" />
    <script src="/assets/application-25bd6b47ad2ef49757a639cd9dc9d7c4b137f7a0bf03bb8d13757d905d6dfcef.js"></script>
    <meta name="csrf-param" content="authenticity_token" />
<meta name="csrf-token" content="NVYE5UI6Z7pl9mWVzE8yGtj98hyxzPhAVyPmHXR6a+Hej4/0GzgC6YplIWf6QNnmBxhJMpzaA6sO2Ue8n8EyMg==" />
  </head>
  <body>
    <section class="heading container">
      <h1>Zero Division</h1>
    </section>
    ...
```

Assuming the server is accessible from your machine and any firewalls are configured to allow traffic over port 80, you should be able to visit the app in your browser.

## The Setup Script

Below is the [full script](https://github.com/atsheehan/zero/blob/master/deploy/setup.sh) of the commands detailed above. These instructions were tested on an Ubuntu 14.04 t2.micro instance using AWS EC2.

```
#!/bin/bash

# Exit early if any of the commands fails
set -e

# Fetch the latest package lists and upgrade any previously installed
# packages.
sudo apt-get update
sudo apt-get -y upgrade

# Enable unattended-upgrades to install essential security updates
# nightly.
sudo tee /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# Libraries required to build Ruby
sudo apt-get -y install autoconf bison build-essential libssl-dev \
     libreadline-dev zlib1g-dev libgdbm-dev

# Download Ruby source code
cd $HOME
wget https://cache.ruby-lang.org/pub/ruby/2.3/ruby-2.3.2.tar.gz
echo "8d7f6ca0f16d77e3d242b24da38985b7539f58dc0da177ec633a83d0c8f5b197 ruby-2.3.2.tar.gz" | sha256sum -c -

tar zxf ruby-2.3.2.tar.gz
cd ruby-2.3.2/

# Compile and install Ruby system-wide
./configure --disable-install-doc
make
sudo make install

# Clean up build artifacts after installed
cd $HOME
rm -rf ruby-2.3.2 ruby-2.3.2.tar.gz

# Use bundler to bootstrap gem installs
sudo gem install --no-document bundler

# Download the latest version of the web application
cd $HOME
wget https://github.com/atsheehan/zero/archive/master.tar.gz
tar zxf master.tar.gz
rm master.tar.gz

# This is the directory where the application source will live.
sudo mkdir -p /srv
sudo mv zero-master /srv/zero
sudo chown -R root:root /srv/zero

# These libraries are necessary for building native gem extensions
sudo apt-get install -y libpq-dev nodejs

# Install and build gems
cd /srv/zero
sudo bundle install --deployment --without development test

# Precompile assets
sudo RAILS_ENV=production bundle exec rake assets:precompile

# Create application user
sudo adduser --system --no-create-home --gecos '' zero

# Create our new temp directory
sudo mkdir -p /var/tmp/zero
sudo chown zero /var/tmp/zero

# Remove the existing temp directory, then replace it with a symlink
sudo rm -rf /srv/zero/tmp
sudo ln -s /var/tmp/zero/ /srv/zero/tmp

# Provide a dummy log file. The actual logs will be capture from
# STDOUT and written to /var/log/upstart/zero.log
sudo rm /srv/zero/log/production.log
sudo ln -s /dev/null /srv/zero/log/production.log

# Use a local PostgreSQL server for demonstration purposes and create
# the "zero" database user.
sudo apt-get install -y postgresql
sudo su postgres -c "createuser -s zero"

# Normally we'd fetch database credentials and other secrets from a
# secure, external source. For this demonstration, we're using a local
# database server so we can connect without a password, and we can
# generate a random secret key base using `rake secret`.
sudo tee /srv/zero/.env <<EOF
DATABASE_NAME=zero_production
DATABASE_HOST=
DATABASE_USER=zero
DATABASE_PASSWORD=
EOF

echo "SECRET_KEY_BASE=$(bundle exec rake secret)" | sudo tee -a /srv/zero/.env

# Configure the database
cd /srv/zero
bundle exec rake db:setup

# Start application service
sudo cp /srv/zero/deploy/upstart.conf /etc/init/zero.conf
sudo start zero

# Add the nginx package repository
sudo tee /etc/apt/sources.list.d/nginx.list <<EOF
deb http://nginx.org/packages/ubuntu/ trusty nginx
deb-src http://nginx.org/packages/ubuntu/ trusty nginx
EOF

# Add the signing key for the nginx repo
cat <<EOF > /tmp/nginx_repo.key
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: GnuPG v2.0.22 (GNU/Linux)

mQENBE5OMmIBCAD+FPYKGriGGf7NqwKfWC83cBV01gabgVWQmZbMcFzeW+hMsgxH
W6iimD0RsfZ9oEbfJCPG0CRSZ7ppq5pKamYs2+EJ8Q2ysOFHHwpGrA2C8zyNAs4I
QxnZZIbETgcSwFtDun0XiqPwPZgyuXVm9PAbLZRbfBzm8wR/3SWygqZBBLdQk5TE
fDR+Eny/M1RVR4xClECONF9UBB2ejFdI1LD45APbP2hsN/piFByU1t7yK2gpFyRt
97WzGHn9MV5/TL7AmRPM4pcr3JacmtCnxXeCZ8nLqedoSuHFuhwyDnlAbu8I16O5
XRrfzhrHRJFM1JnIiGmzZi6zBvH0ItfyX6ttABEBAAG0KW5naW54IHNpZ25pbmcg
a2V5IDxzaWduaW5nLWtleUBuZ2lueC5jb20+iQE+BBMBAgAoAhsDBgsJCAcDAgYV
CAIJCgsEFgIDAQIeAQIXgAUCV2K1+AUJGB4fQQAKCRCr9b2Ce9m/YloaB/9XGrol
kocm7l/tsVjaBQCteXKuwsm4XhCuAQ6YAwA1L1UheGOG/aa2xJvrXE8X32tgcTjr
KoYoXWcdxaFjlXGTt6jV85qRguUzvMOxxSEM2Dn115etN9piPl0Zz+4rkx8+2vJG
F+eMlruPXg/zd88NvyLq5gGHEsFRBMVufYmHtNfcp4okC1klWiRIRSdp4QY1wdrN
1O+/oCTl8Bzy6hcHjLIq3aoumcLxMjtBoclc/5OTioLDwSDfVx7rWyfRhcBzVbwD
oe/PD08AoAA6fxXvWjSxy+dGhEaXoTHjkCbz/l6NxrK3JFyauDgU4K4MytsZ1HDi
MgMW8hZXxszoICTTiQEcBBABAgAGBQJOTkelAAoJEKZP1bF62zmo79oH/1XDb29S
YtWp+MTJTPFEwlWRiyRuDXy3wBd/BpwBRIWfWzMs1gnCjNjk0EVBVGa2grvy9Jtx
JKMd6l/PWXVucSt+U/+GO8rBkw14SdhqxaS2l14v6gyMeUrSbY3XfToGfwHC4sa/
Thn8X4jFaQ2XN5dAIzJGU1s5JA0tjEzUwCnmrKmyMlXZaoQVrmORGjCuH0I0aAFk
RS0UtnB9HPpxhGVbs24xXZQnZDNbUQeulFxS4uP3OLDBAeCHl+v4t/uotIad8v6J
SO93vc1evIje6lguE81HHmJn9noxPItvOvSMb2yPsE8mH4cJHRTFNSEhPW6ghmlf
Wa9ZwiVX5igxcvaIRgQQEQIABgUCTk5b0gAKCRDs8OkLLBcgg1G+AKCnacLb/+W6
cflirUIExgZdUJqoogCeNPVwXiHEIVqithAM1pdY/gcaQZmIRgQQEQIABgUCTk5f
YQAKCRCpN2E5pSTFPnNWAJ9gUozyiS+9jf2rJvqmJSeWuCgVRwCcCUFhXRCpQO2Y
Va3l3WuB+rgKjsQ=
=EWWI
-----END PGP PUBLIC KEY BLOCK-----
EOF

sudo apt-key add /tmp/nginx_repo.key
sudo apt-get update

# Configure nginx web server as reverse proxy
sudo apt-get -y install nginx

sudo rm /etc/nginx/conf.d/default.conf
sudo cp /srv/zero/deploy/nginx.conf /etc/nginx/conf.d/zero.conf

# Restart to pick up new configuration
sudo service nginx restart
```

## Next Steps

At this point we have a server running our Rails application, but we haven't addressed how to run these commands automatically, or deploy changes over time. There are also many other aspects of running a web application that we haven't considered:

* HTTPS: Currently our application will only respond to HTTP requests. Enabling HTTPS requires managing server certificates and changes to our nginx configuration.
* Log management. Although Upstart will handle log rotation, how to we preserve and search through our log files? What happens to logs when we add new servers or shut down existing ones? Our server should be configured to ship logs to a centralized location such as ELK server or an external service (e.g. Papertrail).
* Monitoring system performance. Are we over or under utilizing this server? Should we use a different size box for this application? Are we about to run out of disk space? Collecting and visualizing system metrics can help us answer these questions more easily.
* Alerting. How do we know when our application crashes? What happens if an unexpected user logs in? Are there any anomalies in resource usage?
* Secrets management. We avoided the issue here by using a local PostgreSQL database, but in more complex apps we'll often have multiple external services that we need credentials for. How are these credentials managed in a reliable, secure manner?
* Deployment. How do we run this process repeatedly? Do we have a fixed number of servers to configure, or does it scale dynamically?

These are all topics for many more blog posts, but for now I hope this article provides some value by showing one possible way to configure a production Rails server.
