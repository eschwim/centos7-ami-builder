# centos7-ami-builder
A script to (nearly) fully automate the process of building Centos7 Amazon Machine Images (AMIs)

This script was largely inspired (and contains chunks of code from) Andrei Dragomir's Centos7 AMI scripts:

https://github.com/adragomir/centos-7-ami

It contains various bugfixes and usability improvements to this code, and should allow for the simplest 
provisioning of both PV and HVM AMI types.  Perhaps most importantly, it will allow you to create an
HVM AMI completely from scratch, without having to first create a PV AMI to clone from.

## Prerequisites

You will need:

* A RHEL/Centos 6/7 build machine (can be bare-metal or virtual; this script was tested extensively on a t2.micro AWS instance)
* 20 GB of free disk space on the builder machine (to store the raw machine image and its subsequent AMI bundle)
* Your AWS account ID (available at https://console.aws.amazon.com/billing/home?#/account)
* A S3 bucket to store your AMI in
* AWS IAM credentials (secret & access key) with read/write access to the aforementioned S3 bucket
* An AWS X.509 cert & private key (from https://console.aws.amazon.com/iam/home?#security_credential) to sign your AMI with

## Creating an AMI

* Log in to your build machine as root
* `git clone https://github.com/eschwim/centos7-ami-builder.git`
* `cd centos7-ami-builder/`
* `./centos7-ami-builder pv <your AMI name>` **or** `./centos7-ami-builder hvm <your AMI name>`

The first time that you run the script, you will be prompted to enter the various required configuration parameters.  You can change
these values for subsequent runs by running `./centos7-ami-builder reconfig`
