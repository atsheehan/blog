---
layout: "article"
title: "Immutable Build for a Rails Application"
published_on: "2016-06-06"
---

This article describes how I set up an Ubuntu 14.04 server for hosting a Ruby on Rails application. In particular, it focuses on an *immutable* build of the application, meaning that once it has been built with a particular version, the application source code won't be updated. When I'm ready to deploy a new version, I'll use a new build and new servers to replace the existing ones.

## Purpose

Learning about and using Docker over the past year or so has been an incentive to learn more about immutable infrastructure. The ease of writing a Dockerfile to describe how to run an application in production directly influenced my approach when writing these shell scripts to configure a server.

The reason why I am not writing about Docker at this moment is that it seems like the ecosystem is still in a bit of flux at the moment. Rather than trying to pin down the best workflow using containers at the moment, I'd rather take some of the ideas promoted by Docker and apply them to the tools I'm using now.

This also isn't an argument for shell scripts over other configuration management tools like Chef and Puppet. Shell scripts are the most direct representation of what commands need to be run, but the ideas here can be used with any of the other tools mentioned.

## Goals

The goal is this article is to generate a single shell script that, when run from start to finish on a new Ubuntu 14.04 install, will configure the server to run a Ruby on Rails application. The script is only intended to be run once, and once the server is fully configured we'll take a snapshot of the filesystem so it can be created at will. If anything breaks during the configuration, we'll wipe out the server and start over.

### Prerequisites

This article assumes the following:

* We have shell access and sudo privileges to a server with a fresh install of Ubuntu 14.04. It is assumed that this server will only be used for running the Rails application.
* We have a Rails application that is ready to be deployed. The next section will describe a sample application used in this article and the steps taken to prepare it for a production deployment.
* We have the necessary connection info and credentials to any external services needed by the application. In the sample application we'll connect to an external PostgreSQL database.

## The Sample Ruby on Rails Application

To demonstrate the build process we'll use a [Stack Overflow](https://stackoverflow.com/) clone called [Zero Division](https://github.com/atsheehan/zero). And by clone, I mean a barebones question and answer site without all that additional fluff such as user authentication, fancy styling, or practical value of any kind.

Apart from the initial app creation with `rails new` and some basic [CRUD actions](https://en.wikipedia.org/wiki/Create,_read,_update_and_delete) for questions and answers, there are a few changes that were made to prepare for deployment.

### Logging to stdout

Rather than writing log messages to `log/production.log`, we'll send any output to the `stdout` stream. This way we don't have to deal with managing the log file ourselves and we can push this responsibility to the service running our application. For Ubuntu 14.04 we'll be using Upstart, which will capture `stdout` and save it to a file in the `/var/log/upstart` directory. The benefit of this approach is that Upstart will rotate the logs each day, compressing and deleting logs past a certain date.

The `gem "rails_12factor"` will handle this change automatically.

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

The `dotenv-rails` gem will handle reading credentials from a `.env` file into the environment when the application boots. The benefit of this approach is that by having the application load the `.env` file, we can launch our application outside the context of a shell that would normally handle setting environment variables from a user profile.

### Web server configuration

We'll use Puma as the web server for our application. [Puma is recommended by Heroku](https://devcenter.heroku.com/articles/rails4#running) and we'll end up copying their [configuration settings](https://devcenter.heroku.com/articles/deploying-rails-applications-with-the-puma-web-server#config).

The one addition to Heroku's puma configuration is to listen using a unix socket rather than listening over TCP. Since both the web server and application server are running on the same machine, we can avoid the overhead of the networking stack by using unix sockets.

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

Now that we have an Ubuntu 14.04 server and a sample application to deploy, let's cover the steps we'll take to configure this machine.

At a high level, we'll perform the following:

1. Updating any existing software and configure security updates
2. Install Ruby
3. Prepare Ruby on Rails application
4. Run application as a service
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

To enable the upgrades to run routinely, we need to add the following lines to `/etc/apt/apt.conf.d/20auto-upgrades`:

```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
```

We can do this automatically by running the following commands.

```
$ cat <<EOF > /tmp/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

$ sudo mv /tmp/20auto-upgrades /etc/apt/apt.conf.d
```

More info about configuring the unattended-upgrades package can be found on the [Debian wiki](https://wiki.debian.org/UnattendedUpgrades).

#### Aside: Is upgrading always a good idea?

Running `apt-get upgrade` will install new versions of any existing packages, fixing bugs and adding new features. Bug fixes and new features are usually a good thing, except when they introduce new bugs and break existing features.

One thing to consider is that anything not tracked by the package manager (e.g. applications or libraries compiled from source) won't be notified if their dependencies are updated. Usually we'd just have to restart these services so that they use the upgraded dependency, but sometimes it may require recompiling from scratch (e.g. custom kernel modules may need to be recompiled if the kernel is updated).

### Installing Ruby

To run a Ruby on Rails web application, we're going to need Ruby. There are two common methods for installation:

* Install a precompiled version using a package manager (e.g. `apt-get install ruby`)
* Build and install Ruby from the source code

There are a lot of benefits to using packages:

* Faster install without the compilation step
* Smaller footprint since we don't need any build dependencies
* Files and dependencies are controlled by the package manager
* Widely used and tested to ensure it plays nice with other packages

Ignoring all of that, we'll build Ruby from source. The primary reason is that we'll have more control over the specific version of Ruby to use so that it closely matches our development environment. If I'm building a Rails app using Ruby 2.3.1 on my laptop, I want to ensure that I'm running Ruby 2.3.1 in production too. Package repositories can sometimes lag a version or two behind the latest stable release.

<aside>
  <p>If you want the benefits of package management while also using the latest versions available, another approach would be to build your own Ruby package and store it in an internal repository avaiable to your servers. This requires a bit more work and infrastructure to setup, but could simplify deployment if you have a large number of applications or servers.</p>
</aside>

To build Ruby, we'll need to install a compiler and some other development dependencies. We can install these using the package manager.

```
$ sudo apt-get -y install autoconf bison build-essential libssl-dev \
    libreadline-dev zlib1g-dev libgdbm-dev
```

Next we need to get the source code.

```
$ wget https://cache.ruby-lang.org/pub/ruby/2.3/ruby-2.3.1.tar.gz
```

Unpack the archive.

```
$ tar zxf ruby-2.3.1.tar.gz
$ cd ruby-2.3.1/
```

Configure and build Ruby. Since we're not using this for development, we probably don't need the documentation.

```
$ ./configure --disable-install-doc
$ make
$ sudo make install
```

This will copy the Ruby binaries over to `/usr/local/bin`, installing Ruby system-wide. Since we're assuming the server is dedicated to running our web application, we don't need to deal with a Ruby version manager. Once the files are copied to `/usr/local/bin`, we can clean up our build directory.

```
$ cd $HOME
$ rm -rf ruby-2.3.1 ruby-2.3.1.tar.gz
```

We'll install the *bundler* gem so that we can bootstrap the gem installation process for our application. Again, since this is for production we don't need to include the documentation.

```
$ sudo gem install --no-document bundler
```

#### Aside: Why are these libraries necessary?

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

Some of these libraries are more important than others. The `tk` and `tk/tkutil` libraries are used for building GUI applications, so maybe they're not necessary for a web application. But `zlib` is commonly used for compression, including reading and writing gzip (.gz) files. Without this library, even the `gem` command will fail to work properly:<

```
$ sudo gem install --no-document bundler

ERROR:  Loading command: install (LoadError)
    cannot load such file -- zlib
ERROR:  While executing gem ... (NoMethodError)
    undefined method `invoke_with_build_args' for nil:NilClass
```

It's best to include support for this functionality since they are part of the standard library. Even if you don't use them directly in your application, any gems you use may rely on them.

### Preparing the Application

With Ruby installed, we can now start preparing our application for running in a production environment.

First we'll need to get the source code for our application on the server. This brings up two questions:

* How to get the source code onto the server?
* Where to store the source code?

For getting the source code, one option is to fetch it directly from a version control system (e.g. `git clone REPO`). This works well with public repositories, but if our source is private then we'll need to authenticate our server with the remote repository. This is often done using *readonly* deploy keys.

Before we go down that route, we should consider whether we actually need access to the remote repository. Since this is an immutable build, we're only going to be using one version of our source code. Our server does not need access to the entire history of the repository.

A simpler solution may be to package up the current version of the application in a tar file and copy it to the server. This avoids the need to authenticate our web server with the source repository since it would only be used during the build phase.

If using git, one way to package up an application is to use the `git archive` command. This concatenates all of the files in a branch into a single tar file. The benefit of this approach is that it only includes files that are committed to the repository, leaving behind any files that are local to your machine.

```
local$ git archive master -o tar.tar
local$ scp zero.tar user@server:/tmp/zero.tar
```

On the server, we can then move this file to our destination.

One benefit is that we don't have to give our server access to our remote repository. This may seem trivial, but if the server was compromised and the deploy key leaked, then someone would have access to our source code repository. Even if the access was readonly, they would be able to view the history of the application, including other branches with new features and bug-fixes that haven't been released yet. By removing the link from production servers to the source code repositories, it's one less security risk we have to worry about.

We now have the archived source code on the server, where should we unpack it? According to the [Filesystem Hierarchy Standard](http://www.pathname.com/fhs/pub/fhs-2.3.html#SRVDATAFORSERVICESPROVIDEDBYSYSTEM), the `/srv` directory can be used for services provided by this system.

```
$ sudo mkdir -p /srv/zero
$ sudo mv /tmp/zero.tar /srv/zero/zero.tar
$ cd /srv/zero
$ tar xf zero.tar
$ sudo rm zero.tar
```

Now that our source code is unpacked, we can install any dependencies our app needs. Some of the gems use C code that requires compilation, and some of these gems need additional development libraries. For this application we'll be using the `pg` gem, which requires the `libpq-dev` library. We'll also install `nodejs` which will be used by `uglifier` when we precompile our assets.

```
$ sudo apt-get install -y libpq-dev nodejs
```

Now we can go ahead and install any gems we need.

```
$ cd /srv/zero
$ bundle install --deployment --without development test
```

The [--deployment](http://bundler.io/v1.11/deploying.html#deploying-your-application) flag will install the gems in the `/srv/zero/vendor/bundle` directory, but more importantly it will require the use of `Gemfile.lock`. If for whatever reason this isn't committed to the repository, it will fail rather than installing arbitrary versions of the gems.

We also want to [precompile our assets](http://guides.rubyonrails.org/asset_pipeline.html#precompiling-assets) at this time.

```
$ sudo RAILS_ENV=production bundle exec rake assets:precompile
```

### Creating a User

Up until this point, we've been running our commands using `sudo`, so everything will be owned by the root user. But we don't want to run our Rails application as root. In the dire event that our application is compromised and a [malicious user is allowed to run arbitrary commands through our app](http://blog.codeclimate.com/blog/2013/01/10/rails-remote-code-execution-vulnerability-explained/), they'll be able to access whatever the user running the Rails application has access to. If that happens to the root user, that means they'll have access to everything on the server. To limit the amount of damage they can do, we need to limit what the application user can do.

Let's first create a new user to run our application. Since our application is called `zero`, we'll create a user with the same name.

```
$ sudo adduser --system --group --no-create-home --gecos '' zero
```

The `--system` flag will create a user without a shell and logins disabled, the `--gecos ''` option sets any personal information to an empty string, and the `--no-create-home` directory does what it says it does. By default a system user will belong to `nogroup`, but the `--group` flag will create the `zero` group for this user.

This new user will be running the Rails application, so it needs to be able to read the source code. But the source should be immutable, so our application user shouldn't be able to write to these files. One way we can enforce this is if we keep the owner of the source code as `root`, but change the group to `zero`. This way we can give the group readonly access without the ability to change the files.

Furthermore, if we remove read access from everyone else, then only the root and application users will be able to view the source for the application. If someone was to gain access to the server under the guise of a different user, they wouldn't be able to view the application source code.

```
# Set owner/group of source tree. root will still own the files, but
# add the application user's group
$ sudo chown -R root:zero /srv/zero

# Remove world read-write and group write access to the source
$ sudo chmod -R o-rwx /srv/zero
$ sudo chmod -R g-w /srv/zero
```

When we run nginx later, we'll have to give it access to the public directory so it can serve static assets. Here we can allow other users access view the top level directory and `public`.

```
# Allow everyone to view the top-level directory (but not any files).
$ sudo chmod o+rx /srv/zero

# Allow everyone to view the public directory.
$ sudo chmod -R o+r /srv/zero/public
```

There are two exceptions to our read-only source tree: the `tmp` and `log` directories need to be writeable by our application user.

We could change the owner of the `/srv/zero/tmp` directory so that it is writable by the application user. An alternative is to have the application write to a directory in `/var/tmp` instead. The `/var/tmp` directory may be better optimized for writing temp files and we can avoid filling up the `/srv` directory. By writing all of our temp files to one location, we can easily see where disk space is being used up by temp files.

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
Rails Error: Unable to access log file. Please ensure that /srv/zero/log/production.log exists and is writable (ie, make it writable for user and group: chmod 0664 /srv/zero/log/production.log). The log level has been raised to WARN and the output directed to STDERR until the problem is fixed.
```

We don't actually want to write anything to `production.log` since Upstart will log the output from `stdout` for us. What we can do is create a link to `/dev/null` so that Rails doesn't complain about the missing file.

```
# Provide a dummy log file. The actual logs will be capture from
# STDOUT and written to /var/log/upstart/zero.log
$ sudo ln -s /dev/null /srv/zero/log/production.log
```

### Managing Secrets

Most Rails applications need access to credentials for external services and secret keys used for authentication. These values are typically set through environment variables and are not included in the source code.

Managing these secrets is tricky, and I'm not entirely sure of the best way to handle them. The goal is to minimize their visibility. Although the source code for application may be shared throughout the company (or even public), the secrets necessary to run the application in production should be limited to only those who will be deploying and managing the operations. Likewise, minimizing the number of processes that have access to these secrets while running is helpful to minimize the chance of them being exposed if a server is compromised.

Our Rails application will read the database credentials and encryption keys from the environment. We'll use the `dotenv-rails` gem to load the environment variables from a file when the application starts up. We'll put the secrets in `/srv/zero/.env` as a series of `KEY=VALUE` pairs.

At a minimum, we need to set the following variables (replace the values with your own credentials):

```
DATABASE_NAME=zero_production
DATABASE_HOST=zero-production.host-name.rds.amazonaws.com
DATABASE_USER=zero
DATABASE_PASSWORD=super_secret_password_goes_here
SECRET_KEY_BASE=really_long_random_string_goes_here
```

The way I handle this is by creating the file locally, copying it to the server, then moving it to the appropriate directory.

```
local$ scp .env ubuntu@hostname:/tmp/.env
local$ ssh ubuntu@hostname
$ sudo mv /tmp/.env /srv/zero/.env
$ sudo chown root:zero /srv/zero/.env
$ sudo chmod 440 /srv/zero/.env
```

Again, this may not be the best solution. If we save any sensitive credentials to the filesystem and then take a snapshot of the server, we're baking our secrets into the server image. Anyone who has access to the server image can start it up and read these secrets from the filesystem.

Vault by Hashicorp. Adrian Mouat discusses some strategies in Using Docker.

bake them into the image
- easiest
- less external dependencies

- have to build a new image if any variables change
- cannot reuse image for different environments (e.g. staging vs production)

pass them in as user data
- more flexible
- user data is not encrypted, accessible to any user on the machine

access them from a secure, reliable storage
- s3 can be used

### Manually Starting the Server

We have our user and the application source, so let's verify that we can run the server. Our application user doesn't have a default shell configured, so when switching users we'll have to specify the shell command explicitly.

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

* Can instruct the application server to start on boot once the networking stack is available.
* It will restart on failure.
* Can be controlled via the `start` and `stop` commands.
* Capture and log STDOUT to the /var/log/upstart directory.
* Manages log rotation.
* Simple configuration.

To setup the service, we need to copy the following config file to `/etc/init/zero.conf`.

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

The `start on started networking` line indicates that this process should until the `networking` job is available.

If the server process crashes, we want it to `respawn`. If the server crashes more than 10 times in less than a minute, something is probably wrong so don't keep restarting (via `respawn limit 10 60`).

```
$ sudo cp /srv/zero/deploy/upstart.conf /etc/init/zero.conf
$ sudo start zero
```

If everything is working correctly, we can check the output of the service in `/var/log/zero.conf`.

```
$ sudo tail /var/log/upstart/zero.conf

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

<aside>
<h3>nginx vs. puma</h3>

<p>I don't actually know. nginx can serve static assets quickly. can't find a clear answer though. assume nginx is more resilient. lots of ways to send malformed requests. battle-hardened, build to handle malicious web traffic.</p>
</aside>


```
upstream app {
    server unix:///srv/zero/tmp/zero.sock;
}

server {
    listen *:80;
    root /srv/zero/public;

    location / {
        try_files $uri @app;
    }

    location /assets {
        expires max;
        add_header Cache-Control public;
    }

    location @app {
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_pass http://app;
    }

    error_page 404 /404.html;
    error_page 500 502 503 504 /500.html;
    client_max_body_size 4G;
    keepalive_timeout 10;
    server_tokens off;
}
```

And with that running, we should be able to visit our server running on ...!

## The Setup Script

First log into the server:

```
$ ssh -i /path/to/private/key.pem ubuntu@192.168.1.1
```

the complete file...

## TODO

At this point you can take a snapshot of the filesystem, either as an AMI if using AWS, ... If you start a new instance using this snapshot, the web application should start automatically. You can also use this image to scale out to multiple web servers behind a load balancer, or to quickly recover if one of the servers has a hardware failure. This is one of the benefits of immutable infrastructure.

Some areas we didn't consider:

* HTTPS. Currently our nginx is only configured to serve HTTP requests.
* Log management. Although Upstart will handle log rotation, when we deploy a new server and shut down the existing one, we lose all of our old logs. Our server should be configured to send logs to a centralized location such as ELK or Papertrail.
* Monitoring system performance. Are we over or under utilizing this server? Should we use a different size box for this application?
* Alerting. What happens if an unexpected user logs in? Are there any anomalies in resource usage?
* Deployment. How do

# TODO:
* verify that unattended-upgrades is working
* configure mail when new packages are installed.
* send mail about list changes https://wiki.debian.org/UnattendedUpgrades
* should we checksum the downloaded ruby code?


* http://serverfault.com/questions/472955/how-to-make-upstart-back-off-rather-than-give-up
