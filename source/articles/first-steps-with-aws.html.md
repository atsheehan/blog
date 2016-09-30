---
layout: "article"
title: "First Steps with Amazon Web Services"
published_on: "2016-09-29"
---

Amazon Web Services (AWS) offers an [overwhelming number of products](https://aws.amazon.com/products/) to the uninitiated. When first getting started, it's difficult to differentiate the useful services from the more esoteric ones. Even if you're only interested in using EC2 or S3, there are a handful of other services worth exploring for monitoring and protecting your AWS account. This article describes a few of the services I've found helpful and tips for managing your AWS account.

## Create a Billing Alert with CloudWatch

AWS often charges by usage rather than providing fixed fees. Each service has its own pricing model, and it's very easy to rack up a large bill if you're not paying attention to the costs of each resource. Even worse, if your AWS keys are compromised (e.g. accidentally pushed to GitHub), it's not uncommon for opportunistic Bitcoin miners to spin up a few hundred servers at your expense.

There isn't a way to limit the amount you want to spend each month, but you can [create a billing alert](http://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/monitor-charges.html) to monitor costs. The alert will email or text you once your accumulated monthly costs hit some threshold. This way you're not caught off guard by whatever bill comes your way at the end of the month.

Over time you'll get a sense of how much you spend each month, and you can setup alerts to ensure you're on the right trajectory. If you expect to spend $1,000/month, it might be helpful to setup a few billing alerts for $250/month, $500/month, and $750/month. You can expect the alerts to trigger at each week of the month, but if any of them trigger ahead of schedule then you have an early warning to investigate where the additional costs are coming from.

There is also the a new [Budgets feature](https://aws.amazon.com/blogs/aws/new-aws-budgets-and-forecasts/) which I haven't used much, but looks to support forecasting alerts as an option.

## Use Identity and Access Management to Create a Non-Root User (and Keep Your Access Keys to Yourself)

[Amazon recommends](http://docs.aws.amazon.com/general/latest/gr/root-vs-iam.html) using the [Identity and Access Management (IAM)](https://console.aws.amazon.com/iam/home) service to set yourself up with a non-root user account. Even if you're the only user and you give yourself full Administrative access, there are still some benefits from using IAM rather than your root credentials. AWS has several guides on how [to get started with IAM](http://docs.aws.amazon.com/IAM/latest/UserGuide/getting-started_create-admin-group.html).

One thing to remember is that your IAM user account has its own set of credentials. The access keys that you generate are for your user only. If someone else needs access to an AWS resource, you can create them their own user account with the appropriate permissions and they can use their own set of AWS keys. If you have an application running on an EC2 instance that needs to access some other AWS resource (e.g. a web application that needs to upload to S3), you can create a [**role**](http://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_common-scenarios_services.html) for that EC2 instance that gives it access to other resources without having to use your keys.

In short, you should treat your AWS access key and secret key as your username and password. You should keep them to private and secure; anyone who has those keys can act on your behalf using the AWK SDK.

In some cases, you need to access AWS from a non-EC2 instance (or one that is not under your control). For example, if you're using Heroku and you want to give your web dyno access to S3, you can't assign a role to the web dyno since you aren't responsible for creating them. In this case, I believe the recommended practice is to create a *separate user* for this application that has limited access to only the S3 bucket you care about and has its own set of AWS access keys.

## Log AWS Events with CloudTrail

You can monitor any activity on your account with [CloudTrail](https://console.aws.amazon.com/cloudtrail/home). This will log all actions taken in AWS account and who performed them, whether they are through the AWS web console, CLI, or SDK. The event logs are aggregated and stored in an S3 bucket within ~10 minutes of them occurring.

CloudTrail is helpful for auditing activity on your account, but also in the case where some access keys were compromised. You'll be able to see which user's keys were leaked so they can be disabled, and what resources were used so you know what to undo.

## Use AWS CLI Profiles to Manage Access Keys

I would recommend installing the [AWS CLI](https://aws.amazon.com/cli/). When starting out with AWS, I would rely on the web console for most tasks, but once I knew what I was doing I could save some time using the corresponding CLI command.

More importantly, it forced me to manage my AWS access keys a bit better. When using the AWS CLI or SDK, there is an [order of precedence](http://docs.aws.amazon.com/cli/latest/userguide/cli-chap-getting-started.html#config-settings-and-precedence) for where to find the access keys to authenticate:

1. Pass in the access key and secret key explicitly.
2. Check the `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` environment variables.
3. Read them from the `~/.aws/credentials` file (or `%UserProfile%\.aws\credentials` for Windows).

Initially, I would set the access keys in the `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` environment variables. This works well when dealing with a single AWS account, but if you have access to multiple accounts it can be easy to forget to change the environment variables. That sinking feeling when realizing you've run a command on the wrong account can leave a lasting impression.

The `~/.aws/credentials` file is more flexible since they allow **profiles**. You can store multiple sets of access keys and assign them profile names. When using the CLI, you have to be explicit about which account you're targeting.

To setup profiles and the `~/.aws/credentials` file, you can use the `aws configure` command with the `--profile` option.

```
$ aws configure --profile personal
AWS Access Key ID: AKPERSONALACCESSKEY
AWS Secret Access Key: PERSONALSECRETKEY
Default region name: us-east-1

$ aws configure --profile acme
AWS Access Key ID: AKACMEACCESSKEY
AWS Secret Access Key: ACMESECRETKEY
Default region name: us-east-1
```

This will save the credentials in `~/.aws/credentials` as such:

```
[personal]
aws_access_key_id = AKPERSONALACCESSKEY
aws_secret_access_key = PERSONALSECRETKEY

[acme]
aws_access_key_id =  AKACMEACCESSKEY
aws_secret_access_key = ACMESECRETKEY
```

Then, when you want to use the CLI, you specify the profile:

```
$ aws --profile acme ec2 describe-instances
```

You can even setup an alias in `~/.zshrc` or `~/.bashrc` to avoid having to type out the profile each time:

```
alias aws-personal=aws --profile personal
alias aws-acme-a=aws --profile acme
```

Then the command is shortened to:

```
$ aws-acme ec2 describe-instances
```

If you're using the AWS SDK, I believe most of them support the `AWS_PROFILE` environment variable which knows to look in `~/.aws/credentials`:

```
$ AWS_PROFILE=acme ruby do_something_with_sdk.rb
```

Note that the `~/.aws/credentials` file is not encrypted, so if anyone can read your home directory they can grab your keys from the `~/.aws/credentials` file. The best bet is: make sure no one can read your home directory. When you're logged in, make sure to lock your screen when you step away from your computer. If your computer is lost or stolen, having full-disk encryption enabled can mitigate the chances that someone will be able to recover your access keys.
